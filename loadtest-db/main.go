package main

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"math/rand"
	"os"
	"sync"
	"sync/atomic"
	"time"

	_ "github.com/lib/pq"
)

// Color codes - will be empty if NO_COLOR is set
var (
	Reset   string
	Bold    string
	Dim     string
	Red     string
	Green   string
	Yellow  string
	Blue    string
	Magenta string
	Cyan    string
	White   string
)

func initColors() {
	if os.Getenv("NO_COLOR") != "" || os.Getenv("RAILWAY_ENVIRONMENT") != "" {
		// Disable colors for Railway or when NO_COLOR is set
		return
	}
	Reset = "\033[0m"
	Bold = "\033[1m"
	Dim = "\033[2m"
	Red = "\033[31m"
	Green = "\033[32m"
	Yellow = "\033[33m"
	Blue = "\033[34m"
	Magenta = "\033[35m"
	Cyan = "\033[36m"
	White = "\033[37m"
}

// TestResult holds the result of a single test
type TestResult struct {
	Name         string
	Duration     time.Duration
	TotalOps     int64
	SuccessOps   int64
	FailedOps    int64
	AvgLatency   time.Duration
	MinLatency   time.Duration
	MaxLatency   time.Duration
	OpsPerSecond float64
}

// ReplicationResult holds replication lag test results
type ReplicationResult struct {
	TestCount    int
	SuccessCount int
	FailedCount  int
	AvgLag       time.Duration
	MinLag       time.Duration
	MaxLag       time.Duration
	P50Lag       time.Duration
	P95Lag       time.Duration
	P99Lag       time.Duration
	AllLags      []time.Duration
}

// Config holds database configuration
type Config struct {
	// Primary DB
	PrimaryHost     string
	PrimaryPort     string
	PrimaryUser     string
	PrimaryPassword string
	PrimaryDB       string

	// Replica DB (optional)
	ReplicaHost     string
	ReplicaPort     string
	ReplicaUser     string
	ReplicaPassword string
	ReplicaDB       string

	// Test options
	EnableReplicationTest bool
}

