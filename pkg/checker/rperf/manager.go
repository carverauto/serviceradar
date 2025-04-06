// Package rperf pkg/checker/rperf/manager.go
package rperf

import (
	"encoding/json"
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
func NewRperfManager(db db.Service) RperfManager {
	return &rperfManagerImpl{db: db}
}

// StoreRperfMetric stores an rperf metric in the database.
func (m *rperfManagerImpl) StoreRperfMetric(pollerID string, metric *db.TimeseriesMetric) error {
	return m.db.StoreMetric(pollerID, metric)
}

// GetRperfMetrics retrieves rperf metrics for a poller within a time range.
func (m *rperfManagerImpl) GetRperfMetrics(pollerID string, startTime, endTime time.Time) ([]*db.TimeseriesMetric, error) {
	query := `
        SELECT metric_name, value, metric_type, timestamp, metadata
        FROM timeseries_metrics
        WHERE poller_id = ? AND metric_type = 'rperf' AND timestamp BETWEEN ? AND ?
        ORDER BY timestamp DESC
    `

	rows, err := m.db.Query(query, pollerID, startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to query rperf metrics: %w", err)
	}

	defer func(rows db.Rows) {
		err := rows.Close()
		if err != nil {
			log.Printf("WARNING: failed to close rows: %v", err)
		}
	}(rows)

	var metrics []*db.TimeseriesMetric

	for rows.Next() {
		var m db.TimeseriesMetric

		var metadataJSON string

		if err := rows.Scan(&m.Name, &m.Value, &m.Type, &m.Timestamp, &metadataJSON); err != nil {
			return nil, fmt.Errorf("failed to scan metric: %w", err)
		}

		if metadataJSON != "" { // Handle NULL metadata
			if err := json.Unmarshal([]byte(metadataJSON), &m.Metadata); err != nil {
				log.Printf("Failed to unmarshal metadata for metric %s on poller %s: %v", m.Name, pollerID, err)

				return nil, fmt.Errorf("failed to unmarshal metadata: %w", err)
			}
		} else {
			m.Metadata = make(map[string]interface{})
		}

		metrics = append(metrics, &m)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating rows: %w", err)
	}

	log.Printf("Retrieved %d rperf metrics for poller %s", len(metrics), pollerID)

	return metrics, nil
}
