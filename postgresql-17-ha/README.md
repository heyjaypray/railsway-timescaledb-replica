# 🐘 PostgreSQL 17 HA & Extension Bundle

### _Latest PostgreSQL with Powerhouse Extensions_

A production-ready PostgreSQL 17 template featuring a high-availability cluster and a pre-installed bundle of the most popular extensions for AI, GIS, and scheduling.

---

## 🏛️ System Architecture

1.  **🛰️ Postgres Proxy (Pgpool-II)**:
    - Unified connection endpoint.
    - Automatic Read/Write splitting.
2.  **👑 Postgres Primary**:
    - Master node for write operations.
    - Automatically enables extensions on startup.
3.  **👥 Postgres Replica**:
    - Dedicated read-only standby.
    - Real-time streaming replication from Primary.

---

## 📦 Bundled Extensions

This sub-project comes with the following extensions pre-installed and ready to use:

- **AI/Vector**: `pgvector` (Vector similarity search for AI/LLMs)
- **GIS**: `PostGIS` (Geospatial data storage and analysis)
- **Automation**: `pg_cron` (Run periodic jobs inside the database)
- **Partitioning**: `pg_partman` (Manage partitioned tables easily)
- **Search**: `pg_trgm`, `unaccent`
- **Utilities**: `uuid-ossp`, `pg_stat_statements`

---

## 🔌 Quick Start

1. Set your `POSTGRES_PASSWORD` in Railway.
2. Connect to the **Proxy** node:
   - **Internal Host**: `postgres-17-proxy.railway.internal`
   - **Default Port**: `5432`

### Enabling an Extension

Just run the SQL command:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS postgis;
```

---

_Powered by iCue_
