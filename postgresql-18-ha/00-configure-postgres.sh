#!/bin/bash
# Configure PostgreSQL BEFORE the main server starts
# This script runs during initdb phase

# ── Auto-detect available RAM and calculate tuning parameters ──
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))

# shared_buffers: 25% of RAM (PostgreSQL recommendation)
SHARED_BUFFERS_MB=$((TOTAL_RAM_MB / 4))
# Minimum 256MB, cap at 8GB (diminishing returns above that)
[ "$SHARED_BUFFERS_MB" -lt 256 ] && SHARED_BUFFERS_MB=256
[ "$SHARED_BUFFERS_MB" -gt 8192 ] && SHARED_BUFFERS_MB=8192

# effective_cache_size: 75% of RAM (shared_buffers + OS page cache)
EFFECTIVE_CACHE_MB=$((TOTAL_RAM_MB * 3 / 4))
[ "$EFFECTIVE_CACHE_MB" -lt 512 ] && EFFECTIVE_CACHE_MB=512

# work_mem: RAM / (max_connections * 4) — conservative to avoid OOM
WORK_MEM_MB=$((TOTAL_RAM_MB / 1200))
[ "$WORK_MEM_MB" -lt 4 ] && WORK_MEM_MB=4
[ "$WORK_MEM_MB" -gt 64 ] && WORK_MEM_MB=64

# maintenance_work_mem: 5% of RAM (for VACUUM, CREATE INDEX)
MAINT_WORK_MEM_MB=$((TOTAL_RAM_MB / 20))
[ "$MAINT_WORK_MEM_MB" -lt 64 ] && MAINT_WORK_MEM_MB=64
[ "$MAINT_WORK_MEM_MB" -gt 2048 ] && MAINT_WORK_MEM_MB=2048

echo "PostgreSQL auto-tuning: RAM=${TOTAL_RAM_MB}MB shared_buffers=${SHARED_BUFFERS_MB}MB effective_cache=${EFFECTIVE_CACHE_MB}MB work_mem=${WORK_MEM_MB}MB maintenance_work_mem=${MAINT_WORK_MEM_MB}MB"

# Append to postgresql.conf for pg_cron support, replication, and performance
cat >> "$PGDATA/postgresql.conf" <<EOF
max_connections = 300
shared_preload_libraries = 'pg_stat_statements,pg_cron'
cron.database_name = '${POSTGRES_DB:-postgres}'
password_encryption = scram-sha-256
logging_collector = off
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 1GB
# Cap WAL retained for a single slot. Without this (-1 = unlimited) an
# orphaned/abandoned slot — e.g. a removed or renumbered replica whose slot is
# never dropped — retains WAL forever and fills the volume. Past this bound the
# slot is invalidated (marked 'lost') and its WAL becomes reclaimable, trading a
# stale replica's resync for a bounded disk. Keep comfortably above wal_keep_size.
max_slot_wal_keep_size = 4GB
hot_standby = on
# Required for pg_rewind-based failback (rejoining an old primary as a standby)
wal_log_hints = on

# ── Memory tuning (auto-detected: ${TOTAL_RAM_MB}MB total RAM) ──
shared_buffers = ${SHARED_BUFFERS_MB}MB
effective_cache_size = ${EFFECTIVE_CACHE_MB}MB
work_mem = ${WORK_MEM_MB}MB
maintenance_work_mem = ${MAINT_WORK_MEM_MB}MB

# ── Planner tuning (Railway uses SSDs) ──
random_page_cost = 1.1
effective_io_concurrency = 200
EOF

# Configure pg_hba.conf with replication rules (including IPv6 for Railway)
cat > "$PGDATA/pg_hba.conf" <<EOF
# Local connections
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust

# Railway internal networks (IPv4 and IPv6)
host    all             all             10.0.0.0/8              trust
host    all             all             100.64.0.0/10           trust
host    all             all             fd00::/8                trust

# Replication connections (password required)
host    replication     all             0.0.0.0/0               scram-sha-256
host    replication     all             ::/0                    scram-sha-256

# External connections (password required)
host    all             all             0.0.0.0/0               scram-sha-256
host    all             all             ::/0                    scram-sha-256
EOF

echo "PostgreSQL configured with replication support and IPv6 pg_hba rules"