func main() {
	initColors()

	log.SetOutput(os.Stdout)
	log.SetFlags(0)

	printBanner()

	cfg := loadConfig()

	// Connect to Primary
	primaryConnStr := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		cfg.PrimaryHost, cfg.PrimaryPort, cfg.PrimaryUser, cfg.PrimaryPassword, cfg.PrimaryDB)

	printSection("Database Connection - PRIMARY")
	logInfo("Host", fmt.Sprintf("%s:%s", cfg.PrimaryHost, cfg.PrimaryPort))
	logInfo("User", cfg.PrimaryUser)
	logInfo("Database", cfg.PrimaryDB)

	primaryDB, err := sql.Open("postgres", primaryConnStr)
	if err != nil {
		logError("Failed to open primary database", err)
		os.Exit(1)
	}
	defer primaryDB.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := primaryDB.PingContext(ctx); err != nil {
		logError("Failed to connect to primary database", err)
		os.Exit(1)
	}
	logSuccess("Connected to PRIMARY database successfully!")
	printDatabaseInfo(primaryDB)

	// Connect to Replica (if configured)
	var replicaDB *sql.DB
	if cfg.EnableReplicationTest && cfg.ReplicaHost != "" {
		replicaConnStr := fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
			cfg.ReplicaHost, cfg.ReplicaPort, cfg.ReplicaUser, cfg.ReplicaPassword, cfg.ReplicaDB)

		printSection("Database Connection - REPLICA")
		logInfo("Host", fmt.Sprintf("%s:%s", cfg.ReplicaHost, cfg.ReplicaPort))
		logInfo("User", cfg.ReplicaUser)
		logInfo("Database", cfg.ReplicaDB)

		replicaDB, err = sql.Open("postgres", replicaConnStr)
		if err != nil {
			logError("Failed to open replica database", err)
			os.Exit(1)
		}
		defer replicaDB.Close()

		ctx2, cancel2 := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel2()

		if err := replicaDB.PingContext(ctx2); err != nil {
			logError("Failed to connect to replica database", err)
			os.Exit(1)
		}
		logSuccess("Connected to REPLICA database successfully!")
		printDatabaseInfo(replicaDB)
	}

	// Setup test tables
	printSection("Setting Up Test Environment")
	if err := setupTestTables(primaryDB); err != nil {
		logError("Failed to setup test tables", err)
		os.Exit(1)
	}
	logSuccess("Test tables created successfully!")

	// Run all load tests
	results := []TestResult{}

	printSection("Running Load Tests")
	fmt.Println()

	// Test 1: Light Load - Simple Reads
	results = append(results, runTest(primaryDB, "Light Load - Simple Reads", 5, 10, 5*time.Second, testSimpleRead))

	// Test 2: Light Load - Simple Writes
	results = append(results, runTest(primaryDB, "Light Load - Simple Writes", 5, 10, 5*time.Second, testSimpleWrite))

	// Test 3: Medium Load - Mixed Operations
	results = append(results, runTest(primaryDB, "Medium Load - Mixed R/W", 10, 50, 10*time.Second, testMixedOperations))

	// Test 4: Medium Load - Batch Inserts
	results = append(results, runTest(primaryDB, "Medium Load - Batch Inserts", 10, 20, 10*time.Second, testBatchInsert))

	// Test 5: Heavy Load - Concurrent Reads
	results = append(results, runTest(primaryDB, "Heavy Load - Concurrent Reads", 20, 100, 15*time.Second, testSimpleRead))

	// Test 6: Heavy Load - Concurrent Writes
	results = append(results, runTest(primaryDB, "Heavy Load - Concurrent Writes", 20, 100, 15*time.Second, testSimpleWrite))

	// Test 7: Stress Test - Maximum Throughput
	results = append(results, runTest(primaryDB, "Stress Test - Max Throughput", 50, 200, 20*time.Second, testMixedOperations))

	// Test 8: TimescaleDB Specific - Time Series Insert
	results = append(results, runTest(primaryDB, "TimescaleDB - Time Series Insert", 10, 50, 10*time.Second, testTimeSeriesInsert))

	// Test 9: TimescaleDB Specific - Time Range Query
	results = append(results, runTest(primaryDB, "TimescaleDB - Time Range Query", 10, 50, 10*time.Second, testTimeRangeQuery))

	// Test 10: Complex Query Test
	results = append(results, runTest(primaryDB, "Complex - Aggregation Queries", 5, 20, 10*time.Second, testComplexQuery))

	// Print load test report
	printFinalReport(results)

	// Run Replication Lag Test (if replica is configured)
	if replicaDB != nil && cfg.EnableReplicationTest {
		printSection("Replication Lag Test")
		fmt.Println()
		logInfo("Test Description", "Write to PRIMARY, measure time until data appears on REPLICA")
		fmt.Println()

		repResult := runReplicationLagTest(primaryDB, replicaDB, 100, 10) // 100 tests, max 10s wait
		printReplicationReport(repResult)
	}

	// Cleanup
	printSection("Cleanup")
	if err := cleanupTestTables(primaryDB); err != nil {
		logWarning("Failed to cleanup test tables: " + err.Error())
	} else {
		logSuccess("Test tables cleaned up successfully!")
	}

	printFooter()
}

