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

	db := &DB{Conn: conn}

	if err := db.initSchema(ctx); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrFailedToInit, err)
	}

	return db, nil
}

// getStreamEngineStatements returns the SQL statements for creating regular Append Streams.
func getStreamEngineStatements() []string {
	var statements []string

	statements = append(statements, getMetricsStreamStatements()...)
	statements = append(statements, getPollerStreamStatements()...)
	statements = append(statements, getServiceStreamStatements()...)
	statements = append(statements, getDiscoveryStreamStatements()...)

	return statements
}

// getMetricsStreamStatements returns SQL statements for metrics-related streams.
func getMetricsStreamStatements() []string {
	return []string{
		`CREATE STREAM IF NOT EXISTS cpu_metrics (
            poller_id string,
            timestamp DateTime64(3) DEFAULT now64(3),
            core_id int32,
            usage_percent float64
        )`,

		`CREATE STREAM IF NOT EXISTS disk_metrics (
            poller_id string,
            timestamp DateTime64(3) DEFAULT now64(3),
            mount_point string,
            used_bytes uint64,
            total_bytes uint64
        )`,

		`CREATE STREAM IF NOT EXISTS memory_metrics (
            poller_id string,
            timestamp DateTime64(3) DEFAULT now64(3),
            used_bytes uint64,
            total_bytes uint64
        )`,

		`CREATE STREAM IF NOT EXISTS timeseries_metrics (
			poller_id string,
			target_device_ip string,     -- NEW: Extracted from metadata.target_name
			ifIndex int32,               -- NEW: Extracted/parsed, e.g. from metric_name
			metric_name string,
			metric_type string,
			value string,
			metadata map(string, string),
			timestamp DateTime64(3) DEFAULT now64(3)
		)`,
	}
}

// getPollerStreamStatements returns SQL statements for poller-related streams.
func getPollerStreamStatements() []string {
	return []string{
		`CREATE STREAM IF NOT EXISTS pollers (
            poller_id string,
            first_seen DateTime64(3) DEFAULT now64(3),
            last_seen DateTime64(3) DEFAULT now64(3),
            is_healthy bool
        )`,

		`CREATE STREAM IF NOT EXISTS poller_history (
            poller_id string,
            timestamp DateTime64(3) DEFAULT now64(3),
            is_healthy bool
        )`,
	}
}

// getServiceStreamStatements returns SQL statements for service-related streams.
func getServiceStreamStatements() []string {
	return []string{
		`CREATE STREAM IF NOT EXISTS service_status (
            poller_id string,
            service_name string,
            service_type string,
            available bool,
            details string,
            timestamp DateTime64(3) DEFAULT now64(3),
            agent_id string
        )`,

		`CREATE STREAM IF NOT EXISTS users (
            id string,
            email string,
            name string,
            provider string,
            created_at DateTime64(3) DEFAULT now64(3),
            updated_at DateTime64(3) DEFAULT now64(3)
        )`,
	}
}

// getDiscoveryStreamStatements returns SQL statements for discovery-related streams.
func getDiscoveryStreamStatements() []string {
	return []string{
		`CREATE STREAM IF NOT EXISTS discovered_interfaces (
			timestamp DateTime64(3) DEFAULT now64(3),
			agent_id string,
			poller_id string,
			device_ip string,
			device_id string, -- (e.g., ip:agent_id:poller_id)
			ifIndex int32,
			ifName nullable(string),
			ifDescr nullable(string),
			ifAlias nullable(string),
			ifSpeed uint64,
			ifPhysAddress nullable(string), -- MAC address of the interface
			ip_addresses array(string),    -- IPs configured on this interface
			ifAdminStatus int32,           -- e.g., up(1), down(2), testing(3)
			ifOperStatus int32,            -- e.g., up(1), down(2), testing(3), unknown(4), dormant(5), notPresent(6), lowerLayerDown(7)
			metadata map(string, string)   -- For any other relevant interface data
		)`,

		`CREATE STREAM IF NOT EXISTS topology_discovery_events (
			timestamp DateTime64(3) DEFAULT now64(3),
			agent_id string,
			poller_id string,
			local_device_ip string, -- IP of the device reporting the event
			local_device_id string, -- Unique ID of the local device
			local_ifIndex int32,
			local_ifName nullable(string),
			protocol_type string, -- 'LLDP', 'CDP', 'BGP'

			-- LLDP/CDP specific fields
			neighbor_chassis_id nullable(string),
			neighbor_port_id nullable(string),
			neighbor_port_descr nullable(string),
			neighbor_system_name nullable(string),
			neighbor_management_address nullable(string), -- Management IP of neighbor

			-- BGP specific fields
			neighbor_bgp_router_id nullable(string), -- For BGP, this could be the neighbor's router ID
			neighbor_ip_address nullable(string),    -- For BGP, the peer IP
			neighbor_as nullable(uint32),
			bgp_session_state nullable(string),

			metadata map(string, string) -- Additional details
		)`,
	}
}

