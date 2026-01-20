#!/bin/bash
# บังคับ Log ทุกอย่างออก stdout ตั้งแต่บรรทัดแรก (แก้ปัญหาสีแดงใน Railway)
exec 2>&1
set -e

# Logging colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[Timescale-$NODE_ROLE]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

log "Booting entrypoint script..."

# -------------------------------------------------------------------------
# PROXY ROLE (Pgpool-II)
# -------------------------------------------------------------------------
if [ "$NODE_ROLE" = "PROXY" ]; then
    log "Configuring Pgpool..."
    mkdir -p /var/run/pgpool
    chown -R postgres:postgres /var/run/pgpool || true

    PGPOOL_CONF="/etc/pgpool.conf"
    POOL_HBA="/etc/pool_hba.conf"
    POOL_PASSWD="/etc/pool_passwd"
    
    # สร้าง pool_passwd ทุกครั้งที่บูต เพื่อรองรับการเปลี่ยนรหัสผ่าน
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
enable_pool_hba = on
pool_passwd = '$POOL_PASSWD'
health_check_period = 10
health_check_timeout = 20
health_check_user = '$POSTGRES_USER'
health_check_password = '$POSTGRES_PASSWORD'
sr_check_period = 10
sr_check_user = '$POSTGRES_USER'
sr_check_password = '$POSTGRES_PASSWORD'
num_init_children = 32
max_pool = 4
EOF

    echo "host all all 0.0.0.0/0 trust" > "$POOL_HBA"
    
    log "Waiting for Primary ($PRIMARY_HOST) for Proxy startup..."
    until pg_isready -h "$PRIMARY_HOST" -p 5432 > /dev/null 2>&1; do sleep 5; done
    
    log "Launching Pgpool-II..."
    exec pgpool -n -f "$PGPOOL_CONF" -a "$POOL_HBA" 2>&1
fi

# -------------------------------------------------------------------------
# DATABASE ROLES (PRIMARY/REPLICA)
# -------------------------------------------------------------------------
PG_DATA="${PGDATA:-/var/lib/postgresql/data/pgdata}"
mkdir -p "$(dirname "$PG_DATA")"
chown -R postgres:postgres /var/lib/postgresql/data

# --- PRIMARY MAINTENANCE & PASSWORD SYNC ---
if [ "$NODE_ROLE" = "PRIMARY" ]; then
    (
        log "Primary: Background maintenance started."
        until psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select 1" > /dev/null 2>&1; do sleep 3; done
        
        log "Primary: Syncing passwords with environment variables..."
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "ALTER USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';"
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE USER $REPLICATION_USER WITH REPLICATION PASSWORD '$POSTGRES_PASSWORD';" > /dev/null 2>&1 || \
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "ALTER USER $REPLICATION_USER WITH REPLICATION PASSWORD '$POSTGRES_PASSWORD';"
        
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_create_physical_replication_slot('replica_slot');" > /dev/null 2>&1 || true
        
        log "Primary: Finalizing pg_hba.conf..."
        cat > "$PG_DATA/pg_hba.conf" <<EOF
local   all             all                                     trust
host    replication     $REPLICATION_USER       0.0.0.0/0       md5
host    all             all                     0.0.0.0/0       md5
EOF
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_reload_conf();"
        log "Primary: Readiness check complete."
    ) &
fi

# --- REPLICA SYNC & AUTO-UPDATE ---
if [ "$NODE_ROLE" = "REPLICA" ]; then
    # กรณีบูตครั้งแรก (ไม่มีข้อมูล)
    if [ ! -s "$PG_DATA/PG_VERSION" ]; then
        log "Replica: Initializing base backup from $PRIMARY_HOST..."
        until pg_isready -h "$PRIMARY_HOST" -p 5432 > /dev/null 2>&1; do sleep 5; done
        rm -rf "$PG_DATA"/*
        until PGPASSWORD="$POSTGRES_PASSWORD" pg_basebackup -h "$PRIMARY_HOST" -D "$PG_DATA" -U "$REPLICATION_USER" -v -R --slot=replica_slot; do
            warn "Backup failed, retrying..."
            sleep 5
        done
        log "Replica: Initial sync success."
    fi

    # กรณี Restart/Redeploy: อัปเดตข้อมูลการเชื่อมต่อเสมอ (เผื่อรหัสผ่านเปลี่ยน)
    log "Replica: Updating connection info (primary_conninfo)..."
    # ลบค่าเก่าออกก่อนและเขียนใหม่เพื่อความเป๊ะ
    sed -i "/^primary_conninfo/d" "$PG_DATA/postgresql.auto.conf" || true
    sed -i "/^primary_slot_name/d" "$PG_DATA/postgresql.auto.conf" || true
    echo "primary_conninfo = 'host=$PRIMARY_HOST port=5432 user=$REPLICATION_USER password=$POSTGRES_PASSWORD'" >> "$PG_DATA/postgresql.auto.conf"
    echo "primary_slot_name = 'replica_slot'" >> "$PG_DATA/postgresql.auto.conf"
    chown postgres:postgres "$PG_DATA/postgresql.auto.conf"
fi

# Shared Tuning & Logging Configuration
if [ -f "$PG_DATA/postgresql.conf" ]; then
    # บังคับปิด logging_collector เพื่อให้ Log ออก stdout (แก้ปัญหาสีแดง)
    sed -i "s/^logging_collector.*/logging_collector = off/" "$PG_DATA/postgresql.conf" || true
    chmod 777 /tmp
    timescaledb-tune --quiet --yes --skip-backup --conf-path="$PG_DATA/postgresql.conf" --memory="${TS_TUNE_MEMORY:-1GB}" --cpus="${TS_TUNE_CORES:-1}" > /dev/null 2>&1 || true
    chown postgres:postgres "$PG_DATA/postgresql.conf"
fi

log "Booting PostgreSQL..."
exec docker-entrypoint.sh postgres -c logging_collector=off 2>&1
