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
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/timeplus-io/proton-go-driver/v2"
	"github.com/timeplus-io/proton-go-driver/v2/lib/driver"
)

// DB represents the database connection for Timeplus Proton.
type DB struct {
	conn proton.Conn
}

// New creates a new database connection and initializes the schema.
func New(ctx context.Context, config *models.DBConfig) (Service, error) {
	// Load client certificate and key
	cert, err := tls.LoadX509KeyPair(config.Security.TLS.CertFile, config.Security.TLS.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to load client certificate: %w", ErrFailedOpenDB, err)
	}

	// Load CA certificate
	caCert, err := os.ReadFile(config.Security.TLS.CAFile)
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

	db := &DB{conn: conn}

	if err := db.initSchema(ctx); err != nil {
		return nil, fmt.Errorf("%w: %w", ErrFailedToInit, err)
	}

	return db, nil
}

// initSchema creates the database streams for Proton.
func (db *DB) initSchema(ctx context.Context) error {
	createStreams := []string{
		`CREATE STREAM IF NOT EXISTS cpu_metrics (
            poller_id string,
            timestamp DateTime64(3) DEFAULT now64(3),
            core_id int32,
            usage_percent float64
        ) ENGINE = MergeTree()
        PARTITION BY date(timestamp)
        ORDER BY (poller_id, timestamp)`, // Changed toDate to date

		`CREATE STREAM IF NOT EXISTS disk_metrics (
            poller_id string,
            timestamp DateTime64(3) DEFAULT now64(3),
            mount_point string,
            used_bytes uint64,
            total_bytes uint64
        ) ENGINE = MergeTree()
        PARTITION BY date(timestamp)
        ORDER BY (poller_id, timestamp)`, // Changed toDate to date

		`CREATE STREAM IF NOT EXISTS memory_metrics (
            poller_id string,
            timestamp DateTime64(3) DEFAULT now64(3),
            used_bytes uint64,
            total_bytes uint64
        ) ENGINE = MergeTree()
        PARTITION BY date(timestamp)
        ORDER BY (poller_id, timestamp)`, // Changed toDate to date

		`CREATE STREAM IF NOT EXISTS pollers (
            poller_id string,
            first_seen DateTime64(3) DEFAULT now64(3),
            last_seen DateTime64(3) DEFAULT now64(3),
            is_healthy bool
        ) ENGINE = MergeTree()
        PRIMARY KEY (poller_id)
        ORDER BY poller_id`, // No change here, no toDate

		`CREATE STREAM IF NOT EXISTS poller_history (
            poller_id string,
            timestamp DateTime64(3) DEFAULT now64(3),
            is_healthy bool
        ) ENGINE = MergeTree()
        PARTITION BY date(timestamp)
        ORDER BY (poller_id, timestamp)`, // Changed toDate to date

		`CREATE STREAM IF NOT EXISTS service_status (
            poller_id string,
            service_name string,
            service_type string,
            available bool,
            details string,
            timestamp DateTime64(3) DEFAULT now64(3)
        ) ENGINE = MergeTree()
        PARTITION BY date(timestamp)
        ORDER BY (poller_id, timestamp)`, // Changed toDate to date

		`CREATE STREAM IF NOT EXISTS timeseries_metrics (
            poller_id string,
            metric_name string,
            metric_type string,
            value string,
            metadata string,
            timestamp DateTime64(3) DEFAULT now64(3)
        ) ENGINE = MergeTree()
        PARTITION BY date(timestamp)
        ORDER BY (poller_id, metric_name, timestamp)`, // Changed toDate to date

		`CREATE STREAM IF NOT EXISTS users (
            id string,
            email string,
            name string,
            provider string,
            created_at DateTime64(3) DEFAULT now64(3),
            updated_at DateTime64(3) DEFAULT now64(3)
        ) ENGINE = MergeTree()
        PRIMARY KEY (id)
        ORDER BY id`, // No change here, no toDate
	}

	for _, statement := range createStreams {
		if err := db.conn.Exec(ctx, statement); err != nil {
			return err
		}
	}

	return nil
}