func loadConfig() Config {
	cfg := Config{
		// Primary DB
		PrimaryHost:     getEnv("DB_HOST", getEnv("PRIMARY_HOST", "localhost")),
		PrimaryPort:     getEnv("DB_PORT", getEnv("PRIMARY_PORT", "5432")),
		PrimaryUser:     getEnv("DB_USER", getEnv("PRIMARY_USER", "postgres")),
		PrimaryPassword: getEnv("DB_PASSWORD", getEnv("PRIMARY_PASSWORD", "")),
		PrimaryDB:       getEnv("DB_NAME", getEnv("PRIMARY_DB", "postgres")),

		// Replica DB
		ReplicaHost:     getEnv("REPLICA_HOST", ""),
		ReplicaPort:     getEnv("REPLICA_PORT", "5432"),
		ReplicaUser:     getEnv("REPLICA_USER", getEnv("DB_USER", "postgres")),
		ReplicaPassword: getEnv("REPLICA_PASSWORD", getEnv("DB_PASSWORD", "")),
		ReplicaDB:       getEnv("REPLICA_DB", getEnv("DB_NAME", "postgres")),

		EnableReplicationTest: getEnv("ENABLE_REPLICATION_TEST", "") != "",
	}

	return cfg
}

func getEnv(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}

func setupTestTables(db *sql.DB) error {
	queries := []string{
		`DROP TABLE IF EXISTS loadtest_simple CASCADE`,
		`DROP TABLE IF EXISTS loadtest_timeseries CASCADE`,
		`DROP TABLE IF EXISTS loadtest_replication CASCADE`,
		`CREATE TABLE loadtest_simple (
			id SERIAL PRIMARY KEY,
			data TEXT,
			value INTEGER,
			created_at TIMESTAMPTZ DEFAULT NOW()
		)`,
		`CREATE TABLE loadtest_timeseries (
			time TIMESTAMPTZ NOT NULL,
			device_id TEXT NOT NULL,
			temperature DOUBLE PRECISION,
			humidity DOUBLE PRECISION,
			pressure DOUBLE PRECISION
		)`,
		`CREATE TABLE loadtest_replication (
			id TEXT PRIMARY KEY,
			write_time TIMESTAMPTZ NOT NULL,
			data TEXT
		)`,
		`CREATE INDEX IF NOT EXISTS idx_loadtest_simple_created ON loadtest_simple(created_at)`,
		`CREATE INDEX IF NOT EXISTS idx_loadtest_timeseries_time ON loadtest_timeseries(time DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_loadtest_timeseries_device ON loadtest_timeseries(device_id, time DESC)`,
	}

	for _, q := range queries {
		if _, err := db.Exec(q); err != nil {
			return fmt.Errorf("failed to execute: %s - %w", q, err)
		}
	}

	// Try to create hypertable (may fail if TimescaleDB is not installed)
	_, err := db.Exec(`SELECT create_hypertable('loadtest_timeseries', 'time', if_not_exists => TRUE)`)
	if err != nil {
		logWarning("TimescaleDB hypertable creation skipped (extension may not be installed)")
	} else {
		logSuccess("TimescaleDB hypertable created!")
	}

	// Pre-populate with some data
	for i := 0; i < 1000; i++ {
		_, err := db.Exec(`INSERT INTO loadtest_simple (data, value) VALUES ($1, $2)`,
			fmt.Sprintf("initial_data_%d", i), rand.Intn(10000))
		if err != nil {
			return err
		}
	}

	// Pre-populate timeseries
	baseTime := time.Now().Add(-24 * time.Hour)
	for i := 0; i < 1000; i++ {
		t := baseTime.Add(time.Duration(i) * time.Minute)
		_, err := db.Exec(`INSERT INTO loadtest_timeseries (time, device_id, temperature, humidity, pressure) 
			VALUES ($1, $2, $3, $4, $5)`,
			t,
			fmt.Sprintf("device_%d", rand.Intn(10)),
			20+rand.Float64()*15,
			30+rand.Float64()*50,
			1000+rand.Float64()*50)
		if err != nil {
			return err
		}
	}

	return nil
}

func cleanupTestTables(db *sql.DB) error {
	queries := []string{
		`DROP TABLE IF EXISTS loadtest_simple CASCADE`,
		`DROP TABLE IF EXISTS loadtest_timeseries CASCADE`,
		`DROP TABLE IF EXISTS loadtest_replication CASCADE`,
	}

	for _, q := range queries {
		if _, err := db.Exec(q); err != nil {
			return err
		}
	}
	return nil
}

