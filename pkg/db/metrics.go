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
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/timeplus-io/proton-go-driver/v2/lib/driver"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	rperfBitsPerSecondDivisor = 1e6 // To convert bps to Mbps
)

// convertValueToFloat64 converts a string value to float64, logging errors but not failing the operation
func convertValueToFloat64(value, _ string) float64 {
	if value == "" {
		return 0.0
	}

	floatVal, err := strconv.ParseFloat(value, 64)
	if err != nil {
		// Failed to convert metric value to float64, using 0.0 as fallback
		return 0.0
	}

	return floatVal
}

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
        SELECT metric_name, metric_type, value, metadata, timestamp, target_device_ip, ifIndex, device_id, partition 
        FROM table(timeseries_metrics)
        WHERE poller_id = $1
        AND %s = $2
        AND timestamp BETWEEN $3 AND $4`, filterColumn)

	rows, err := db.Conn.Query(ctx, query, pollerID, filterValue, start, end)
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = rows.Close() // Ignore close error in defer
	}()

	var metrics []models.TimeseriesMetric

	for rows.Next() {
		var metric models.TimeseriesMetric

		// Scan metadata as string and value as float64
		var metadataStr string

		var valueFloat float64

		err := rows.Scan(
			&metric.Name,
			&metric.Type,
			&valueFloat,  // Scan as float64 from database
			&metadataStr, // Scan as string from database
			&metric.Timestamp,
			&metric.TargetDeviceIP,
			&metric.IfIndex,
			&metric.DeviceID,
			&metric.Partition,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan metric row: %w", err)
		}

		// Convert float64 value back to string for the model
		metric.Value = fmt.Sprintf("%g", valueFloat)

		// Assign the scanned metadata string directly
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
			errorMsg := ""
			if result.Error != nil {
				errorMsg = *result.Error
			}

			db.logger.Warn().
				Str("target", result.Target).
				Str("poller_id", pollerID).
				Str("error", errorMsg).
				Msg("Skipping metrics storage for failed rperf test")

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
			db.logger.Error().Err(err).Str("poller_id", pollerID).Str("target", result.Target).Msg("Failed to marshal rperf result metadata")
			continue
		}

		metadataStr := string(metadataBytes)

		for _, m := range metricsToStore {
			err = batch.Append(
				timestamp,                              // timestamp
				pollerID,                               // poller_id
				"",                                     // agent_id
				m.Name,                                 // metric_name
				"rperf",                                // metric_type
				"",                                     // device_id (to be populated later)
				convertValueToFloat64(m.Value, m.Name), // value (converted to float64)
				"",                                     // unit
				map[string]string{},                    // tags
				"",                                     // partition (to be populated later)
				1.0,                                    // scale
				false,                                  // is_delta
				result.Target,                          // target_device_ip
				int32(0),                               // ifIndex (not applicable for rperf)
				metadataStr,                            // metadata
			)
			if err != nil {
				db.logger.Error().Err(err).Str("metric_name", m.Name).Str("poller_id", pollerID).Msg("Failed to append rperf metric")
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
		db.logger.Error().Err(err).Str("poller_id", pollerID).Msg("Failed to unmarshal outer rperf wrapper")
		return fmt.Errorf("failed to unmarshal rperf wrapper message: %w", err)
	}

	if wrapper.Status == "" {
		db.logger.Warn().Str("poller_id", pollerID).Msg("No nested status found in rperf message")
		return nil
	}

	var rperfData struct {
		Results   []models.RperfMetric `json:"results"`
		Timestamp string               `json:"timestamp"`
	}

	if err := json.Unmarshal([]byte(wrapper.Status), &rperfData); err != nil {
		db.logger.Error().Err(err).Str("poller_id", pollerID).Msg("Failed to unmarshal nested rperf data")
		return fmt.Errorf("failed to unmarshal nested rperf data: %w", err)
	}

	if len(rperfData.Results) == 0 {
		db.logger.Warn().Str("poller_id", pollerID).Msg("No rperf results found")
		return nil
	}

	storedCount, err := db.storeRperfMetricsToBatch(ctx, pollerID, rperfData.Results, timestamp)
	if err != nil {
		return fmt.Errorf("failed to store rperf metrics: %w", err)
	}

	db.logger.Info().Int("stored_count", storedCount).Str("poller_id", pollerID).Msg("Stored rperf metrics")

	return nil
}

// StoreRperfMetricsBatch stores multiple rperf metrics in a single batch operation.
func (db *DB) StoreRperfMetricsBatch(
	ctx context.Context, pollerID string, metrics []*models.RperfMetric, timestamp time.Time) error {
	if len(metrics) == 0 {
		db.logger.Debug().Str("poller_id", pollerID).Msg("No rperf metrics to store")
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
		db.logger.Debug().Str("poller_id", pollerID).Msg("No valid rperf metrics to send")
		return nil
	}

	db.logger.Info().Int("stored_count", storedCount).Str("poller_id", pollerID).Msg("Stored rperf metrics batch")

	return nil
}

// GetMetrics retrieves metrics for a specific poller and metric name.
func (db *DB) GetMetrics(
	ctx context.Context, pollerID, metricName string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	metrics, err := db.queryTimeseriesMetrics(ctx, pollerID, metricName, "metric_name", start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics: %w", err)
	}

	return metrics, nil
}

// GetMetricsByType retrieves metrics for a specific poller and metric type.
func (db *DB) GetMetricsByType(
	ctx context.Context, pollerID, metricType string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	metrics, err := db.queryTimeseriesMetrics(ctx, pollerID, metricType, "metric_type", start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics by type: %w", err)
	}

	return metrics, nil
}

// GetCPUMetrics retrieves CPU metrics for a specific core.
func (db *DB) GetCPUMetrics(
	ctx context.Context, pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, agent_id, host_id, core_id, usage_percent
		FROM table(cpu_metrics)
		WHERE poller_id = $1 AND core_id = $2 AND timestamp BETWEEN $3 AND $4
		ORDER BY timestamp`,
		pollerID, coreID, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query CPU metrics: %w", err)
	}
	defer func() {
		_ = rows.Close() // Ignore close error in defer
	}()

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
	db.logger.Debug().
		Str("poller_id", pollerID).
		Str("metric_name", metric.Name).
		Str("target_ip", metric.TargetDeviceIP).
		Int("if_index", int(metric.IfIndex)).
		Msg("Storing single metric")

	// Validate metadata as a JSON string
	metadataStr := metric.Metadata
	if metadataStr != "" {
		// Ensure metadata is valid JSON
		var temp interface{}
		if err := json.Unmarshal([]byte(metadataStr), &temp); err != nil {
			db.logger.Error().Err(err).Str("metric_name", metric.Name).Msg("Invalid JSON metadata for metric")
			return fmt.Errorf("invalid JSON metadata: %w", err)
		}
	}

	batch, err := db.Conn.PrepareBatch(ctx, "INSERT INTO timeseries_metrics (* except _tp_time)")
	if err != nil {
		return fmt.Errorf("failed to prepare batch: %w", err)
	}

	err = batch.Append(
		metric.Timestamp, // timestamp
		pollerID,         // poller_id
		"",               // agent_id
		metric.Name,      // metric_name
		metric.Type,      // metric_type
		metric.DeviceID,  // device_id
		convertValueToFloat64(metric.Value, metric.Name), // value (converted to float64)
		"",                    // unit
		map[string]string{},   // tags
		metric.Partition,      // partition
		1.0,                   // scale
		false,                 // is_delta
		metric.TargetDeviceIP, // target_device_ip
		metric.IfIndex,        // ifIndex
		metadataStr,           // metadata
	)
	if err != nil {
		db.logger.Error().
			Err(err).
			Str("metric_name", metric.Name).
			Str("poller_id", pollerID).
			Str("target_ip", metric.TargetDeviceIP).
			Str("metadata", metadataStr).
			Msg("Failed to append single metric to batch")

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
				db.logger.Error().
					Err(err).
					Str("metric_name", metric.Name).
					Str("poller_id", pollerID).
					Str("target_ip", metric.TargetDeviceIP).
					Msg("Invalid JSON metadata for metric")

				continue
			}
		}

		err = batch.Append(
			metric.Timestamp, // timestamp
			pollerID,         // poller_id
			"",               // agent_id
			metric.Name,      // metric_name
			metric.Type,      // metric_type
			metric.DeviceID,  // device_id
			convertValueToFloat64(metric.Value, metric.Name), // value (converted to float64)
			"",                    // unit
			map[string]string{},   // tags
			metric.Partition,      // partition
			1.0,                   // scale
			false,                 // is_delta
			metric.TargetDeviceIP, // target_device_ip
			metric.IfIndex,        // ifIndex
			metadataStr,           // metadata
		)
		if err != nil {
			db.logger.Error().Err(err).Str("metric_name", metric.Name).Msg("Failed to append metric to batch")
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
				db.logger.Error().
					Err(err).
					Str("metric_name", metric.Name).
					Str("poller_id", pollerID).
					Str("target_ip", metric.TargetDeviceIP).
					Msg("Invalid JSON metadata for metric")

				continue
			}
		}

		err = batch.Append(
			metric.Timestamp, // timestamp
			pollerID,         // poller_id
			"",               // agent_id
			metric.Name,      // metric_name
			metric.Type,      // metric_type
			metric.DeviceID,  // device_id
			convertValueToFloat64(metric.Value, metric.Name), // value (converted to float64)
			"",                    // unit
			map[string]string{},   // tags
			metric.Partition,      // partition
			1.0,                   // scale
			false,                 // is_delta
			metric.TargetDeviceIP, // target_device_ip
			metric.IfIndex,        // ifIndex
			metadataStr,           // metadata
		)
		if err != nil {
			db.logger.Error().
				Err(err).
				Str("metric_name", metric.Name).
				Str("poller_id", pollerID).
				Str("target_ip", metric.TargetDeviceIP).
				Str("metadata", metadataStr).
				Msg("Failed to append metric to batch")

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
	ctx context.Context,
	pollerID, agentID, hostID, partition, hostIP string,
	metrics *models.SysmonMetrics,
	timestamp time.Time) error {
	deviceID := fmt.Sprintf("%s:%s", partition, hostIP)
	if err := db.storeCPUMetrics(ctx, pollerID, agentID, hostID, deviceID,
		partition, metrics.CPUs, timestamp); err != nil {
		return fmt.Errorf("failed to store CPU metrics: %w", err)
	}

	if err := db.storeDiskMetrics(ctx, pollerID, agentID, hostID, deviceID,
		partition, metrics.Disks, timestamp); err != nil {
		return fmt.Errorf("failed to store disk metrics: %w", err)
	}

	if err := db.storeMemoryMetrics(ctx, pollerID, agentID, hostID, deviceID,
		partition, metrics.Memory, timestamp); err != nil {
		return fmt.Errorf("failed to store memory metrics: %w", err)
	}

	if err := db.storeProcessMetrics(ctx, pollerID, agentID, hostID, deviceID,
		partition, metrics.Processes, timestamp); err != nil {
		return fmt.Errorf("failed to store process metrics: %w", err)
	}

	return nil
}

