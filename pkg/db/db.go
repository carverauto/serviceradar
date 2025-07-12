/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package db

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/timeplus-io/proton-go-driver/v2"
	"github.com/timeplus-io/proton-go-driver/v2/lib/driver"
)

// DB represents the database connection for Timeplus Proton.
type DB struct {
	Conn          proton.Conn
	writeBuffer   []*models.SweepResult
	bufferMutex   sync.Mutex
	flushTimer    *time.Timer
	ctx           context.Context
	cancel        context.CancelFunc
	maxBufferSize int
	flushInterval time.Duration
}

// createTLSConfig builds TLS configuration from security settings
func createTLSConfig(config *models.DBConfig) (*tls.Config, error) {
	// Construct absolute paths for certificate files
	certDir := config.Security.CertDir
	certFile := config.Security.TLS.CertFile
	keyFile := config.Security.TLS.KeyFile
	caFile := config.Security.TLS.CAFile

	// Prepend CertDir to relative paths
	if certDir != "" {
		if !filepath.IsAbs(certFile) {
			certFile = filepath.Join(certDir, certFile)
		}

		if !filepath.IsAbs(keyFile) {
			keyFile = filepath.Join(certDir, keyFile)
		}

		if !filepath.IsAbs(caFile) {
			caFile = filepath.Join(certDir, caFile)
		}
	}

	// Load client certificate and key
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to load client certificate: %w", ErrFailedOpenDB, err)
	}

	// Load CA certificate
	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to read CA certificate: %w", ErrFailedOpenDB, err)
	}

	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("%w: failed to append CA certificate to pool", ErrFailedOpenDB)
	}

	// Configure TLS with mTLS settings
	return &tls.Config{
		Certificates:       []tls.Certificate{cert},
		RootCAs:            caCertPool,
		InsecureSkipVerify: false,
		MinVersion:         tls.VersionTLS13,
		ServerName:         config.Security.ServerName,
	}, nil
}

// New creates a new database connection and initializes the schema.
func New(ctx context.Context, config *models.DBConfig) (Service, error) {
	tlsConfig, err := createTLSConfig(config)
	if err != nil {
		return nil, err
	}

	conn, err := proton.Open(&proton.Options{
		Addr: []string{config.DBAddr},
		TLS:  tlsConfig,
		Auth: proton.Auth{
			Database: config.DBName,
			Username: config.DBUser,
			Password: config.DBPass,
		},
		Compression: &proton.Compression{
			Method: proton.CompressionLZ4,
		},
		Settings: proton.Settings{
			"max_execution_time":         60,
			"max_memory_usage":           2000000000, // 2 GiB
			"max_insert_block_size":      100000,
			"min_insert_block_size_rows": 1000,
		},
		DialTimeout:     5 * time.Second,
		MaxOpenConns:    10,
		MaxIdleConns:    5,
		ConnMaxLifetime: time.Hour,
	})

	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrFailedOpenDB, err)
	}

	// Run database migrations to ensure schema is up-to-date.
	if err := RunMigrations(ctx, conn); err != nil {
		return nil, fmt.Errorf("failed to run database migrations: %w", err)
	}

	return createDBWithBuffer(ctx, conn, config), nil
}

// createDBWithBuffer creates the DB struct with write buffering configured
func createDBWithBuffer(ctx context.Context, conn proton.Conn, config *models.DBConfig) *DB {
	bufferCtx, cancel := context.WithCancel(ctx)

	// Configure write buffer settings
	maxBufferSize := 500
	flushInterval := 30 * time.Second

	if config.WriteBuffer.MaxSize > 0 {
		maxBufferSize = config.WriteBuffer.MaxSize
	}

	if config.WriteBuffer.FlushInterval > 0 {
		flushInterval = time.Duration(config.WriteBuffer.FlushInterval)
	}

	db := &DB{
		Conn:          conn,
		writeBuffer:   make([]*models.SweepResult, 0, maxBufferSize*2), // Pre-allocate with 2x capacity
		ctx:           bufferCtx,
		cancel:        cancel,
		maxBufferSize: maxBufferSize,
		flushInterval: flushInterval,
	}

	// Start the background flush routine only if buffering is enabled
	if maxBufferSize > 0 {
		go db.backgroundFlush()
		log.Printf("DEBUG [database]: Started write buffer with max_size=%d, flush_interval=%v", maxBufferSize, flushInterval)
	} else {
		log.Printf("DEBUG [database]: Write buffering disabled, all writes will be direct")
	}

	return db
}

