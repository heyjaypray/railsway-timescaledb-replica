# PostgreSQL/TimescaleDB Load Test Framework

🚀 **เครื่องมือทดสอบประสิทธิภาพ PostgreSQL และ TimescaleDB**

รองรับ Load Testing หลายรูปแบบ และ **Replication Lag Test** สำหรับวัดเวลา sync ระหว่าง Primary → Replica

---

## 📋 Features

| Feature                 | Description                                    |
| ----------------------- | ---------------------------------------------- |
| ✅ Load Testing         | ทดสอบหลายรูปแบบ (Light, Medium, Heavy, Stress) |
| ✅ TimescaleDB Support  | ทดสอบ Time Series operations โดยเฉพาะ          |
| ✅ Replication Lag Test | วัดเวลา sync ระหว่าง Primary → Replica         |
| ✅ Railway Friendly     | ปิด ANSI colors อัตโนมัติบน Railway            |
| ✅ Detailed Reports     | P50, P95, P99 latency statistics               |
| ✅ Clean UI             | แสดงผลสวยงามใน Terminal                        |

---

## 🔧 Environment Variables

### Primary Database (Required)

| Variable      | Description       | Default     |
| ------------- | ----------------- | ----------- |
| `DB_HOST`     | PostgreSQL host   | `localhost` |
| `DB_PORT`     | PostgreSQL port   | `5432`      |
| `DB_USER`     | Database user     | `postgres`  |
| `DB_PASSWORD` | Database password | _(empty)_   |
| `DB_NAME`     | Database name     | `postgres`  |

### Replica Database (Optional)

| Variable                  | Description                 | Default                 |
| ------------------------- | --------------------------- | ----------------------- |
| `REPLICA_HOST`            | Replica host                | _(empty)_               |
| `REPLICA_PORT`            | Replica port                | `5432`                  |
| `REPLICA_USER`            | Replica user                | _(same as DB_USER)_     |
| `REPLICA_PASSWORD`        | Replica password            | _(same as DB_PASSWORD)_ |
| `REPLICA_DB`              | Replica database            | _(same as DB_NAME)_     |
| `ENABLE_REPLICATION_TEST` | Enable replication lag test | _(empty = disabled)_    |

### Display Options

| Variable              | Description                                |
| --------------------- | ------------------------------------------ |
| `NO_COLOR`            | Set to any value to disable ANSI colors    |
| `RAILWAY_ENVIRONMENT` | Auto-detected on Railway (disables colors) |

---

## 🏃 Quick Start

### Run Locally (Single Database)

```bash
export DB_HOST=localhost
export DB_PORT=5432
export DB_USER=postgres
export DB_PASSWORD=your_password
export DB_NAME=postgres

go run main.go
```

### Run with Replication Test

```bash
# Primary Database
export DB_HOST=primary.internal
export DB_PORT=5432
export DB_USER=postgres
export DB_PASSWORD=your_password
export DB_NAME=postgres

# Replica Database
export REPLICA_HOST=replica.internal
export REPLICA_PORT=5432
export ENABLE_REPLICATION_TEST=true

go run main.go
```

---

## 🐳 Docker

### Build

```bash
docker build -t loadtest-db .
```

### Run Basic Test

```bash
docker run --rm \
  -e DB_HOST=your-db-host \
  -e DB_PORT=5432 \
  -e DB_USER=postgres \
  -e DB_PASSWORD=your_password \
  -e DB_NAME=postgres \
  loadtest-db
```

### Run with Replication Test

```bash
docker run --rm \
  -e DB_HOST=primary.internal \
  -e DB_PORT=5432 \
  -e DB_USER=postgres \
  -e DB_PASSWORD=your_password \
  -e REPLICA_HOST=replica.internal \
  -e REPLICA_PORT=5432 \
  -e ENABLE_REPLICATION_TEST=true \
  loadtest-db
```

---

## 🚂 Deploy to Railway

### Step 1: Create Service

สร้าง service ใหม่จาก folder `loadtest-db/`

### Step 2: Environment Variables

**สำหรับ Load Test ปกติ:**

```env
DB_HOST=postgres-primary.railway.internal
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=${{postgres.POSTGRES_PASSWORD}}
DB_NAME=postgres
```

**สำหรับ Replication Lag Test:**

```env
DB_HOST=postgres-primary.railway.internal
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=${{postgres.POSTGRES_PASSWORD}}
DB_NAME=postgres
REPLICA_HOST=postgres-replica.railway.internal
REPLICA_PORT=5432
ENABLE_REPLICATION_TEST=true
```

### Step 3: Deploy

Deploy และดู logs ใน Railway Dashboard

> **Note:** Railway จะตรวจจับ `RAILWAY_ENVIRONMENT` และปิด ANSI colors อัตโนมัติ ทำให้ logs ไม่ถูกมองเป็น ERROR

---

## 📊 Test Scenarios

### Load Tests

