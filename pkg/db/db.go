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
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/carverauto/serviceradar/pkg/deviceupdate"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// Static errors for err113 compliance
var (
	ErrDatabaseNotInitialized = errors.New("database connection not initialized")
	ErrCNPGUnavailable        = errors.New("cnpg connection pool not configured")
	ErrUnknownExecutorType    = errors.New("unknown executor type")
)

const defaultPartitionValue = "default"

// PgxExecutor is an interface satisfied by both *pgxpool.Pool and pgx.Tx
type PgxExecutor interface {
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	SendBatch(ctx context.Context, b *pgx.Batch) pgx.BatchResults
}

// DB represents the CNPG-backed database connection.
type DB struct {
	pgPool   *pgxpool.Pool
	executor PgxExecutor
	logger   logger.Logger

	// deviceUpdatesMu serializes CNPG device-related batch writes to prevent deadlocks.
	// This mutex protects cnpgInsertDeviceUpdates, UpsertDeviceIdentifiers, and
	// StoreNetworkSightings operations from circular lock dependencies.
	// Using a pointer so transaction-scoped DB copies share the same mutex.
	deviceUpdatesMu *sync.Mutex
}

// New creates a new CNPG-backed database connection and initializes the schema.
func New(ctx context.Context, config *models.CoreServiceConfig, log logger.Logger) (Service, error) {
	if config == nil {
		return nil, fmt.Errorf("%w: database configuration missing", ErrFailedOpenDB)
	}

	cnpgPool, err := newCNPGPool(ctx, config, log)
	if err != nil {
		return nil, err
	}

	if cnpgPool == nil {
		return nil, fmt.Errorf("%w: CNPG configuration not provided", ErrFailedOpenDB)
	}

	if shouldRunDBMigrations() {
		if err := RunCNPGMigrations(ctx, cnpgPool, log); err != nil {
			cnpgPool.Close()
			return nil, fmt.Errorf("failed to run CNPG migrations: %w", err)
		}
	} else {
		log.Info().Msg("Skipping CNPG migrations (ENABLE_DB_MIGRATIONS=false)")
	}

	db := &DB{
		pgPool:          cnpgPool,
		executor:        cnpgPool, // Default to pool
		logger:          log,
		deviceUpdatesMu: &sync.Mutex{},
	}

	return db, nil
}

func shouldRunDBMigrations() bool {
	val, ok := os.LookupEnv("ENABLE_DB_MIGRATIONS")
	if !ok {
		return true
	}

	val = strings.TrimSpace(strings.ToLower(val))
	switch val {
	case "", "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return true
	}
}

func (db *DB) cnpgConfigured() bool {
	return db != nil && db.executor != nil
}

func (db *DB) UseCNPGReads() bool {
	return db.cnpgConfigured()
}

func (db *DB) UseCNPGWrites() bool {
	return db.useCNPGWrites()
}

func (db *DB) useCNPGWrites() bool {
	return db.cnpgConfigured()
}

func (db *DB) conn() PgxExecutor {
	if db.executor != nil {
		return db.executor
	}
	return db.pgPool
}

// Close closes the database connection.
func (db *DB) Close() error {
	if db.pgPool != nil {
		db.pgPool.Close()
	}

	return nil
}

// WithTx executes the given function within a transaction.
func (db *DB) WithTx(ctx context.Context, fn func(tx Service) error) error {
	if db.pgPool == nil {
		return ErrCNPGUnavailable
	}

	// If we are already in a transaction, we can create a savepoint (nested tx)
	// but simpler for now to just reuse the executor if it's already a tx,
	// OR if it's the pool, start a new tx.
	// Since db.executor is initialized to pgPool, checking type is safer.

	var tx pgx.Tx
	var err error

	if _, ok := db.executor.(*pgxpool.Pool); ok {
		// Start a new transaction from the pool
		tx, err = db.pgPool.Begin(ctx)
		if err != nil {
			return fmt.Errorf("begin tx: %w", err)
		}
	} else if currentTx, ok := db.executor.(pgx.Tx); ok {
		// Already in a transaction, create a nested transaction (savepoint)
		tx, err = currentTx.Begin(ctx)
		if err != nil {
			return fmt.Errorf("begin nested tx: %w", err)
		}
	} else {
		return ErrUnknownExecutorType
	}

	defer func() {
		if p := recover(); p != nil {
			_ = tx.Rollback(ctx)
			panic(p)
		}
	}()

	// Create a shallow copy of DB using the transaction executor
	txDB := &DB{
		pgPool:          db.pgPool, // Keep pool reference for access to stateless methods if needed
		executor:        tx,
		logger:          db.logger,
		deviceUpdatesMu: db.deviceUpdatesMu, // Share mutex with parent for deadlock prevention
	}

	if err := fn(txDB); err != nil {
		_ = tx.Rollback(ctx)
		return err
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit tx: %w", err)
	}

	return nil
}

