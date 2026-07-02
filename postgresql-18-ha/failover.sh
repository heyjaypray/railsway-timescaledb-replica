#!/bin/bash
# failover.sh — pgpool failover_command.
# Invoked by Pgpool-II ON THE PROXY when a backend is detached.
# Configured in pgpool.conf as:
#   failover_command = '/usr/local/bin/failover.sh %d %P %m %H'
#     $1 = %d  failed node id
#     $2 = %P  old primary node id
#     $3 = %m  new main node id  (the standby pgpool selected as replacement)
#     $4 = %H  new main node hostname
#
# Job: if the PRIMARY failed, promote the standby pgpool chose. That's it —
# pgpool then routes writes to it. Remaining standbys are handled by
# follow-primary.sh (follow_primary_command).
set +e
FAILED_NODE_ID="$1"
OLD_PRIMARY_ID="$2"
NEW_PRIMARY_ID="$3"
NEW_PRIMARY_HOST="$4"
TAG="[HA-FAILOVER]"

echo "$TAG failed=$FAILED_NODE_ID old_primary=$OLD_PRIMARY_ID new_primary=$NEW_PRIMARY_ID host=$NEW_PRIMARY_HOST"

# A standby failed — nothing to promote.
if [ "$FAILED_NODE_ID" != "$OLD_PRIMARY_ID" ]; then
    echo "$TAG Standby node $FAILED_NODE_ID failed; no promotion needed."
    exit 0
fi

# No surviving standby to promote — cluster stays read-only until one returns.
if [ -z "$NEW_PRIMARY_HOST" ] || [ "$NEW_PRIMARY_ID" = "-1" ]; then
    echo "$TAG PRIMARY failed but NO standby available to promote. Cluster is read-only."
    exit 0
fi

echo "$TAG PRIMARY failed. Promoting node $NEW_PRIMARY_ID ($NEW_PRIMARY_HOST)..."
OUT=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$NEW_PRIMARY_HOST" -p 5432 -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" -tAc "SELECT pg_promote(wait := true, wait_seconds := 60);" 2>&1)
RC=$?
if [ $RC -eq 0 ]; then
    echo "$TAG Promotion of $NEW_PRIMARY_HOST complete (pg_promote=$OUT)."
else
    echo "$TAG Promotion FAILED rc=$RC: $OUT — manual intervention required."
fi
exit 0
