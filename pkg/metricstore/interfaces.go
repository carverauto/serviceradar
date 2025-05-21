package metricstore

import (
	"context"
	"github.com/carverauto/serviceradar/pkg/models"
	"time"
)

// RperfManager defines the interface for managing rperf metrics.
type RperfManager interface {
	StoreRperfMetric(ctx context.Context, pollerID string, metric *models.RperfMetric, timestamp time.Time) error // Use RperfMetric as the input
	GetRperfMetrics(ctx context.Context, pollerID string, startTime, endTime time.Time) ([]*models.RperfMetric, error)
}

// SNMPManager defines the interface for managing SNMP metrics.
type SNMPManager interface {
	GetSNMPMetrics(ctx context.Context, nodeID string, startTime, endTime time.Time) ([]models.SNMPMetric, error)
	// If you later add a specific StoreSNMPMetric, it would go here.
	// For now, SNMP data is collected by the agent and sent as generic TimeseriesMetrics
	// or handled by the `snmp.SNMPService` internally.
}
