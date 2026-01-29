# TimescaleDB HA for Railway

🚀 Production-ready TimescaleDB High Availability cluster with automatic failover, load balancing, and auto-recovery.

## Architecture

```
                         ┌─────────────────┐
                         │   Application   │
                         └────────┬────────┘
                                  │
                         ┌────────▼────────┐
                         │  Pgpool-II 4.7  │  ← Load Balancer & Connection Pool
                         │     (PROXY)     │
                         └────────┬────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
┌───────▼───────┐         ┌───────▼───────┐         ┌───────▼───────┐
│  TimescaleDB  │         │  TimescaleDB  │         │  TimescaleDB  │
│   (PRIMARY)   │◄────────│  (REPLICA 1)  │         │  (REPLICA 2)  │
│  Read/Write   │  Stream │   Read Only   │         │   Read Only   │
└───────────────┘   WAL   └───────────────┘         └───────────────┘
        │                                                   ▲
        └───────────────────────────────────────────────────┘
                              Stream WAL
```

## Features

### 🔄 High Availability

- **Streaming Replication**: Real-time WAL streaming from PRIMARY to REPLICA
- **Auto Failback**: Automatic reconnection when replica comes back online
- **Load Balancing**: Read queries distributed across PRIMARY and REPLICA

### 🛡️ Resilience

- **Auto-Recovery**: Replica automatically re-syncs when connection is lost
- **Graceful Shutdown**: Proper cleanup on container stop
- **Health Checks**: Comprehensive health monitoring for each node

### ⚡ Performance

- **Connection Pooling**: Efficient connection management via Pgpool
- **Statement-level Load Balancing**: Optimized for mixed read/write workloads
- **TimescaleDB Tuning**: Auto-configured for optimal performance

## Quick Start

### Environment Variables (All Nodes)

| Variable            | Description                           | Default      |
| ------------------- | ------------------------------------- | ------------ |
| `POSTGRES_USER`     | Database username                     | `postgres`   |
| `POSTGRES_PASSWORD` | Database password                     | Required     |
| `POSTGRES_DB`       | Default database                      | `postgres`   |
| `NODE_ROLE`         | Node role: PRIMARY, REPLICA, or PROXY | `PRIMARY`    |
| `REPLICATION_USER`  | Replication user                      | `replicator` |
| `TS_TUNE_MEMORY`    | Memory for TimescaleDB tuning         | `2GB`        |
| `TS_TUNE_CORES`     | CPU cores for TimescaleDB tuning      | `2`          |

### Additional Variables for REPLICA

| Variable       | Description                                      | Default |
| -------------- | ------------------------------------------------ | ------- |
| `PRIMARY_HOST` | Hostname of PRIMARY node                         | Required |
| `REPLICA_ID`   | Unique ID for this replica (1, 2, etc.)          | `1`     |

### Additional Variables for PROXY

| Variable         | Description                           |
| ---------------- | ------------------------------------- |
| `PRIMARY_HOST`   | Hostname of PRIMARY node              |
| `REPLICA_HOST`   | Hostname of REPLICA 1 node            |
| `REPLICA_HOST_2` | Hostname of REPLICA 2 node (optional) |

### Performance Tuning (PROXY)

| Variable | Description | Default |
| -------- | ----------- | ------- |
| `READ_WEIGHT_PRIMARY` | Read weight for PRIMARY (0 = no reads) | `0` |
| `READ_WEIGHT_REPLICA` | Read weight for each replica | `1` |
| `DELAY_THRESHOLD_BYTES` | Max replication lag before removing replica from pool | `1000000` (1MB) |
| `ENABLE_QUERY_CACHE` | Enable in-memory query cache | `on` |
| `QUERY_CACHE_SIZE` | Query cache size in bytes | `67108864` (64MB) |
| `LOAD_BALANCE_ON_WRITE` | Load balance behavior after writes: `off`, `transaction`, `trans_transaction`, `always` | `transaction` |

**Tuning Tips:**

- **Read-heavy workload**: Keep `READ_WEIGHT_PRIMARY=0` to offload PRIMARY for writes only
- **Mixed workload**: Set `READ_WEIGHT_PRIMARY=1` to include PRIMARY in read pool
- **Strict consistency**: Use `LOAD_BALANCE_ON_WRITE=transaction` to prevent stale reads after write
- **Eventual consistency OK**: Use `LOAD_BALANCE_ON_WRITE=off` for maximum read throughput

### Recovery Settings (REPLICA)

| Variable                  | Description                        | Default |
| ------------------------- | ---------------------------------- | ------- |
| `RECOVERY_CHECK_INTERVAL` | Seconds between recovery checks    | `30`    |
| `MAX_RECOVERY_ATTEMPTS`   | Max retry attempts for base backup | `3`     |

## Deployment on Railway

### Step 1: Deploy PRIMARY

1. Create a new service from this repo
2. Set environment variables:
   ```
   POSTGRES_PASSWORD=your_secure_password
   NODE_ROLE=PRIMARY
   ```
3. Add a volume mounted to `/var/lib/postgresql/data`

### Step 2: Deploy REPLICA 1

1. Create another service from this repo
2. Set environment variables:
   ```
   POSTGRES_PASSWORD=your_secure_password
   NODE_ROLE=REPLICA
   REPLICA_ID=1
   PRIMARY_HOST=timescale-primary.railway.internal
   ```
