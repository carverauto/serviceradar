package metrics

import (
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
)

//go:generate mockgen -destination=mock_buffer.go -package=metrics github.com/mfreeman451/serviceradar/pkg/metrics MetricStore,MetricCollector

type MetricStore interface {
	Add(timestamp time.Time, responseTime int64, serviceName string)
	GetPoints() []models.MetricPoint
}

type MetricCollector interface {
	AddMetric(nodeID string, timestamp time.Time, responseTime int64, serviceName string) error
	GetMetrics(nodeID string) []models.MetricPoint
}
