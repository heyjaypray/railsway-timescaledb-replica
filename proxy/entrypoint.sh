#!/bin/bash
# Entrypoint for PROXY node only (Pgpool-II)
# Version 2.0 - Enhanced with Auto-Failback and Better Recovery
exec 2>&1
set -e

# Logging
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[Timescale-PROXY]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Default values
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"

# Performance tuning defaults (optimized for fast reads)
READ_WEIGHT_PRIMARY="${READ_WEIGHT_PRIMARY:-0}"       # 0 = don't send reads to primary
READ_WEIGHT_REPLICA="${READ_WEIGHT_REPLICA:-1}"       # Weight for each replica
DELAY_THRESHOLD_BYTES="${DELAY_THRESHOLD_BYTES:-1000000}"  # 1MB - remove lagging replicas
ENABLE_QUERY_CACHE="${ENABLE_QUERY_CACHE:-on}"        # Cache repeated queries
QUERY_CACHE_SIZE="${QUERY_CACHE_SIZE:-67108864}"      # 64MB cache
LOAD_BALANCE_ON_WRITE="${LOAD_BALANCE_ON_WRITE:-transaction}"  # Prevent stale reads after write

log "Starting Pgpool-II Proxy v2.0 (Debian/Pgpool 4.7)..."
log "Config: USER=$POSTGRES_USER, DB=$POSTGRES_DB"

