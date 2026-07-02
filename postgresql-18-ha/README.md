# 🐘 PostgreSQL 18 HA & Extension Bundle

### _Cutting-Edge PostgreSQL 18 with Powerhouse Extensions_

The most advanced PostgreSQL setup on Railway, featuring version 18 with high-availability and a pre-installed bundle of extensions for AI, GIS, and more.

---

## 🏛️ System Architecture

1.  **🛰️ Postgres Proxy (Pgpool-II)**:
    - Unified connection endpoint.
    - Automatic Read/Write splitting.
2.  **👑 Postgres Primary**:
    - Master node with native **UUIDv7 support** (New in PG 18!).
    - Automatically enables extensions on startup.
3.  **👥 Postgres Replica**:
    - Dedicated read-only standby.
    - Real-time streaming replication.

---

## 📦 Bundled Extensions

- **AI/Vector**: `pgvector`
- **GIS**: `PostGIS`
- **Automation**: `pg_cron`
- **Partitioning**: `pg_partman`
- **Utilities**: `uuid-ossp`, `pg_stat_statements`, `pg_trgm`, `unaccent`

---

## 🔌 Quick Start

1. Set `POSTGRES_PASSWORD` in Railway.
2. Connect to: `postgres-18-proxy.railway.internal` (Port: `5432`)

### Native UUIDv7 Example (New in PG 18)

PostgreSQL 18 now supports native UUIDv7 for better indexing performance:

```sql
SELECT gen_random_uuid_v7();
```

---

## 🔁 High Availability: failover & assisted failback

### Always on: primary auto-reattach
The proxy's background monitor watches **all** nodes including the primary
(node 0). If pgpool falsely detaches a *healthy* primary after a transient
network blip, the monitor re-attaches it within ~20s. This is the common
Railway failure mode and needs no configuration.

### Opt-in: automatic failover (`ENABLE_AUTO_FAILOVER=true`)
Off by default. When enabled:

- **Primary dies** → pgpool promotes a surviving standby (`failover.sh`,
  `pg_promote()`), and the remaining standbys are re-pointed at it
  (`follow-primary.sh`). Writes resume automatically.
- **Old primary returns** → on boot it compares its PostgreSQL **timeline** to
  its peers. The promoted node has a higher timeline, so the returning node
  recognises it is stale and **rejoins as a standby via `pg_rewind`** — it can
  never come back as a second primary. Timeline is a total order, so two
  nodes can't both decide to stay primary → **no split-brain**.
- **Failback is assisted, not automatic.** Moving the primary role *back* to
  the original node is a deliberate, graceful switchover you run when
  convenient (see below).

### No-split-brain invariant
The legitimate primary is always the reachable node with the **highest
timeline**. Every node that boots believing it's a primary yields (rewind →
standby) if a peer has a higher timeline. The proxy also refuses to re-attach a
node claiming "primary" while another primary is already active.

### Enabling it (do this in staging first)
1. Set the `ENABLE_AUTO_FAILOVER` param to `true`.
2. Ensure **every DB service** has `PEER_HOSTS` = comma-separated private
   hostnames of the *other* DB nodes, and the proxy has `REPLICA_HOST_2` set if
   you run a second replica (the prod `us-west-replica` is not in this template
   — add it to `PEER_HOSTS` on each node and to the proxy).
3. Redeploy all four services so the new image + `wal_log_hints=on` take effect.

**Staging validation checklist:**
- Kill the primary service → a standby is promoted, app writes resume.
- Restart the old primary → it rejoins as a standby (look for `pg_rewind
  succeeded` in its logs), not a second primary.
- `show pool_nodes` on the proxy shows exactly one `primary`.
- Run a planned switchover back and confirm no errors.

### Planned switchover / failback (operator-run)
On the **proxy** container:
```bash
switchover.sh 0     # gracefully move the primary role back to node 0
```
It verifies the target is an up, caught-up standby, then performs a graceful
pgpool switchover (`pcp_promote_node -s`). After a failover you may also want to
realign the static `NODE_ROLE` env vars to match reality during a maintenance
window.

### Caveats
- This is a lightweight HA layer on pgpool, **not** Patroni. It has no
  distributed consensus store; it arbitrates purely on PostgreSQL timelines.
  For stricter guarantees, migrate to Patroni + etcd.
- `pg_rewind` requires `wal_log_hints=on` (now set). Existing clusters get it
  after their next restart + checkpoint.

---

_Powered by iCue_
