// Package cloud pkg/cloud/interfaces.go

//go:generate mockgen -destination=mock_server.go -package=cloud github.com/mfreeman451/serviceradar/pkg/cloud NodeService,CloudService

package cloud

import (
	"context"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/cloud/api"
	"github.com/mfreeman451/serviceradar/pkg/metrics"
)

// NodeService represents node-related operations.
type NodeService interface {
	GetNodeStatus(nodeID string) (*api.NodeStatus, error)
	UpdateNodeStatus(nodeID string, status *api.NodeStatus) error
	GetNodeHistory(nodeID string, limit int) ([]api.NodeHistoryPoint, error)
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

// CloudService represents the main cloud service functionality.
type CloudService interface {
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	ReportStatus(ctx context.Context, nodeID string, status *api.NodeStatus) error
	GetMetricsManager() metrics.MetricCollector
}
