// Package rperf pkg/checker/rperf/interfaces.go
package rperf

import (
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
)

// RperfManager defines the interface for managing rperf metrics.
type RperfManager interface {
	StoreRperfMetric(nodeID string, metric *db.TimeseriesMetric) error
	GetRperfMetrics(nodeID string, startTime, endTime time.Time) ([]db.TimeseriesMetric, error)
}
