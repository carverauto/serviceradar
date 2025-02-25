// Package cloud pkg/cloud/interfaces.go

//go:generate mockgen -destination=mock_server.go -package=cloud github.com/carverauto/serviceradar/pkg/cloud NodeService,CloudService

package cloud

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/cloud/api"
	"github.com/carverauto/serviceradar/pkg/metrics"
)

// NodeService represents node-related operations.
type NodeService interface {
	GetNodeStatus(nodeID string) (*api.NodeStatus, error)
	UpdateNodeStatus(nodeID string, status *api.NodeStatus) error
	GetNodeHistory(nodeID string, limit int) ([]api.NodeHistoryPoint, error)
	CheckNodeHealth(nodeID string) (bool, error)
}

// CloudService represents the main cloud service functionality.
type CloudService interface {
	Start(ctx context.Context) error
	Stop(ctx context.Context) error
	ReportStatus(ctx context.Context, nodeID string, status *api.NodeStatus) error
	GetMetricsManager() metrics.MetricCollector
}
