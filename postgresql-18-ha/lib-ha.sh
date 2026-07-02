#!/bin/bash
# lib-ha.sh — shared helpers for the assisted HA model.
# Sourced by entrypoint.sh. Safe to source in any role.
#
# Design invariant (no split-brain):
#   The legitimate current primary is always the reachable node whose
#   PostgreSQL TIMELINE is highest. A standby that gets promoted bumps its
#   timeline (+1), so a stale ex-primary ALWAYS has a strictly lower timeline
#   than the node that replaced it. Any node that boots thinking it is a
#   primary yields (pg_rewind -> standby) if a peer with a higher timeline
#   exists. Comparing timelines is a total order, so this can never make two
#   nodes both decide to stay primary.

ha_log()  { echo -e "\033[0;32m[HA]\033[0m $1"; }
ha_warn() { echo -e "\033[1;33m[HA-WARN]\033[0m $1"; }

# Timeline of the LOCAL data directory (server may be stopped).
ha_local_timeline() {
    su postgres -s /bin/bash -c "pg_controldata -D '$PG_DATA'" 2>/dev/null \
        | grep "Latest checkpoint's TimeLineID" | awk '{print $NF}'
}

# 't' / 'f' / '' (empty = unreachable) — is a remote node in recovery (a standby)?
ha_remote_in_recovery() {
    local host="$1"
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$host" -p 5432 -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]'
}

# Timeline of a remote (running) node, or '' if unreachable.
ha_remote_timeline() {
    local host="$1"
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$host" -p 5432 -U "$POSTGRES_USER" \
        -d "$POSTGRES_DB" -tAc "SELECT timeline_id FROM pg_control_checkpoint();" 2>/dev/null | tr -d '[:space:]'
}

# Echo the hostname of the reachable PRIMARY (in_recovery=f) with the highest
# timeline among a comma-separated peer list. Empty if none found.
ha_discover_primary() {
    local peers="$1" best_host="" best_tl=-1 h inrec ptl
    IFS=',' read -ra _HS <<< "$peers"
    for h in "${_HS[@]}"; do
        h=$(echo "$h" | tr -d '[:space:]'); [ -z "$h" ] && continue
        inrec=$(ha_remote_in_recovery "$h"); [ "$inrec" = "f" ] || continue
        ptl=$(ha_remote_timeline "$h"); [ -z "$ptl" ] && continue
        if [ "$ptl" -gt "$best_tl" ]; then best_tl="$ptl"; best_host="$h"; fi
    done
    echo "$best_host"
}

# Decide the role for a node that currently has NO standby.signal (i.e. it
# believes it is a primary). Sets global RECONCILE_ACTION:
#   "primary"          -> we are the legitimate primary, start normally
#   "standby:<host>"   -> a newer primary exists; rejoin as its standby
ha_reconcile_role() {
    local peers="$1" my_tl best_host="" best_tl=-1 h inrec ptl
    my_tl=$(ha_local_timeline); [ -z "$my_tl" ] && my_tl=0
    IFS=',' read -ra _HS <<< "$peers"
    for h in "${_HS[@]}"; do
        h=$(echo "$h" | tr -d '[:space:]'); [ -z "$h" ] && continue
        inrec=$(ha_remote_in_recovery "$h"); [ "$inrec" = "f" ] || continue
        ptl=$(ha_remote_timeline "$h"); [ -z "$ptl" ] && continue
        if [ "$ptl" -gt "$best_tl" ]; then best_tl="$ptl"; best_host="$h"; fi
    done
    if [ -n "$best_host" ] && [ "$best_tl" -gt "$my_tl" ]; then
        ha_log "Peer $best_host has timeline $best_tl > local $my_tl — yielding, will rejoin as standby."
        RECONCILE_ACTION="standby:$best_host"
    else
        RECONCILE_ACTION="primary"
    fi
}

# Rejoin THIS node as a standby of $1 (the new primary) via pg_rewind.
# Fail-safe: if pg_rewind cannot succeed we still write standby config so the
# node comes up read-only (or fails to stream) — it will NEVER start as a
# competing primary.
ha_rejoin_as_standby() {
    local newp="$1"
    ha_log "Rejoining as standby of $newp via pg_rewind..."

    # 1. Guarantee a clean shutdown of our data dir (pg_rewind requires it).
    #    Start with NO network + read-only so we cannot accept/diverge writes.
    su postgres -s /bin/bash -c \
        "pg_ctl -D '$PG_DATA' -w -t 60 -o \"-c listen_addresses='' -c default_transaction_read_only=on\" start" >/dev/null 2>&1
    su postgres -s /bin/bash -c "pg_ctl -D '$PG_DATA' -w -m fast stop" >/dev/null 2>&1

    # 2. Ensure a replication slot exists on the new primary for us.
    PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$newp" -p 5432 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
        "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='oldprimary_slot') THEN PERFORM pg_create_physical_replication_slot('oldprimary_slot'); END IF; END \$\$;" >/dev/null 2>&1

    # 3. Rewind our data dir onto the new primary's history.
    if su postgres -s /bin/bash -c \
        "PGPASSWORD='$POSTGRES_PASSWORD' pg_rewind --target-pgdata='$PG_DATA' --source-server='host=$newp port=5432 user=$POSTGRES_USER dbname=$POSTGRES_DB' --restore-target-wal"; then
        ha_log "pg_rewind succeeded."
    else
        ha_warn "pg_rewind FAILED. This node will come up read-only following the new primary;"
        ha_warn "if it cannot stream, delete this service's volume to force a fresh pg_basebackup."
    fi

    # 4. Write standby config pointing at the new primary.
    sed -i '/^primary_conninfo/d;/^primary_slot_name/d' "$PG_DATA/postgresql.auto.conf" 2>/dev/null || true
    echo "primary_conninfo = 'host=$newp port=5432 user=$REPLICATION_USER password=$POSTGRES_PASSWORD application_name=oldprimary'" >> "$PG_DATA/postgresql.auto.conf"
    echo "primary_slot_name = 'oldprimary_slot'" >> "$PG_DATA/postgresql.auto.conf"
    touch "$PG_DATA/standby.signal"
    chown postgres:postgres "$PG_DATA/postgresql.auto.conf" "$PG_DATA/standby.signal"
    ha_log "Standby config written; node will start as a standby of $newp."
}

# Echo "yes" if any UP pgpool node OTHER than $1 currently has role=primary.
# Used by the proxy monitor to refuse re-attaching a stale ex-primary.
ha_pgpool_has_other_primary() {
    local exclude="$1" maxn=1 i info status role
    [ -n "$REPLICA_HOST_2" ] && maxn=2
    for i in $(seq 0 "$maxn"); do
        [ "$i" = "$exclude" ] && continue
        info=$(pcp_node_info -h localhost -p 9898 -U "$POSTGRES_USER" -w -n "$i" 2>/dev/null || echo "")
        status=$(echo "$info" | awk '{print $3}')
        role=$(echo "$info" | awk '{print $5}')
        if [ "$role" = "primary" ] && { [ "$status" = "1" ] || [ "$status" = "2" ]; }; then
            echo "yes"; return 0
        fi
    done
    echo "no"
}