# Signal handlers for graceful shutdown
cleanup() {
    log "Received shutdown signal, cleaning up..."
    pkill -TERM pgpool 2>/dev/null || true
    sleep 2
    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# Create directories
mkdir -p /var/run/pgpool /var/log/pgpool /tmp
chmod 777 /tmp

PGPOOL_CONF="/etc/pgpool2/pgpool.conf"
PCP_CONF="/etc/pgpool2/pcp.conf"

# Escape single quotes in password
ESCAPED_PASSWORD=$(printf '%s' "$POSTGRES_PASSWORD" | sed "s/'/''/g")

# Create PCP password file for attach node commands
PCP_PASSWORD_HASH=$(echo -n "${POSTGRES_USER}${POSTGRES_PASSWORD}" | md5sum | cut -d' ' -f1)
echo "${POSTGRES_USER}:${PCP_PASSWORD_HASH}" > "$PCP_CONF"

log "Configuring Pgpool-II with enhanced failback..."

# Determine if running in single-node mode (DR failover scenario)
SINGLE_NODE_MODE="false"
if [ -z "$REPLICA_HOST" ] || [ "$REPLICA_HOST" = "$PRIMARY_HOST" ]; then
    SINGLE_NODE_MODE="true"
    log "Running in SINGLE-NODE mode (DR/failover configuration)"
fi

cat > "$PGPOOL_CONF" <<EOF
# Pgpool-II 4.7 Configuration for TimescaleDB HA
# Enhanced with Auto-Failback and Better Recovery

listen_addresses = '*'
port = 5432
pcp_listen_addresses = '*'
pcp_port = 9898

# Unix socket
unix_socket_directories = '/var/run/pgpool,/tmp'
pcp_socket_dir = '/var/run/pgpool'

# Backend nodes (weights optimized for read-heavy workloads)
backend_hostname0 = '$PRIMARY_HOST'
backend_port0 = 5432
backend_weight0 = 1
backend_flag0 = 'ALLOW_TO_FAILOVER'
backend_data_directory0 = '/var/lib/postgresql/data'
EOF

# Only add replica backend if not in single-node mode
if [ "$SINGLE_NODE_MODE" = "false" ]; then
    cat >> "$PGPOOL_CONF" <<EOF

backend_hostname1 = '$REPLICA_HOST'
backend_port1 = 5432
backend_weight1 = $READ_WEIGHT_REPLICA
backend_flag1 = 'ALLOW_TO_FAILOVER'
backend_data_directory1 = '/var/lib/postgresql/data'
EOF

    # Add second replica if REPLICA_HOST_2 is set
    if [ -n "$REPLICA_HOST_2" ]; then
        log "Adding second replica: $REPLICA_HOST_2"
        cat >> "$PGPOOL_CONF" <<EOF

backend_hostname2 = '$REPLICA_HOST_2'
backend_port2 = 5432
backend_weight2 = $READ_WEIGHT_REPLICA
backend_flag2 = 'ALLOW_TO_FAILOVER'
backend_data_directory2 = '/var/lib/postgresql/data'
EOF
    fi
fi

cat >> "$PGPOOL_CONF" <<EOF

# Clustering mode
backend_clustering_mode = 'streaming_replication'
EOF

# Configure load balancing based on mode
if [ "$SINGLE_NODE_MODE" = "true" ]; then
    log "Configuring single-node mode (no load balancing)"
    cat >> "$PGPOOL_CONF" <<EOF
load_balance_mode = off

# Session handling
statement_level_load_balance = off
disable_load_balance_on_write = 'always'
allow_sql_comments = on

# No redirect preferences in single-node mode
database_redirect_preference_list = ''
app_name_redirect_preference_list = ''
EOF
else
    cat >> "$PGPOOL_CONF" <<EOF
load_balance_mode = on

# Session handling for TimescaleDB/pgx compatibility
statement_level_load_balance = on
disable_load_balance_on_write = '$LOAD_BALANCE_ON_WRITE'
allow_sql_comments = on

# Load balance preferences - force standby for reads
database_redirect_preference_list = 'postgres:standby'
app_name_redirect_preference_list = 'psql:standby,pgadmin:standby,dbeaver:standby'
EOF
fi

cat >> "$PGPOOL_CONF" <<EOF

# Allow all functions to be load balanced (empty = all allowed)
black_function_list = ''
white_function_list = ''
black_query_pattern_list = ''

# Authentication: Pass-through to backend
enable_pool_hba = off
pool_passwd = ''
allow_clear_text_frontend_auth = on

# Health Check - Tolerant for Railway cross-region networking
# Railway internal DNS has transient latency spikes between regions.
# Aggressive checks cause false detachments that never recover.
health_check_period = 10
health_check_timeout = 30
health_check_user = '$POSTGRES_USER'
health_check_password = '$ESCAPED_PASSWORD'
health_check_database = '$POSTGRES_DB'
health_check_max_retries = 10
health_check_retry_delay = 5
connect_timeout = 20000

# Auto failback when replica comes back online
auto_failback = on
auto_failback_interval = 10

# Failover behavior - Prevent false detachments
failover_on_backend_error = off
failover_on_backend_shutdown = off
detach_false_primary = off

# Streaming Replication Check - Relaxed to avoid false positives
sr_check_period = 15
sr_check_user = '$POSTGRES_USER'
sr_check_password = '$ESCAPED_PASSWORD'
sr_check_database = '$POSTGRES_DB'
delay_threshold = $DELAY_THRESHOLD_BYTES

# Logging
log_destination = 'stderr'
log_line_prefix = '%t: pid %p: '
log_connections = off
log_disconnections = off
log_hostname = off
log_statement = off
log_per_node_statement = off
log_client_messages = off
log_min_messages = error

# Connection pooling
num_init_children = 32
max_pool = 4
child_life_time = 300
child_max_connections = 0
connection_life_time = 0
client_idle_limit = 0

# Memory cache for faster repeated reads
memory_cache_enabled = $ENABLE_QUERY_CACHE
memqcache_method = 'shmem'
memqcache_total_size = $QUERY_CACHE_SIZE
memqcache_max_num_cache = 1000000
memqcache_expire = 60
memqcache_auto_cache_invalidation = on
memqcache_maxcache = 409600

# Watchdog (disabled - single proxy)
use_watchdog = off

# PID file
pid_file_name = '/var/run/pgpool/pgpool.pid'
logdir = '/var/log/pgpool'
EOF

log "Waiting for Primary ($PRIMARY_HOST)..."
until pg_isready -h "$PRIMARY_HOST" -p 5432 -U "$POSTGRES_USER" > /dev/null 2>&1; do 
    warn "Primary not ready, waiting..."
    sleep 5
done

# Background node monitor for re-attach if auto_failback fails
# Runs every 20s and explicitly logs attach success/failure
(
    set +e
    log "Starting background node monitor..."
    sleep 30  # Wait for pgpool to fully start
    
    # Determine max node index based on configuration
    MAX_NODE=0
    if [ "$SINGLE_NODE_MODE" = "false" ]; then
        MAX_NODE=1
        if [ -n "$REPLICA_HOST_2" ]; then
            MAX_NODE=2
        fi
    fi
    
    # Build hostname array for readable logging
    declare -A NODE_HOSTS
    NODE_HOSTS[0]="$PRIMARY_HOST"
    [ -n "$REPLICA_HOST" ] && NODE_HOSTS[1]="$REPLICA_HOST"
    [ -n "$REPLICA_HOST_2" ] && NODE_HOSTS[2]="$REPLICA_HOST_2"
    
    CYCLE=0
    
    while true; do
        sleep 20
        CYCLE=$((CYCLE+1))
        
        # Skip replica monitoring in single-node mode
        if [ "$SINGLE_NODE_MODE" = "false" ]; then
            # Check each standby node (1..MAX_NODE)
            for NODE_ID in $(seq 1 $MAX_NODE); do
                HOST="${NODE_HOSTS[$NODE_ID]}"
                [ -z "$HOST" ] && continue
                
                # Check if the backend PostgreSQL is reachable
                if pg_isready -h "$HOST" -p 5432 -U "$POSTGRES_USER" -t 5 > /dev/null 2>&1; then
                    # Get PgPool's view of this node
                    NODE_STATUS=$(PGPOOL_PCP_PASSWORD="$POSTGRES_PASSWORD" pcp_node_info -h localhost -p 9898 -U "$POSTGRES_USER" -n $NODE_ID 2>/dev/null | cut -d' ' -f3 || echo "unknown")
                    
                    if [ "$NODE_STATUS" = "down" ] || [ "$NODE_STATUS" = "3" ]; then
                        log "Node $NODE_ID ($HOST) is healthy at PG level but PgPool status=$NODE_STATUS. Re-attaching..."
                        ATTACH_RESULT=$(PGPOOL_PCP_PASSWORD="$POSTGRES_PASSWORD" pcp_attach_node -h localhost -p 9898 -U "$POSTGRES_USER" -n $NODE_ID 2>&1)
                        ATTACH_RC=$?
                        if [ $ATTACH_RC -eq 0 ]; then
                            log "Successfully re-attached node $NODE_ID ($HOST)"
                        else
                            warn "Failed to re-attach node $NODE_ID ($HOST): rc=$ATTACH_RC output=$ATTACH_RESULT"
                        fi
                    fi
                else
                    # Only log unreachable nodes every 3rd cycle to reduce noise
                    if [ $((CYCLE % 3)) -eq 0 ]; then
                        warn "Node $NODE_ID ($HOST) is unreachable at PG level, skipping attach"
                    fi
                fi
            done
        fi
        
        # Log cluster status every 6th cycle (~2 minutes)
        if [ $((CYCLE % 6)) -eq 0 ]; then
            log "Cluster status (cycle $CYCLE):"
            for i in $(seq 0 $MAX_NODE); do
                STATUS=$(PGPOOL_PCP_PASSWORD="$POSTGRES_PASSWORD" pcp_node_info -h localhost -p 9898 -U "$POSTGRES_USER" -n $i 2>/dev/null || echo "error")
                echo "  Node $i (${NODE_HOSTS[$i]:-unknown}): $STATUS"
            done
        fi
    done
) &

log "Primary is ready! Launching Pgpool-II..."
exec pgpool -n -f "$PGPOOL_CONF" 2>&1
