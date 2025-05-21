/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package db

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	rperfBitsPerSecondDivisor = 1e6 // To convert bps to Mbps
)

// rperfWrapper defines the outer structure received from the agent for rperf checks.
type rperfWrapper struct {
	Status       string `json:"status"` // This holds the nested JSON string with actual results
	ResponseTime int64  `json:"response_time"`
	Available    bool   `json:"available"`
}

// queryTimeseriesMetrics executes a query on timeseries_metrics and returns the results.
func (db *DB) queryTimeseriesMetrics(
	ctx context.Context,
	pollerID, filterValue, filterColumn string,
	start, end time.Time,
) ([]models.TimeseriesMetric, error) {
	query := fmt.Sprintf(`
		SELECT metric_name, metric_type, value, metadata, timestamp
		FROM timeseries_metrics
		WHERE poller_id = $1
		AND %s = $2
		AND timestamp BETWEEN $3 AND $4`, filterColumn)

	rows, err := db.Conn.Query(ctx, query, pollerID, filterValue, start, end)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var metrics []models.TimeseriesMetric

	for rows.Next() {
		var metric models.TimeseriesMetric

		var metadataStr string

		err := rows.Scan(
			&metric.Name,
			&metric.Type,
			&metric.Value,
			&metadataStr,
			&metric.Timestamp,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan metric row: %w", err)
		}

		if metadataStr != "" {
			var rawMetadata json.RawMessage

			if err := json.Unmarshal([]byte(metadataStr), &rawMetadata); err != nil {
				log.Printf("Warning: failed to unmarshal metadata for metric %s: %v. Raw: %s", metric.Name, err, metadataStr)
			} else {
				metric.Metadata = rawMetadata
			}
		}

		metrics = append(metrics, metric)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating rows: %w", err)
	}

	return metrics, nil
}

// storeRperfMetricsToBatch stores rperf metrics to a batch and returns the number of stored metrics.
func (db *DB) storeRperfMetricsToBatch(
	ctx context.Context,
	pollerID string,
	metrics []models.RperfMetric,
	timestamp time.Time,
) (int, error) {
	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO timeseries_metrics (* except _tp_time)")
	if err != nil {
		return 0, fmt.Errorf("failed to prepare batch: %w", err)
	}

	storedCount := 0

	for _, result := range metrics {
		if !result.Success {
			log.Printf("Skipping metrics storage for failed rperf test (Target: %s) on poller %s. Error: %v",
				result.Target, pollerID, result.Error)
			continue
		}

		metricsToStore := []struct {
			Name  string
			Value string
		}{
			{
				Name:  fmt.Sprintf("rperf_%s_bandwidth_mbps", result.Target),
				Value: fmt.Sprintf("%.2f", result.BitsPerSec/rperfBitsPerSecondDivisor),
			},
			{
				Name:  fmt.Sprintf("rperf_%s_jitter_ms", result.Target),
				Value: fmt.Sprintf("%.2f", result.JitterMs),
			},
			{
				Name:  fmt.Sprintf("rperf_%s_loss_percent", result.Target),
				Value: fmt.Sprintf("%.1f", result.LossPercent),
			},
		}

		metadataBytes, err := json.Marshal(result)
		if err != nil {
			log.Printf("Failed to marshal rperf result metadata for poller %s, target %s: %v", pollerID, result.Target, err)
			continue
		}

		metadataStr := string(metadataBytes)

		for _, m := range metricsToStore {
			err = batch.Append(
				pollerID,
				m.Name,
				"rperf",
				m.Value,
				metadataStr,
				timestamp,
			)
			if err != nil {
				log.Printf("Failed to append rperf metric %s for poller %s: %v", m.Name, pollerID, err)
			} else {
				storedCount++
			}
		}
	}

	if err := batch.Send(); err != nil {
		return storedCount, fmt.Errorf("failed to send batch: %w", err)
	}

	return storedCount, nil
}

// StoreRperfMetrics stores rperf-checker data as timeseries metrics.
func (db *DB) StoreRperfMetrics(ctx context.Context, pollerID, _, message string, timestamp time.Time) error {
	var wrapper rperfWrapper

	if err := json.Unmarshal([]byte(message), &wrapper); err != nil {
		log.Printf("Failed to unmarshal outer rperf wrapper for poller %s: %v", pollerID, err)
		return fmt.Errorf("failed to unmarshal rperf wrapper message: %w", err)
	}

	if wrapper.Status == "" {
		log.Printf("No nested status found in rperf message for poller %s", pollerID)
		return nil
	}

	var rperfData struct {
		Results   []models.RperfMetric `json:"results"`
		Timestamp string               `json:"timestamp"`
	}

	if err := json.Unmarshal([]byte(wrapper.Status), &rperfData); err != nil {
		log.Printf("Failed to unmarshal nested rperf data for poller %s: %v", pollerID, err)
		return fmt.Errorf("failed to unmarshal nested rperf data: %w", err)
	}

	if len(rperfData.Results) == 0 {
		log.Printf("No rperf results found for poller %s", pollerID)
		return nil
	}

	storedCount, err := db.storeRperfMetricsToBatch(ctx, pollerID, rperfData.Results, timestamp)
	if err != nil {
		return fmt.Errorf("failed to store rperf metrics: %w", err)
	}

	log.Printf("Stored %d rperf metrics for poller %s", storedCount, pollerID)

	return nil
}