| Test Name                        | Workers | Duration | Description            |
| -------------------------------- | ------- | -------- | ---------------------- |
| Light Load - Simple Reads        | 5       | 5s       | อ่านข้อมูลง่ายๆ        |
| Light Load - Simple Writes       | 5       | 5s       | เขียนข้อมูลง่ายๆ       |
| Medium Load - Mixed R/W          | 10      | 10s      | 70% reads / 30% writes |
| Medium Load - Batch Inserts      | 10      | 10s      | Batch insert 10 rows   |
| Heavy Load - Concurrent Reads    | 20      | 15s      | Concurrent reads       |
| Heavy Load - Concurrent Writes   | 20      | 15s      | Concurrent writes      |
| Stress Test - Max Throughput     | 50      | 20s      | Maximum throughput     |
| TimescaleDB - Time Series Insert | 10      | 10s      | Time series inserts    |
| TimescaleDB - Time Range Query   | 10      | 10s      | Time range queries     |
| Complex - Aggregation Queries    | 5       | 10s      | Aggregation queries    |

### Replication Lag Test

วิธีการทำงาน:

1. เขียนข้อมูลไปที่ **PRIMARY**
2. Poll **REPLICA** จนกว่าจะเห็นข้อมูล
3. วัดระยะเวลาทั้งหมด (Replication Lag)
4. ทำซ้ำ 100 ครั้ง
5. รายงาน Statistics

---

## 📈 Sample Output

### Load Test Report

```
══════════════════════════════════════════════════════════════════════
  Final Report Summary
══════════════════════════════════════════════════════════════════════

   ┌──────────────────────────────────────────┬───────────┬───────────┬───────────┐
   │ Test Name                                │ Ops/Sec   │ Avg Lat   │ Success%  │
   ├──────────────────────────────────────────┼───────────┼───────────┼───────────┤
   │ Light Load - Simple Reads                │   1523.45 │    656µs  │   100.0%  │
   │ Light Load - Simple Writes               │    892.31 │   1.12ms  │   100.0%  │
   │ Medium Load - Mixed R/W                  │   1245.67 │    803µs  │    99.9%  │
   │ Heavy Load - Concurrent Reads            │   3456.78 │    289µs  │   100.0%  │
   │ Stress Test - Max Throughput             │   2345.67 │    426µs  │    99.8%  │
   └──────────────────────────────────────────┴───────────┴───────────┴───────────┘

   [BEST]    Best Throughput: 3456.78 ops/sec (Heavy Load - Concurrent Reads)
   [SLOW]    Slowest:         892.31 ops/sec (Light Load - Simple Writes)
   [TOTAL]   Overall Success: 99.9% (12345/12350 ops)
```

### Replication Lag Report

```
══════════════════════════════════════════════════════════════════════
  Replication Lag Report
══════════════════════════════════════════════════════════════════════

   ┌─────────────────────────────────────────────────────────────────┐
   │ Total Tests:                   100                              │
   │ Successful:                    100                              │
   │ Failed/Timeout:                0                                │
   │ Success Rate:                  100.0%                           │
   ├─────────────────────────────────────────────────────────────────┤
   │ Average Replication Lag:       2.5ms                            │
   │ Minimum Replication Lag:       1.2ms                            │
   │ Maximum Replication Lag:       8.7ms                            │
   ├─────────────────────────────────────────────────────────────────┤
   │ P50 (Median) Lag:              2.1ms                            │
   │ P95 Lag:                       5.3ms                            │
   │ P99 Lag:                       7.8ms                            │
   └─────────────────────────────────────────────────────────────────┘

   [EXCELLENT] Replication is very fast! Avg lag < 10ms
```

---

## 📊 Performance Assessment

### Load Test

| Status   | Condition           | Meaning     |
| -------- | ------------------- | ----------- |
| `[OK]`   | Success ≥ 95%       | Test passed |
| `[WARN]` | 80% ≤ Success < 95% | Some issues |
| `[FAIL]` | Success < 80%       | Test failed |

### Replication Lag

| Rating        | Condition   | Description                   |
| ------------- | ----------- | ----------------------------- |
| `[EXCELLENT]` | Avg < 10ms  | Replication is very fast      |
| `[GOOD]`      | Avg < 100ms | Replication is healthy        |
| `[WARNING]`   | Avg < 1s    | Replication lag is noticeable |
| `[CRITICAL]`  | Avg ≥ 1s    | Replication lag is high       |

---

## 🔍 Database Role Detection

เครื่องมือจะตรวจจับ role ของ database โดยอัตโนมัติ:

```
[INFO] Role: PRIMARY (read-write)
```

หรือ

```
[INFO] Role: REPLICA (read-only)
```

---

## 📁 Project Structure

```
loadtest-db/
├── main.go          # Main application code
├── Dockerfile       # Docker build configuration
├── railway.json     # Railway deployment config
├── go.mod           # Go module definition
├── go.sum           # Go dependencies checksum
└── README.md        # This file
```

---

## 🛠️ Building

```bash
# Build binary
go build -o loadtest-db .

# Run binary
./loadtest-db
```

---

## 📝 License

MIT
