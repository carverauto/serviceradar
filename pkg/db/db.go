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
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/timeplus-io/proton-go-driver/v2"
)

// DB represents the database connection for Timeplus Proton.
type DB struct {
	conn proton.Conn
}

// New creates a new database connection and initializes the schema.
func New(ctx context.Context, addr, database, username, password string) (Service, error) {
	log.Println("Address:", addr)
	log.Println("Database:", database)
	log.Println("Username:", username)
	conn, err := proton.Open(&proton.Options{
		Addr: []string{addr},
		Auth: proton.Auth{
			Database: database,
			Username: username,
			Password: password,
		},
		Compression: &proton.Compression{
			Method: proton.CompressionLZ4,
		},
		Settings: proton.Settings{
			"max_execution_time": 60,
			// "allow_experimental_json_type": true, // Enable JSON type // doesnt exist -- marked for removal
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
	// Break up the SQL statements into individual commands
	createStreams := []string{
		`CREATE STREAM IF NOT EXISTS cpu_metrics (
            poller_id string,
            timestamp DateTime64(3) DEFAULT now64(3),
            core_id int32,
            usage_percent float64
        ) ENGINE = MergeTree()
        ORDER BY (poller_id, timestamp)`,

		`CREATE STREAM IF NOT EXISTS disk_metrics (
            poller_id string,
            timestamp DateTime64(3) DEFAULT now64(3),
            mount_point string,
            used_bytes uint64,
            total_bytes uint64
        ) ENGINE = MergeTree()
        ORDER BY (poller_id, timestamp)`,

		`CREATE STREAM IF NOT EXISTS memory_metrics (
            poller_id string,
            timestamp DateTime64(3) DEFAULT now64(3),
            used_bytes uint64,
            total_bytes uint64
        ) ENGINE = MergeTree()
        ORDER BY (poller_id, timestamp)`,

		`CREATE STREAM IF NOT EXISTS pollers (
            poller_id string,
            first_seen DateTime64(3) DEFAULT now64(3),
            last_seen DateTime64(3) DEFAULT now64(3),
            is_healthy bool
        ) ENGINE = MergeTree()
        PRIMARY KEY (poller_id)
        ORDER BY poller_id`,

		`CREATE STREAM IF NOT EXISTS poller_history (
            poller_id string,
            timestamp DateTime64(3) DEFAULT now64(3),
            is_healthy bool
        ) ENGINE = MergeTree()
        ORDER BY (poller_id, timestamp)`,

		`CREATE STREAM IF NOT EXISTS service_status (
            poller_id string,
            service_name string,
            service_type string,
            available bool,
            details string,
            timestamp DateTime64(3) DEFAULT now64(3)
        ) ENGINE = MergeTree()
        ORDER BY (poller_id, timestamp)`,

		`CREATE STREAM IF NOT EXISTS timeseries_metrics (
            poller_id string,
            metric_name string,
            metric_type string,
            value string,
            metadata string,
            timestamp DateTime64(3) DEFAULT now64(3)
        ) ENGINE = MergeTree()
        ORDER BY (poller_id, metric_name, timestamp)`,

		`CREATE STREAM IF NOT EXISTS users (
            id string,
            email string,
            name string,
            provider string,
            created_at DateTime64(3) DEFAULT now64(3),
            updated_at DateTime64(3) DEFAULT now64(3)
        ) ENGINE = MergeTree()
        PRIMARY KEY (id)
        ORDER BY id`,
	}

	// Execute each statement individually
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

// UpdatePollerStatus updates a poller's status.
func (db *DB) UpdatePollerStatus(ctx context.Context, status *PollerStatus) error {
	// Update or insert poller status
	batch, err := db.conn.PrepareBatch(ctx, "INSERT INTO pollers (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	err = batch.Append(
		status.PollerID,
		status.FirstSeen,
		status.LastSeen,
		status.IsHealthy,
	)
	if err != nil {
		return fmt.Errorf("failed to append poller status: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to update poller status: %w", err)
	}

	// Add to poller history
	batch, err = db.conn.PrepareBatch(ctx, "INSERT INTO poller_history (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	err = batch.Append(
		status.PollerID,
		status.LastSeen,
		status.IsHealthy,
	)
	if err != nil {
		return fmt.Errorf("failed to append poller history: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to add poller history: %w", err)
	}

	return nil
}

// GetPollerStatus retrieves a poller's current status.
func (db *DB) GetPollerStatus(ctx context.Context, pollerID string) (*PollerStatus, error) {
	var status PollerStatus

	rows, err := db.conn.Query(ctx, `
		SELECT poller_id, first_seen, last_seen, is_healthy
		FROM pollers
		WHERE poller_id = $1
		LIMIT 1`,
		pollerID)
	if err != nil {
		return nil, fmt.Errorf("%w poller status: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

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
	defer rows.Close()

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
	defer rows.Close()

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
func (db *DB) GetPollerHistory(ctx context.Context, pollerID string) ([]PollerStatus, error) {
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
	defer rows.Close()

	var history []PollerStatus
	for rows.Next() {
		var status PollerStatus
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
	defer rows.Close()

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

	// Store details directly as a string (JSON)
	err = batch.Append(
		status.PollerID,
		status.ServiceName,
		status.ServiceType,
		status.Available,
		status.Details, // Store as string
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
	defer rows.Close()

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
	defer rows.Close()

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
func (db *DB) ListPollerStatuses(ctx context.Context, patterns []string) ([]PollerStatus, error) {
	query := `SELECT poller_id, is_healthy, last_seen FROM pollers`

	var args []interface{}

	if len(patterns) > 0 {
		conditions := make([]string, 0, len(patterns))

		for _, pattern := range patterns {
			conditions = append(conditions, "poller_id LIKE ?")
			args = append(args, pattern)
		}

		query += " WHERE " + strings.Join(conditions, " OR ")
	}

	query += " ORDER BY last_seen DESC"

	rows, err := db.conn.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query pollers: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

	var statuses []PollerStatus

	for rows.Next() {
		var status PollerStatus

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
	query := `SELECT poller_id FROM pollers WHERE first_seen = last_seen`

	var args []interface{}

	if len(patterns) > 0 {
		conditions := make([]string, 0, len(patterns))
		for _, pattern := range patterns {
			conditions = append(conditions, "poller_id LIKE ?")
			args = append(args, pattern)
		}

		query += " AND (" + strings.Join(conditions, " OR ") + ")"
	}

	rows, err := db.conn.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("%w: failed to query never reported pollers: %w", ErrFailedToQuery, err)
	}
	defer rows.Close()

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
