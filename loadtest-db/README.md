# Deploy and Host PostgreSQL/TimescaleDB Load Test on Railway

**PostgreSQL/TimescaleDB Load Test** is a comprehensive database performance testing tool designed to benchmark your PostgreSQL and TimescaleDB clusters. It measures throughput, latency, and replication lag across multiple test scenarios—from light reads to stress tests—providing detailed statistics including P50, P95, and P99 percentiles.

## About Hosting PostgreSQL/TimescaleDB Load Test

Deploying this load testing tool on Railway allows you to benchmark your database directly from within the internal network, eliminating external latency and providing accurate performance metrics. The tool automatically connects to your Primary and Replica nodes, runs 10 different test scenarios (simple reads/writes, batch inserts, time-series operations, and aggregation queries), and measures replication lag in real-time. It features Railway-friendly logging that automatically disables ANSI colors, ensuring clean logs in your dashboard. Simply configure the database connection environment variables and deploy—results appear instantly in your logs.

## Common Use Cases

- **Pre-Production Validation**: Verify database performance meets requirements before deploying applications.
- **Replication Health Check**: Measure Primary → Replica sync latency to ensure data consistency.
- **Capacity Planning**: Stress test to determine maximum throughput and identify bottlenecks.
- **TimescaleDB Benchmarking**: Test time-series specific operations like hypertable inserts and time-range queries.

## Dependencies for PostgreSQL/TimescaleDB Load Test Hosting

- **Go 1.23+**: Runtime for the load testing application.
- **PostgreSQL/TimescaleDB**: Target database cluster to benchmark (Primary required, Replica optional).
- **lib/pq Driver**: PostgreSQL driver for Go database connectivity.

### Deployment Dependencies

- [Railway App](https://railway.app)
- [TimescaleDB Replica Template](https://railway.app/template/timescaledb-replica) (recommended target database)

### Implementation Details

Configure environment variables to connect to your database:

```bash
# Primary Database (Required)
DB_HOST=timescale-proxy.railway.internal
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=${POSTGRES_PASSWORD}
DB_NAME=postgres

# Replica Database (Optional - for Replication Lag Test)
REPLICA_HOST=timescale-replica.railway.internal
REPLICA_PORT=5432
ENABLE_REPLICATION_TEST=true
```

The tool runs automatically on deploy, executes all test scenarios, and outputs a comprehensive report:

| Metric          | Description                                   |
| --------------- | --------------------------------------------- |
| Ops/Sec         | Operations per second (throughput)            |
| Avg Latency     | Average response time                         |
| Min/Max Latency | Latency range                                 |
| Success Rate    | Percentage of successful operations           |
| Replication Lag | Time for data to sync from Primary to Replica |
| P50/P95/P99     | Latency percentiles                           |

## Why Deploy PostgreSQL/TimescaleDB Load Test on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your infrastructure so you don't have to deal with configuration, while allowing you to vertically and horizontally scale it.

By deploying PostgreSQL/TimescaleDB Load Test on Railway, you are one step closer to supporting a complete full-stack application with minimal burden. Host your servers, databases, AI agents, and more on Railway.

---

by iCue
