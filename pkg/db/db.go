/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package db pkg/db/db.go provides SQLite database functionality for ServiceRadar
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"log"
	"time"

	_ "github.com/mattn/go-sqlite3" // SQLite driver
)

var (
	errFailedToClean     = errors.New("failed to clean")
	errFailedToBeginTx   = errors.New("failed to begin transaction")
	errFailedToScan      = errors.New("failed to scan")
	errFailedToQuery     = errors.New("failed to query")
	errFailedToInsert    = errors.New("failed to insert")
	errFailedToInit      = errors.New("failed to initialize schema")
	errFailedToEnableWAL = errors.New("failed to enable WAL mode")
	errFailedOpenDB      = errors.New("failed to open database")
)

const (
	// Maximum number of history points to keep per node.
	maxHistoryPoints = 1000

	// SQL statements for database initialization.
	createTablesSQL = `
	-- Node information
	CREATE TABLE IF NOT EXISTS nodes (
		node_id TEXT PRIMARY KEY,
		first_seen TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
		last_seen TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
		is_healthy BOOLEAN NOT NULL DEFAULT 0
	);

	-- Node status history
	CREATE TABLE IF NOT EXISTS node_history (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		node_id TEXT NOT NULL,
		timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
		is_healthy BOOLEAN NOT NULL DEFAULT 0,
		FOREIGN KEY (node_id) REFERENCES nodes(node_id) ON DELETE CASCADE
	);

	-- Service status
	CREATE TABLE IF NOT EXISTS service_status (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		node_id TEXT NOT NULL,
		service_name TEXT NOT NULL,
		service_type TEXT NOT NULL,
		available BOOLEAN NOT NULL DEFAULT 0,
		details TEXT,
		timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
		FOREIGN KEY (node_id) REFERENCES nodes(node_id) ON DELETE CASCADE
	);

	-- Service history
	CREATE TABLE IF NOT EXISTS service_history (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		service_status_id INTEGER NOT NULL,
		timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
		available BOOLEAN NOT NULL DEFAULT 0,
		details TEXT,
		FOREIGN KEY (service_status_id) REFERENCES service_status(id) ON DELETE CASCADE
	);

	    -- Network sweep results
    CREATE TABLE IF NOT EXISTS sweep_results (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        poller_id TEXT NOT NULL,
        network TEXT NOT NULL,
        total_hosts INTEGER NOT NULL,
        active_hosts INTEGER NOT NULL,
        timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (poller_id) REFERENCES nodes(node_id) ON DELETE CASCADE
    );

    -- Port scan results
    CREATE TABLE IF NOT EXISTS port_results (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sweep_id INTEGER NOT NULL,
        port INTEGER NOT NULL,
        available INTEGER NOT NULL,
        FOREIGN KEY (sweep_id) REFERENCES sweep_results(id) ON DELETE CASCADE
    );	

	-- Timeseries metrics table
    CREATE TABLE IF NOT EXISTS timeseries_metrics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        node_id TEXT NOT NULL,
        metric_name TEXT NOT NULL,
        metric_type TEXT NOT NULL,
        value TEXT NOT NULL,
        metadata TEXT,         -- JSON field for type-specific metadata
        timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (node_id) REFERENCES nodes(node_id) ON DELETE CASCADE
    );

	-- Indexes for better query performance
	CREATE INDEX IF NOT EXISTS idx_sweep_results_poller_time 
        ON sweep_results(poller_id, timestamp);
    CREATE INDEX IF NOT EXISTS idx_port_results_sweep 
        ON port_results(sweep_id);
	CREATE INDEX IF NOT EXISTS idx_node_history_node_time 
		ON node_history(node_id, timestamp);
	CREATE INDEX IF NOT EXISTS idx_service_status_node_time 
		ON service_status(node_id, timestamp);
	CREATE INDEX IF NOT EXISTS idx_service_status_type 
		ON service_status(service_type);
	CREATE INDEX IF NOT EXISTS idx_service_history_status_time 
		ON service_history(service_status_id, timestamp);

	 -- Indexes for timeseries data
    CREATE INDEX IF NOT EXISTS idx_metrics_node_name 
		ON timeseries_metrics(node_id, metric_name);
    CREATE INDEX IF NOT EXISTS idx_metrics_type 
		ON timeseries_metrics(metric_type);
    CREATE INDEX IF NOT EXISTS idx_metrics_timestamp 
		ON timeseries_metrics(timestamp);

	-- Enable WAL mode for better concurrent access
	PRAGMA journal_mode=WAL;
	PRAGMA foreign_keys=ON;
	`
)

