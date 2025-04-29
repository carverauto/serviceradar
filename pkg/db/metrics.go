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
	"sort"
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

// StoreMetric stores a timeseries metric in the database.
func (db *DB) StoreMetric(ctx context.Context, pollerID string, metric *TimeseriesMetric) error {
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

	batch, err := db.conn.PrepareBatch(ctx, "INSERT INTO timeseries_metrics (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	err = batch.Append(
		pollerID,
		metric.Name,
		metric.Type,
		metric.Value,
		metadataStr, // Use JSON string
		metric.Timestamp,
	)
	if err != nil {
		return fmt.Errorf("failed to append metric: %w", err)
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to store metric %s for poller %s: %w", metric.Name, pollerID, err)
	}

	log.Printf("Successfully stored metric %s for poller %s", metric.Name, pollerID)
	return nil
}

// GetMetrics retrieves metrics for a specific poller and metric name.
func (db *DB) GetMetrics(ctx context.Context, pollerID, metricName string, start, end time.Time) ([]TimeseriesMetric, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT metric_name, metric_type, value, metadata, timestamp
		FROM timeseries_metrics
		WHERE poller_id = $1
		AND metric_name = $2
		AND timestamp BETWEEN $3 AND $4`,
		pollerID, metricName, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics: %w", err)
	}
	defer rows.Close()

	var metrics []TimeseriesMetric

	for rows.Next() {
		var metric TimeseriesMetric
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

		// Convert metadata string to JSON RawMessage
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

// GetMetricsByType retrieves metrics for a specific poller and metric type.
func (db *DB) GetMetricsByType(ctx context.Context, pollerID, metricType string, start, end time.Time) ([]TimeseriesMetric, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT metric_name, metric_type, value, metadata, timestamp
		FROM timeseries_metrics
		WHERE poller_id = $1
		AND metric_type = $2
		AND timestamp BETWEEN $3 AND $4`,
		pollerID, metricType, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics by type: %w", err)
	}
	defer rows.Close()

	var metrics []TimeseriesMetric

	for rows.Next() {
		var metric TimeseriesMetric
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

		// Convert metadata string to JSON RawMessage
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
		Results   []RperfMetric `json:"results"`
		Timestamp string        `json:"timestamp"`
	}

	if err := json.Unmarshal([]byte(wrapper.Status), &rperfData); err != nil {
		log.Printf("Failed to unmarshal nested rperf data for poller %s: %v", pollerID, err)
		return fmt.Errorf("failed to unmarshal nested rperf data: %w", err)
	}

	if len(rperfData.Results) == 0 {
		log.Printf("No rperf results found for poller %s", pollerID)
		return nil
	}

	batch, err := db.conn.PrepareBatch(ctx, "INSERT INTO timeseries_metrics (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	storedCount := 0
	for _, result := range rperfData.Results {
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

		// Convert result to JSON string
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
		return fmt.Errorf("failed to send batch: %w", err)
	}

	log.Printf("Stored %d rperf metrics for poller %s", storedCount, pollerID)
	return nil
}

// StoreSysmonMetrics stores sysmon metrics.
func (db *DB) StoreSysmonMetrics(ctx context.Context, pollerID string, metrics *models.SysmonMetrics, timestamp time.Time) error {
	// Store CPU metrics
	cpuBatch, err := db.conn.PrepareBatch(ctx, "INSERT INTO cpu_metrics (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare CPU batch: %w", err)
	}

	for _, cpu := range metrics.CPUs {
		err = cpuBatch.Append(
			pollerID,
			timestamp,
			cpu.CoreID,
			cpu.UsagePercent,
		)
		if err != nil {
			return fmt.Errorf("failed to append CPU metric for core %d: %w", cpu.CoreID, err)
		}
	}

	if err := cpuBatch.Send(); err != nil {
		return fmt.Errorf("failed to store CPU metrics: %w", err)
	}

	// Store disk metrics
	diskBatch, err := db.conn.PrepareBatch(ctx, "INSERT INTO disk_metrics (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare disk batch: %w", err)
	}

	for _, disk := range metrics.Disks {
		err = diskBatch.Append(
			pollerID,
			timestamp,
			disk.MountPoint,
			disk.UsedBytes,
			disk.TotalBytes,
		)
		if err != nil {
			return fmt.Errorf("failed to append disk metric for %s: %w", disk.MountPoint, err)
		}
	}

	if err := diskBatch.Send(); err != nil {
		return fmt.Errorf("failed to store disk metrics: %w", err)
	}

	// Store memory metrics
	memoryBatch, err := db.conn.PrepareBatch(ctx, "INSERT INTO memory_metrics (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare memory batch: %w", err)
	}

	err = memoryBatch.Append(
		pollerID,
		timestamp,
		metrics.Memory.UsedBytes,
		metrics.Memory.TotalBytes,
	)
	if err != nil {
		return fmt.Errorf("failed to append memory metric: %w", err)
	}

	if err := memoryBatch.Send(); err != nil {
		return fmt.Errorf("failed to store memory metrics: %w", err)
	}

	log.Printf("Stored sysmon metrics for poller %s: %d CPUs, %d disks, 1 memory", pollerID, len(metrics.CPUs), len(metrics.Disks))
	return nil
}