// storeCPUMetrics stores CPU metrics in a batch.
func (db *DB) storeCPUMetrics(
	ctx context.Context,
	pollerID, agentID, hostID, deviceID, partition string,
	cpus []models.CPUMetric,
	timestamp time.Time) error {
	if len(cpus) == 0 {
		return nil
	}

	return db.executeBatch(ctx, "INSERT INTO cpu_metrics (* except _tp_time)", func(batch driver.Batch) error {
		for _, cpu := range cpus {
			if err := batch.Append(timestamp, pollerID, agentID, hostID,
				cpu.CoreID, cpu.UsagePercent, deviceID, partition); err != nil {
				db.logger.Error().Err(err).Int("core_id", int(cpu.CoreID)).Msg("Failed to append CPU metric")
				continue
			}
		}

		return nil
	})
}

// storeDiskMetrics stores disk metrics in a batch.
func (db *DB) storeDiskMetrics(
	ctx context.Context,
	pollerID, agentID, hostID, deviceID, partition string,
	disks []models.DiskMetric,
	timestamp time.Time) error {
	if len(disks) == 0 {
		return nil
	}

	return db.executeBatch(ctx, "INSERT INTO disk_metrics (* except _tp_time)", func(batch driver.Batch) error {
		for _, disk := range disks {
			// Calculate missing fields for the 12-column schema
			availableBytes := uint64(0)
			if disk.TotalBytes > disk.UsedBytes {
				availableBytes = disk.TotalBytes - disk.UsedBytes
			}

			usagePercent := 0.0
			if disk.TotalBytes > 0 {
				usagePercent = (float64(disk.UsedBytes) / float64(disk.TotalBytes)) * 100.0
			}

			deviceName := disk.MountPoint // Use mount point as device name if not available

			if err := batch.Append(
				timestamp,       // timestamp
				pollerID,        // poller_id
				agentID,         // agent_id
				hostID,          // host_id
				disk.MountPoint, // mount_point
				deviceName,      // device_name
				disk.TotalBytes, // total_bytes
				disk.UsedBytes,  // used_bytes
				availableBytes,  // available_bytes
				usagePercent,    // usage_percent
				deviceID,        // device_id
				partition,       // partition
			); err != nil {
				db.logger.Error().Err(err).Str("mount_point", disk.MountPoint).Msg("Failed to append disk metric")
				continue
			}
		}

		return nil
	})
}

