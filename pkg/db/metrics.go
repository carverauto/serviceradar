package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"time"
)

// StoreMetric stores a timeseries metric in the database
func (db *DB) StoreMetric(nodeID string, metric *TimeseriesMetric) error {
	log.Printf("Storing metric: %v", metric)

	// Convert metadata to JSON if present
	var metadataJSON sql.NullString
	if metric.Metadata != nil {
		metadata, err := json.Marshal(metric.Metadata)
		if err != nil {
			return fmt.Errorf("failed to marshal metadata: %w", err)
		}
		metadataJSON.String = string(metadata)
		metadataJSON.Valid = true
	}

	_, err := db.Exec(`
        INSERT INTO timeseries_metrics 
            (node_id, metric_name, metric_type, value, metadata, timestamp)
        VALUES (?, ?, ?, ?, ?, ?)`,
		nodeID,
		metric.Name,
		metric.Type,
		metric.Value,
		metadataJSON,
		metric.Timestamp,
	)

	if err != nil {
		return fmt.Errorf("failed to store metric: %w", err)
	}

	log.Printf("Stored metric: %v", metric)

	return nil
}

// GetMetrics retrieves metrics for a specific node and metric name
func (db *DB) GetMetrics(nodeID, metricName string, start, end time.Time) ([]TimeseriesMetric, error) {
	rows, err := db.Query(`
        SELECT metric_name, metric_type, value, metadata, timestamp
        FROM timeseries_metrics
        WHERE node_id = ? 
        AND metric_name = ?
        AND timestamp BETWEEN ? AND ?
        ORDER BY timestamp ASC`,
		nodeID,
		metricName,
		start,
		end,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics: %w", err)
	}
	defer CloseRows(rows)

	return db.scanMetrics(rows)
}

// GetMetricsByType retrieves metrics for a specific node and metric type
func (db *DB) GetMetricsByType(nodeID, metricType string, start, end time.Time) ([]TimeseriesMetric, error) {
	rows, err := db.Query(`
        SELECT metric_name, metric_type, value, metadata, timestamp
        FROM timeseries_metrics
        WHERE node_id = ? 
        AND metric_type = ?
        AND timestamp BETWEEN ? AND ?
        ORDER BY timestamp ASC`,
		nodeID,
		metricType,
		start,
		end,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics by type: %w", err)
	}
	defer CloseRows(rows)

	return db.scanMetrics(rows)
}

// Helper function to scan metric rows
func (db *DB) scanMetrics(rows Rows) ([]TimeseriesMetric, error) {
	var metrics []TimeseriesMetric

	for rows.Next() {
		var metric TimeseriesMetric
		var metadataJSON sql.NullString

		err := rows.Scan(
			&metric.Name,
			&metric.Type,
			&metric.Value,
			&metadataJSON,
			&metric.Timestamp,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan metric row: %w", err)
		}

		// Parse metadata JSON if present
		if metadataJSON.Valid {
			var metadata interface{}
			if err := json.Unmarshal([]byte(metadataJSON.String), &metadata); err != nil {
				return nil, fmt.Errorf("failed to unmarshal metadata: %w", err)
			}
			metric.Metadata = metadata
		}

		metrics = append(metrics, metric)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating rows: %w", err)
	}

	return metrics, nil
}
