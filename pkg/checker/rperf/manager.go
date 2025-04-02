// Package rperf pkg/checker/rperf/manager.go
package rperf

import (
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
)

// rperfManagerImpl is the concrete implementation of RperfManager.
type rperfManagerImpl struct {
	db db.Service
}

// NewRperfManager creates a new RperfManager instance.
func NewRperfManager(db db.Service) RperfManager { // Return the interface type
	return &rperfManagerImpl{db: db}
}

// StoreRperfMetric stores an rperf metric in the database.
func (m *rperfManagerImpl) StoreRperfMetric(nodeID string, metric *db.TimeseriesMetric) error {
	return m.db.StoreMetric(nodeID, metric)
}

// GetRperfMetrics retrieves rperf metrics for a node within a time range.
func (m *rperfManagerImpl) GetRperfMetrics(nodeID string, startTime, endTime time.Time) ([]db.TimeseriesMetric, error) {
	log.Printf("Fetching rperf metrics for node %s from %v to %v", nodeID, startTime, endTime)

	metrics, err := m.db.GetMetricsByType(nodeID, "rperf", startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch rperf metrics: %w", err)
	}

	log.Printf("Retrieved %d rperf metrics for node %s", len(metrics), nodeID)
	return metrics, nil
}