type TestFunc func(db *sql.DB) error

func runTest(db *sql.DB, name string, concurrency, opsPerWorker int, duration time.Duration, testFn TestFunc) TestResult {
	printTestHeader(name)
	fmt.Printf("   Concurrency: %d workers | Ops/Worker: %d | Duration: %v\n", concurrency, opsPerWorker, duration)
	fmt.Println()

	var totalOps, successOps, failedOps int64
	var totalLatency int64
	var minLatency, maxLatency int64
	minLatency = int64(time.Hour)

	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()

	var wg sync.WaitGroup
	startTime := time.Now()

	// Progress display
	progressDone := make(chan bool)
	go showProgress(ctx, &successOps, &failedOps, startTime, progressDone)

	for w := 0; w < concurrency; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < opsPerWorker; i++ {
				select {
				case <-ctx.Done():
					return
				default:
				}

				opStart := time.Now()
				err := testFn(db)
				latency := time.Since(opStart)

				atomic.AddInt64(&totalOps, 1)
				atomic.AddInt64(&totalLatency, int64(latency))

				if err != nil {
					atomic.AddInt64(&failedOps, 1)
				} else {
					atomic.AddInt64(&successOps, 1)
				}

				// Update min/max latency
				latencyNs := int64(latency)
				for {
					oldMin := atomic.LoadInt64(&minLatency)
					if latencyNs >= oldMin || atomic.CompareAndSwapInt64(&minLatency, oldMin, latencyNs) {
						break
					}
				}
				for {
					oldMax := atomic.LoadInt64(&maxLatency)
					if latencyNs <= oldMax || atomic.CompareAndSwapInt64(&maxLatency, oldMax, latencyNs) {
						break
					}
				}
			}
		}()
	}

	wg.Wait()
	cancel()
	<-progressDone

	elapsed := time.Since(startTime)

	result := TestResult{
		Name:       name,
		Duration:   elapsed,
		TotalOps:   atomic.LoadInt64(&totalOps),
		SuccessOps: atomic.LoadInt64(&successOps),
		FailedOps:  atomic.LoadInt64(&failedOps),
	}

	if result.TotalOps > 0 {
		result.AvgLatency = time.Duration(atomic.LoadInt64(&totalLatency) / result.TotalOps)
		result.MinLatency = time.Duration(atomic.LoadInt64(&minLatency))
		result.MaxLatency = time.Duration(atomic.LoadInt64(&maxLatency))
		result.OpsPerSecond = float64(result.SuccessOps) / elapsed.Seconds()
	}

	printTestResult(result)
	return result
}

