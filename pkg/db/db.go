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
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"time"

	"github.com/timeplus-io/proton-go-driver/v2"
	"github.com/timeplus-io/proton-go-driver/v2/lib/driver"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// Static errors for err113 compliance
var (
	ErrDatabaseNotInitialized = errors.New("database connection not initialized")
)

// DB represents the database connection for Timeplus Proton.
type DB struct {
	Conn          proton.Conn
	writeBuffer   []*models.SweepResult
	ctx           context.Context
	cancel        context.CancelFunc
	maxBufferSize int
	flushInterval time.Duration
	logger        logger.Logger
}

// GetStreamingConnection returns the underlying proton connection for streaming queries
func (db *DB) GetStreamingConnection() (interface{}, error) {
	if db.Conn == nil {
		return nil, ErrDatabaseNotInitialized
	}

	return db.Conn, nil
}

// createTLSConfig builds TLS configuration from security settings
func createTLSConfig(config *models.CoreServiceConfig) (*tls.Config, error) {
	// If no security config, return nil for no TLS
	if config.Security == nil {
		return nil, nil
	}

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

// createDatabaseTLSConfig builds TLS configuration specifically for database connections
func createDatabaseTLSConfig(config *models.CoreServiceConfig) (*tls.Config, error) {
	// If no database TLS config, fall back to service security config
	if config.Database.TLS == nil {
		return createTLSConfig(config)
	}

	dbTLS := config.Database.TLS

	// Construct absolute paths for certificate files
	certFile := dbTLS.CertFile
	keyFile := dbTLS.KeyFile
	caFile := dbTLS.CAFile

	// All database TLS files should already be absolute paths

	if !filepath.IsAbs(certFile) {
		return nil, fmt.Errorf("%w: database TLS cert_file must be absolute path", ErrFailedOpenDB)
	}

	if !filepath.IsAbs(keyFile) {
		return nil, fmt.Errorf("%w: database TLS key_file must be absolute path", ErrFailedOpenDB)
	}

	if !filepath.IsAbs(caFile) {
		return nil, fmt.Errorf("%w: database TLS ca_file must be absolute path", ErrFailedOpenDB)
	}

	// Load client certificate and key
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to load database client certificate: %w", ErrFailedOpenDB, err)
	}

	// Load CA certificate
	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to read database CA certificate: %w", ErrFailedOpenDB, err)
	}

	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("%w: failed to append database CA certificate to pool", ErrFailedOpenDB)
	}

	// Get server name from security config, fallback to "proton.serviceradar" for database
	serverName := "proton.serviceradar"
	if config.Security != nil && config.Security.ServerName != "" {
		serverName = config.Security.ServerName
	}

	// Configure TLS with mTLS settings for database
	return &tls.Config{
		Certificates:       []tls.Certificate{cert},
		RootCAs:            caCertPool,
		InsecureSkipVerify: false,
		MinVersion:         tls.VersionTLS13,
		ServerName:         serverName,
	}, nil
}

// New creates a new database connection and initializes the schema.
func New(ctx context.Context, config *models.CoreServiceConfig, log logger.Logger) (Service, error) {
	tlsConfig, err := createDatabaseTLSConfig(config)
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
			"max_execution_time":         0,          // Disable execution timeout for streaming queries
			"max_memory_usage":           2000000000, // 2 GiB
			"max_insert_block_size":      100000,
			"min_insert_block_size_rows": 1000,
			"max_result_rows":            0,       // Disable row limit for streaming
			"result_overflow_mode":       "break", // Allow unlimited results
			"max_rows_to_read":           0,       // Disable read limit
            "stream_flush_interval_ms":   100,     // Flush streaming results frequently
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
	if err := RunMigrations(ctx, conn, log); err != nil {
		return nil, fmt.Errorf("failed to run database migrations: %w", err)
	}

	return createDBWithBuffer(ctx, conn, config, log), nil
}

// createDBWithBuffer creates the DB struct with write buffering configured
func createDBWithBuffer(ctx context.Context, conn proton.Conn, config *models.CoreServiceConfig, log logger.Logger) *DB {
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
		logger:        log,
	}

	return db
}

// Close closes the database connection.
func (db *DB) Close() error {
	// Stop the background flush routine
	if db.cancel != nil {
		db.cancel()
	}

	return db.Conn.Close()
}