// storeMemoryMetrics stores memory metrics in a batch.
func (db *DB) storeMemoryMetrics(
	ctx context.Context,
	pollerID, agentID, hostID, deviceID, partition string,
	memory *models.MemoryMetric,
	timestamp time.Time) error {
	if memory.UsedBytes == 0 && memory.TotalBytes == 0 {
		return nil
	}

	return db.executeBatch(ctx, "INSERT INTO memory_metrics (* except _tp_time)", func(batch driver.Batch) error {
		// Calculate missing fields for the memory_metrics schema
		availableBytes := uint64(0)
		if memory.TotalBytes > memory.UsedBytes {
			availableBytes = memory.TotalBytes - memory.UsedBytes
		}

		usagePercent := 0.0
		if memory.TotalBytes > 0 {
			usagePercent = (float64(memory.UsedBytes) / float64(memory.TotalBytes)) * 100.0
		}

		return batch.Append(
			timestamp,         // timestamp
			pollerID,          // poller_id
			agentID,           // agent_id
			hostID,            // host_id
			memory.TotalBytes, // total_bytes
			memory.UsedBytes,  // used_bytes
			availableBytes,    // available_bytes
			usagePercent,      // usage_percent
			deviceID,          // device_id
			partition,         // partition
		)
	})
}

