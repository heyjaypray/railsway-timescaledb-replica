#!/bin/bash
# switchover.sh — PLANNED, operator-initiated failback/switchover.
# Run this ON THE PROXY container (it uses pgpool's PCP interface).
#
#   Usage:  switchover.sh <target_node_id>
#   Example (move the primary role back to node 0 after it has rejoined):
#           switchover.sh 0
#
# This is the "assisted" half of assisted-failback: after a failover, the old
# primary rejoins automatically as a standby. When YOU decide to move the
# primary role back (e.g. during a maintenance window), run this. It performs a
# graceful pgpool switchover (pcp_promote_node -s): the current primary is
# demoted cleanly and the target standby is promoted, with no split-brain.
set -e
TARGET="$1"
TAG="[HA-SWITCHOVER]"

if [ -z "$TARGET" ]; then
    echo "$TAG usage: switchover.sh <target_node_id>"; exit 2
fi

# Resolve the target's host from pgpool.
INFO=$(pcp_node_info -h localhost -p 9898 -U "$POSTGRES_USER" -w -n "$TARGET")
HOST=$(echo "$INFO" | awk '{print $1}')
STATUS=$(echo "$INFO" | awk '{print $3}')
ROLE=$(echo "$INFO" | awk '{print $5}')
echo "$TAG target node $TARGET => host=$HOST status=$STATUS role=$ROLE"

if [ "$ROLE" = "primary" ]; then
    echo "$TAG node $TARGET is already the primary. Nothing to do."; exit 0
fi
if [ "$STATUS" != "1" ] && [ "$STATUS" != "2" ]; then
    echo "$TAG node $TARGET is not up (status=$STATUS). Aborting."; exit 1
fi

# Safety: confirm the target is a caught-up standby before promoting it.
INREC=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$HOST" -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
          -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]')
if [ "$INREC" != "t" ]; then
    echo "$TAG node $TARGET is not a standby (in_recovery='$INREC'). Aborting."; exit 1
fi

LAG=$(PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$HOST" -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
        "SELECT COALESCE(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()),0);" 2>/dev/null | tr -d '[:space:]')
echo "$TAG node $TARGET replay lag: ${LAG:-unknown} bytes"
if [ -n "$LAG" ] && [ "$LAG" -gt "${SWITCHOVER_MAX_LAG_BYTES:-16777216}" ]; then
    echo "$TAG lag ${LAG}B exceeds limit. Let it catch up or set SWITCHOVER_MAX_LAG_BYTES. Aborting."; exit 1
fi

echo "$TAG Performing graceful switchover to node $TARGET ($HOST)..."
pcp_promote_node -h localhost -p 9898 -U "$POSTGRES_USER" -w -s -n "$TARGET"
echo "$TAG Switchover requested. Watch the proxy log; follow-primary will re-point the other standbys."