// Replication Lag Test
func runReplicationLagTest(primaryDB, replicaDB *sql.DB, testCount int, maxWaitSeconds int) ReplicationResult {
	result := ReplicationResult{
		TestCount: testCount,
		MinLag:    time.Hour,
		AllLags:   make([]time.Duration, 0, testCount),
	}

	maxWait := time.Duration(maxWaitSeconds) * time.Second

	for i := 0; i < testCount; i++ {
		// Generate unique ID
		uuid := fmt.Sprintf("%d-%d-%d", time.Now().UnixNano(), rand.Int63(), i)
		writeTime := time.Now()

		// Write to PRIMARY
		_, err := primaryDB.Exec(`INSERT INTO loadtest_replication (id, write_time, data) VALUES ($1, $2, $3)`,
			uuid, writeTime, fmt.Sprintf("test_data_%d", i))
		if err != nil {
			result.FailedCount++
			fmt.Printf("   [%d/%d] Write failed: %v\n", i+1, testCount, err)
			continue
		}

		// Poll REPLICA until data appears
		pollStart := time.Now()
		found := false
		var readTime time.Time

		for time.Since(pollStart) < maxWait {
			var count int
			err := replicaDB.QueryRow(`SELECT COUNT(*) FROM loadtest_replication WHERE id = $1`, uuid).Scan(&count)
			if err == nil && count > 0 {
				readTime = time.Now()
				found = true
				break
			}
			time.Sleep(1 * time.Millisecond) // Poll every 1ms
		}

		if found {
			lag := readTime.Sub(writeTime)
			result.SuccessCount++
			result.AllLags = append(result.AllLags, lag)

			if lag < result.MinLag {
				result.MinLag = lag
			}
			if lag > result.MaxLag {
				result.MaxLag = lag
			}

			// Log progress every 10 tests
			if (i+1)%10 == 0 || i == 0 {
				fmt.Printf("   [%d/%d] Replication lag: %v\n", i+1, testCount, lag.Round(time.Microsecond))
			}
		} else {
			result.FailedCount++
			fmt.Printf("   [%d/%d] Timeout - data not replicated within %v\n", i+1, testCount, maxWait)
		}
	}

	// Calculate statistics
	if len(result.AllLags) > 0 {
		var totalLag time.Duration
		for _, lag := range result.AllLags {
			totalLag += lag
		}
		result.AvgLag = totalLag / time.Duration(len(result.AllLags))

		// Sort for percentiles
		sortedLags := make([]time.Duration, len(result.AllLags))
		copy(sortedLags, result.AllLags)
		sortDurations(sortedLags)

		result.P50Lag = sortedLags[len(sortedLags)*50/100]
		result.P95Lag = sortedLags[len(sortedLags)*95/100]
		if len(sortedLags) > 0 {
			result.P99Lag = sortedLags[len(sortedLags)*99/100]
		}
	}

	return result
}

func sortDurations(d []time.Duration) {
	for i := 0; i < len(d); i++ {
		for j := i + 1; j < len(d); j++ {
			if d[j] < d[i] {
				d[i], d[j] = d[j], d[i]
			}
		}
	}
}

func showProgress(ctx context.Context, success, failed *int64, startTime time.Time, done chan bool) {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	spinChars := []string{"|", "/", "-", "\\"}
	spinIdx := 0

	for {
		select {
		case <-ctx.Done():
			fmt.Print("\r                                                                    \r")
			done <- true
			return
		case <-ticker.C:
			elapsed := time.Since(startTime)
			s := atomic.LoadInt64(success)
			f := atomic.LoadInt64(failed)
			ops := float64(s) / elapsed.Seconds()
			spin := spinChars[spinIdx%len(spinChars)]
			spinIdx++

			fmt.Printf("\r   %s Running... Success: %d | Failed: %d | %.1f ops/s | %v elapsed   ",
				spin, s, f, ops, elapsed.Round(time.Millisecond))
		}
	}
}

// Test functions
func testSimpleRead(db *sql.DB) error {
	id := rand.Intn(1000) + 1
	var data string
	var value int
	return db.QueryRow(`SELECT data, value FROM loadtest_simple WHERE id = $1`, id).Scan(&data, &value)
}

func testSimpleWrite(db *sql.DB) error {
	_, err := db.Exec(`INSERT INTO loadtest_simple (data, value) VALUES ($1, $2)`,
		fmt.Sprintf("test_data_%d", rand.Int63()), rand.Intn(10000))
	return err
}

func testMixedOperations(db *sql.DB) error {
	if rand.Float32() < 0.7 { // 70% reads
		return testSimpleRead(db)
	}
	return testSimpleWrite(db)
}

func testBatchInsert(db *sql.DB) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`INSERT INTO loadtest_simple (data, value) VALUES ($1, $2)`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for i := 0; i < 10; i++ {
		if _, err := stmt.Exec(fmt.Sprintf("batch_%d_%d", time.Now().UnixNano(), i), rand.Intn(10000)); err != nil {
			return err
		}
	}

	return tx.Commit()
}

