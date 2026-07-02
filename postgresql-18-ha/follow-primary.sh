#!/bin/bash
# follow-primary.sh — pgpool follow_primary_command.
# Invoked by Pgpool-II ON THE PROXY once per remaining standby after a primary
# failover, to re-point that standby at the newly promoted primary.
# Configured in pgpool.conf as:
#   follow_primary_command = '/usr/local/bin/follow-primary.sh %d %h %H %m'
#     $1 = %d  node id to reconfigure
#     $2 = %h  its hostname
#     $3 = %H  new primary hostname
#     $4 = %m  new main (primary) node id
#
# primary_conninfo is reloadable since PG13, so re-pointing needs only a
# reload, not a restart.
set +e
TARGET_NODE_ID="$1"
TARGET_HOST="$2"
NEW_PRIMARY_HOST="$3"
NEW_PRIMARY_ID="$4"
TAG="[HA-FOLLOW]"

echo "$TAG node=$TARGET_NODE_ID host=$TARGET_HOST new_primary=$NEW_PRIMARY_HOST"

# Never reconfigure the new primary itself.
[ "$TARGET_NODE_ID" = "$NEW_PRIMARY_ID" ] && exit 0
[ -z "$TARGET_HOST" ] && exit 0
[ -z "$NEW_PRIMARY_HOST" ] && exit 0

# Only touch a node that is actually a reachable standby.
INREC=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$TARGET_HOST" -p 5432 -U "$POSTGRES_USER" \
          -d "$POSTGRES_DB" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]')
if [ "$INREC" != "t" ]; then
    echo "$TAG node $TARGET_NODE_ID not a reachable standby (in_recovery='$INREC'); skipping."
    exit 0
fi

SLOT="replica_slot_${TARGET_NODE_ID}"

# Ensure the slot exists on the new primary (the promoted node may not have
# run primary-role maintenance yet).
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$NEW_PRIMARY_HOST" -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
    "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='${SLOT}') THEN PERFORM pg_create_physical_replication_slot('${SLOT}'); END IF; END \$\$;" >/dev/null 2>&1

CONNINFO="host=${NEW_PRIMARY_HOST} port=5432 user=${REPLICATION_USER} password=${POSTGRES_PASSWORD} application_name=replica${TARGET_NODE_ID}"
PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$TARGET_HOST" -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<SQL 2>&1
ALTER SYSTEM SET primary_conninfo = '${CONNINFO}';
ALTER SYSTEM SET primary_slot_name = '${SLOT}';
SELECT pg_reload_conf();
SQL
echo "$TAG node $TARGET_NODE_ID re-pointed at $NEW_PRIMARY_HOST"
exit 0
