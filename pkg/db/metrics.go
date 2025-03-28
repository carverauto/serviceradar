/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"time"
)

// StoreMetric stores a timeseries metric in the database.
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

// GetMetrics retrieves metrics for a specific node and metric name.
func (db *DB) GetMetrics(nodeID, metricName string, start, end time.Time) ([]TimeseriesMetric, error) {
	rows, err := db.Query(`
        SELECT metric_name, metric_type, value, metadata, timestamp
        FROM timeseries_metrics
        WHERE node_id = ? 
        AND metric_name = ?
        AND timestamp BETWEEN ? AND ?`,
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

// GetMetricsByType retrieves metrics for a specific node and metric type.
func (db *DB) GetMetricsByType(nodeID, metricType string, start, end time.Time) ([]TimeseriesMetric, error) {
	rows, err := db.Query(`
        SELECT metric_name, metric_type, value, metadata, timestamp
        FROM timeseries_metrics
        WHERE node_id = ? 
        AND metric_type = ?
        AND timestamp BETWEEN ? AND ?`,
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

func (*DB) scanMetrics(rows Rows) ([]TimeseriesMetric, error) {
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
