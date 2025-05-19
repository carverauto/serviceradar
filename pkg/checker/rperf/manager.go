package rperf

import (
	"context"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
)

// rperfManagerImpl is the concrete implementation of RperfManager.
type rperfManagerImpl struct {
	db db.Service
}

// NewRperfManager creates a new RperfManager instance.
func NewRperfManager(d db.Service) RperfManager {
	return &rperfManagerImpl{db: d}
}

// StoreRperfMetric stores an rperf metric in the database.
func (m *rperfManagerImpl) StoreRperfMetric(ctx context.Context, pollerID string, metric *db.TimeseriesMetric) error {
	return m.db.StoreMetric(ctx, pollerID, metric)
}

// GetRperfMetrics retrieves rperf metrics for a poller within a time range.
func (m *rperfManagerImpl) GetRperfMetrics(
	ctx context.Context, pollerID string, startTime, endTime time.Time) ([]*db.TimeseriesMetric, error) {
	metrics, err := m.db.GetMetricsByType(ctx, pollerID, "rperf", startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to query rperf metrics: %w", err)
	}

	// Convert []TimeseriesMetric to []*TimeseriesMetric
	pointerMetrics := make([]*db.TimeseriesMetric, len(metrics))
	for i := range metrics {
		pointerMetrics[i] = &metrics[i]
	}

	return pointerMetrics, nil
}
