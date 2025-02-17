// Package db pkg/db/interfaces.go
package db

import (
	"time"
)

//go:generate mockgen -destination=mock_db.go -package=db github.com/mfreeman451/serviceradar/pkg/db Row,Result,Rows,Transaction,Service

// TimeseriesMetric represents a generic timeseries datapoint.
type TimeseriesMetric struct {
	Name      string      `json:"name"`
	Value     string      `json:"value"` // Store as string for flexibility
	Type      string      `json:"type"`  // Metric type identifier
	Timestamp time.Time   `json:"timestamp"`
	Metadata  interface{} `json:"metadata"` // Additional type-specific metadata
}

// Row represents a database row.
type Row interface {
	Scan(dest ...interface{}) error
}

// Result represents the result of a database operation.
type Result interface {
	LastInsertId() (int64, error)
	RowsAffected() (int64, error)
}

// Rows represents multiple database rows.
type Rows interface {
	Next() bool
	Scan(dest ...interface{}) error
	Close() error
	Err() error
}

// Transaction represents operations that can be performed within a database transaction.
type Transaction interface {
	Exec(query string, args ...interface{}) (Result, error)
	Query(query string, args ...interface{}) (Rows, error)
	QueryRow(query string, args ...interface{}) Row
	Commit() error
	Rollback() error
}

// Service represents all database operations.
type Service interface {
	// Core database operations.

	Begin() (Transaction, error)
	Close() error
	Exec(query string, args ...interface{}) (Result, error)
	Query(query string, args ...interface{}) (Rows, error)
	QueryRow(query string, args ...interface{}) Row

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

	// Generic timeseries methods

	StoreMetric(nodeID string, metric *TimeseriesMetric) error
	GetMetrics(nodeID, metricName string, start, end time.Time) ([]TimeseriesMetric, error)
	GetMetricsByType(nodeID, metricType string, start, end time.Time) ([]TimeseriesMetric, error)
}