// GetCPUMetrics retrieves CPU metrics for a specific core.
func (db *DB) GetCPUMetrics(ctx context.Context, pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error) {
	rows, err := db.conn.Query(ctx, `
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

// GetAllMountPoints retrieves all unique mount points for a poller.
func (db *DB) GetAllMountPoints(ctx context.Context, pollerID string) ([]string, error) {
	log.Printf("Querying all mount points for poller %s", pollerID)

	rows, err := db.conn.Query(ctx, `
		SELECT DISTINCT mount_point
		FROM disk_metrics
		WHERE poller_id = $1
		ORDER BY mount_point ASC`,
		pollerID)
	if err != nil {
		log.Printf("Error querying mount points: %v", err)
		return nil, fmt.Errorf("failed to query mount points: %w", err)
	}
	defer rows.Close()

	var mountPoints []string
	for rows.Next() {
		var mountPoint string
		if err := rows.Scan(&mountPoint); err != nil {
			log.Printf("Error scanning mount point: %v", err)
			continue
		}
		mountPoints = append(mountPoints, mountPoint)
	}

	log.Printf("Found %d unique mount points for poller %s", len(mountPoints), pollerID)
	return mountPoints, nil
}

// GetAllCPUMetrics retrieves all CPU metrics for a poller within a time range, grouped by timestamp.
func (db *DB) GetAllCPUMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]SysmonCPUResponse, error) {
	log.Printf("Querying all CPU metrics for poller %s between %s and %s",
		pollerID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, core_id, usage_percent
		FROM cpu_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, core_id ASC`,
		pollerID, start, end)
	if err != nil {
		log.Printf("Error querying all CPU metrics: %v", err)
		return nil, fmt.Errorf("failed to query all CPU metrics: %w", err)
	}
	defer rows.Close()

	data := make(map[time.Time][]models.CPUMetric)
	for rows.Next() {
		var m models.CPUMetric
		var timestamp time.Time
		if err := rows.Scan(&timestamp, &m.CoreID, &m.UsagePercent); err != nil {
			log.Printf("Error scanning CPU metric row: %v", err)
			continue
		}
		m.Timestamp = timestamp
		data[timestamp] = append(data[timestamp], m)
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating CPU metrics rows: %v", err)
		return nil, err
	}

	result := make([]SysmonCPUResponse, 0, len(data))
	for ts, cpus := range data {
		result = append(result, SysmonCPUResponse{
			Cpus:      cpus,
			Timestamp: ts,
		})
	}

	// Sort by timestamp descending
	sort.Slice(result, func(i, j int) bool {
		return result[i].Timestamp.After(result[j].Timestamp)
	})

	log.Printf("Retrieved %d CPU metric timestamps for poller %s", len(result), pollerID)
	return result, nil
}