// DB represents the database connection and operations.
type DB struct {
	*sql.DB
}

// New creates a new database connection and initializes the schema.
func New(dbPath string) (Service, error) {
	sqlDB, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedOpenDB, err)
	}

	// Enable WAL mode for better concurrent access
	if _, err := sqlDB.Exec("PRAGMA journal_mode=WAL"); err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToEnableWAL, err)
	}

	db := &DB{sqlDB}
	if err := db.initSchema(); err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToInit, err)
	}

	return db, nil
}

func (db *DB) Begin() (Transaction, error) {
	tx, err := db.DB.Begin()
	if err != nil {
		return nil, fmt.Errorf("begin transaction: %w", err)
	}

	return &SQLTx{tx}, nil
}

func (db *DB) Exec(query string, args ...interface{}) (Result, error) {
	result, err := db.DB.Exec(query, args...)
	if err != nil {
		return nil, fmt.Errorf("exec query: %w", err)
	}

	return &SQLResult{result}, nil
}

func (db *DB) Query(query string, args ...interface{}) (Rows, error) {
	rows, err := db.DB.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("query: %w", err)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("rows error: %w", err)
	}

	return &SQLRows{rows}, nil
}

func (db *DB) QueryRow(query string, args ...interface{}) Row {
	return &SQLRow{db.DB.QueryRow(query, args...)}
}

// initSchema creates the database tables if they don't exist.
func (db *DB) initSchema() error {
	_, err := db.Exec(createTablesSQL)

	return err
}

func (db *DB) UpdateNodeStatus(status *NodeStatus) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer rollbackOnError(tx, err)

	err = db.updateExistingNode(tx, status)
	if errors.Is(err, sql.ErrNoRows) {
		err = db.insertNewNode(tx, status)
	}

	if err != nil {
		return fmt.Errorf("failed to update node status: %w", err)
	}

	err = db.addNodeHistory(tx, status)
	if err != nil {
		return fmt.Errorf("failed to add node history: %w", err)
	}

	return tx.Commit()
}

// Rewrite the above function using our interface.
func (*DB) updateExistingNode(tx Transaction, status *NodeStatus) error {
	result, err := tx.Exec(`
		UPDATE nodes 
		SET last_seen = ?,
			is_healthy = ?
		WHERE node_id = ?
	`, status.LastSeen, status.IsHealthy, status.NodeID)
	if err != nil {
		return fmt.Errorf("%w node: %w", ErrFailedToInsert, err)
	}

	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("%w rows affected: %w", ErrFailedToInsert, err)
	}

	if rowsAffected == 0 {
		return sql.ErrNoRows
	}

	return nil
}

func (*DB) insertNewNode(tx Transaction, status *NodeStatus) error {
	_, err := tx.Exec(`
        INSERT INTO nodes (node_id, first_seen, last_seen, is_healthy)
        VALUES (?, CURRENT_TIMESTAMP, ?, ?)
    `, status.NodeID, status.LastSeen, status.IsHealthy)

	if err != nil {
		return fmt.Errorf("%w node: %w", errFailedToInsert, err)
	}

	return nil
}

func (*DB) addNodeHistory(tx Transaction, status *NodeStatus) error {
	_, err := tx.Exec(`
        INSERT INTO node_history (node_id, timestamp, is_healthy)
        VALUES (?, ?, ?)
    `, status.NodeID, status.LastSeen, status.IsHealthy)

	if err != nil {
		return fmt.Errorf("%w node history: %w", errFailedToInsert, err)
	}

	return nil
}

func rollbackOnError(tx Transaction, err error) {
	if err != nil {
		if rbErr := tx.Rollback(); rbErr != nil {
			log.Printf("Error rolling back transaction: %v", rbErr)
		}
	}
}

// UpdateServiceStatus updates a service's status.
func (db *DB) UpdateServiceStatus(status *ServiceStatus) error {
	const insertSQL = `
		INSERT INTO service_status 
			(node_id, service_name, service_type, available, details, timestamp)
		VALUES (?, ?, ?, ?, ?, ?)
	`

	_, err := db.Exec(insertSQL,
		status.NodeID,
		status.ServiceName,
		status.ServiceType,
		status.Available,
		status.Details,
		status.Timestamp)

	if err != nil {
		return fmt.Errorf("%w service status: %w", errFailedToInsert, err)
	}

	return nil
}

