#!/bin/bash
# 1. Force Log to stdout (Fix red logs in Railway)
exec 2>&1
set -e

# Logging colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[Postgres-HA-$NODE_ROLE]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Default values for environment variables
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
REPLICATION_USER="${REPLICATION_USER:-replicator}"
REPLICA_ID="${REPLICA_ID:-1}"
MAX_REPLICAS="${MAX_REPLICAS:-2}"

# Performance tuning defaults (optimized for fast reads)
READ_WEIGHT_PRIMARY="${READ_WEIGHT_PRIMARY:-0}"
READ_WEIGHT_REPLICA="${READ_WEIGHT_REPLICA:-1}"
DELAY_THRESHOLD_BYTES="${DELAY_THRESHOLD_BYTES:-1000000}"
ENABLE_QUERY_CACHE="${ENABLE_QUERY_CACHE:-on}"
QUERY_CACHE_SIZE="${QUERY_CACHE_SIZE:-67108864}"
LOAD_BALANCE_ON_WRITE="${LOAD_BALANCE_ON_WRITE:-transaction}"

log "Booting PostgreSQL 18 HA Entrypoint..."
log "Config: USER=$POSTGRES_USER, DB=$POSTGRES_DB, REPL_USER=$REPLICATION_USER"

# -------------------------------------------------------------------------
# PROXY ROLE (Pgpool-II)
# -------------------------------------------------------------------------
if [ "$NODE_ROLE" = "PROXY" ]; then
    log "Configuring Pgpool-II Proxy..."
    mkdir -p /var/run/pgpool /var/log/pgpool
    chown -R postgres:postgres /var/run/pgpool /var/log/pgpool || true

    PGPOOL_CONF="/etc/pgpool.conf"
    
    # Escape single quotes in password for config safety
    ESCAPED_PASSWORD=$(printf '%s' "$POSTGRES_PASSWORD" | sed "s/'/''/g")
    
    cat > "$PGPOOL_CONF" <<EOF
listen_addresses = '*'
port = 5432
pcp_port = 9898

# Backend nodes (weights optimized for read-heavy workloads)
backend_hostname0 = '$PRIMARY_HOST'
backend_port0 = 5432
backend_weight0 = $READ_WEIGHT_PRIMARY
backend_flag0 = 'ALLOW_TO_FAILOVER'

backend_hostname1 = '$REPLICA_HOST'
backend_port1 = 5432
backend_weight1 = $READ_WEIGHT_REPLICA
backend_flag1 = 'ALLOW_TO_FAILOVER'
EOF

    # Add second replica if REPLICA_HOST_2 is set
    if [ -n "$REPLICA_HOST_2" ]; then
        log "Adding second replica: $REPLICA_HOST_2"
        cat >> "$PGPOOL_CONF" <<EOF

backend_hostname2 = '$REPLICA_HOST_2'
backend_port2 = 5432
backend_weight2 = $READ_WEIGHT_REPLICA
backend_flag2 = 'ALLOW_TO_FAILOVER'
EOF
    fi

    cat >> "$PGPOOL_CONF" <<EOF

backend_clustering_mode = 'streaming_replication'
load_balance_mode = on

# Session handling for pgx/Go compatibility
statement_level_load_balance = on
disable_load_balance_on_write = '$LOAD_BALANCE_ON_WRITE'
allow_sql_comments = on

# Authentication: Pass-through
enable_pool_hba = off
pool_passwd = ''
allow_clear_text_frontend_auth = on

# Health Check & SR Check
health_check_period = 5
health_check_timeout = 20
health_check_user = '$POSTGRES_USER'
health_check_password = '$ESCAPED_PASSWORD'
health_check_database = '$POSTGRES_DB'
health_check_max_retries = 5
health_check_retry_delay = 2
auto_failback = on
auto_failback_interval = 30

sr_check_period = 5
sr_check_user = '$POSTGRES_USER'
sr_check_password = '$ESCAPED_PASSWORD'
sr_check_database = '$POSTGRES_DB'
delay_threshold = $DELAY_THRESHOLD_BYTES

# Logging
log_min_messages = warning

# Connection pooling
num_init_children = 32
max_pool = 4
child_life_time = 300
connection_life_time = 0
client_idle_limit = 0

# Memory cache for faster repeated reads
memory_cache_enabled = $ENABLE_QUERY_CACHE
memqcache_method = 'shmem'
memqcache_total_size = $QUERY_CACHE_SIZE
memqcache_max_num_cache = 1000000
memqcache_expire = 60
memqcache_auto_cache_invalidation = on
memqcache_maxcache = 409600
EOF

    log "Waiting for Primary ($PRIMARY_HOST)..."
    until pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$POSTGRES_USER" > /dev/null 2>&1; do sleep 5; done
    
    log "Launching Pgpool-II..."
    exec pgpool -n -f "$PGPOOL_CONF" 2>&1
fi

