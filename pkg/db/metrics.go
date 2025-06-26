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
	"github.com/timeplus-io/proton-go-driver/v2/lib/driver"
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
// queryTimeseriesMetrics executes a query on timeseries_metrics and returns the results.
func (db *DB) queryTimeseriesMetrics(
	ctx context.Context,
	pollerID, filterValue, filterColumn string,
	start, end time.Time,
) ([]models.TimeseriesMetric, error) {
	query := fmt.Sprintf(`
        SELECT metric_name, metric_type, value, metadata, timestamp, target_device_ip, ifIndex 
        FROM table(timeseries_metrics)
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

		// Scan metadata as a string
		var metadataStr string

		err := rows.Scan(
			&metric.Name,
			&metric.Type,
			&metric.Value,
			&metadataStr, // Scan into string
			&metric.Timestamp,
			&metric.TargetDeviceIP,
			&metric.IfIndex,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan metric row: %w", err)
		}

		// Assign the scanned string to metric.Metadata
		metric.Metadata = metadataStr

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

	for i := 0; i < len(metrics); i++ {
		result := &metrics[i]
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
		SELECT timestamp, agent_id, host_id, core_id, usage_percent
		FROM table(cpu_metrics)
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
		var agentID, hostID string

		if err := rows.Scan(&m.Timestamp, &agentID, &hostID, &m.CoreID, &m.UsagePercent); err != nil {
			return nil, fmt.Errorf("failed to scan CPU metric: %w", err)
		}

		m.AgentID = agentID
		m.HostID = hostID
		metrics = append(metrics, m)
	}

	return metrics, nil
}

// StoreMetric stores a timeseries metric in the database.
// This is optimized to use batch operations internally, making a single metric
// store functionally similar to the batch operation but with a simpler API.
func (db *DB) StoreMetric(ctx context.Context, pollerID string, metric *models.TimeseriesMetric) error {
	log.Printf("Storing single metric: PollerID=%s, Name=%s, TargetIP=%s, IfIndex=%d",
		pollerID, metric.Name, metric.TargetDeviceIP, metric.IfIndex)

	// Validate metadata as a JSON string
	metadataStr := metric.Metadata
	if metadataStr != "" {
		// Ensure metadata is valid JSON
		var temp interface{}
		if err := json.Unmarshal([]byte(metadataStr), &temp); err != nil {
			log.Printf("Invalid JSON metadata for metric %s: %v", metric.Name, err)
			return fmt.Errorf("invalid JSON metadata: %w", err)
		}
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO timeseries_metrics (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	err = batch.Append(
		pollerID,
		metric.TargetDeviceIP,
		metric.IfIndex,
		metric.Name,
		metric.Type,
		metric.Value,
		metadataStr, // Use metadata string directly
		metric.Timestamp,
	)
	if err != nil {
		log.Printf("Failed to append single metric %s (poller: %s, target: %s) to batch: %v. Metadata: %s",
			metric.Name, pollerID, metric.TargetDeviceIP, err, metadataStr)
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
		// Use metadata directly as a string
		metadataStr := metric.Metadata

		// Validate metadata as JSON if non-empty
		if metadataStr != "" {
			var temp interface{}

			if err = json.Unmarshal([]byte(metadataStr), &temp); err != nil {
				log.Printf("Invalid JSON metadata for metric %s (poller: %s, target: %s): %v",
					metric.Name, pollerID, metric.TargetDeviceIP, err)
				continue
			}
		}

		err = batch.Append(
			pollerID,
			metric.TargetDeviceIP,
			metric.IfIndex,
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

// StoreMetrics stores multiple timeseries metrics in a single batch.
func (db *DB) StoreMetrics(ctx context.Context, pollerID string, metrics []*models.TimeseriesMetric) error {
	if len(metrics) == 0 {
		return nil
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO timeseries_metrics (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	for _, metric := range metrics {
		// Use metadata directly as a string
		metadataStr := metric.Metadata

		// Validate metadata as JSON if non-empty
		if metadataStr != "" {
			var temp interface{}

			if err = json.Unmarshal([]byte(metadataStr), &temp); err != nil {
				log.Printf("Invalid JSON metadata for metric %s (poller: %s, target: %s): %v",
					metric.Name, pollerID, metric.TargetDeviceIP, err)
				continue
			}
		}

		err = batch.Append(
			pollerID,
			metric.TargetDeviceIP,
			metric.IfIndex,
			metric.Name,
			metric.Type,
			metric.Value,
			metadataStr,
			metric.Timestamp,
		)
		if err != nil {
			log.Printf("Failed to append metric %s (poller: %s, target: %s) to batch: %v. Metadata: %s",
				metric.Name, pollerID, metric.TargetDeviceIP, err, metadataStr)
			return fmt.Errorf("failed to append metric %s to batch: %w", metric.Name, err)
		}
	}

	if err := batch.Send(); err != nil {
		return fmt.Errorf("failed to store metrics batch: %w", err)
	}

	return nil
}

// StoreSysmonMetrics stores sysmon metrics for CPU, disk, and memory.
func (db *DB) StoreSysmonMetrics(
	ctx context.Context, pollerID, agentID, hostID string, metrics *models.SysmonMetrics, timestamp time.Time) error {
	if err := db.storeCPUMetrics(ctx, pollerID, agentID, hostID, metrics.CPUs, timestamp); err != nil {
		return fmt.Errorf("failed to store CPU metrics: %w", err)
	}

	if err := db.storeDiskMetrics(ctx, pollerID, agentID, hostID, metrics.Disks, timestamp); err != nil {
		return fmt.Errorf("failed to store disk metrics: %w", err)
	}

	if err := db.storeMemoryMetrics(ctx, pollerID, agentID, hostID, metrics.Memory, timestamp); err != nil {
		return fmt.Errorf("failed to store memory metrics: %w", err)
	}

	return nil
}

// storeCPUMetrics stores CPU metrics in a batch.
func (db *DB) storeCPUMetrics(ctx context.Context, pollerID, agentID, hostID string, cpus []models.CPUMetric, timestamp time.Time) error {
	if len(cpus) == 0 {
		return nil
	}

	return db.executeBatch(ctx, "INSERT INTO cpu_metrics (* except _tp_time)", func(batch driver.Batch) error {
		for _, cpu := range cpus {
			if err := batch.Append(pollerID, agentID, hostID, timestamp, cpu.CoreID, cpu.UsagePercent); err != nil {
				log.Printf("Failed to append CPU metric for core %d: %v", cpu.CoreID, err)
				continue
			}
		}

		return nil
	})
}

// storeDiskMetrics stores disk metrics in a batch.
func (db *DB) storeDiskMetrics(ctx context.Context, pollerID, agentID, hostID string, disks []models.DiskMetric, timestamp time.Time) error {
	if len(disks) == 0 {
		return nil
	}

	return db.executeBatch(ctx, "INSERT INTO disk_metrics (* except _tp_time)", func(batch driver.Batch) error {
		for _, disk := range disks {
			if err := batch.Append(pollerID, agentID, hostID, timestamp, disk.MountPoint, disk.UsedBytes, disk.TotalBytes); err != nil {
				log.Printf("Failed to append disk metric for %s: %v", disk.MountPoint, err)
				continue
			}
		}

		return nil
	})
}

// storeMemoryMetrics stores memory metrics in a batch.
func (db *DB) storeMemoryMetrics(ctx context.Context, pollerID, agentID, hostID string, memory models.MemoryMetric, timestamp time.Time) error {
	if memory.UsedBytes == 0 && memory.TotalBytes == 0 {
		return nil
	}

	return db.executeBatch(ctx, "INSERT INTO memory_metrics (* except _tp_time)", func(batch driver.Batch) error {
		return batch.Append(pollerID, agentID, hostID, timestamp, memory.UsedBytes, memory.TotalBytes)
	})
}

// GetAllCPUMetrics retrieves all CPU metrics for a poller within a time range, grouped by timestamp.
func (db *DB) GetAllCPUMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonCPUResponse, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, agent_id, host_id, core_id, usage_percent
		FROM table(cpu_metrics)
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, core_id ASC`,
		pollerID, start, end)
	if err != nil {
		log.Printf("Error querying all CPU metrics: %v", err)

		return nil, fmt.Errorf("failed to query all CPU metrics: %w", err)
	}
	defer CloseRows(rows)

	data := make(map[time.Time][]models.CPUMetric)

	for rows.Next() {
		var m models.CPUMetric
		var agentID, hostID string
		var timestamp time.Time

		if err := rows.Scan(&timestamp, &agentID, &hostID, &m.CoreID, &m.UsagePercent); err != nil {
			log.Printf("Error scanning CPU metric row: %v", err)
			continue
		}

		m.Timestamp = timestamp
		m.AgentID = agentID
		m.HostID = hostID
		data[timestamp] = append(data[timestamp], m)
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating CPU metrics rows: %v", err)

		return nil, err
	}

	result := make([]models.SysmonCPUResponse, 0, len(data))

	for ts, cpus := range data {
		result = append(result, models.SysmonCPUResponse{
			Cpus:      cpus,
			Timestamp: ts,
		})
	}

	// Sort by timestamp descending
	sort.Slice(result, func(i, j int) bool {
		return result[i].Timestamp.After(result[j].Timestamp)
	})

	return result, nil
}

