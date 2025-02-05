// Package db pkg/db/interfaces.go

//go:generate mockgen -destination=mock_db.go -package=db github.com/mfreeman451/serviceradar/pkg/db Service,TransactionManager,Transaction

package db

import (
	"database/sql"
	"time"
)

// Service represents all database operations.
type Service interface {
	// Core database operations.

	Begin() (*sql.Tx, error)
	Close() error
	Exec(query string, args ...interface{}) (sql.Result, error)
	Query(query string, args ...interface{}) (*sql.Rows, error)
	QueryRow(query string, args ...interface{}) *sql.Row

	// Node operations.

	UpdateNodeStatus(status *NodeStatus) error
	GetNodeStatus(nodeID string) (*NodeStatus, error)
	GetNodeHistory(nodeID string) ([]NodeStatus, error)
	GetNodeHistoryPoints(nodeID string, limit int) ([]NodeHistoryPoint, error)
	IsNodeOffline(nodeID string, threshold time.Duration) (bool, error)

	// Service operations.

	UpdateServiceStatus(status *ServiceStatus) error
	GetNodeServices(nodeID string) ([]ServiceStatus, error)
	GetServiceHistory(nodeID, serviceName string, limit int) ([]ServiceStatus, error)

	// Maintenance operations.

	CleanOldData(retentionPeriod time.Duration) error
}

// TransactionManager represents database transaction operations.
type TransactionManager interface {
	Begin() (*sql.Tx, error)
	Commit() error
	Rollback() error
}

// Transaction represents operations that can be performed within a database transaction.
type Transaction interface {
	Exec(query string, args ...interface{}) (sql.Result, error)
	Query(query string, args ...interface{}) (*sql.Rows, error)
	QueryRow(query string, args ...interface{}) *sql.Row
}