// GetAllDiskMetrics retrieves all disk metrics for a poller.
func (db *DB) GetAllDiskMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.DiskMetric, error) {
	log.Printf("Querying all disk metrics for poller %s between %s and %s",
		pollerID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	rows, err := db.conn.Query(ctx, `
		SELECT mount_point, used_bytes, total_bytes, timestamp
		FROM disk_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, mount_point ASC`,
		pollerID, start, end)
	if err != nil {
		log.Printf("Error querying all disk metrics: %v", err)
		return nil, fmt.Errorf("failed to query all disk metrics: %w", err)
	}
	defer rows.Close()

	var metrics []models.DiskMetric
	for rows.Next() {
		var m models.DiskMetric
		if err = rows.Scan(&m.MountPoint, &m.UsedBytes, &m.TotalBytes, &m.Timestamp); err != nil {
			log.Printf("Error scanning disk metric row: %v", err)
			continue
		}
		metrics = append(metrics, m)
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating disk metrics rows: %v", err)
		return metrics, err
	}

	log.Printf("Retrieved %d disk metrics for poller %s", len(metrics), pollerID)
	return metrics, nil
}

// GetDiskMetrics retrieves disk metrics for a specific mount point.
func (db *DB) GetDiskMetrics(ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, mount_point, used_bytes, total_bytes
		FROM disk_metrics
		WHERE poller_id = $1 AND mount_point = $2 AND timestamp BETWEEN $3 AND $4
		ORDER BY timestamp`,
		pollerID, mountPoint, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query disk metrics: %w", err)
	}
	defer rows.Close()

	var metrics []models.DiskMetric
	for rows.Next() {
		var m models.DiskMetric
		if err = rows.Scan(&m.Timestamp, &m.MountPoint, &m.UsedBytes, &m.TotalBytes); err != nil {
			log.Printf("Error scanning disk metric row: %v", err)
			continue
		}
		metrics = append(metrics, m)
	}

	return metrics, nil
}

// GetMemoryMetrics retrieves memory metrics.
func (db *DB) GetMemoryMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.MemoryMetric, error) {
	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, used_bytes, total_bytes
		FROM memory_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp`,
		pollerID, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query memory metrics: %w", err)
	}
	defer rows.Close()

	var metrics []models.MemoryMetric
	for rows.Next() {
		var m models.MemoryMetric
		if err = rows.Scan(&m.Timestamp, &m.UsedBytes, &m.TotalBytes); err != nil {
			log.Printf("Error scanning memory metric row: %v", err)
			continue
		}
		metrics = append(metrics, m)
	}

	return metrics, nil
}

// GetAllDiskMetricsGrouped retrieves disk metrics grouped by timestamp.
func (db *DB) GetAllDiskMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]SysmonDiskResponse, error) {
	log.Printf("Querying all disk metrics for poller %s between %s and %s",
		pollerID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, mount_point, used_bytes, total_bytes
		FROM disk_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, mount_point ASC`,
		pollerID, start, end)
	if err != nil {
		log.Printf("Error querying all disk metrics: %v", err)
		return nil, fmt.Errorf("failed to query all disk metrics: %w", err)
	}
	defer rows.Close()

	data := make(map[time.Time][]models.DiskMetric)
	for rows.Next() {
		var m models.DiskMetric
		var timestamp time.Time
		if err = rows.Scan(&timestamp, &m.MountPoint, &m.UsedBytes, &m.TotalBytes); err != nil {
			log.Printf("Error scanning disk metric row: %v", err)
			continue
		}
		m.Timestamp = timestamp
		data[timestamp] = append(data[timestamp], m)
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating disk metrics rows: %v", err)
		return nil, err
	}

	result := make([]SysmonDiskResponse, 0, len(data))
	for ts, disks := range data {
		result = append(result, SysmonDiskResponse{
			Disks:     disks,
			Timestamp: ts,
		})
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].Timestamp.After(result[j].Timestamp)
	})

	log.Printf("Retrieved %d disk metric timestamps for poller %s", len(result), pollerID)
	return result, nil
}

// GetMemoryMetricsGrouped retrieves memory metrics grouped by timestamp.
func (db *DB) GetMemoryMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]SysmonMemoryResponse, error) {
	log.Printf("Querying memory metrics for poller %s between %s and %s",
		pollerID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	rows, err := db.conn.Query(ctx, `
		SELECT timestamp, used_bytes, total_bytes
		FROM memory_metrics
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC`,
		pollerID, start, end)
	if err != nil {
		log.Printf("Error querying memory metrics: %v", err)
		return nil, fmt.Errorf("failed to query memory metrics: %w", err)
	}
	defer rows.Close()

	var result []SysmonMemoryResponse
	for rows.Next() {
		var m models.MemoryMetric
		var timestamp time.Time
		if err = rows.Scan(&timestamp, &m.UsedBytes, &m.TotalBytes); err != nil {
			log.Printf("Error scanning memory metric row: %v", err)
			continue
		}
		m.Timestamp = timestamp
		result = append(result, SysmonMemoryResponse{
			Memory:    m,
			Timestamp: timestamp,
		})
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating memory metrics rows: %v", err)
		return nil, err
	}

	log.Printf("Retrieved %d memory metric timestamps for poller %s", len(result), pollerID)
	return result, nil
}
