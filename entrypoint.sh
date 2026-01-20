#!/bin/bash
set -e

# Logging functions
log() { echo -e "\033[0;32m[Timescale-$NODE_ROLE]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

log "Starting entrypoint script..."

# -------------------------------------------------------------------------
# PROXY ROLE (Pgpool-II)
# -------------------------------------------------------------------------
if [ "$NODE_ROLE" = "PROXY" ]; then
    log "Configuring Pgpool Proxy..."
    mkdir -p /var/run/pgpool
    chown -R postgres:postgres /var/run/pgpool || true

    PGPOOL_CONF="/etc/pgpool.conf"
    POOL_HBA="/etc/pool_hba.conf"
    
    cat > "$PGPOOL_CONF" <<EOF
listen_addresses = '*'
port = 5432
pcp_port = 9898
backend_hostname0 = '$PRIMARY_HOST'
backend_port0 = 5432
backend_hostname1 = '$REPLICA_HOST'
backend_port1 = 5432
backend_clustering_mode = 'streaming_replication'
load_balance_mode = on
master_slave_sub_mode = 'stream'
health_check_period = 10
health_check_user = '$POSTGRES_USER'
health_check_password = '$POSTGRES_PASSWORD'
EOF

    echo "host all all 0.0.0.0/0 trust" > "$POOL_HBA"
    
    log "Waiting for Primary ($PRIMARY_HOST)..."
    until pg_isready -h "$PRIMARY_HOST" -p 5432 > /dev/null 2>&1; do sleep 5; done
    
    log "Launching Pgpool-II..."
    exec pgpool -n -f "$PGPOOL_CONF" -a "$POOL_HBA"
fi

# -------------------------------------------------------------------------
# DATABASE ROLES (PRIMARY/REPLICA)
# -------------------------------------------------------------------------
PG_DATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"
mkdir -p "$(dirname "$PG_DATA")"
chown -R postgres:postgres /var/lib/postgresql/data

# --- PRIMARY MAINTENANCE ---
if [ "$NODE_ROLE" = "PRIMARY" ]; then
    (
        log "Primary: Waiting for DB to be ready for setup..."
        until psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select 1" > /dev/null 2>&1; do sleep 3; done
        
        log "Primary: Setting up replication user..."
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE USER $REPLICATION_USER WITH REPLICATION PASSWORD '$POSTGRES_PASSWORD';" || true
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_create_physical_replication_slot('replica_slot');" || true
        
        log "Primary: Updating pg_hba.conf..."
        if ! grep -q "replication $REPLICATION_USER" "$PG_DATA/pg_hba.conf"; then
            echo "host replication $REPLICATION_USER 0.0.0.0/0 md5" >> "$PG_DATA/pg_hba.conf"
            echo "host all all 0.0.0.0/0 md5" >> "$PG_DATA/pg_hba.conf"
            psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_reload_conf();"
        fi
        log "Primary: Setup complete."
    ) &
fi

# --- REPLICA SYNC ---
if [ "$NODE_ROLE" = "REPLICA" ]; then
    if [ ! -s "$PG_DATA/PG_VERSION" ]; then
        log "Replica: Waiting for Primary ($PRIMARY_HOST)..."
        until pg_isready -h "$PRIMARY_HOST" -p 5432 > /dev/null 2>&1; do sleep 5; done

        log "Replica: Starting base backup..."
        rm -rf "$PG_DATA"/*
        until PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup -h "$PRIMARY_HOST" -D "$PG_DATA" -U "$REPLICATION_USER" -v -R --slot=replica_slot; do
            warn "Backup failed, retrying (Primary might be initializing)..."
            sleep 5
        done
        
        # Correct parameter name is 'primary_slot_name' (not replication_slot)
        echo "primary_conninfo = 'host=$PRIMARY_HOST port=5432 user=$REPLICATION_USER password=$POSTGRES_PASSWORD'" >> "$PG_DATA/postgresql.auto.conf"
        echo "primary_slot_name = 'replica_slot'" >> "$PG_DATA/postgresql.auto.conf"
        chown postgres:postgres "$PG_DATA/postgresql.auto.conf"
        log "Replica: Initial sync success."
    fi
fi

log "Booting TimescaleDB..."
exec docker-entrypoint.sh postgres