// storeProcessMetrics stores process metrics in a batch.
func (db *DB) storeProcessMetrics(
	ctx context.Context,
	pollerID, agentID, hostID, deviceID, partition string,
	processes []models.ProcessMetric,
	timestamp time.Time) error {
	if len(processes) == 0 {
		return nil
	}

	return db.executeBatch(ctx, "INSERT INTO process_metrics (* except _tp_time)", func(batch driver.Batch) error {
		for i := range processes {
			process := &processes[i]
			if err := batch.Append(
				timestamp,           // timestamp
				pollerID,            // poller_id
				agentID,             // agent_id
				hostID,              // host_id
				process.PID,         // pid
				process.Name,        // name
				process.CPUUsage,    // cpu_usage
				process.MemoryUsage, // memory_usage
				process.Status,      // status
				process.StartTime,   // start_time
				deviceID,            // device_id
				partition,           // partition
			); err != nil {
				db.logger.Error().Err(err).Int("pid", int(process.PID)).Str("process_name", process.Name).Msg("Failed to append process metric")
				continue
			}
		}

		return nil
	})
}

// GetAllCPUMetrics retrieves all CPU metrics for a poller within a time range, grouped by timestamp.
func (db *DB) GetAllCPUMetrics(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonCPUResponse, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, agent_id, host_id, core_id, usage_percent
		FROM table(cpu_metrics)
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, core_id ASC`,
		pollerID, start, end)
	if err != nil {
		db.logger.Error().Err(err).Msg("Error querying all CPU metrics")

		return nil, fmt.Errorf("failed to query all CPU metrics: %w", err)
	}
	defer db.CloseRows(rows)

	data := make(map[time.Time][]models.CPUMetric)

	for rows.Next() {
		var m models.CPUMetric

		var agentID, hostID string

		var timestamp time.Time

		if err := rows.Scan(&timestamp, &agentID, &hostID, &m.CoreID, &m.UsagePercent); err != nil {
			db.logger.Error().Err(err).Msg("Error scanning CPU metric row")
			continue
		}

		m.Timestamp = timestamp
		m.AgentID = agentID
		m.HostID = hostID
		data[timestamp] = append(data[timestamp], m)
	}

	if err := rows.Err(); err != nil {
		db.logger.Error().Err(err).Msg("Error iterating CPU metrics rows")

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
func (db *DB) GetAllDiskMetrics(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.DiskMetric, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT mount_point, used_bytes, total_bytes, timestamp, agent_id, host_id
		FROM table(disk_metrics)
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, mount_point ASC`,
		pollerID, start, end)
	if err != nil {
		db.logger.Error().Err(err).Msg("Error querying all disk metrics")

		return nil, fmt.Errorf("failed to query all disk metrics: %w", err)
	}
	defer db.CloseRows(rows)

	var metrics []models.DiskMetric

	for rows.Next() {
		var m models.DiskMetric

		if err = rows.Scan(&m.MountPoint, &m.UsedBytes, &m.TotalBytes, &m.Timestamp, &m.AgentID, &m.HostID); err != nil {
			db.logger.Error().Err(err).Msg("Error scanning disk metric row")

			continue
		}

		metrics = append(metrics, m)
	}

	if err := rows.Err(); err != nil {
		db.logger.Error().Err(err).Msg("Error iterating disk metrics rows")

		return metrics, err
	}

	return metrics, nil
}

