#!/bin/bash
# บังคับให้ Output ทุกอย่างออกทาง stdout เพื่อแก้ปัญหาสีแดงใน Railway
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
    
    # Generate MD5 password for Pgpool backend auth
    log "Generating pool_passwd (MD5)..."
    PASS_HASH=$(printf "%s%s" "$POSTGRES_PASSWORD" "$POSTGRES_USER" | md5sum | awk '{print $1}')
    echo "$POSTGRES_USER:md5$PASS_HASH" > "$POOL_PASSWD"
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

# Authentication
enable_pool_hba = on
pool_passwd = '$POOL_PASSWD'

# Health Check & Replication Check
health_check_period = 10
health_check_timeout = 20
health_check_user = '$POSTGRES_USER'
health_check_password = '$POSTGRES_PASSWORD'

# Streaming Replication Check
sr_check_period = 10
sr_check_user = '$POSTGRES_USER'
sr_check_password = '$POSTGRES_PASSWORD'

# Connection Pool Settings
num_init_children = 32
max_pool = 4
child_life_time = 300
EOF

    echo "host all all 0.0.0.0/0 trust" > "$POOL_HBA"
    
    log "Waiting for Primary ($PRIMARY_HOST) to be ready..."
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
        log "Primary: Background maintenance worker started."
        # เชื่อมต่อผ่าน Unix Socket (ไม่ต้องระบุ -h)
        until psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select 1" > /dev/null 2>&1; do sleep 3; done
        
        log "Primary: Configuring roles and slots..."
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE USER $REPLICATION_USER WITH REPLICATION PASSWORD '$POSTGRES_PASSWORD';" > /dev/null 2>&1 || true
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_create_physical_replication_slot('replica_slot');" > /dev/null 2>&1 || true
        
        # ตรวจสอบและซ่อม pg_hba.conf
        if ! grep -q "replication $REPLICATION_USER" "$PG_DATA/pg_hba.conf"; then
            log "Primary: Repairing pg_hba.conf to allow internal and replication connections..."
            # กฎบรรทัดบนสุด: อนุญาตให้ลอคอลเชื่อมต่อได้โดยตรง และคนนอกต้องใช้รหัสผ่าน
            sed -i "1ilocal all all trust" "$PG_DATA/pg_hba.conf"
            sed -i "2ihost replication $REPLICATION_USER 0.0.0.0/0 md5" "$PG_DATA/pg_hba.conf"
            sed -i "3ihost all all 0.0.0.0/0 md5" "$PG_DATA/pg_hba.conf"
            psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_reload_conf();" > /dev/null 2>&1
        fi
        log "Primary: Setup finished successfully."
    ) &
fi

# --- REPLICA SYNC ---
if [ "$NODE_ROLE" = "REPLICA" ]; then
    if [ ! -s "$PG_DATA/PG_VERSION" ]; then
        log "Replica: Waiting for Primary ($PRIMARY_HOST)..."
        until pg_isready -h "$PRIMARY_HOST" -p 5432 > /dev/null 2>&1; do sleep 5; done

        log "Replica: Syncing data from primary..."
        rm -rf "$PG_DATA"/*
        until PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup -h "$PRIMARY_HOST" -D "$PG_DATA" -U "$REPLICATION_USER" -v -R --slot=replica_slot; do
            warn "Sync failed, retrying..."
            sleep 5
        done
        
        echo "primary_conninfo = 'host=$PRIMARY_HOST port=5432 user=$REPLICATION_USER password=$POSTGRES_PASSWORD'" >> "$PG_DATA/postgresql.auto.conf"
        echo "primary_slot_name = 'replica_slot'" >> "$PG_DATA/postgresql.auto.conf"
        chown postgres:postgres "$PG_DATA/postgresql.auto.conf"
        log "Replica: Synchronized."
    fi
fi

# บังคับคอนฟิกที่สำคัญ (แก้ปัญหาสีแดงและประสิทธิภาพ)
if [ -f "$PG_DATA/postgresql.conf" ]; then
    # ปิด logging_collector เพื่อให้ log ออก stdout ตรงๆ (ลดสีแดงใน Railway)
    sed -i "s/^logging_collector.*/logging_collector = off/" "$PG_DATA/postgresql.conf" || true
    echo "logging_collector = off" >> "$PG_DATA/postgresql.conf"
    
    chmod 777 /tmp
    timescaledb-tune --quiet --yes --skip-backup --conf-path="$PG_DATA/postgresql.conf" --memory="${TS_TUNE_MEMORY:-1GB}" --cpus="${TS_TUNE_CORES:-1}" > /dev/null 2>&1 || true
    chown postgres:postgres "$PG_DATA/postgresql.conf"
fi

log "Booting TimescaleDB..."
# บังคับรันแบบปิด logging_collector อีกครั้งเพื่อความชัวร์
exec docker-entrypoint.sh postgres -c logging_collector=off
