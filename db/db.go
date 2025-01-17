// Package db db/db.go provides SQLite database functionality for HomeMon
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"log"
	"time"
)

var (
	errFailedToClean     = errors.New("failed to clean")
	errFailedToBeginTx   = errors.New("failed to begin transaction")
	errFailedToScan      = errors.New("failed to scan")
	errFailedToQuery     = errors.New("failed to query")
	errFailedToInsert    = errors.New("failed to insert")
	errFailedToTrim      = errors.New("failed to trim")
	errFailedToUpsert    = errors.New("failed to upsert node")
	errFailedToRollback  = errors.New("failed to rollback")
	errFailedToInit      = errors.New("failed to initialize schema")
	errFailedToEnableWAL = errors.New("failed to enable WAL mode")
	errFailedOpenDB      = fmt.Errorf("failed to open database")
)

const (
	// Maximum number of history points to keep per node.
	maxHistoryPoints = 1000

	// SQL statements for database initialization.
	createTablesSQL = `
		CREATE TABLE IF NOT EXISTS nodes (
			node_id TEXT PRIMARY KEY,
			first_seen TIMESTAMP NOT NULL,
			last_seen TIMESTAMP NOT NULL,
			is_healthy BOOLEAN NOT NULL
		);

		CREATE TABLE IF NOT EXISTS node_history (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			node_id TEXT NOT NULL,
			timestamp TIMESTAMP NOT NULL,
			is_healthy BOOLEAN NOT NULL,
			FOREIGN KEY (node_id) REFERENCES nodes(node_id)
		);

		CREATE TABLE IF NOT EXISTS service_status (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			node_id TEXT NOT NULL,
			service_name TEXT NOT NULL,
			service_type TEXT NOT NULL,
			available BOOLEAN NOT NULL,
			details TEXT,
			timestamp TIMESTAMP NOT NULL,
			FOREIGN KEY (node_id) REFERENCES nodes(node_id)
		);

		CREATE INDEX IF NOT EXISTS idx_node_history_node_time 
			ON node_history(node_id, timestamp);
		CREATE INDEX IF NOT EXISTS idx_service_status_node_time 
			ON service_status(node_id, timestamp);
	`

	// SQL to trim old history points.
	trimHistorySQL = `
		WITH RankedHistory AS (
			SELECT id,
				   ROW_NUMBER() OVER (PARTITION BY node_id ORDER BY timestamp DESC) as rn
			FROM node_history
			WHERE node_id = ?
		)
		DELETE FROM node_history
		WHERE id IN (
			SELECT id FROM RankedHistory WHERE rn > ?
		);
	`
)

// DB represents the database connection and operations.
type DB struct {
	*sql.DB
}

// NodeStatus represents a node's current status.
type NodeStatus struct {
	NodeID    string    `json:"node_id"`
	IsHealthy bool      `json:"is_healthy"`
	FirstSeen time.Time `json:"first_seen"`
	LastSeen  time.Time `json:"last_seen"`
}

// ServiceStatus represents a service's status.
type ServiceStatus struct {
	NodeID      string    `json:"node_id"`
	ServiceName string    `json:"service_name"`
	ServiceType string    `json:"service_type"`
	Available   bool      `json:"available"`
	Details     string    `json:"details"`
	Timestamp   time.Time `json:"timestamp"`
}

// New creates a new database connection and initializes the schema.
func New(dbPath string) (*DB, error) {
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

// initSchema creates the database tables if they don't exist.
func (db *DB) initSchema() error {
	_, err := db.Exec(createTablesSQL)

	return err
}

// UpdateNodeStatus updates a node's status and maintains history.
func (db *DB) UpdateNodeStatus(status *NodeStatus) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("%w: %w", errFailedToBeginTx, err)
	}

	defer func() {
		if err != nil {
			if rbErr := tx.Rollback(); rbErr != nil {
				log.Printf("failed to rollback: %v", rbErr)
				err = fmt.Errorf("%w: %w", errFailedToRollback, rbErr)
			}

			return
		}

		err = tx.Commit()
	}()

	// Update or insert node status
	const upsertNodeSQL = `
		INSERT INTO nodes (node_id, first_seen, last_seen, is_healthy)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(node_id) DO UPDATE SET
			last_seen = ?,
			is_healthy = ?
		WHERE node_id = ?
	`

	_, err = tx.Exec(upsertNodeSQL,
		status.NodeID, status.FirstSeen, status.LastSeen, status.IsHealthy,
		status.LastSeen, status.IsHealthy, status.NodeID)
	if err != nil {
		return fmt.Errorf("%w node: %w", errFailedToUpsert, err)
	}

	// Add history entry
	const insertHistorySQL = `
		INSERT INTO node_history (node_id, timestamp, is_healthy)
		VALUES (?, ?, ?)
	`

	_, err = tx.Exec(insertHistorySQL,
		status.NodeID, status.LastSeen, status.IsHealthy)
	if err != nil {
		return fmt.Errorf("%w history: %w", errFailedToInsert, err)
	}

	// Trim old history points
	_, err = tx.Exec(trimHistorySQL, status.NodeID, maxHistoryPoints)
	if err != nil {
		return fmt.Errorf("%w history: %w", errFailedToTrim, err)
	}

	return nil
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
		return nil, fmt.Errorf("%w node history: %w", errFailedToQuery, err)
	}

	defer func(rows *sql.Rows) {
		err := rows.Close()
		if err != nil {
			log.Printf("failed to close rows: %v", err)
		}
	}(rows)

	var history []NodeStatus

	for rows.Next() {
		var h NodeStatus

		h.NodeID = nodeID

		if err := rows.Scan(&h.LastSeen, &h.IsHealthy); err != nil {
			return nil, fmt.Errorf("%w history row: %w", errFailedToScan, err)
		}

		history = append(history, h)
	}

	return history, nil
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
		return nil, fmt.Errorf("failed to query service history: %w", err)
	}

	defer func(rows *sql.Rows) {
		err := rows.Close()
		if err != nil {
			log.Printf("failed to close rows: %v", err)
		}
	}(rows)

	var history []ServiceStatus

	for rows.Next() {
		var s ServiceStatus
		s.NodeID = nodeID
		s.ServiceName = serviceName

		if err := rows.Scan(&s.Timestamp, &s.Available, &s.Details); err != nil {
			return nil, fmt.Errorf("failed to scan service history row: %w", err)
		}

		history = append(history, s)
	}

	return history, nil
}

// CleanOldData removes data older than the retention period.
func (db *DB) CleanOldData(retentionPeriod time.Duration) error {
	cutoff := time.Now().Add(-retentionPeriod)

	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("%w: %w", errFailedToBeginTx, err)
	}

	defer func() {
		if err != nil {
			if rbErr := tx.Rollback(); rbErr != nil {
				log.Printf("failed to rollback: %v", rbErr)
			}

			return
		}

		err = tx.Commit()
	}()

	// Clean up node history
	if _, err := tx.Exec(
		"DELETE FROM node_history WHERE timestamp < ?",
		cutoff,
	); err != nil {
		return fmt.Errorf("%w node history %w", errFailedToClean, err)
	}

	// Clean up service status
	if _, err := tx.Exec(
		"DELETE FROM service_status WHERE timestamp < ?",
		cutoff,
	); err != nil {
		return fmt.Errorf("%w service status: %w", errFailedToClean, err)
	}

	return nil
}