// GetDiskMetrics retrieves disk metrics for a specific mount point.
func (db *DB) GetDiskMetrics(
	ctx context.Context, pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, mount_point, used_bytes, total_bytes, agent_id, host_id
		FROM table(disk_metrics)
		WHERE poller_id = $1 AND mount_point = $2 AND timestamp BETWEEN $3 AND $4
		ORDER BY timestamp`,
		pollerID, mountPoint, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query disk metrics: %w", err)
	}
	defer db.CloseRows(rows)

	var metrics []models.DiskMetric

	for rows.Next() {
		var m models.DiskMetric

		if err = rows.Scan(&m.Timestamp, &m.MountPoint, &m.UsedBytes, &m.TotalBytes, &m.AgentID, &m.HostID); err != nil {
			db.logger.Error().Err(err).Msg("Error scanning disk metric row")
			continue
		}

		metrics = append(metrics, m)
	}

	return metrics, nil
}

// GetMemoryMetrics retrieves memory metrics.
func (db *DB) GetMemoryMetrics(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.MemoryMetric, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, used_bytes, total_bytes, agent_id, host_id
		FROM table(memory_metrics)
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp`,
		pollerID, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query memory metrics: %w", err)
	}
	defer db.CloseRows(rows)

	var metrics []models.MemoryMetric

	for rows.Next() {
		var m models.MemoryMetric

		if err = rows.Scan(&m.Timestamp, &m.UsedBytes, &m.TotalBytes, &m.AgentID, &m.HostID); err != nil {
			db.logger.Error().Err(err).Msg("Error scanning memory metric row")

			continue
		}

		metrics = append(metrics, m)
	}

	return metrics, nil
}