// LockOCSFDevices locks the specified IPs in the ocsf_devices table for update.
func (db *DB) LockOCSFDevices(ctx context.Context, ips []string) error {
	if len(ips) == 0 {
		return nil
	}
	if !db.cnpgConfigured() {
		return ErrCNPGUnavailable
	}

	// SELECT ... FOR UPDATE SKIP LOCKED is typical for queue processing,
	// but here we want to wait for the lock because we intend to update these specific rows.
	// We use NO KEY UPDATE to avoid blocking foreign key checks if we're not modifying PKs
	// (though we might modify PK if we delete? No, we update rows).
	const query = `
SELECT 1 FROM ocsf_devices
WHERE ip = ANY($1)
FOR UPDATE`

	_, err := db.conn().Exec(ctx, query, ips)
	if err != nil {
		return fmt.Errorf("failed to lock OCSF devices: %w", err)
	}

	return nil
}

// QueryCNPGRows executes a query against the CNPG pool and returns a Rows implementation.
func (db *DB) QueryCNPGRows(ctx context.Context, query string, args ...interface{}) (Rows, error) {
	if !db.cnpgConfigured() {
		return nil, ErrCNPGUnavailable
	}

	rows, err := db.conn().Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}

	return &cnpgRows{rows: rows}, nil
}

// QueryRegistryRows proxies registry reads to the CNPG pool.
func (db *DB) QueryRegistryRows(ctx context.Context, query string, args ...interface{}) (Rows, error) {
	return db.QueryCNPGRows(ctx, query, args...)
}

// ExecCNPG executes a statement against the CNPG pool.
func (db *DB) ExecCNPG(ctx context.Context, query string, args ...interface{}) error {
	if !db.cnpgConfigured() {
		return ErrCNPGUnavailable
	}

	if _, err := db.conn().Exec(ctx, query, args...); err != nil {
		return fmt.Errorf("cnpg exec: %w", err)
	}

	return nil
}

// ExecuteQuery executes a raw SQL query against the CNPG database.
func (db *DB) ExecuteQuery(ctx context.Context, query string, params ...interface{}) ([]map[string]interface{}, error) {
	if !db.cnpgConfigured() {
		return nil, ErrCNPGUnavailable
	}

	rows, err := db.conn().Query(ctx, query, params...)
	if err != nil {
		return nil, fmt.Errorf("failed to execute query: %w", err)
	}
	defer rows.Close()

	fieldDescriptions := rows.FieldDescriptions()
	var results []map[string]interface{}

	for rows.Next() {
		values, err := rows.Values()
		if err != nil {
			return nil, fmt.Errorf("failed to read row values: %w", err)
		}

		row := make(map[string]interface{}, len(fieldDescriptions))
		for idx, fd := range fieldDescriptions {
			row[fd.Name] = normalizeCNPGValue(values[idx])
		}

		results = append(results, row)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating rows: %w", err)
	}

	return results, nil
}

func normalizeCNPGValue(value interface{}) interface{} {
	switch v := value.(type) {
	case []byte:
		return string(v)
	case time.Time:
		return v.UTC()
	default:
		return v
	}
}

// GetAllMountPoints retrieves all unique mount points for a poller.
// PublishDeviceUpdate publishes a single device update to the device_updates stream.
func (db *DB) PublishDeviceUpdate(ctx context.Context, update *models.DeviceUpdate) error {
	return db.PublishBatchDeviceUpdates(ctx, []*models.DeviceUpdate{update})
}

// PublishBatchDeviceUpdates publishes device updates directly to the device_updates stream.
func (db *DB) PublishBatchDeviceUpdates(ctx context.Context, updates []*models.DeviceUpdate) error {
	if len(updates) == 0 {
		return nil
	}

	for _, update := range updates {
		deviceupdate.SanitizeMetadata(update)
		normalizeDeviceUpdate(update)
	}

	return db.cnpgInsertDeviceUpdates(ctx, updates)
}

func normalizeDeviceUpdate(update *models.DeviceUpdate) {
	if update == nil {
		return
	}

	// Ensure required fields
	if update.DeviceID == "" {
		// Check if this is a service component (poller/agent/checker)
		if update.ServiceType != nil && update.ServiceID != "" {
			// Generate service-aware device ID: serviceradar:type:id
			update.DeviceID = models.GenerateServiceDeviceID(*update.ServiceType, update.ServiceID)
			update.Partition = models.ServiceDevicePartition
		} else {
			// Generate network device ID: partition:ip
			if update.Partition == "" {
				update.Partition = defaultPartitionValue
			}
			update.DeviceID = models.GenerateNetworkDeviceID(update.Partition, update.IP)
		}
	}

	if update.Metadata == nil {
		update.Metadata = make(map[string]string)
	}
}

type cnpgRows struct {
	rows pgx.Rows
}

func (r *cnpgRows) Next() bool {
	if r == nil || r.rows == nil {
		return false
	}
	return r.rows.Next()
}

func (r *cnpgRows) Scan(dest ...interface{}) error {
	if r == nil || r.rows == nil {
		return ErrCNPGRowsNotInitialized
	}
	return r.rows.Scan(dest...)
}

func (r *cnpgRows) Close() error {
	if r == nil || r.rows == nil {
		return nil
	}
	r.rows.Close()
	return nil
}

func (r *cnpgRows) Err() error {
	if r == nil || r.rows == nil {
		return nil
	}
	return r.rows.Err()
}