func testTimeSeriesInsert(db *sql.DB) error {
	_, err := db.Exec(`INSERT INTO loadtest_timeseries (time, device_id, temperature, humidity, pressure) 
		VALUES ($1, $2, $3, $4, $5)`,
		time.Now(),
		fmt.Sprintf("device_%d", rand.Intn(100)),
		20+rand.Float64()*15,
		30+rand.Float64()*50,
		1000+rand.Float64()*50)
	return err
}

func testTimeRangeQuery(db *sql.DB) error {
	endTime := time.Now()
	startTime := endTime.Add(-time.Duration(rand.Intn(60)+1) * time.Minute)

	rows, err := db.Query(`SELECT time, device_id, temperature, humidity, pressure 
		FROM loadtest_timeseries 
		WHERE time >= $1 AND time <= $2 
		ORDER BY time DESC 
		LIMIT 100`, startTime, endTime)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var t time.Time
		var deviceID string
		var temp, humidity, pressure float64
		if err := rows.Scan(&t, &deviceID, &temp, &humidity, &pressure); err != nil {
			return err
		}
	}
	return rows.Err()
}

func testComplexQuery(db *sql.DB) error {
	deviceID := fmt.Sprintf("device_%d", rand.Intn(10))

	rows, err := db.Query(`
		SELECT 
			device_id,
			COUNT(*) as count,
			AVG(temperature) as avg_temp,
			MIN(temperature) as min_temp,
			MAX(temperature) as max_temp,
			AVG(humidity) as avg_humidity,
			AVG(pressure) as avg_pressure
		FROM loadtest_timeseries
		WHERE device_id = $1
		  AND time >= NOW() - INTERVAL '1 hour'
		GROUP BY device_id
	`, deviceID)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var id string
		var count int
		var avgTemp, minTemp, maxTemp, avgHumidity, avgPressure sql.NullFloat64
		if err := rows.Scan(&id, &count, &avgTemp, &minTemp, &maxTemp, &avgHumidity, &avgPressure); err != nil {
			return err
		}
	}
	return rows.Err()
}

// UI Functions
func printBanner() {
	fmt.Println()
	fmt.Println(Cyan + Bold + `
  ╔══════════════════════════════════════════════════════════════════════╗
  ║                                                                      ║
  ║   ██████╗ ██████╗     ██╗      ██████╗  █████╗ ██████╗ ████████╗     ║
  ║   ██╔══██╗██╔══██╗    ██║     ██╔═══██╗██╔══██╗██╔══██╗╚══██╔══╝     ║
  ║   ██║  ██║██████╔╝    ██║     ██║   ██║███████║██║  ██║   ██║        ║
  ║   ██║  ██║██╔══██╗    ██║     ██║   ██║██╔══██║██║  ██║   ██║        ║
  ║   ██████╔╝██████╔╝    ███████╗╚██████╔╝██║  ██║██████╔╝   ██║        ║
  ║   ╚═════╝ ╚═════╝     ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═════╝    ╚═╝        ║
  ║                                                                      ║
  ║         PostgreSQL / TimescaleDB Load Testing Framework              ║
  ║                        Version 1.1.0                                 ║
  ╚══════════════════════════════════════════════════════════════════════╝
` + Reset)
}

func printSection(title string) {
	fmt.Println()
	fmt.Printf("%s%s══════════════════════════════════════════════════════════════════════%s\n", Blue, Bold, Reset)
	fmt.Printf("%s%s  %s%s\n", Blue, Bold, title, Reset)
	fmt.Printf("%s%s══════════════════════════════════════════════════════════════════════%s\n", Blue, Bold, Reset)
}

func printTestHeader(name string) {
	fmt.Println()
	fmt.Printf("%s┌──────────────────────────────────────────────────────────────────────┐%s\n", Magenta, Reset)
	fmt.Printf("%s│%s %-68s %s│%s\n", Magenta, White+Bold, "[TEST] "+name, Magenta, Reset)
	fmt.Printf("%s└──────────────────────────────────────────────────────────────────────┘%s\n", Magenta, Reset)
}

