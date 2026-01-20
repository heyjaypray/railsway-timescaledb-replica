# 🚀 Railsway TimescaleDB HA & Proxy

### _Enterprise-Grade Time-Series Cluster for Railway_

A premium, production-ready TimescaleDB (Postgres 16) template featuring a centralized connection proxy, automatic Read/Write splitting, and high-availability (HA).

---

## 🏛️ System Architecture

This template deploys a robust 3-node architecture designed for maximum performance and reliability:

1.  **🛰️ Timescale Proxy (Pgpool-II)**:
    - **Unified Endpoint**: Connect to a single host; the proxy handles everything else.
    - **Auto R/W Splitting**: Routes Writes to Primary and Reads to Replica.
    - **Auto Failback**: Automatically re-attaches nodes once they become healthy.
2.  **👑 Timescale Primary (Master)**:
    - Optimized for **Write Operations**. Handles replication management.
    - Auto-syncs credentials with Railway environment variables.
3.  **👥 Timescale Replica (Standby)**:
    - Dedicated **Read Node**. Synchronizes in real-time.
    - Offloads heavy query workloads from the master.

---

## 🔌 Connection Guide (วิธีการเชื่อมต่อ)

### 1. 🛡️ Internal / Private Connection (เชื่อมต่อภายใน Railway)

Recommended for your backend applications running within the same Railway project.

- **Host**: `timescale-proxy.railway.internal`
- **Port**: `5432`
- **User**: `postgres` (or as configured in `POSTGRES_USER`)
- **Password**: Your `${POSTGRES_PASSWORD}`
- **Database**: Your `${POSTGRES_DB}`

### 2. 🌍 External / Public Connection (เชื่อมต่อจากภายนอก)

Use this for DBeaver, TablePlus, or local development.

- **Step 1**: Go to your **timescale-proxy** service in Railway.
- **Step 2**: Click **Settings** > **Public Networking** > **TCP Proxy**.
- **Step 3**: Use the provided Public Domain and Port (e.g., `monorail.proxy.rlwy.net:12345`).
- **Connection String**:
  `postgresql://postgres:YOUR_PASSWORD@monorail.proxy.rlwy.net:PORT/postgres`

---

## ✨ Key Features

- **⚡ Zero-Config Auto-Tuning**: Automatically applies `timescaledb-tune` based on defined resources.
- **🔄 Real-time Streaming Replication**: Data is synced instantly via physical replication slots.
- **🛡️ High Availability**: The proxy continuously monitors node health and handles failover.
- **� Password Auto-Sync**: If you change `POSTGRES_PASSWORD` in Railway, the cluster updates itself automatically on redeploy.

---

## 🛠️ Maintenance & Verification

### Check Replication Status

Connect to the **Primary** node and run:

```sql
SELECT * FROM pg_stat_replication;
```

### Check Proxy Node Status

Connect to the **Proxy** node and run:

```sql
show pool_nodes;
```

- `status` 1 = **UP** (Healthy)
- `status` 3 = **DOWN** (Offline/Syncing)

---

## 📈 Optimization Pro-Tips

```sql
-- 🧊 Compression Policy: Save ~90% storage
SELECT add_compression_policy('your_metrics_table', INTERVAL '7 days');

-- 🏎️ Continuous Aggregates: Real-time lightning-fast reports
CREATE MATERIALIZED VIEW hourly_stats WITH (timescaledb.continuous) AS ...
```

---

_Powered by Advanced Agentic Coding Architecture_