// GetAllDiskMetricsGrouped retrieves disk metrics grouped by timestamp.
func (db *DB) GetAllDiskMetricsGrouped(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonDiskResponse, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, mount_point, used_bytes, total_bytes, agent_id, host_id
		FROM table(disk_metrics)
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, mount_point ASC`,
		pollerID, start, end)
	if err != nil {
		db.logger.Error().Err(err).Msg("Error querying all disk metrics")

		return nil, fmt.Errorf("failed to query all disk metrics: %w", err)
	}
	defer db.CloseRows(rows)

	data := make(map[time.Time][]models.DiskMetric)

	for rows.Next() {
		var m models.DiskMetric

		var timestamp time.Time

		if err = rows.Scan(&timestamp, &m.MountPoint, &m.UsedBytes, &m.TotalBytes, &m.AgentID, &m.HostID); err != nil {
			db.logger.Error().Err(err).Msg("Error scanning disk metric row")

			continue
		}

		m.Timestamp = timestamp
		data[timestamp] = append(data[timestamp], m)
	}

	if err := rows.Err(); err != nil {
		db.logger.Error().Err(err).Msg("Error iterating disk metrics rows")

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
func (db *DB) GetMemoryMetricsGrouped(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonMemoryResponse, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, used_bytes, total_bytes, agent_id, host_id
		FROM table(memory_metrics)
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC`,
		pollerID, start, end)
	if err != nil {
		db.logger.Error().Err(err).Msg("Error querying memory metrics")

		return nil, fmt.Errorf("failed to query memory metrics: %w", err)
	}
	defer db.CloseRows(rows)

	var result []models.SysmonMemoryResponse

	for rows.Next() {
		var m models.MemoryMetric

		var timestamp time.Time

		if err = rows.Scan(&timestamp, &m.UsedBytes, &m.TotalBytes, &m.AgentID, &m.HostID); err != nil {
			db.logger.Error().Err(err).Msg("Error scanning memory metric row")

			continue
		}

		m.Timestamp = timestamp
		result = append(result, models.SysmonMemoryResponse{
			Memory:    m,
			Timestamp: timestamp,
		})
	}

	if err := rows.Err(); err != nil {
		db.logger.Error().Err(err).Msg("Error iterating memory metrics rows")

		return nil, err
	}

	return result, nil
}

// GetMetricsForDevice retrieves all metrics for a specific device within a time range.
func (db *DB) GetMetricsForDevice(
	ctx context.Context, deviceID string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	return db.getTimeseriesMetricsByFilter(ctx, "device_id", deviceID, start, end)
}

// GetMetricsForDeviceByType retrieves metrics for a specific device filtered by metric type.
func (db *DB) GetMetricsForDeviceByType(
	ctx context.Context, deviceID, metricType string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	filters := map[string]string{
		"device_id":   deviceID,
		"metric_type": metricType,
	}

	return db.getTimeseriesMetricsByFilters(ctx, filters, start, end)
}

// GetMetricsForPartition retrieves all metrics for devices within a specific partition.
func (db *DB) GetMetricsForPartition(
	ctx context.Context, partition string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	return db.getTimeseriesMetricsByFilter(ctx, "partition", partition, start, end)
}

// getTimeseriesMetricsByFilter is a helper function to query timeseries metrics by a single filter criteria
func (db *DB) getTimeseriesMetricsByFilter(
	ctx context.Context, filterField, filterValue string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	filters := map[string]string{filterField: filterValue}
	return db.getTimeseriesMetricsByFilters(ctx, filters, start, end)
}