3. Add a volume mounted to `/var/lib/postgresql/data`

### Step 3: Deploy REPLICA 2 (Optional)

1. Create another service from this repo
2. Set environment variables:
   ```
   POSTGRES_PASSWORD=your_secure_password
   NODE_ROLE=REPLICA
   REPLICA_ID=2
   PRIMARY_HOST=timescale-primary.railway.internal
   ```
3. Add a volume mounted to `/var/lib/postgresql/data`

### Step 4: Deploy PROXY

**Option A: Using Dockerfile (Alpine + Pgpool 4.7 compiled)**

```
dockerfilePath=Dockerfile
NODE_ROLE=PROXY
```

**Option B: Using Dockerfile.proxy (Debian + Pgpool from package)**

```
dockerfilePath=Dockerfile.proxy
NODE_ROLE=PROXY
```

Environment variables (single replica):

```
POSTGRES_PASSWORD=your_secure_password
PRIMARY_HOST=timescale-primary.railway.internal
REPLICA_HOST=timescale-replica-1.railway.internal
```

Environment variables (two replicas):

```
POSTGRES_PASSWORD=your_secure_password
PRIMARY_HOST=timescale-primary.railway.internal
REPLICA_HOST=timescale-replica-1.railway.internal
REPLICA_HOST_2=timescale-replica-2.railway.internal
```

## Connection Strings

### Through PROXY (Recommended)

```
postgresql://postgres:password@timescale-proxy.railway.internal:5432/postgres
```

### Direct to PRIMARY

```
postgresql://postgres:password@timescale-primary.railway.internal:5432/postgres
```

## Auto-Recovery Mechanism

### Replica Recovery Flow

```
┌─────────────────┐
│ Replication OK? │
└────────┬────────┘
         │ No
         ▼
┌─────────────────┐
│ Check WAL Recv  │──► Still streaming? ──► Wait
└────────┬────────┘
         │ Not streaming
         ▼
┌─────────────────┐
│ Consecutive     │
│ Failures >= 5?  │
└────────┬────────┘
         │ Yes
         ▼
┌─────────────────┐
│ Primary Ready?  │──► No ──► Retry later
└────────┬────────┘
         │ Yes
         ▼
┌─────────────────┐
│ Full pg_base-   │
│ backup re-sync  │
└─────────────────┘
```

### Pgpool Auto-Failback

1. Pgpool detects replica is down
2. Detaches replica from pool (continues with PRIMARY only)
3. Background monitor checks every 60s if replica is healthy
4. When replica responds, auto-attach via PCP command

## Monitoring

### Check Cluster Status (via PROXY)

```sql
-- Show backend nodes
SHOW pool_nodes;

-- Check replication status (on PRIMARY)
SELECT * FROM pg_stat_replication;

-- Check replication slots (on PRIMARY) - shows all replica slots
SELECT slot_name, active, restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as lag
FROM pg_replication_slots
WHERE slot_name LIKE 'replica_slot_%';

-- Check replication lag (on REPLICA)
SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;
```

### PCP Commands (on PROXY)

```bash
# Show node info
pcp_node_info -h localhost -p 9898 -U postgres -n 0  # PRIMARY
pcp_node_info -h localhost -p 9898 -U postgres -n 1  # REPLICA 1
pcp_node_info -h localhost -p 9898 -U postgres -n 2  # REPLICA 2 (if configured)

# Manually attach node
pcp_attach_node -h localhost -p 9898 -U postgres -n 1  # Attach REPLICA 1
pcp_attach_node -h localhost -p 9898 -U postgres -n 2  # Attach REPLICA 2

# Detach node
pcp_detach_node -h localhost -p 9898 -U postgres -n 1
```

## Troubleshooting

### Replica Not Replicating

1. Check PRIMARY logs for replication issues
2. Verify replication slot exists:
   ```sql
   SELECT * FROM pg_replication_slots;
   ```
3. Check replica's WAL receiver:
   ```sql
   SELECT * FROM pg_stat_wal_receiver;
   ```

### Replica Stuck on Re-sync

1. Increase `MAX_RECOVERY_ATTEMPTS`
2. Check network connectivity between nodes
3. Manually trigger re-sync by deleting data volume

### Pgpool Shows Node as Down

1. Check node is healthy: `pg_isready -h hostname`
2. Manually attach: `pcp_attach_node -n 1`
3. Check Pgpool logs for connection errors

## File Structure

```
├── Dockerfile           # Multi-role image (Alpine + Pgpool compiled)
├── Dockerfile.proxy     # Lightweight proxy-only image (Debian)
├── entrypoint.sh        # Unified entrypoint for PRIMARY/REPLICA/PROXY
├── entrypoint-proxy.sh  # Standalone proxy entrypoint
├── healthcheck.sh       # Unified healthcheck
├── healthcheck-proxy.sh # Proxy-specific healthcheck
└── railway.json         # Railway deployment config
```

## Version History

- **v2.0**: Auto-recovery, enhanced failback, graceful shutdown
- **v1.0**: Initial HA setup with streaming replication

## License

MIT License - See [LICENSE](LICENSE) for details.