// StoreRperfMetricsBatch stores multiple rperf metrics in a single batch operation.
func (db *DB) StoreRperfMetricsBatch(ctx context.Context, pollerID string, metrics []*models.RperfMetric, timestamp time.Time) error {
	if len(metrics) == 0 {
		log.Printf("No rperf metrics to store for poller %s", pollerID)
		return nil
	}

	// Convert []*RperfMetric to []RperfMetric for compatibility
	rperfMetrics := make([]models.RperfMetric, len(metrics))
	for i, m := range metrics {
		rperfMetrics[i] = *m
	}

	storedCount, err := db.storeRperfMetricsToBatch(ctx, pollerID, rperfMetrics, timestamp)
	if err != nil {
		return fmt.Errorf("failed to store rperf metrics: %w", err)
	}

	if storedCount == 0 {
		log.Printf("No valid rperf metrics to send for poller %s", pollerID)
		return nil
	}

	log.Printf("Stored %d rperf metrics for poller %s", storedCount, pollerID)

	return nil
}

// GetMetrics retrieves metrics for a specific poller and metric name.
func (db *DB) GetMetrics(ctx context.Context, pollerID, metricName string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	metrics, err := db.queryTimeseriesMetrics(ctx, pollerID, metricName, "metric_name", start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics: %w", err)
	}

	return metrics, nil
}

// GetMetricsByType retrieves metrics for a specific poller and metric type.
func (db *DB) GetMetricsByType(ctx context.Context, pollerID, metricType string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	metrics, err := db.queryTimeseriesMetrics(ctx, pollerID, metricType, "metric_type", start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics by type: %w", err)
	}

	return metrics, nil
}

// GetCPUMetrics retrieves CPU metrics for a specific core.
func (db *DB) GetCPUMetrics(ctx context.Context, pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, core_id, usage_percent
		FROM cpu_metrics
		WHERE poller_id = $1 AND core_id = $2 AND timestamp BETWEEN $3 AND $4
		ORDER BY timestamp`,
		pollerID, coreID, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query CPU metrics: %w", err)
	}
	defer rows.Close()

	var metrics []models.CPUMetric

	for rows.Next() {
		var m models.CPUMetric

		if err := rows.Scan(&m.Timestamp, &m.CoreID, &m.UsagePercent); err != nil {
			return nil, fmt.Errorf("failed to scan CPU metric: %w", err)
		}

		metrics = append(metrics, m)
	}

	return metrics, nil
}

// StoreMetric stores a timeseries metric in the database.
// This is optimized to use batch operations internally, making a single metric
// store functionally similar to the batch operation but with a simpler API.
func (db *DB) StoreMetric(ctx context.Context, pollerID string, metric *models.TimeseriesMetric) error {
	log.Printf("Storing metric: %v", metric)

	// Convert metadata to JSON string
	var metadataStr string

	if metric.Metadata != nil {
		metadataBytes, err := json.Marshal(metric.Metadata)
		if err != nil {
			return fmt.Errorf("failed to marshal metadata: %w", err)
		}

		metadataStr = string(metadataBytes)
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO timeseries_metrics (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	err = batch.Append(
		pollerID,
		metric.Name,
		metric.Type,
		metric.Value,
		metadataStr,
		metric.Timestamp,
	)
	if err != nil {
		return fmt.Errorf("failed to append metric: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to store metric %s for poller %s: %w", metric.Name, pollerID, err)
	}

	return nil
}

// BatchMetricsOperation executes a batch operation for timeseries metrics
// This is a generic helper function that can be used by specialized metric functions
func (db *DB) BatchMetricsOperation(ctx context.Context, pollerID string, metrics []*models.TimeseriesMetric) error {
	if len(metrics) == 0 {
		return nil
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO timeseries_metrics (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare metrics batch: %w", err)
	}

	for _, metric := range metrics {
		metadataStr := ""

		if metric.Metadata != nil {
			var metadataBytes []byte

			metadataBytes, err = json.Marshal(metric.Metadata)
			if err != nil {
				log.Printf("Failed to marshal metadata for metric %s: %v", metric.Name, err)
				continue
			}

			metadataStr = string(metadataBytes)
		}

		err = batch.Append(
			pollerID,
			metric.Name,
			metric.Type,
			metric.Value,
			metadataStr,
			metric.Timestamp,
		)
		if err != nil {
			log.Printf("Failed to append metric %s to batch: %v", metric.Name, err)
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to send metrics batch: %w", err)
	}

	return nil
}
