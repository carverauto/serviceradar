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
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/carverauto/serviceradar/pkg/deviceupdate"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// Static errors for err113 compliance
var (
	ErrDatabaseNotInitialized = errors.New("database connection not initialized")
	ErrCNPGUnavailable        = errors.New("cnpg connection pool not configured")
	ErrStreamingUnsupported   = errors.New("proton streaming connections are no longer supported")
)

// DB represents the CNPG-backed database connection.
type DB struct {
	pgPool *pgxpool.Pool
	logger logger.Logger
}

// GetStreamingConnection returns the underlying proton connection for streaming queries
func (db *DB) GetStreamingConnection() (interface{}, error) {
	return nil, ErrStreamingUnsupported
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

	return &DB{
		pgPool: cnpgPool,
		logger: log,
	}, nil
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
	return db != nil && db.pgPool != nil
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

// Close closes the database connection.
func (db *DB) Close() error {
	if db.pgPool != nil {
		db.pgPool.Close()
	}

	return nil
}

// QueryCNPGRows executes a query against the CNPG pool and returns a Rows implementation.
func (db *DB) QueryCNPGRows(ctx context.Context, query string, args ...interface{}) (Rows, error) {
	if !db.cnpgConfigured() {
		return nil, ErrCNPGUnavailable
	}

	rows, err := db.pgPool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}

	return &cnpgRows{rows: rows}, nil
}

// ExecCNPG executes a statement against the CNPG pool.
func (db *DB) ExecCNPG(ctx context.Context, query string, args ...interface{}) error {
	if !db.cnpgConfigured() {
		return ErrCNPGUnavailable
	}

	if _, err := db.pgPool.Exec(ctx, query, args...); err != nil {
		return fmt.Errorf("cnpg exec: %w", err)
	}

	return nil
}

// ExecuteQuery executes a raw SQL query against the CNPG database.
func (db *DB) ExecuteQuery(ctx context.Context, query string, params ...interface{}) ([]map[string]interface{}, error) {
	if !db.cnpgConfigured() {
		return nil, ErrCNPGUnavailable
	}

	rows, err := db.pgPool.Query(ctx, query, params...)
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
			row[string(fd.Name)] = normalizeCNPGValue(values[idx])
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
				update.Partition = "default"
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
		return fmt.Errorf("cnpg rows not initialized")
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
