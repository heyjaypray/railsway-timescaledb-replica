#!/bin/bash
# บังคับให้ Output ทุกอย่าง (รวมถึง Error) ออกทาง stdout เพื่อไม่ให้ Railway แสดงผลเป็นสีแดง
exec 2>&1
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
    POOL_PASSWD="/etc/pool_passwd"
    
    # Generate MD5 password for Pgpool's internal auth
    # Format: username:md5(password + username)
    log "Generating pool_passwd..."
    echo "$POSTGRES_USER:$(echo -n "$POSTGRES_PASSWORD$POSTGRES_USER" | md5sum | awk '{print "md5"$1}')" > "$POOL_PASSWD"
    chown postgres:postgres "$POOL_PASSWD"
    chmod 600 "$POOL_PASSWD"

    cat > "$PGPOOL_CONF" <<EOF
listen_addresses = '*'
port = 5432
pcp_port = 9898
backend_hostname0 = '$PRIMARY_HOST'
backend_port0 = 5432
backend_flag0 = 'ALLOW_TO_FAILOVER'
backend_hostname1 = '$REPLICA_HOST'
backend_port1 = 5432
backend_flag1 = 'ALLOW_TO_FAILOVER'

backend_clustering_mode = 'streaming_replication'
load_balance_mode = on
master_slave_sub_mode = 'stream'

# Authentication Settings
enable_pool_hba = on
pool_passwd = '$POOL_PASSWD'

# Health Check Settings (สำคัญเพื่อให้ Proxy รู้ว่าตัวไหนเป็น Primary)
health_check_period = 10
health_check_timeout = 5
health_check_user = '$POSTGRES_USER'
health_check_password = '$POSTGRES_PASSWORD'

# Streaming Replication Check (สำหรับ Read/Write splitting)
sr_check_period = 10
sr_check_user = '$POSTGRES_USER'
sr_check_password = '$POSTGRES_PASSWORD'

# Connection Pool Settings
num_init_children = 32
max_pool = 4
child_life_time = 300
EOF

    echo "host all all 0.0.0.0/0 trust" > "$POOL_HBA"
    
    log "Waiting for Primary ($PRIMARY_HOST) connectivity..."
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
        log "Primary: Background maintenance task started."
        until psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select 1" > /dev/null 2>&1; do sleep 3; done
        
        log "Primary: Ensuring replication user and slot..."
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE USER $REPLICATION_USER WITH REPLICATION PASSWORD '$POSTGRES_PASSWORD';" > /dev/null 2>&1 || true
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_create_physical_replication_slot('replica_slot');" > /dev/null 2>&1 || true
        
        # ตรวจสอบและซ่อม pg_hba.conf
        if ! grep -q "replication $REPLICATION_USER" "$PG_DATA/pg_hba.conf"; then
            log "Primary: Updating pg_hba.conf..."
            # ใช้สิทธิ์ trust สำหรับ localhost เพื่อให้ maintenance สั่งงานได้ง่าย
            sed -i "1ihost replication $REPLICATION_USER 0.0.0.0/0 md5" "$PG_DATA/pg_hba.conf"
            sed -i "1ihost all all 0.0.0.0/0 md5" "$PG_DATA/pg_hba.conf"
            psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_reload_conf();" > /dev/null 2>&1
        fi
        log "Primary: Maintenance complete."
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
            warn "Backup failed, retrying..."
            sleep 5
        done
        
        # ตั้งค่า slot name ให้ถูกต้องตาม Postgres 12+
        echo "primary_conninfo = 'host=$PRIMARY_HOST port=5432 user=$REPLICATION_USER password=$POSTGRES_PASSWORD'" >> "$PG_DATA/postgresql.auto.conf"
        echo "primary_slot_name = 'replica_slot'" >> "$PG_DATA/postgresql.auto.conf"
        chown postgres:postgres "$PG_DATA/postgresql.auto.conf"
        log "Replica: Sync successful."
    fi
fi

# Auto-tuning
if [ -f "$PG_DATA/postgresql.conf" ]; then
    chmod 777 /tmp
    timescaledb-tune --quiet --yes --skip-backup --conf-path="$PG_DATA/postgresql.conf" --memory="${TS_TUNE_MEMORY:-1GB}" --cpus="${TS_TUNE_CORES:-1}" > /dev/null 2>&1 || true
    chown postgres:postgres "$PG_DATA/postgresql.conf"
fi

log "Booting TimescaleDB..."
exec docker-entrypoint.sh postgres