// Close closes the database connection.
func (db *DB) Close() error {
	// Stop the background flush routine
	if db.cancel != nil {
		db.cancel()
	}

	// Flush any remaining data
	if err := db.flushBuffer(context.Background()); err != nil {
		log.Printf("WARNING [database]: Failed to flush buffer during close: %v", err)
	}

	return db.Conn.Close()
}

// ExecuteQuery executes a raw SQL query against the Proton database.
func (db *DB) ExecuteQuery(ctx context.Context, query string, params ...interface{}) ([]map[string]interface{}, error) {
	rows, err := db.Conn.Query(ctx, query, params...)
	if err != nil {
		return nil, fmt.Errorf("failed to execute query: %w", err)
	}
	defer rows.Close()

	columnTypes := rows.ColumnTypes()

	columns := make([]string, len(columnTypes))

	for i, ct := range columnTypes {
		columns[i] = ct.Name()
	}

	var results []map[string]interface{}

	scanVars := make([]interface{}, len(columnTypes))

	for i := range columnTypes {
		scanVars[i] = reflect.New(columnTypes[i].ScanType()).Interface()
	}

	for rows.Next() {
		if err := rows.Scan(scanVars...); err != nil {
			return nil, fmt.Errorf("failed to scan row: %w", err)
		}

		row := convertRow(columns, scanVars)
		results = append(results, row)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating rows: %w", err)
	}

	return results, nil
}

// convertRow converts scanned row values to a map, handling type dereferencing.
func convertRow(columns []string, scanVars []interface{}) map[string]interface{} {
	row := make(map[string]interface{}, len(columns))

	for i, col := range columns {
		row[col] = dereferenceValue(scanVars[i])
	}

	return row
}

// dereferenceValue dereferences a scanned value and returns its concrete type.
func dereferenceValue(v interface{}) interface{} {
	switch val := v.(type) {
	case *string:
		return *val
	case *uint8:
		return *val
	case *uint64:
		return *val
	case *int64:
		return *val
	case *float64:
		return *val
	case *time.Time:
		return *val
	case *bool:
		return *val
	default:
		// Handle non-pointer types or unexpected types
		if reflect.TypeOf(v).Kind() == reflect.Ptr {
			if reflect.ValueOf(v).IsNil() {
				return nil
			}

			return reflect.ValueOf(v).Elem().Interface()
		}

		return v
	}
}

// executeBatch prepares and sends a batch operation, handling errors.
func (db *DB) executeBatch(ctx context.Context, query string, appendFunc func(driver.Batch) error) error {
	batch, err := db.Conn.PrepareBatch(ctx, query)
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	if err := appendFunc(batch); err != nil {
		return fmt.Errorf("failed to append to batch: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to send batch: %w", err)
	}

	return nil
}

