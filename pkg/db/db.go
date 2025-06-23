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
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/timeplus-io/proton-go-driver/v2"
	"github.com/timeplus-io/proton-go-driver/v2/lib/driver"
)

// DB represents the database connection for Timeplus Proton.
type DB struct {
	Conn proton.Conn
}

// New creates a new database connection and initializes the schema.
func New(ctx context.Context, config *models.DBConfig) (Service, error) {
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
	tlsConfig := &tls.Config{
		Certificates:       []tls.Certificate{cert},
		RootCAs:            caCertPool,
		InsecureSkipVerify: false,
		MinVersion:         tls.VersionTLS13,
		ServerName:         config.Security.ServerName,
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

	db := &DB{Conn: conn}

	return db, nil
}

// Close closes the database connection.
func (db *DB) Close() error {
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

// CloseRows safely closes a Rows type and logs any error.
func CloseRows(rows Rows) {
	if err := rows.Close(); err != nil {
		log.Printf("failed to close rows: %v", err)
	}
}
