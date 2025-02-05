// Package cloud pkg/cloud/interfaces.go

//go:generate mockgen -destination=mock_server.go -package=cloud github.com/mfreeman451/serviceradar/pkg/cloud DatabaseService,AlertService,MetricsService,APIService,NodeService,CloudService,TransactionService

package cloud

import (
	"context"
	"database/sql"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/cloud/alerts"
	"github.com/mfreeman451/serviceradar/pkg/cloud/api"
	"github.com/mfreeman451/serviceradar/pkg/metrics"
	"github.com/mfreeman451/serviceradar/pkg/models"
)

// DatabaseService represents all database operations.
type DatabaseService interface {
	Begin() (*sql.Tx, error)
	Close() error
	Exec(query string, args ...interface{}) (sql.Result, error)
	Query(query string, args ...interface{}) (*sql.Rows, error)
	QueryRow(query string, args ...interface{}) *sql.Row
	UpdateNodeStatus(status *NodeStatus) error
	UpdateServiceStatus(status *ServiceStatus) error
	GetNodeHistoryPoints(nodeID string, limit int) ([]NodeHistoryPoint, error)
	CleanOldData(age time.Duration) error
}

// AlertService represents the alerting system.
type AlertService interface {
	Alert(ctx context.Context, alert *alerts.WebhookAlert) error
	IsEnabled() bool
}

// MetricsService represents the metrics collection system.
type MetricsService interface {
	AddMetric(nodeID string, timestamp time.Time, value int64, serviceType string) error
	GetMetrics(nodeID string) []models.MetricPoint
	CleanupStaleNodes(age time.Duration)
}

// APIService represents the API server functionality.
type APIService interface {
	Start(addr string) error
	UpdateNodeStatus(nodeID string, status *api.NodeStatus)
	SetNodeHistoryHandler(handler func(nodeID string) ([]api.NodeHistoryPoint, error))
	SetKnownPollers(knownPollers []string)
}

// NodeService represents node-related operations.
type NodeService interface {
	GetNodeStatus(nodeID string) (*NodeStatus, error)
	UpdateNodeStatus(nodeID string, status *NodeStatus) error
	GetNodeHistory(nodeID string, limit int) ([]NodeHistoryPoint, error)
	CheckNodeHealth(nodeID string) (bool, error)
}

// ServiceStatus represents the status of a monitored service.
type ServiceStatus struct {
	NodeID      string
	ServiceName string
	ServiceType string
	Available   bool
	Details     string
	Timestamp   time.Time
}

// NodeStatus represents the status of a node.
type NodeStatus struct {
	NodeID    string
	IsHealthy bool
	LastSeen  time.Time
}

// NodeHistoryPoint represents a point in a node's history.
type NodeHistoryPoint struct {
	Timestamp time.Time
	IsHealthy bool
}

// CloudService represents the main cloud service functionality.
type CloudService interface {
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	ReportStatus(ctx context.Context, nodeID string, status *NodeStatus) error
	GetMetricsManager() metrics.MetricCollector
}

// TransactionService represents database transaction operations.
type TransactionService interface {
	Begin() (*sql.Tx, error)
	Commit() error
	Rollback() error
	Exec(query string, args ...interface{}) (sql.Result, error)
	Query(query string, args ...interface{}) (*sql.Rows, error)
	QueryRow(query string, args ...interface{}) *sql.Row
}
