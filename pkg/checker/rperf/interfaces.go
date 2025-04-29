// Package rperf pkg/checker/rperf/interfaces.go
package rperf

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
)

// RperfManager defines the interface for managing rperf metrics.
type RperfManager interface {
	StoreRperfMetric(ctx context.Context, pollerID string, metric *db.TimeseriesMetric) error
	GetRperfMetrics(ctx context.Context, pollerID string, startTime, endTime time.Time) ([]*db.TimeseriesMetric, error)
}