// ExecuteQuery executes a raw SQL query against the Proton database.
func (db *DB) ExecuteQuery(ctx context.Context, query string, params ...interface{}) ([]map[string]interface{}, error) {
	rows, err := db.Conn.Query(ctx, query, params...)
	if err != nil {
		return nil, fmt.Errorf("failed to execute query: %w", err)
	}

	defer func() { _ = rows.Close() }()

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
		db.logger.Error().Err(err).Str("poller_id", pollerID).Msg("Error querying mount points")
		return nil, fmt.Errorf("failed to query mount points: %w", err)
	}
	defer db.CloseRows(rows)

	var mountPoints []string

	for rows.Next() {
		var mountPoint string

		if err := rows.Scan(&mountPoint); err != nil {
			db.logger.Error().Err(err).Str("poller_id", pollerID).Msg("Error scanning mount point")

			continue
		}

		mountPoints = append(mountPoints, mountPoint)
	}

	db.logger.Debug().
		Int("mount_point_count", len(mountPoints)).
		Str("poller_id", pollerID).
		Msg("Found unique mount points")

	return mountPoints, nil
}

func isValidTimestamp(t time.Time) bool {
	minTime := time.Date(1925, 1, 1, 0, 0, 0, 0, time.UTC)
	maxTime := time.Date(2283, 11, 11, 0, 0, 0, 0, time.UTC)

	return t.After(minTime) && t.Before(maxTime)
}

// PublishDeviceUpdate publishes a single device update to the device_updates stream.
func (db *DB) PublishDeviceUpdate(ctx context.Context, update *models.DeviceUpdate) error {
	return db.PublishBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
}

// PublishBatchDeviceUpdates publishes device updates directly to the device_updates stream.
func (db *DB) PublishBatchDeviceUpdates(ctx context.Context, updates []*models.DeviceUpdate) error {
	if len(updates) == 0 {
		return nil
	}

	// Proton's log_max_record_size is typically 10MB
	// Use much smaller batch to account for serialization overhead and metadata
	const maxBatchBytes = 5 * 1024 * 1024 // 5MB safety limit (half of the 10MB limit)

	const maxBatchSize = 500 // Maximum records per batch (reduced from 1000)

	totalUpdates := len(updates)
	db.logger.Debug().
		Int("update_count", totalUpdates).
		Msg("Publishing device updates directly to device_updates stream")

	// Process updates in dynamic chunks based on byte size
	processedCount := 0
	batchNum := 0

	for processedCount < totalUpdates {
		batchNum++
		currentBatchSize := db.calculateBatchSize(updates, processedCount, maxBatchSize, maxBatchBytes)

		if err := db.processBatch(ctx, updates, batchNum, processedCount, currentBatchSize); err != nil {
			return err
		}

		processedCount += currentBatchSize
	}

	db.logger.Info().
		Int("update_count", totalUpdates).
		Int("total_batches", batchNum).
		Msg("Successfully published device updates to device_updates stream")

	return nil
}

// CloseRows safely closes a Rows type and logs any error.
func (db *DB) CloseRows(rows Rows) {
	if err := rows.Close(); err != nil {
		db.logger.Error().Err(err).
			Msg("Error closing rows")
	}
}

// estimateUpdateSize estimates the byte size of a device update record
func (*DB) estimateUpdateSize(update *models.DeviceUpdate) int {
	// Estimate bytes for this record with more conservative calculation
	// Account for column overhead and potential JSON expansion
	recordEstimate := 50 // Base overhead for row structure

	// String fields with padding for potential escaping
	recordEstimate += len(update.AgentID) * 2
	recordEstimate += len(update.PollerID) * 2
	recordEstimate += len(update.Partition) * 2
	recordEstimate += len(update.DeviceID) * 2
	recordEstimate += len(string(update.Source)) * 2
	recordEstimate += len(update.IP) * 2

	if update.MAC != nil {
		recordEstimate += len(*update.MAC) * 2
	}

	if update.Hostname != nil {
		recordEstimate += len(*update.Hostname) * 2
	}

	// Estimate metadata size with more conservative JSON overhead
	// Metadata can be large and JSON serialization adds significant overhead
	metadataEstimate := 50 // Base JSON object overhead
	for k, v := range update.Metadata {
		// Account for JSON escaping, quotes, and structure
		metadataEstimate += (len(k)+len(v))*3 + 20
	}

	recordEstimate += metadataEstimate

	// Add overhead for timestamp and boolean fields
	recordEstimate += 100

	return recordEstimate
}