// GetAllMountPoints retrieves all unique mount points for a poller.
func (db *DB) GetAllMountPoints(ctx context.Context, pollerID string) ([]string, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT DISTINCT mount_point
		FROM table(disk_metrics)
		WHERE poller_id = $1 
		ORDER BY mount_point`,
		pollerID)
	if err != nil {
		log.Printf("Error querying mount points: %v", err)
		return nil, fmt.Errorf("failed to query mount points: %w", err)
	}
	defer CloseRows(rows)

	var mountPoints []string

	for rows.Next() {
		var mountPoint string

		if err := rows.Scan(&mountPoint); err != nil {
			log.Printf("Error scanning mount point: %v", err)

			continue
		}

		mountPoints = append(mountPoints, mountPoint)
	}

	log.Printf("Found %d unique mount points for poller %s", len(mountPoints), pollerID)

	return mountPoints, nil
}

func isValidTimestamp(t time.Time) bool {
	minTime := time.Date(1925, 1, 1, 0, 0, 0, 0, time.UTC)
	maxTime := time.Date(2283, 11, 11, 0, 0, 0, 0, time.UTC)

	return t.After(minTime) && t.Before(maxTime)
}

// PublishBatchSweepResults publishes a batch of sweep results to the sweep_results stream.
func (db *DB) PublishBatchSweepResults(ctx context.Context, results []*models.SweepResult) error {
	// If buffering is disabled (maxBufferSize = 0), write directly
	if db.maxBufferSize == 0 {
		log.Printf("DEBUG [database]: Buffering disabled, writing %d results directly", len(results))
		return db.StoreSweepResults(ctx, results)
	}

	db.bufferMutex.Lock()
	defer db.bufferMutex.Unlock()

	// Add results to buffer
	db.writeBuffer = append(db.writeBuffer, results...)

	log.Printf("DEBUG [database]: Added %d results to buffer, buffer size now: %d", len(results), len(db.writeBuffer))

	// Check if we need to flush immediately
	if len(db.writeBuffer) >= db.maxBufferSize {
		log.Printf("DEBUG [database]: Buffer size limit reached (%d), flushing immediately", len(db.writeBuffer))
		return db.flushBufferUnsafe(ctx)
	}

	// Reset the flush timer
	if db.flushTimer != nil {
		db.flushTimer.Stop()
	}

	db.flushTimer = time.AfterFunc(db.flushInterval, func() {
		db.bufferMutex.Lock()
		defer db.bufferMutex.Unlock()

		if len(db.writeBuffer) > 0 {
			log.Printf("DEBUG [database]: Timer triggered flush for %d buffered results", len(db.writeBuffer))

			if err := db.flushBufferUnsafe(context.Background()); err != nil {
				log.Printf("ERROR [database]: Timer flush failed: %v", err)
			}
		}
	})

	return nil
}

// PublishSweepResult publishes a single sweep result to the sweep_results stream.
func (db *DB) PublishSweepResult(ctx context.Context, result *models.SweepResult) error {
	return db.PublishBatchSweepResults(ctx, []*models.SweepResult{result})
}

// backgroundFlush runs a background goroutine to periodically flush the buffer
func (db *DB) backgroundFlush() {
	ticker := time.NewTicker(db.flushInterval / 2) // Check twice as often as flush interval
	defer ticker.Stop()

	for {
		select {
		case <-db.ctx.Done():
			log.Printf("DEBUG [database]: Background flush routine stopping")
			return
		case <-ticker.C:
			db.bufferMutex.Lock()
			if len(db.writeBuffer) > 0 {
				log.Printf("DEBUG [database]: Background flush triggered for %d buffered results", len(db.writeBuffer))

				if err := db.flushBufferUnsafe(context.Background()); err != nil {
					log.Printf("ERROR [database]: Background flush failed: %v", err)
				}
			}
			db.bufferMutex.Unlock()
		}
	}
}

// flushBuffer safely flushes the write buffer to the database
func (db *DB) flushBuffer(ctx context.Context) error {
	db.bufferMutex.Lock()
	defer db.bufferMutex.Unlock()

	return db.flushBufferUnsafe(ctx)
}

// flushBufferUnsafe flushes the write buffer to the database (caller must hold bufferMutex)
func (db *DB) flushBufferUnsafe(ctx context.Context) error {
	if len(db.writeBuffer) == 0 {
		return nil
	}

	// Make a copy of the buffer to minimize lock time
	toFlush := make([]*models.SweepResult, len(db.writeBuffer))
	copy(toFlush, db.writeBuffer)

	// Clear the buffer
	db.writeBuffer = db.writeBuffer[:0]

	// Stop the timer since we're flushing now
	if db.flushTimer != nil {
		db.flushTimer.Stop()
		db.flushTimer = nil
	}

	log.Printf("DEBUG [database]: Flushing %d buffered results to database", len(toFlush))

	// Perform the actual database write
	if err := db.StoreSweepResults(ctx, toFlush); err != nil {
		// On error, add the data back to the buffer to retry later
		log.Printf("ERROR [database]: Failed to flush buffer, re-adding %d results: %v", len(toFlush), err)
		db.writeBuffer = append(db.writeBuffer, toFlush...)

		return err
	}

	log.Printf("DEBUG [database]: Successfully flushed %d results to database", len(toFlush))

	return nil
}

// CloseRows safely closes a Rows type and logs any error.
func CloseRows(rows Rows) {
	if err := rows.Close(); err != nil {
		log.Printf("failed to close rows: %v", err)
	}
}