// Close closes the database connection.
func (db *DB) Close() error {
	return db.conn.Close()
}

// StoreMetrics stores multiple timeseries metrics in a single batch.
func (db *DB) StoreMetrics(ctx context.Context, pollerID string, metrics []*TimeseriesMetric) error {
	if len(metrics) == 0 {
		return nil
	}

	batch, err := db.conn.PrepareBatch(ctx, "INSERT INTO timeseries_metrics (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, metric := range metrics {
		metadataStr := ""

		if metric.Metadata != nil {
			var metadataBytes []byte

			metadataBytes, err = json.Marshal(metric.Metadata)
			if err != nil {
				log.Printf("Failed to marshal metadata for metric %s: %v", metric.Name, err)

				continue
			}

			metadataStr = string(metadataBytes)
		}

		err = batch.Append(
			pollerID,
			metric.Name,
			metric.Type,
			metric.Value,
			metadataStr,
			metric.Timestamp,
		)
		if err != nil {
			log.Printf("Failed to append metric %s: %v", metric.Name, err)

			continue
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to store metrics: %w", err)
	}

	return nil
}

// StoreSysmonMetrics stores sysmon metrics for CPU, disk, and memory.
func (db *DB) StoreSysmonMetrics(ctx context.Context, pollerID string, metrics *models.SysmonMetrics, timestamp time.Time) error {
	if err := db.storeCPUMetrics(ctx, pollerID, metrics.CPUs, timestamp); err != nil {
		return fmt.Errorf("failed to store CPU metrics: %w", err)
	}

	if err := db.storeDiskMetrics(ctx, pollerID, metrics.Disks, timestamp); err != nil {
		return fmt.Errorf("failed to store disk metrics: %w", err)
	}

	if err := db.storeMemoryMetrics(ctx, pollerID, metrics.Memory, timestamp); err != nil {
		return fmt.Errorf("failed to store memory metrics: %w", err)
	}

	return nil
}

// storeCPUMetrics stores CPU metrics in a batch.
func (db *DB) storeCPUMetrics(ctx context.Context, pollerID string, cpus []models.CPUMetric, timestamp time.Time) error {
	if len(cpus) == 0 {
		return nil
	}

	return db.executeBatch(ctx, "INSERT INTO cpu_metrics (* except _tp_time)", func(batch driver.Batch) error {
		for _, cpu := range cpus {
			if err := batch.Append(pollerID, timestamp, cpu.CoreID, cpu.UsagePercent); err != nil {
				log.Printf("Failed to append CPU metric for core %d: %v", cpu.CoreID, err)
				continue
			}
		}

		return nil
	})
}

// storeDiskMetrics stores disk metrics in a batch.
func (db *DB) storeDiskMetrics(ctx context.Context, pollerID string, disks []models.DiskMetric, timestamp time.Time) error {
	if len(disks) == 0 {
		return nil
	}

	return db.executeBatch(ctx, "INSERT INTO disk_metrics (* except _tp_time)", func(batch driver.Batch) error {
		for _, disk := range disks {
			if err := batch.Append(pollerID, timestamp, disk.MountPoint, disk.UsedBytes, disk.TotalBytes); err != nil {
				log.Printf("Failed to append disk metric for %s: %v", disk.MountPoint, err)
				continue
			}
		}

		return nil
	})
}

// storeMemoryMetrics stores memory metrics in a batch.
func (db *DB) storeMemoryMetrics(ctx context.Context, pollerID string, memory models.MemoryMetric, timestamp time.Time) error {
	if memory.UsedBytes == 0 && memory.TotalBytes == 0 {
		return nil
	}

	return db.executeBatch(ctx, "INSERT INTO memory_metrics (* except _tp_time)", func(batch driver.Batch) error {
		return batch.Append(pollerID, timestamp, memory.UsedBytes, memory.TotalBytes)
	})
}

// UpdateServiceStatuses updates multiple service statuses in a single batch.
func (db *DB) UpdateServiceStatuses(ctx context.Context, statuses []*ServiceStatus) error {
	if len(statuses) == 0 {
		return nil
	}

	batch, err := db.conn.PrepareBatch(ctx, "INSERT INTO service_status (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, status := range statuses {
		err = batch.Append(
			status.PollerID,
			status.ServiceName,
			status.ServiceType,
			status.Available,
			status.Details,
			status.Timestamp,
		)
		if err != nil {
			return fmt.Errorf("failed to append service status for %s: %w", status.ServiceName, err)
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("%w service statuses: %w", ErrFailedToInsert, err)
	}

	return nil
}

// UpdatePollerStatus updates a poller's status and logs it in the history.
func (db *DB) UpdatePollerStatus(ctx context.Context, status *models.PollerStatus) error {
	if err := validatePollerStatus(status); err != nil {
		return err
	}

	// Preserve original FirstSeen if poller exists
	if err := db.preserveFirstSeen(ctx, status); err != nil {
		return fmt.Errorf("failed to check poller existence: %w", err)
	}

	// Update pollers table
	if err := db.insertPollerStatus(ctx, status); err != nil {
		log.Printf("Failed to update poller status for %s: %v", status.PollerID, err)
		return fmt.Errorf("failed to update poller status: %w", err)
	}

	// Check if status has changed before logging to poller_history
	existing, err := db.GetPollerStatus(ctx, status.PollerID)
	if err != nil && !errors.Is(err, ErrFailedToQuery) {
		return fmt.Errorf("failed to check existing poller status: %w", err)
	}

	if existing == nil || existing.IsHealthy != status.IsHealthy || existing.LastSeen != status.LastSeen {
		if err := db.insertPollerHistory(ctx, status); err != nil {
			log.Printf("Failed to add poller history for %s: %v", status.PollerID, err)
			return fmt.Errorf("failed to add poller history: %w", err)
		}
	}

	log.Printf("Successfully updated poller status for %s", status.PollerID)

	return nil
}

var (
	errInvalidPollerID = errors.New("invalid poller ID")
)

// validatePollerStatus ensures the poller status is valid and sets default timestamps.
func validatePollerStatus(status *models.PollerStatus) error {
	if status.PollerID == "" {
		return errInvalidPollerID
	}

	now := time.Now()
	if !isValidTimestamp(status.FirstSeen) {
		status.FirstSeen = now
	}

	if !isValidTimestamp(status.LastSeen) {
		status.LastSeen = now
	}

	return nil
}

// preserveFirstSeen retrieves the existing poller and preserves its FirstSeen timestamp.
func (db *DB) preserveFirstSeen(ctx context.Context, status *models.PollerStatus) error {
	existing, err := db.GetPollerStatus(ctx, status.PollerID)
	if err != nil && !errors.Is(err, ErrFailedToQuery) {
		return err
	}

	if existing != nil {
		status.FirstSeen = existing.FirstSeen
	}

	return nil
}

// insertPollerStatus inserts or updates the poller status in the pollers table.
func (db *DB) insertPollerStatus(ctx context.Context, status *models.PollerStatus) error {
	return db.executeBatch(ctx, "INSERT INTO pollers (* except _tp_time)", func(batch driver.Batch) error {
		return batch.Append(
			status.PollerID,
			status.FirstSeen,
			status.LastSeen,
			status.IsHealthy,
		)
	})
}

// insertPollerHistory logs the poller status in the poller_history table.
func (db *DB) insertPollerHistory(ctx context.Context, status *models.PollerStatus) error {
	return db.executeBatch(ctx, "INSERT INTO poller_history (* except _tp_time)", func(batch driver.Batch) error {
		return batch.Append(
			status.PollerID,
			status.LastSeen,
			status.IsHealthy,
		)
	})
}

// executeBatch prepares and sends a batch operation, handling errors.
func (db *DB) executeBatch(ctx context.Context, query string, appendFunc func(driver.Batch) error) error {
	batch, err := db.conn.PrepareBatch(ctx, query)
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

// GetPollerStatus retrieves a poller's current status.
func (db *DB) GetPollerStatus(ctx context.Context, pollerID string) (*models.PollerStatus, error) {
	var status models.PollerStatus

	rows, err := db.conn.Query(ctx, `
		SELECT poller_id, first_seen, last_seen, is_healthy
		FROM pollers
		WHERE poller_id = $1
		LIMIT 1`,
		pollerID)
	if err != nil {
		return nil, fmt.Errorf("%w poller status: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	if !rows.Next() {
		return nil, fmt.Errorf("%w: poller not found", ErrFailedToQuery)
	}

	err = rows.Scan(
		&status.PollerID,
		&status.FirstSeen,
		&status.LastSeen,
		&status.IsHealthy,
	)
	if err != nil {
		return nil, fmt.Errorf("%w poller status: %w", ErrFailedToScan, err)
	}

	return &status, nil
}

// GetPollerServices retrieves services for a poller.
func (db *DB) GetPollerServices(ctx context.Context, pollerID string) ([]ServiceStatus, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT service_name, service_type, available, details, timestamp
		FROM service_status
		WHERE poller_id = $1
		ORDER BY service_type, service_name`,
		pollerID)
	if err != nil {
		return nil, fmt.Errorf("%w poller services: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var services []ServiceStatus

	for rows.Next() {
		var s ServiceStatus

		s.PollerID = pollerID
		if err := rows.Scan(&s.ServiceName, &s.ServiceType, &s.Available, &s.Details, &s.Timestamp); err != nil {
			return nil, fmt.Errorf("%w service row: %w", ErrFailedToScan, err)
		}

		services = append(services, s)
	}

	return services, nil
}

// GetPollerHistoryPoints retrieves history points for a poller.
func (db *DB) GetPollerHistoryPoints(ctx context.Context, pollerID string, limit int) ([]PollerHistoryPoint, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, is_healthy
		FROM poller_history
		WHERE poller_id = $1
		ORDER BY timestamp DESC
		LIMIT $2`,
		pollerID, limit)
	if err != nil {
		return nil, fmt.Errorf("%w poller history points: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var points []PollerHistoryPoint

	for rows.Next() {
		var point PollerHistoryPoint

		if err := rows.Scan(&point.Timestamp, &point.IsHealthy); err != nil {
			return nil, fmt.Errorf("%w history point: %w", ErrFailedToScan, err)
		}

		points = append(points, point)
	}

	return points, nil
}

// GetPollerHistory retrieves the history for a poller.
func (db *DB) GetPollerHistory(ctx context.Context, pollerID string) ([]models.PollerStatus, error) {
	const maxHistoryPoints = 1000

	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, is_healthy
		FROM poller_history
		WHERE poller_id = $1
		ORDER BY timestamp DESC
		LIMIT $2`,
		pollerID, maxHistoryPoints)
	if err != nil {
		return nil, fmt.Errorf("%w poller history: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var history []models.PollerStatus

	for rows.Next() {
		var status models.PollerStatus

		status.PollerID = pollerID
		if err := rows.Scan(&status.LastSeen, &status.IsHealthy); err != nil {
			return nil, fmt.Errorf("%w history row: %w", ErrFailedToScan, err)
		}

		history = append(history, status)
	}

	return history, nil
}

// IsPollerOffline checks if a poller is offline based on the threshold.
func (db *DB) IsPollerOffline(ctx context.Context, pollerID string, threshold time.Duration) (bool, error) {
	cutoff := time.Now().Add(-threshold)

	rows, err := db.conn.Query(ctx, `
		SELECT COUNT(*)
		FROM pollers
		WHERE poller_id = $1
		AND last_seen < $2`,
		pollerID, cutoff)
	if err != nil {
		return false, fmt.Errorf("%w poller status: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var count int

	if !rows.Next() {
		return false, fmt.Errorf("%w: count result not found", ErrFailedToQuery)
	}

	if err := rows.Scan(&count); err != nil {
		return false, fmt.Errorf("%w count: %w", ErrFailedToScan, err)
	}

	return count > 0, nil
}

// UpdateServiceStatus updates a service's status.
func (db *DB) UpdateServiceStatus(ctx context.Context, status *ServiceStatus) error {
	batch, err := db.conn.PrepareBatch(ctx, "INSERT INTO service_status (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	err = batch.Append(
		status.PollerID,
		status.ServiceName,
		status.ServiceType,
		status.Available,
		status.Details,
		status.Timestamp,
	)
	if err != nil {
		return fmt.Errorf("failed to append service status: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("%w service status: %w", ErrFailedToInsert, err)
	}

	return nil
}

// GetServiceHistory retrieves the recent history for a service.
func (db *DB) GetServiceHistory(ctx context.Context, pollerID, serviceName string, limit int) ([]ServiceStatus, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, available, details
		FROM service_status
		WHERE poller_id = $1 AND service_name = $2
		ORDER BY timestamp DESC
		LIMIT $3`,
		pollerID, serviceName, limit)
	if err != nil {
		return nil, fmt.Errorf("%w service history: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var history []ServiceStatus

	for rows.Next() {
		var s ServiceStatus

		s.PollerID = pollerID
		s.ServiceName = serviceName

		if err := rows.Scan(&s.Timestamp, &s.Available, &s.Details); err != nil {
			return nil, fmt.Errorf("%w service history row: %w", ErrFailedToScan, err)
		}

		history = append(history, s)
	}

	return history, nil
}

// ListPollers retrieves all poller IDs from the pollers stream.
func (db *DB) ListPollers(ctx context.Context) ([]string, error) {
	rows, err := db.conn.Query(ctx, "SELECT poller_id FROM pollers")
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query pollers: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var pollerIDs []string

	for rows.Next() {
		var pollerID string

		if err := rows.Scan(&pollerID); err != nil {
			log.Printf("Error scanning poller ID: %v", err)

			continue
		}

		pollerIDs = append(pollerIDs, pollerID)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: error iterating rows: %w", ErrFailedToQuery, err)
	}

	return pollerIDs, nil
}

// DeletePoller deletes a poller by ID.
func (db *DB) DeletePoller(ctx context.Context, pollerID string) error {
	batch, err := db.conn.PrepareBatch(ctx, "DELETE FROM pollers WHERE poller_id = $1")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	if err := batch.Append(pollerID); err != nil {
		return fmt.Errorf("failed to append poller ID: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("%w: failed to delete poller: %w", ErrFailedToInsert, err)
	}

	return nil
}

// ListPollerStatuses retrieves poller statuses, optionally filtered by patterns.
func (db *DB) ListPollerStatuses(ctx context.Context, patterns []string) ([]models.PollerStatus, error) {
	query := `SELECT poller_id, is_healthy, last_seen FROM pollers`

	var args []interface{}

	if len(patterns) > 0 {
		conditions := make([]string, 0, len(patterns))

		for _, pattern := range patterns {
			conditions = append(conditions, "poller_id LIKE $1")
			args = append(args, pattern)
		}

		query += " WHERE " + strings.Join(conditions, " OR ")
	}

	query += " ORDER BY last_seen DESC"

	rows, err := db.conn.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query pollers: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var statuses []models.PollerStatus

	for rows.Next() {
		var status models.PollerStatus

		if err := rows.Scan(&status.PollerID, &status.IsHealthy, &status.LastSeen); err != nil {
			log.Printf("Error scanning poller status: %v", err)

			continue
		}

		statuses = append(statuses, status)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: error iterating rows: %w", ErrFailedToQuery, err)
	}

	return statuses, nil
}

// ListNeverReportedPollers retrieves poller IDs that have never reported (first_seen = last_seen).
func (db *DB) ListNeverReportedPollers(ctx context.Context, patterns []string) ([]string, error) {
	query := `
        WITH history AS (
            SELECT poller_id, MAX(timestamp) AS latest_timestamp
            FROM poller_history
            GROUP BY poller_id
        )
        SELECT DISTINCT pollers.poller_id
        FROM pollers
        LEFT JOIN history ON pollers.poller_id = history.poller_id
        WHERE history.latest_timestamp IS NULL OR history.latest_timestamp = pollers.first_seen`

	var args []interface{}

	if len(patterns) > 0 {
		conditions := make([]string, 0, len(patterns))

		for i, pattern := range patterns {
			conditions = append(conditions, fmt.Sprintf("pollers.poller_id LIKE $%d", i+1))
			args = append(args, pattern)
		}

		query += " AND (" + strings.Join(conditions, " OR ") + ")"
	}

	query += " ORDER BY pollers.poller_id"

	rows, err := db.conn.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query never reported pollers: %w", ErrFailedToQuery, err)
	}
	defer CloseRows(rows)

	var pollerIDs []string

	for rows.Next() {
		var pollerID string

		if err := rows.Scan(&pollerID); err != nil {
			log.Printf("Error scanning poller ID: %v", err)

			continue
		}

		pollerIDs = append(pollerIDs, pollerID)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("%w: error iterating rows: %w", ErrFailedToQuery, err)
	}

	log.Printf("Found %d never reported pollers: %v", len(pollerIDs), pollerIDs)

	return pollerIDs, nil
}

// GetAllMountPoints retrieves all unique mount points for a poller.
func (db *DB) GetAllMountPoints(ctx context.Context, pollerID string) ([]string, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT DISTINCT mount_point
		FROM disk_metrics
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

// GetAllCPUMetrics retrieves all CPU metrics for a poller within a time range, grouped by timestamp.
func (db *DB) GetAllCPUMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]SysmonCPUResponse, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, core_id, usage_percent
		FROM cpu_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, core_id ASC`,
		pollerID, start, end)
	if err != nil {
		log.Printf("Error querying all CPU metrics: %v", err)

		return nil, fmt.Errorf("failed to query all CPU metrics: %w", err)
	}
	defer CloseRows(rows)

	data := make(map[time.Time][]models.CPUMetric)

	for rows.Next() {
		var m models.CPUMetric

		var timestamp time.Time

		if err := rows.Scan(&timestamp, &m.CoreID, &m.UsagePercent); err != nil {
			log.Printf("Error scanning CPU metric row: %v", err)
			continue
		}

		m.Timestamp = timestamp
		data[timestamp] = append(data[timestamp], m)
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating CPU metrics rows: %v", err)

		return nil, err
	}

	result := make([]SysmonCPUResponse, 0, len(data))

	for ts, cpus := range data {
		result = append(result, SysmonCPUResponse{
			Cpus:      cpus,
			Timestamp: ts,
		})
	}

	// Sort by timestamp descending
	sort.Slice(result, func(i, j int) bool {
		return result[i].Timestamp.After(result[j].Timestamp)
	})

	return result, nil
}

// GetAllDiskMetrics retrieves all disk metrics for a poller.
func (db *DB) GetAllDiskMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.DiskMetric, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT mount_point, used_bytes, total_bytes, timestamp
		FROM disk_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, mount_point ASC`,
		pollerID, start, end)
	if err != nil {
		log.Printf("Error querying all disk metrics: %v", err)

		return nil, fmt.Errorf("failed to query all disk metrics: %w", err)
	}
	defer CloseRows(rows)

	var metrics []models.DiskMetric

	for rows.Next() {
		var m models.DiskMetric

		if err = rows.Scan(&m.MountPoint, &m.UsedBytes, &m.TotalBytes, &m.Timestamp); err != nil {
			log.Printf("Error scanning disk metric row: %v", err)

			continue
		}

		metrics = append(metrics, m)
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating disk metrics rows: %v", err)

		return metrics, err
	}

	return metrics, nil
}

// GetDiskMetrics retrieves disk metrics for a specific mount point.
func (db *DB) GetDiskMetrics(ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, mount_point, used_bytes, total_bytes
		FROM disk_metrics
		WHERE poller_id = $1 AND mount_point = $2 AND timestamp BETWEEN $3 AND $4
		ORDER BY timestamp`,
		pollerID, mountPoint, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query disk metrics: %w", err)
	}
	defer CloseRows(rows)

	var metrics []models.DiskMetric

	for rows.Next() {
		var m models.DiskMetric

		if err = rows.Scan(&m.Timestamp, &m.MountPoint, &m.UsedBytes, &m.TotalBytes); err != nil {
			log.Printf("Error scanning disk metric row: %v", err)
			continue
		}

		metrics = append(metrics, m)
	}

	return metrics, nil
}

// GetMemoryMetrics retrieves memory metrics.
func (db *DB) GetMemoryMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.MemoryMetric, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, used_bytes, total_bytes
		FROM memory_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp`,
		pollerID, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query memory metrics: %w", err)
	}
	defer CloseRows(rows)

	var metrics []models.MemoryMetric

	for rows.Next() {
		var m models.MemoryMetric

		if err = rows.Scan(&m.Timestamp, &m.UsedBytes, &m.TotalBytes); err != nil {
			log.Printf("Error scanning memory metric row: %v", err)

			continue
		}

		metrics = append(metrics, m)
	}

	return metrics, nil
}

// GetAllDiskMetricsGrouped retrieves disk metrics grouped by timestamp.
func (db *DB) GetAllDiskMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]SysmonDiskResponse, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, mount_point, used_bytes, total_bytes
		FROM disk_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, mount_point ASC`,
		pollerID, start, end)
	if err != nil {
		log.Printf("Error querying all disk metrics: %s", err)

		return nil, fmt.Errorf("failed to query all disk metrics: %w", err)
	}
	defer CloseRows(rows)

	data := make(map[time.Time][]models.DiskMetric)

	for rows.Next() {
		var m models.DiskMetric

		var timestamp time.Time

		if err = rows.Scan(&timestamp, &m.MountPoint, &m.UsedBytes, &m.TotalBytes); err != nil {
			log.Printf("Error scanning disk metric row: %v", err)

			continue
		}

		m.Timestamp = timestamp

		data[timestamp] = append(data[timestamp], m)
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating disk metrics rows: %v", err)

		return nil, err
	}

	result := make([]SysmonDiskResponse, 0, len(data))

	for ts, disks := range data {
		result = append(result, SysmonDiskResponse{
			Disks:     disks,
			Timestamp: ts,
		})
	}

	// Sort by timestamp descending
	sort.Slice(result, func(i, j int) bool {
		return result[i].Timestamp.After(result[j].Timestamp)
	})

	return result, nil
}

// GetMemoryMetricsGrouped retrieves memory metrics grouped by timestamp.
func (db *DB) GetMemoryMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]SysmonMemoryResponse, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, used_bytes, total_bytes
		FROM memory_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC`,
		pollerID, start, end)
	if err != nil {
		log.Printf("Error querying memory metrics: %v", err)

		return nil, fmt.Errorf("failed to query memory metrics: %w", err)
	}
	defer CloseRows(rows)

	var result []SysmonMemoryResponse

	for rows.Next() {
		var m models.MemoryMetric

		var timestamp time.Time

		if err = rows.Scan(&timestamp, &m.UsedBytes, &m.TotalBytes); err != nil {
			log.Printf("Error scanning memory metric row: %v", err)

			continue
		}

		m.Timestamp = timestamp

		result = append(result, SysmonMemoryResponse{
			Memory:    m,
			Timestamp: timestamp,
		})
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating memory metrics rows: %v", err)

		return nil, err
	}

	return result, nil
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