// GetAllDiskMetrics retrieves all disk metrics for a poller.
func (db *DB) GetAllDiskMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.DiskMetric, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT mount_point, used_bytes, total_bytes, timestamp, agent_id, host_id
		FROM table(disk_metrics)
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, mount_point ASC`,
		pollerID, start, end)
	if err != nil {
		log.Printf("Error querying all disk metrics: %v", err)

		return nil, fmt.Errorf("failed to query all disk metrics: %w", err)
	}
	defer CloseRows(rows)

	var metrics []models.DiskMetric

	for rows.Next() {
		var m models.DiskMetric

		if err = rows.Scan(&m.MountPoint, &m.UsedBytes, &m.TotalBytes, &m.Timestamp, &m.AgentID, &m.HostID); err != nil {
			log.Printf("Error scanning disk metric row: %v", err)

			continue
		}

		metrics = append(metrics, m)
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating disk metrics rows: %v", err)

		return metrics, err
	}

	return metrics, nil
}

// GetDiskMetrics retrieves disk metrics for a specific mount point.
func (db *DB) GetDiskMetrics(ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, mount_point, used_bytes, total_bytes, agent_id, host_id
		FROM table(disk_metrics)
		WHERE poller_id = $1 AND mount_point = $2 AND timestamp BETWEEN $3 AND $4
		ORDER BY timestamp`,
		pollerID, mountPoint, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query disk metrics: %w", err)
	}
	defer CloseRows(rows)

	var metrics []models.DiskMetric

	for rows.Next() {
		var m models.DiskMetric

		if err = rows.Scan(&m.Timestamp, &m.MountPoint, &m.UsedBytes, &m.TotalBytes, &m.AgentID, &m.HostID); err != nil {
			log.Printf("Error scanning disk metric row: %v", err)
			continue
		}

		metrics = append(metrics, m)
	}

	return metrics, nil
}