// getVersionedKVStreamStatements returns the SQL statements for creating versioned KV streams.
func getVersionedKVStreamStatements() []string {
	return []string{
		// Versioned Streams using SETTINGS mode='versioned_kv'
		`CREATE STREAM IF NOT EXISTS sweep_results (
          agent_id string,
          poller_id string,
          discovery_source string,
          ip string,
          mac nullable(string),
          hostname nullable(string),
          timestamp DateTime64(3) DEFAULT now64(3),
          available boolean,
          metadata map(string, string)
          -- _tp_time is NOT explicitly defined here
       )
       PRIMARY KEY (ip, agent_id, poller_id)
       SETTINGS mode='versioned_kv', version_column='_tp_time'`,

		`CREATE STREAM IF NOT EXISTS icmp_results (
          agent_id string,
          poller_id string,
          discovery_source string,
          ip string,
          mac nullable(string),
          hostname nullable(string),
          timestamp DateTime64(3) DEFAULT now64(3),
          available boolean,
          metadata map(string, string)
       )
       PRIMARY KEY (ip, agent_id, poller_id)
       SETTINGS mode='versioned_kv', version_column='_tp_time'`,

		`CREATE STREAM IF NOT EXISTS snmp_results (
          agent_id string,
          poller_id string,
          discovery_source string,
          ip string,
          mac nullable(string),
          hostname nullable(string),
          timestamp DateTime64(3) DEFAULT now64(3),
          available boolean,
          metadata map(string, string)
       )
       PRIMARY KEY (ip, agent_id, poller_id)
       SETTINGS mode='versioned_kv', version_column='_tp_time'`,

		`CREATE STREAM IF NOT EXISTS devices (
          device_id string,
          agent_id string,
          poller_id string,
          discovery_source string,
          ip string,
          mac nullable(string),
          hostname nullable(string),
          first_seen DateTime64(3),
          last_seen DateTime64(3),
          is_available boolean,
          metadata map(string, string)
       )
       PRIMARY KEY (device_id)
       SETTINGS mode='versioned_kv', version_column='_tp_time'`,
	}
}

// getMaterializedViewStatements returns the SQL statements for creating materialized views.
func getMaterializedViewStatements() []string {
	return []string{
		// Materialized View
		// The MV will insert into the system-generated _tp_time column in 'devices'
		`CREATE MATERIALIZED VIEW IF NOT EXISTS devices_mv INTO devices AS
        SELECT
            concat(ip, ':', agent_id, ':', poller_id) AS device_id,
            agent_id,
            poller_id,
            discovery_source,
            ip,
            mac,
            hostname,
            timestamp AS first_seen,
            timestamp AS last_seen,
            available AS is_available,
            metadata,
            now64(3) AS _tp_time
        FROM sweep_results`,
	}
}

// getCreateStreamStatements returns the SQL statements for creating database streams.
func getCreateStreamStatements() []string {
	// Combine statements from all helper functions
	var statements []string

	statements = append(statements, getStreamEngineStatements()...)
	statements = append(statements, getVersionedKVStreamStatements()...)
	statements = append(statements, getMaterializedViewStatements()...)

	return statements
}

// initSchema creates the database streams for Proton, excluding netflow_metrics.
// Note: devices_mv is a minimal materialized view streaming from sweep_results only.
// Historical data is not processed; devices populates naturally from new data.
// Streams use ChangelogStream engine to support continuous streaming for materialized views.
func (db *DB) initSchema(ctx context.Context) error {
	log.Println("=== Initializing schema with db.go version: 2025-05-13-v23 ===")

	// Get the stream creation statements
	createStreams := getCreateStreamStatements()

	// Execute each statement with detailed logging
	for i, statement := range createStreams {
		log.Printf("Executing SQL statement %d: %s", i+1, statement)

		if err := db.Conn.Exec(ctx, statement); err != nil {
			log.Printf("ERROR: Failed to execute SQL statement %d: %v", i+1, err)

			return fmt.Errorf("failed to execute statement %d: %w", i+1, err)
		}

		log.Printf("Successfully executed SQL statement %d", i+1)
	}

	log.Println("=== Schema initialized successfully ===")

	return nil
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
		ORDER BY mount_point ASC`,
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
