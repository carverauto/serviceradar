package metrics

import (
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

//go:generate mockgen -destination=mock_buffer.go -package=metrics github.com/carverauto/serviceradar/pkg/metrics MetricStore,MetricCollector

type MetricStore interface {
	Add(timestamp time.Time, responseTime int64, serviceName string)
	GetPoints() []models.MetricPoint
	GetLastPoint() *models.MetricPoint // New method
}

type MetricCollector interface {
	AddMetric(nodeID string, timestamp time.Time, responseTime int64, serviceName string) error
	GetMetrics(nodeID string) []models.MetricPoint
	CleanupStaleNodes(staleDuration time.Duration)
}