// getTimeseriesMetricsByFilters is a helper function to query timeseries metrics by multiple filter criteria
func (db *DB) getTimeseriesMetricsByFilters(
	ctx context.Context, filters map[string]string, start, end time.Time) ([]models.TimeseriesMetric, error) {
	// pre-allocate with expected size
	whereConditions := make([]string, 0, len(filters)+2) // +2 for timestamp conditions

	for field, value := range filters {
		whereConditions = append(whereConditions, fmt.Sprintf("%s = '%s'", field, value))
	}

	whereClause := strings.Join(whereConditions, " AND ")

	query := fmt.Sprintf(`
        SELECT metric_name, metric_type, value, metadata, timestamp, target_device_ip, 
		ifIndex, device_id, partition, poller_id
        FROM table(timeseries_metrics)
        WHERE %s AND timestamp BETWEEN '%s' AND '%s'
        ORDER BY timestamp DESC`,
		whereClause, start.Format(time.RFC3339), end.Format(time.RFC3339))

	rows, err := db.Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics with filters %v: %w", filters, err)
	}
	defer func() {
		_ = rows.Close() // Ignore close error in defer
	}()

	var metrics []models.TimeseriesMetric

	for rows.Next() {
		var m models.TimeseriesMetric

		var valueFloat float64

		var metadataStr string

		if err := rows.Scan(
			&m.Name,
			&m.Type,
			&valueFloat,  // Scan as float64 from database
			&metadataStr, // Scan as string from database
			&m.Timestamp,
			&m.TargetDeviceIP,
			&m.IfIndex,
			&m.DeviceID,
			&m.Partition,
			&m.PollerID,
		); err != nil {
			return nil, fmt.Errorf("failed to scan metric with filters %v: %w", filters, err)
		}

		// Convert float64 value back to string for the model
		m.Value = fmt.Sprintf("%g", valueFloat)

		// Assign the scanned metadata string directly
		m.Metadata = metadataStr

		metrics = append(metrics, m)
	}

	return metrics, nil
}

// GetAllProcessMetrics retrieves all process metrics for a poller within a time range.
func (db *DB) GetAllProcessMetrics(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.ProcessMetric, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, agent_id, host_id, pid, name, cpu_usage, memory_usage, status, start_time
		FROM table(process_metrics)
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, pid ASC`,
		pollerID, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query process metrics: %w", err)
	}
	defer db.CloseRows(rows)

	var metrics []models.ProcessMetric

	for rows.Next() {
		var m models.ProcessMetric

		if err = rows.Scan(&m.Timestamp, &m.AgentID, &m.HostID, &m.PID, &m.Name,
			&m.CPUUsage, &m.MemoryUsage, &m.Status, &m.StartTime); err != nil {
			db.logger.Error().Err(err).Msg("Error scanning process metric row")

			continue
		}

		metrics = append(metrics, m)
	}

	return metrics, nil
}

// GetAllProcessMetricsGrouped retrieves process metrics grouped by timestamp.
func (db *DB) GetAllProcessMetricsGrouped(
	ctx context.Context, pollerID string, start, end time.Time) ([]models.SysmonProcessResponse, error) {
	rows, err := db.Conn.Query(ctx, `
		SELECT timestamp, agent_id, host_id, pid, name, cpu_usage, memory_usage, status, start_time
		FROM table(process_metrics)
		WHERE poller_id = $1 AND timestamp BETWEEN $2 AND $3
		ORDER BY timestamp DESC, pid ASC`,
		pollerID, start, end)
	if err != nil {
		db.logger.Error().Err(err).Msg("Error querying all process metrics")
		return nil, fmt.Errorf("failed to query all process metrics: %w", err)
	}
	defer db.CloseRows(rows)

	data := make(map[time.Time][]models.ProcessMetric)

	for rows.Next() {
		var m models.ProcessMetric

		var timestamp time.Time

		if err = rows.Scan(&timestamp, &m.AgentID, &m.HostID, &m.PID, &m.Name,
			&m.CPUUsage, &m.MemoryUsage, &m.Status, &m.StartTime); err != nil {
			db.logger.Error().Err(err).Msg("Error scanning process metric row")

			continue
		}

		m.Timestamp = timestamp
		data[timestamp] = append(data[timestamp], m)
	}

	if err := rows.Err(); err != nil {
		db.logger.Error().Err(err).Msg("Error iterating process metrics rows")
		return nil, err
	}

	result := make([]models.SysmonProcessResponse, 0, len(data))
	for ts, processes := range data {
		result = append(result, models.SysmonProcessResponse{
			Processes: processes,
			Timestamp: ts,
		})
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].Timestamp.After(result[j].Timestamp)
	})

	return result, nil
}
