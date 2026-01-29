#!/bin/bash
# Configure PostgreSQL BEFORE the main server starts
# This script runs during initdb phase

# Append to postgresql.conf for pg_cron support and replication
cat >> "$PGDATA/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_stat_statements,pg_cron'
cron.database_name = '${POSTGRES_DB:-postgres}'
password_encryption = scram-sha-256
logging_collector = off
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 1GB
hot_standby = on
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
