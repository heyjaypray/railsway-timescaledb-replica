# 🚀 Railsway TimescaleDB HA & Proxy

### _Enterprise-Grade Time-Series Cluster for Railway_

A premium, production-ready TimescaleDB (Postgres 16) template featuring a centralized connection proxy and automatic Read/Write splitting. Deploy a high-performance, resilient database cluster in a single click.

---

## 🏛️ System Architecture

This template deploys a robust 3-node architecture designed for maximum performance and reliability:

1.  **🛰️ Timescale Proxy (Pgpool-II)**:
    - **Unified Endpoint**: Connect to a single host; the proxy handles everything else.
    - **Auto R/W Splitting**: Automatically routes Write operations (Insert/Update) to the Primary and Read operations (Select) to the Replica.
    - **Connection Pooling**: Manages connection queues to prevent database overload during traffic spikes.
2.  **👑 Timescale Primary (Master)**:
    - The source of truth. Handles all data modifications and replication management.
    - Optimized as the primary **Write Node**.
3.  **👥 Timescale Replica (Standby)**:
    - Real-time synchronization with the Primary.
    - Dedicated **Read Node** to offload query heavy workloads from the master.

---

## ✨ Key Features

- **⚡ Zero-Config Auto-Tuning**: Automatically applies `timescaledb-tune` based on defined RAM/CPU resources on Railway.
- **🔄 Real-time Streaming Replication**: Synchronizes data across nodes instantly as changes occur.
- **🛡️ Intelligent Failover & Monitoring**: The proxy continuously monitors node health. If a node fails, traffic is automatically rerouted to maintain uptime.
- **📦 Reliable Persistence**: Pre-configured persistent volumes for every node to ensure zero data loss.
- **🛠️ Postgres 16 & TimescaleDB Native**: Built on the latest stable versions for modern features and security.

---

## ⚙️ Core Configuration

Customize your cluster using these environment variables:

| Variable            | Description                                         | Default    |
| :------------------ | :-------------------------------------------------- | :--------- |
| `POSTGRES_PASSWORD` | Master password for DB and Replication              | _Required_ |
| `TS_TUNE_MEMORY`    | RAM allocation for performance tuning (e.g., `2GB`) | `1GB`      |
| `PRIMARY_WEIGHT`    | Read load balance weight for Primary node           | `1`        |
| `REPLICA_WEIGHT`    | Read load balance weight for Replica node           | `1`        |

---

## 🔌 Connection Guide

Say goodbye to managing multiple connection strings. Simply point your application to the **Proxy Node**:

- **Host**: `timescale-proxy.railway.internal` (Internal Railway Hostname)
- **Port**: `5432`
- **Username**: `postgres`
- **Password**: Your `POSTGRES_PASSWORD`

> [!IMPORTANT]
> **Developer Experience**: Your app interacts with the proxy as if it were a standard standalone PostgreSQL database. No complex logic is required in your code to separate reads and writes.

---

## 📈 Optimization Pro-Tips

Unlock the full power of TimescaleDB by enabling these policies on your hypertables:

```sql
-- 🧊 Compression Policy: Shrink data older than 7 days (Save ~90% storage)
SELECT add_compression_policy('your_metrics_table', INTERVAL '7 days');

-- 🗑️ Retention Policy: Automatically delete data older than 90 days
SELECT add_retention_policy('your_metrics_table', INTERVAL '90 days');

-- 🏎️ Continuous Aggregates: Real-time materialized views for lightning-fast reports
CREATE MATERIALIZED VIEW hourly_stats WITH (timescaledb.continuous) AS ...
```

---

## 🚀 Quick Start

1. Fork/Clone this repository to your Railway project.
2. Deploy via the provided `railway.json`.
3. Scale your time-series data without limits!

---

_Powered by Advanced Agentic Coding Architecture_