func printTestResult(result TestResult) {
	fmt.Println()
	successRate := float64(result.SuccessOps) / float64(result.TotalOps) * 100

	// Status indicator
	statusIcon := "[OK]"
	if successRate < 95 {
		statusIcon = "[WARN]"
	}
	if successRate < 80 {
		statusIcon = "[FAIL]"
	}

	fmt.Printf("   %s Result: %.1f%% success rate\n", statusIcon, successRate)
	fmt.Println()
	fmt.Println("   ┌─────────────────────────────────────────────────────────────────┐")
	fmt.Printf("   │ %-20s %d ops                                   │\n", "Total Operations:", result.TotalOps)
	fmt.Printf("   │ %-20s %d ops                                   │\n", "Successful:", result.SuccessOps)
	fmt.Printf("   │ %-20s %d ops                                   │\n", "Failed:", result.FailedOps)
	fmt.Printf("   │ %-20s %.2f ops/sec                             │\n", "Throughput:", result.OpsPerSecond)
	fmt.Println("   ├─────────────────────────────────────────────────────────────────┤")
	fmt.Printf("   │ %-20s %v                                  │\n", "Avg Latency:", result.AvgLatency.Round(time.Microsecond))
	fmt.Printf("   │ %-20s %v                                  │\n", "Min Latency:", result.MinLatency.Round(time.Microsecond))
	fmt.Printf("   │ %-20s %v                                  │\n", "Max Latency:", result.MaxLatency.Round(time.Microsecond))
	fmt.Println("   └─────────────────────────────────────────────────────────────────┘")
}

func printFinalReport(results []TestResult) {
	printSection("Final Report Summary")
	fmt.Println()

	// Header
	fmt.Println("   ┌──────────────────────────────────────────┬───────────┬───────────┬───────────┐")
	fmt.Printf("   │ %-40s │ %-9s │ %-9s │ %-9s │\n", "Test Name", "Ops/Sec", "Avg Lat", "Success%")
	fmt.Println("   ├──────────────────────────────────────────┼───────────┼───────────┼───────────┤")

	var totalOps, totalSuccess float64
	var bestThroughput, worstThroughput float64 = 0, 999999999
	var bestTest, worstTest string

	for _, r := range results {
		successRate := float64(r.SuccessOps) / float64(r.TotalOps) * 100
		totalOps += float64(r.TotalOps)
		totalSuccess += float64(r.SuccessOps)

		if r.OpsPerSecond > bestThroughput {
			bestThroughput = r.OpsPerSecond
			bestTest = r.Name
		}
		if r.OpsPerSecond < worstThroughput && r.OpsPerSecond > 0 {
			worstThroughput = r.OpsPerSecond
			worstTest = r.Name
		}

		name := r.Name
		if len(name) > 38 {
			name = name[:35] + "..."
		}

		fmt.Printf("   │ %-40s │ %9.2f │ %9s │ %8.1f%% │\n",
			name, r.OpsPerSecond, r.AvgLatency.Round(time.Microsecond).String(), successRate)
	}

	fmt.Println("   └──────────────────────────────────────────┴───────────┴───────────┴───────────┘")

	// Summary stats
	fmt.Println()
	fmt.Printf("   [BEST]    Best Throughput: %.2f ops/sec (%s)\n", bestThroughput, bestTest)
	fmt.Printf("   [SLOW]    Slowest:         %.2f ops/sec (%s)\n", worstThroughput, worstTest)
	fmt.Printf("   [TOTAL]   Overall Success: %.1f%% (%.0f/%.0f ops)\n", totalSuccess/totalOps*100, totalSuccess, totalOps)
}

