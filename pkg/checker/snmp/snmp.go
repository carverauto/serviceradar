package snmp

import (
	"fmt"
	"log"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/db"
)

// SNMPMetricsManager implements the SNMPManager interface for handling SNMP metrics
type SNMPMetricsManager struct {
	db db.Service
}

// NewSNMPManager creates a new SNMPManager instance
func NewSNMPManager(db db.Service) SNMPManager {
	return &SNMPMetricsManager{
		db: db,
	}
}

// GetSNMPMetrics fetches SNMP metrics from the database for a given node
func (s *SNMPMetricsManager) GetSNMPMetrics(nodeID string, startTime, endTime time.Time) ([]db.SNMPMetric, error) {
	log.Printf("Fetching SNMP metrics for node %s from %v to %v", nodeID, startTime, endTime)

	query := `
        SELECT oid_name, value, value_type, timestamp, scale, is_delta
        FROM timeseries_metrics
        WHERE node_id = ? AND metric_type = 'snmp' AND timestamp BETWEEN ? AND ?
    `

	rows, err := s.db.Query(query, nodeID, startTime, endTime)
	if err != nil {
		return nil, fmt.Errorf("failed to query SNMP metrics: %w", err)
	}
	defer db.CloseRows(rows)

	var metrics []db.SNMPMetric
	for rows.Next() {
		var metric db.SNMPMetric
		if err := rows.Scan(
			&metric.OIDName,
			&metric.Value,
			&metric.ValueType,
			&metric.Timestamp,
			&metric.Scale,
			&metric.IsDelta,
		); err != nil {
			return nil, fmt.Errorf("failed to scan SNMP metric: %w", err)
		}
		metrics = append(metrics, metric)
	}

	log.Printf("Retrieved %d SNMP metrics for node %s", len(metrics), nodeID)
	return metrics, nil
}
