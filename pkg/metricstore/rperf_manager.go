package metricstore

import (
	"context"
	"encoding/json" // For marshaling RperfMetric into metadata
	"fmt"
	"github.com/carverauto/serviceradar/pkg/models"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
)

type rperfManagerImpl struct { // Retained name but now in new package
	db db.Service
}

// NewRperfManager creates a new RperfManager instance.
func NewRperfManager(d db.Service) RperfManager {
	return &rperfManagerImpl{db: d}
}

const (
	rperfBitsPerSecondDivisor = 1e6 // To convert bps to Mbps
)

// StoreRperfMetric stores an rperf metric in the database.
// It takes a metrics.RperfMetric and converts it into generic metrics.TimeseriesMetric
func (m *rperfManagerImpl) StoreRperfMetric(ctx context.Context, pollerID string, rperfResult *models.RperfMetric, timestamp time.Time) error {
	if !rperfResult.Success {
		log.Printf("Skipping metrics storage for failed rperf test (Target: %s) on poller %s. Error: %v",
			rperfResult.Target, pollerID, *rperfResult.Error)
		return nil
	}

	// Marshal the original RperfMetric as metadata
	metadataBytes, err := json.Marshal(rperfResult)
	if err != nil {
		return fmt.Errorf("failed to marshal rperf result metadata for poller %s, target %s: %w", pollerID, rperfResult.Target, err)
	}
	metadataRaw := json.RawMessage(metadataBytes)

	metricsToStore := []*models.TimeseriesMetric{ // Use metrics.TimeseriesMetric
		{
			Name:      fmt.Sprintf("rperf_%s_bandwidth_mbps", rperfResult.Target),
			Value:     fmt.Sprintf("%.2f", rperfResult.BitsPerSec/rperfBitsPerSecondDivisor),
			Type:      "rperf",
			Timestamp: timestamp,
			Metadata:  metadataRaw,
		},
		{
			Name:      fmt.Sprintf("rperf_%s_jitter_ms", rperfResult.Target),
			Value:     fmt.Sprintf("%.2f", rperfResult.JitterMs),
			Type:      "rperf",
			Timestamp: timestamp,
			Metadata:  metadataRaw,
		},
		{
			Name:      fmt.Sprintf("rperf_%s_loss_percent", rperfResult.Target),
			Value:     fmt.Sprintf("%.1f", rperfResult.LossPercent),
			Type:      "rperf",
			Timestamp: timestamp,
			Metadata:  metadataRaw,
		},
	}

	// Call the underlying db.Service with the generic TimeseriesMetrics
	return m.db.StoreMetrics(ctx, pollerID, metricsToStore) // StoreMetrics takes []*metrics.TimeseriesMetric
}

// GetRperfMetrics retrieves rperf metrics for a poller within a time range.
func (m *rperfManagerImpl) GetRperfMetrics(ctx context.Context, pollerID string, startTime, endTime time.Time) ([]*models.RperfMetric, error) {
	// Query the generic timeseries metrics
	tsMetrics, err := m.db.GetMetricsByType(ctx, pollerID, "rperf", startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to query rperf timeseries metrics: %w", err)
	}

	rperfMetrics := make([]*models.RperfMetric, 0, len(tsMetrics))
	for _, m := range tsMetrics {
		if m.Metadata != nil {
			var rperfMetric models.RperfMetric // Use metrics.RperfMetric
			if err := json.Unmarshal(m.Metadata, &rperfMetric); err != nil {
				log.Printf("Warning: failed to unmarshal rperf metadata for metric %s: %v", m.Name, err)
				continue
			}
			rperfMetrics = append(rperfMetrics, &rperfMetric)
		}
	}
	return rperfMetrics, nil
}