func printReplicationReport(result ReplicationResult) {
	printSection("Replication Lag Report")
	fmt.Println()

	successRate := float64(result.SuccessCount) / float64(result.TestCount) * 100

	fmt.Println("   ┌─────────────────────────────────────────────────────────────────┐")
	fmt.Printf("   │ %-30s %-33d │\n", "Total Tests:", result.TestCount)
	fmt.Printf("   │ %-30s %-33d │\n", "Successful:", result.SuccessCount)
	fmt.Printf("   │ %-30s %-33d │\n", "Failed/Timeout:", result.FailedCount)
	fmt.Printf("   │ %-30s %-32.1f%% │\n", "Success Rate:", successRate)
	fmt.Println("   ├─────────────────────────────────────────────────────────────────┤")
	fmt.Printf("   │ %-30s %-33s │\n", "Average Replication Lag:", result.AvgLag.Round(time.Microsecond))
	fmt.Printf("   │ %-30s %-33s │\n", "Minimum Replication Lag:", result.MinLag.Round(time.Microsecond))
	fmt.Printf("   │ %-30s %-33s │\n", "Maximum Replication Lag:", result.MaxLag.Round(time.Microsecond))
	fmt.Println("   ├─────────────────────────────────────────────────────────────────┤")
	fmt.Printf("   │ %-30s %-33s │\n", "P50 (Median) Lag:", result.P50Lag.Round(time.Microsecond))
	fmt.Printf("   │ %-30s %-33s │\n", "P95 Lag:", result.P95Lag.Round(time.Microsecond))
	fmt.Printf("   │ %-30s %-33s │\n", "P99 Lag:", result.P99Lag.Round(time.Microsecond))
	fmt.Println("   └─────────────────────────────────────────────────────────────────┘")

	// Performance assessment
	fmt.Println()
	if result.AvgLag < 10*time.Millisecond {
		fmt.Println("   [EXCELLENT] Replication is very fast! Avg lag < 10ms")
	} else if result.AvgLag < 100*time.Millisecond {
		fmt.Println("   [GOOD] Replication is healthy. Avg lag < 100ms")
	} else if result.AvgLag < 1*time.Second {
		fmt.Println("   [WARNING] Replication lag is noticeable. Avg lag < 1s")
	} else {
		fmt.Println("   [CRITICAL] Replication lag is high! Avg lag > 1s")
	}
}

func printDatabaseInfo(db *sql.DB) {
	var version string
	db.QueryRow("SELECT version()").Scan(&version)
	logInfo("Version", version)

	// Check for TimescaleDB
	var tsVersion string
	err := db.QueryRow("SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'").Scan(&tsVersion)
	if err == nil {
		logInfo("TimescaleDB", "v"+tsVersion+" [OK]")
	} else {
		logInfo("TimescaleDB", "Not installed")
	}

	// Check if this is a replica
	var isRecovery bool
	err = db.QueryRow("SELECT pg_is_in_recovery()").Scan(&isRecovery)
	if err == nil {
		if isRecovery {
			logInfo("Role", "REPLICA (read-only)")
		} else {
			logInfo("Role", "PRIMARY (read-write)")
		}
	}
}

func logInfo(label, value string) {
	fmt.Printf("   %s[INFO]%s %s: %s\n", Cyan, Reset, label, value)
}

func logSuccess(msg string) {
	fmt.Printf("   %s[OK]%s %s\n", Green, Reset, msg)
}

func logError(msg string, err error) {
	fmt.Printf("   %s[ERROR]%s %s: %v\n", Red, Reset, msg, err)
}

func logWarning(msg string) {
	fmt.Printf("   %s[WARN]%s %s\n", Yellow, Reset, msg)
}

func printFooter() {
	fmt.Println()
	fmt.Println(Cyan + Bold + `
  ╔══════════════════════════════════════════════════════════════════════╗
  ║                                                                      ║
  ║                    Load Test Complete!                               ║
  ║                                                                      ║
  ║          Thank you for using DB Load Test Framework                  ║
  ║                                                                      ║
  ╚══════════════════════════════════════════════════════════════════════╝
` + Reset)
}