// calculateBatchSize determines the optimal batch size based on byte limits
func (db *DB) calculateBatchSize(updates []*models.DeviceUpdate, startIndex, maxBatchSize, maxBatchBytes int) int {
	totalUpdates := len(updates)
	currentBatchSize := 0
	estimatedBytes := 0

	// Determine optimal batch size by estimating bytes
	for currentBatchSize < maxBatchSize && startIndex+currentBatchSize < totalUpdates {
		update := updates[startIndex+currentBatchSize]
		recordEstimate := db.estimateUpdateSize(update)

		// Check if adding this record would exceed byte limit
		// Be more conservative - stop if we're over 80% of limit
		if estimatedBytes+recordEstimate > (maxBatchBytes*80/100) && currentBatchSize > 0 {
			break
		}

		estimatedBytes += recordEstimate
		currentBatchSize++
	}

	// If we haven't added any records yet, force at least one
	// This handles the case where a single record is very large
	if currentBatchSize == 0 {
		currentBatchSize = 1

		db.logger.Warn().
			Int("record_index", startIndex).
			Int("estimated_bytes", estimatedBytes).
			Msg("Single record exceeds batch size limit, forcing single record batch")
	}

	// Ensure we don't exceed remaining updates
	remainingUpdates := totalUpdates - startIndex
	if currentBatchSize > remainingUpdates {
		currentBatchSize = remainingUpdates
	}

	return currentBatchSize
}

// processBatch processes a single batch of device updates
func (db *DB) processBatch(ctx context.Context, updates []*models.DeviceUpdate, batchNum, startIndex, batchSize int) error {
	endIndex := startIndex + batchSize
	chunk := updates[startIndex:endIndex]

	// Estimate total bytes for logging
	estimatedBytes := 0
	for _, update := range chunk {
		estimatedBytes += db.estimateUpdateSize(update)
	}

	db.logger.Debug().
		Int("batch_num", batchNum).
		Int("chunk_size", batchSize).
		Int("estimated_bytes", estimatedBytes).
		Int("chunk_start", startIndex).
		Int("chunk_end", endIndex).
		Int("total_updates", len(updates)).
		Msg("Processing device updates chunk with byte size estimation")

	batch, err := db.Conn.PrepareBatch(ctx,
		"INSERT INTO device_updates (agent_id, poller_id, partition, device_id, discovery_source, "+
			"ip, mac, hostname, timestamp, available, metadata)")
	if err != nil {
		return fmt.Errorf("failed to prepare device updates batch %d (records %d-%d): %w", batchNum, startIndex, endIndex, err)
	}

	for _, update := range chunk {
		if err := db.appendUpdateToBatch(batch, update); err != nil {
			return fmt.Errorf("failed to append device update in batch %d (records %d-%d): %w", batchNum, startIndex, endIndex, err)
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to send device updates batch %d (records %d-%d): %w", batchNum, startIndex, endIndex, err)
	}

	db.logger.Debug().
		Int("batch_num", batchNum).
		Int("chunk_size", batchSize).
		Int("estimated_bytes", estimatedBytes).
		Int("processed_so_far", endIndex).
		Int("total_updates", len(updates)).
		Msg("Successfully published device updates chunk")

	return nil
}

// appendUpdateToBatch appends a single device update to a batch
func (*DB) appendUpdateToBatch(batch driver.Batch, update *models.DeviceUpdate) error {
	// Ensure required fields
	if update.DeviceID == "" {
		if update.Partition == "" {
			update.Partition = "default"
		}

		update.DeviceID = fmt.Sprintf("%s:%s", update.Partition, update.IP)
	}

	if update.Metadata == nil {
		update.Metadata = make(map[string]string)
	}

	return batch.Append(
		update.AgentID,
		update.PollerID,
		update.Partition,
		update.DeviceID,
		string(update.Source),
		update.IP,
		update.MAC,
		update.Hostname,
		update.Timestamp,
		update.IsAvailable,
		update.Metadata,
	)
}
