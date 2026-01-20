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

_Powered by iCue_