// GetMemoryMetrics retrieves memory metrics.
func (db *DB) GetMemoryMetrics(ctx context.Context, pollerID string, start, end time.Time) ([]models.MemoryMetric, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, used_bytes, total_bytes, agent_id, host_id
		FROM table(memory_metrics)
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp`,
		pollerID, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query memory metrics: %w", err)
	}
	defer CloseRows(rows)

	var metrics []models.MemoryMetric

	for rows.Next() {
		var m models.MemoryMetric

		if err = rows.Scan(&m.Timestamp, &m.UsedBytes, &m.TotalBytes, &m.AgentID, &m.HostID); err != nil {
			log.Printf("Error scanning memory metric row: %v", err)

			continue
		}

		metrics = append(metrics, m)
	}

	return metrics, nil
}

// GetAllDiskMetricsGrouped retrieves disk metrics grouped by timestamp.
func (db *DB) GetAllDiskMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonDiskResponse, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, mount_point, used_bytes, total_bytes, agent_id, host_id
		FROM table(disk_metrics)
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, mount_point ASC`,
		pollerID, start, end)
	if err != nil {
		log.Printf("Error querying all disk metrics: %s", err)

		return nil, fmt.Errorf("failed to query all disk metrics: %w", err)
	}
	defer CloseRows(rows)

	data := make(map[time.Time][]models.DiskMetric)

	for rows.Next() {
		var m models.DiskMetric
		var timestamp time.Time

		if err = rows.Scan(&timestamp, &m.MountPoint, &m.UsedBytes, &m.TotalBytes, &m.AgentID, &m.HostID); err != nil {
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

	result := make([]models.SysmonDiskResponse, 0, len(data))

	for ts, disks := range data {
		result = append(result, models.SysmonDiskResponse{
			Disks:     disks,
			Timestamp: ts,
		})
	}

	// Sort by timestamp descending
	sort.Slice(result, func(i, j int) bool {
		return result[i].Timestamp.After(result[j].Timestamp)
	})

	return result, nil
}

// GetMemoryMetricsGrouped retrieves memory metrics grouped by timestamp.
func (db *DB) GetMemoryMetricsGrouped(ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonMemoryResponse, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, used_bytes, total_bytes, agent_id, host_id
		FROM table(memory_metrics)
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC`,
		pollerID, start, end)
	if err != nil {
		log.Printf("Error querying memory metrics: %v", err)

		return nil, fmt.Errorf("failed to query memory metrics: %w", err)
	}
	defer CloseRows(rows)

	var result []models.SysmonMemoryResponse

	for rows.Next() {
		var m models.MemoryMetric
		var timestamp time.Time

		if err = rows.Scan(&timestamp, &m.UsedBytes, &m.TotalBytes, &m.AgentID, &m.HostID); err != nil {
			log.Printf("Error scanning memory metric row: %v", err)

			continue
		}

		m.Timestamp = timestamp
		result = append(result, models.SysmonMemoryResponse{
			Memory:    m,
			Timestamp: timestamp,
		})
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating memory metrics rows: %v", err)

		return nil, err
	}

	return result, nil
}