# -------------------------------------------------------------------------
# DATABASE ROLES (PRIMARY/REPLICA)
# -------------------------------------------------------------------------
PG_DATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"
mkdir -p "$(dirname "$PG_DATA")"
chown -R postgres:postgres /var/lib/postgresql/data

# --- PRIMARY SETUP WITH RESILIENCE ---
if [ "$NODE_ROLE" = "PRIMARY" ]; then
    (
        set +e
        log "Primary: Background maintenance thread started."
        
        while true; do
            if pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" > /dev/null 2>&1; then
                log "Primary: Server is ready. Running maintenance tasks..."
                
                # Escape single quotes in password for SQL safety
                ESCAPED_PWD=$(printf '%s' "$POSTGRES_PASSWORD" | sed "s/'/''/g")
                
                psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOSQL 2>&1
-- Sync main user password
ALTER USER "$POSTGRES_USER" WITH PASSWORD '$ESCAPED_PWD';

-- Ensure replication user exists
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$REPLICATION_USER') THEN
        CREATE USER "$REPLICATION_USER" WITH REPLICATION PASSWORD '$ESCAPED_PWD';
    ELSE
        ALTER USER "$REPLICATION_USER" WITH REPLICATION PASSWORD '$ESCAPED_PWD';
    END IF;
END \$\$;

-- Replication Slots for multiple replicas
DO \$\$
DECLARE
    slot TEXT;
BEGIN
    FOR i IN 1..$MAX_REPLICAS LOOP
        slot := 'replica_slot_' || i;
        IF NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = slot) THEN
            PERFORM pg_create_physical_replication_slot(slot);
            RAISE NOTICE 'Created replication slot: %', slot;
        END IF;
    END LOOP;
END \$\$;

-- Configure for better replication
ALTER SYSTEM SET wal_keep_size = '1GB';
ALTER SYSTEM SET max_replication_slots = 10;
ALTER SYSTEM SET max_wal_senders = 10;

-- pg_cron extension (requires shared_preload_libraries, only works after real server start)
CREATE EXTENSION IF NOT EXISTS "pg_cron";
EOSQL

                if [ $? -eq 0 ]; then
                    log "Primary: User, replication, and extension configuration successful."
                    # Apply final HBA rules
                    cat > "$PG_DATA/pg_hba.conf" <<EOF
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    all             all             10.0.0.0/8              trust
host    all             all             100.64.0.0/10           trust
host    all             all             fd00::/8                trust
host    replication     all             0.0.0.0/0               scram-sha-256
host    replication     all             ::/0                    scram-sha-256
host    all             all             0.0.0.0/0               scram-sha-256
host    all             all             ::/0                    scram-sha-256
EOF
                    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_reload_conf();" > /dev/null 2>&1
                    log "Primary: Maintenance task completed."
                    break
                else
                    warn "Primary: SQL tasks encountered an error, retrying in 5s..."
                fi
            fi
            sleep 5
        done
    ) &
fi

# --- REPLICA SETUP ---
if [ "$NODE_ROLE" = "REPLICA" ]; then
    SLOT_NAME="replica_slot_${REPLICA_ID}"
    APP_NAME="replica${REPLICA_ID}"
    
    log "Replica $REPLICA_ID: Initializing sync logic using slot '$SLOT_NAME'..."
    
    if [ ! -s "$PG_DATA/PG_VERSION" ]; then
        log "Replica $REPLICA_ID: Cloning data from $PRIMARY_HOST..."
        until pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$POSTGRES_USER" > /dev/null 2>&1; do sleep 5; done
        rm -rf "$PG_DATA"/*
        until PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup -h "$PRIMARY_HOST" -D "$PG_DATA" -U "$REPLICATION_USER" -v -R --slot=$SLOT_NAME --checkpoint=fast; do
            warn "Waiting for primary to be ready for backup..."
            sleep 10
        done
        log "Replica $REPLICA_ID: Sync complete."
    fi
    
    # Update postgresql.auto.conf with unique slot based on REPLICA_ID
    ESCAPED_PWD=$(printf '%s' "$POSTGRES_PASSWORD" | sed "s/'/''/g")
    
    sed -i '/^primary_conninfo/d' "$PG_DATA/postgresql.auto.conf" 2>/dev/null || true
    sed -i '/^primary_slot_name/d' "$PG_DATA/postgresql.auto.conf" 2>/dev/null || true
    echo "primary_conninfo = 'host=$PRIMARY_HOST port=5432 user=$REPLICATION_USER password=$ESCAPED_PWD application_name=$APP_NAME'" >> "$PG_DATA/postgresql.auto.conf"
    echo "primary_slot_name = '$SLOT_NAME'" >> "$PG_DATA/postgresql.auto.conf"
    
    # Ensure standby.signal exists
    touch "$PG_DATA/standby.signal"
    chown postgres:postgres "$PG_DATA/postgresql.auto.conf" "$PG_DATA/standby.signal"
fi

log "Starting PostgreSQL 18 HA node in $NODE_ROLE mode..."
exec docker-entrypoint.sh postgres -c logging_collector=off 2>&1
