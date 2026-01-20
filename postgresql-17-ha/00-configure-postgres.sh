#!/bin/bash
# Configure PostgreSQL BEFORE the main server starts
# This script runs during initdb phase

# Append to postgresql.conf for pg_cron support
echo "shared_preload_libraries = 'pg_stat_statements,pg_cron'" >> "$PGDATA/postgresql.conf"
echo "cron.database_name = '${POSTGRES_DB:-postgres}'" >> "$PGDATA/postgresql.conf"
echo "password_encryption = scram-sha-256" >> "$PGDATA/postgresql.conf"
echo "logging_collector = off" >> "$PGDATA/postgresql.conf"