func (db *DB) GetNodeStatus(nodeID string) (*NodeStatus, error) {
	const query = `
        SELECT node_id, first_seen, last_seen, is_healthy
        FROM nodes
        WHERE node_id = ?
    `

	var status NodeStatus
	err := db.QueryRow(query, nodeID).Scan(
		&status.NodeID,
		&status.FirstSeen,
		&status.LastSeen,
		&status.IsHealthy,
	)

	if err != nil {
		return nil, fmt.Errorf("%w node status: %w", errFailedToQuery, err)
	}

	return &status, nil
}

func (db *DB) GetNodeServices(nodeID string) ([]ServiceStatus, error) {
	const querySQL = `
        SELECT service_name, service_type, available, details, timestamp
        FROM service_status
        WHERE node_id = ?
        ORDER BY service_type, service_name
    `

	rows, err := db.Query(querySQL, nodeID)
	if err != nil {
		return nil, fmt.Errorf("%w node services: %w", errFailedToQuery, err)
	}
	defer CloseRows(rows)

	var services []ServiceStatus

	for rows.Next() {
		var s ServiceStatus
		s.NodeID = nodeID

		if err := rows.Scan(&s.ServiceName, &s.ServiceType, &s.Available, &s.Details, &s.Timestamp); err != nil {
			return nil, fmt.Errorf("%w service row: %w", errFailedToScan, err)
		}

		services = append(services, s)
	}

	return services, nil
}

func (db *DB) GetNodeHistoryPoints(nodeID string, limit int) ([]NodeHistoryPoint, error) {
	const query = `
        SELECT timestamp, is_healthy
        FROM node_history
        WHERE node_id = ?
        ORDER BY timestamp DESC
        LIMIT ?
    `

	rows, err := db.Query(query, nodeID, limit)
	if err != nil {
		return nil, fmt.Errorf("%w node history points: %w", errFailedToQuery, err)
	}
	defer CloseRows(rows)

	var points []NodeHistoryPoint

	for rows.Next() {
		var point NodeHistoryPoint
		if err := rows.Scan(&point.Timestamp, &point.IsHealthy); err != nil {
			return nil, fmt.Errorf("%w history point: %w", errFailedToScan, err)
		}

		points = append(points, point)
	}

	return points, nil
}

// GetNodeHistory retrieves the history for a node.
func (db *DB) GetNodeHistory(nodeID string) ([]NodeStatus, error) {
	const querySQL = `
        SELECT timestamp, is_healthy 
        FROM node_history 
        WHERE node_id = ? 
        ORDER BY timestamp DESC 
        LIMIT ?
    `

	rows, err := db.Query(querySQL, nodeID, maxHistoryPoints)
	if err != nil {
		return nil, fmt.Errorf("failed to query node history: %w", err)
	}
	defer CloseRows(rows)

	var history []NodeStatus

	for rows.Next() {
		var status NodeStatus

		status.NodeID = nodeID
		if err := rows.Scan(&status.LastSeen, &status.IsHealthy); err != nil {
			return nil, fmt.Errorf("failed to scan history row: %w", err)
		}

		history = append(history, status)
	}

	return history, nil
}

func (db *DB) IsNodeOffline(nodeID string, threshold time.Duration) (bool, error) {
	const querySQL = `
        SELECT COUNT(*) 
        FROM nodes n 
        WHERE n.node_id = ? 
        AND n.last_seen < datetime('now', ?)
    `

	var count int

	thresholdStr := fmt.Sprintf("-%d seconds", int(threshold.Seconds()))

	err := db.QueryRow(querySQL, nodeID, thresholdStr).Scan(&count)
	if err != nil {
		return false, fmt.Errorf("failed to check node status: %w", err)
	}

	return count > 0, nil
}

// GetServiceHistory retrieves the recent history for a service.
func (db *DB) GetServiceHistory(nodeID, serviceName string, limit int) ([]ServiceStatus, error) {
	const querySQL = `
		SELECT timestamp, available, details
		FROM service_status
		WHERE node_id = ? AND service_name = ?
		ORDER BY timestamp DESC
		LIMIT ?
	`

	rows, err := db.Query(querySQL, nodeID, serviceName, limit)
	if err != nil {
		return nil, fmt.Errorf("%w service history: %w", errFailedToQuery, err)
	}
	defer CloseRows(rows)

	var history []ServiceStatus

	for rows.Next() {
		var s ServiceStatus

		s.NodeID = nodeID

		s.ServiceName = serviceName

		if err := rows.Scan(&s.Timestamp, &s.Available, &s.Details); err != nil {
			return nil, fmt.Errorf("%w service history row: %w", errFailedToScan, err)
		}

		history = append(history, s)
	}

	return history, nil
}
