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

// StoreRperfMetrics stores rperf-checker data as timeseries metrics
func (db *DB) StoreRperfMetrics(nodeID, serviceName string, message string, timestamp time.Time) error {
	log.Printf("Processing rperf metrics for node %s, raw message: %s", nodeID, message)

	var rperfData struct {
		Results []RperfMetric `json:"results"`
	}

	if err := json.Unmarshal([]byte(message), &rperfData); err != nil {
		log.Printf("Failed to unmarshal rperf message for node %s: %v", nodeID, err)
		return fmt.Errorf("failed to unmarshal rperf message: %w", err)
	}

	log.Printf("Unmarshaled rperf data for node %s: %d results", nodeID, len(rperfData.Results))

	if len(rperfData.Results) == 0 {
		log.Printf("No rperf results found in message for node %s", nodeID)
		return nil
	}

	for i, result := range rperfData.Results {
		log.Printf("Processing rperf result %d for node %s: %+v", i, nodeID, result)
		metrics := map[string]struct {
			Value  string
			Metric *RperfMetric
		}{
			fmt.Sprintf("rperf_%s_bandwidth", result.Target): {
				Value:  fmt.Sprintf("%.2f", result.BitsPerSec/1e6),
				Metric: &result,
			},
			fmt.Sprintf("rperf_%s_jitter", result.Target): {
				Value:  fmt.Sprintf("%.2f", result.JitterMs),
				Metric: &result,
			},
			fmt.Sprintf("rperf_%s_loss", result.Target): {
				Value:  fmt.Sprintf("%.1f", result.LossPercent),
				Metric: &result,
			},
		}

		for metricName, data := range metrics {
			metadata, err := json.Marshal(data.Metric)
			if err != nil {
				log.Printf("Failed to marshal rperf metadata for node %s, metric %s: %v", nodeID, metricName, err)
				return fmt.Errorf("failed to marshal rperf metadata: %w", err)
			}

			metric := &TimeseriesMetric{
				Name:      metricName,
				Type:      "rperf",
				Value:     data.Value,
				Timestamp: timestamp,
				Metadata:  json.RawMessage(metadata),
			}

			if err := db.StoreMetric(nodeID, metric); err != nil {
				log.Printf("Failed to store rperf metric %s for node %s: %v", metricName, nodeID, err)
				return fmt.Errorf("failed to store rperf metric %s: %w", metricName, err)
			}
		}
	}

	log.Printf("Successfully stored %d rperf metrics for node %s", len(rperfData.Results)*3, nodeID)

	return nil
}
