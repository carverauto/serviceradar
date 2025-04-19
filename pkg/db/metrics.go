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
	"strconv"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// StoreMetric stores a timeseries metric in the database.
func (db *DB) StoreMetric(pollerID string, metric *TimeseriesMetric) error {
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
            (poller_id, metric_name, metric_type, value, metadata, timestamp)
        VALUES (?, ?, ?, ?, ?, ?)`,
		pollerID,
		metric.Name,
		metric.Type,
		metric.Value,
		metadataJSON,
		metric.Timestamp,
	)

	if err != nil {
		// Use %w for error wrapping
		return fmt.Errorf("failed to store metric %s for poller %s: %w", metric.Name, pollerID, err)
	}

	// Log successful storage *after* the operation succeeds
	log.Printf("Successfully stored metric %s for poller %s", metric.Name, pollerID)

	return nil
}

// GetMetrics retrieves metrics for a specific poller and metric name.
func (db *DB) GetMetrics(pollerID, metricName string, start, end time.Time) ([]TimeseriesMetric, error) {
	rows, err := db.Query(`
        SELECT metric_name, metric_type, value, metadata, timestamp
        FROM timeseries_metrics
        WHERE poller_id = ?
        AND metric_name = ?
        AND timestamp BETWEEN ? AND ?`,
		pollerID,
		metricName,
		start,
		end,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics: %w", err)
	}
	defer CloseRows(rows) // Use the helper function

	return db.scanMetrics(rows)
}

// GetMetricsByType retrieves metrics for a specific poller and metric type.
func (db *DB) GetMetricsByType(pollerID, metricType string, start, end time.Time) ([]TimeseriesMetric, error) {
	rows, err := db.Query(`
        SELECT metric_name, metric_type, value, metadata, timestamp
        FROM timeseries_metrics
        WHERE poller_id = ?
        AND metric_type = ?
        AND timestamp BETWEEN ? AND ?`,
		pollerID,
		metricType,
		start,
		end,
	)
	if err != nil {
		return nil, fmt.Errorf("failed to query metrics by type: %w", err)
	}
	defer CloseRows(rows) // Use the helper function

	return db.scanMetrics(rows)
}

// scanMetrics is a helper function to scan rows into TimeseriesMetric slices.
func (*DB) scanMetrics(rows Rows) ([]TimeseriesMetric, error) {
	var metrics []TimeseriesMetric

	for rows.Next() {
		var metric TimeseriesMetric

		var metadataJSON sql.NullString // Use sql.NullString to handle potential NULLs

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

		// Parse metadata JSON if present and valid
		if metadataJSON.Valid && metadataJSON.String != "" {
			// Use json.RawMessage to preserve the structure for flexibility
			var rawMetadata json.RawMessage
			if err := json.Unmarshal([]byte(metadataJSON.String), &rawMetadata); err != nil {
				// Log the error but don't fail the whole query, maybe just skip metadata
				log.Printf("Warning: failed to unmarshal metadata for metric %s: %v. Raw: %s", metric.Name, err, metadataJSON.String)
			} else {
				metric.Metadata = rawMetadata // Assign the raw JSON
			}
		}

		metrics = append(metrics, metric)
	}

	// Check for errors during row iteration
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating rows: %w", err)
	}

	return metrics, nil
}

const (
	rperfMetricsStored        = 3   // Number of metrics stored per rperf result (bandwidth, jitter, loss)
	rperfBitsPerSecondDivisor = 1e6 // To convert bps to Mbps
)

// rperfWrapper defines the outer structure received from the agent for rperf checks.
type rperfWrapper struct {
	Status       string `json:"status"` // This holds the nested JSON string with actual results
	ResponseTime int64  `json:"response_time"`
	Available    bool   `json:"available"`
}

// StoreRperfMetrics stores rperf-checker data as timeseries metrics.
func (db *DB) StoreRperfMetrics(pollerID, _, message string, timestamp time.Time) error {
	var wrapper rperfWrapper
	if err := json.Unmarshal([]byte(message), &wrapper); err != nil {
		log.Printf("Failed to unmarshal outer rperf wrapper for poller %s: %v", pollerID, err)

		return fmt.Errorf("failed to unmarshal rperf wrapper message: %w", err)
	}

	if wrapper.Status == "" {
		log.Printf("No nested status found in rperf message for poller %s", pollerID)

		return nil
	}

	// 2. Unmarshal the nested JSON string from the 'status' field
	var rperfData struct {
		Results   []RperfMetric `json:"results"`
		Timestamp string        `json:"timestamp"` // Capture the timestamp from the nested data as well if needed
	}

	if err := json.Unmarshal([]byte(wrapper.Status), &rperfData); err != nil {
		log.Printf("Failed to unmarshal nested rperf data ('status' field) for poller %s: %v", pollerID, err)

		return fmt.Errorf("failed to unmarshal nested rperf data: %w", err)
	}

	if len(rperfData.Results) == 0 {
		log.Printf("No rperf results found in nested data for poller %s", pollerID)

		return nil // Not an error, just no results to store
	}

	// 3. Process and store each result as metrics
	storedCount := 0

	for _, result := range rperfData.Results {
		// Skip storing metrics if the test itself reported failure
		if !result.Success {
			log.Printf("Skipping metrics storage for failed rperf test (Target: %s) on poller %s. Error: %v",
				result.Target, pollerID, result.Error)

			continue // Move to the next result
		}

		// --- Prepare metrics ---
		metricsToStore := []struct {
			Name  string
			Value string
		}{
			{
				Name:  fmt.Sprintf("rperf_%s_bandwidth_mbps", result.Target), // Suffix clarifies units
				Value: fmt.Sprintf("%.2f", result.BitsPerSec/rperfBitsPerSecondDivisor),
			},
			{
				Name:  fmt.Sprintf("rperf_%s_jitter_ms", result.Target), // Suffix clarifies units
				Value: fmt.Sprintf("%.2f", result.JitterMs),
			},
			{
				Name:  fmt.Sprintf("rperf_%s_loss_percent", result.Target), // Suffix clarifies units
				Value: fmt.Sprintf("%.1f", result.LossPercent),
			},
		}

		// Marshal the *individual* result as metadata for all related metrics
		// Use json.RawMessage for efficiency if storing as raw JSON
		metadataBytes, err := json.Marshal(result)
		if err != nil {
			// Log error but maybe continue storing other metrics? Or fail the batch?
			log.Printf("ERROR: Failed to marshal rperf result metadata for poller %s, "+
				"target %s: %v. Skipping metrics for this result.", pollerID, result.Target, err)

			continue // Skip this specific result's metrics
		}

		metadata := json.RawMessage(metadataBytes)

		// --- Store each metric ---
		for _, m := range metricsToStore {
			metric := &TimeseriesMetric{
				Name:      m.Name,
				Type:      "rperf", // Consistent type for all rperf metrics
				Value:     m.Value,
				Timestamp: timestamp, // Use the timestamp passed from the core service
				Metadata:  metadata,  // Store the full result as metadata
			}

			if err := db.StoreMetric(pollerID, metric); err != nil {
				// Log the specific error but try to continue with other metrics/results
				// return fmt.Errorf("failed to store rperf metric %s: %w", m.Name, err) // Option: Fail fast
				log.Printf("ERROR: Failed to store rperf metric %s for poller %s: %v", m.Name, pollerID, err)
			} else {
				storedCount++
			}
		}
	}

	log.Printf("Finished processing rperf metrics for poller %s. Stored %d metrics.", pollerID, storedCount)

	return nil
}

func (db *DB) GetCPUMetrics(pollerID string, coreID int, start, end time.Time) ([]models.CPUMetric, error) {
	rows, err := db.Query(`
        SELECT timestamp, core_id, usage_percent
        FROM cpu_metrics
        WHERE poller_id = ? AND core_id = ? AND timestamp BETWEEN ? AND ?
        ORDER BY timestamp`,
		pollerID, coreID, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query CPU metrics: %w", err)
	}
	defer CloseRows(rows)

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

func (db *DB) StoreSysmonMetrics(pollerID string, metrics *models.SysmonMetrics, timestamp time.Time) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("failed to begin transaction: %w", err)
	}
	defer rollbackOnError(tx, err)

	for _, cpu := range metrics.CPUs {
		_, err = tx.Exec(`
            INSERT INTO cpu_metrics (poller_id, timestamp, core_id, usage_percent)
            VALUES (?, ?, ?, ?)`,
			pollerID, timestamp, cpu.CoreID, cpu.UsagePercent)
		if err != nil {
			return fmt.Errorf("failed to store CPU metric for core %d: %w", cpu.CoreID, err)
		}
	}

	for _, disk := range metrics.Disks {
		_, err = tx.Exec(`
            INSERT INTO disk_metrics (poller_id, timestamp, mount_point, used_bytes, total_bytes)
            VALUES (?, ?, ?, ?, ?)`,
			pollerID, timestamp, disk.MountPoint, fmt.Sprintf("%d", disk.UsedBytes), fmt.Sprintf("%d", disk.TotalBytes))
		if err != nil {
			return fmt.Errorf("failed to store disk metric for %s: %w", disk.MountPoint, err)
		}
	}

	_, err = tx.Exec(`
        INSERT INTO memory_metrics (poller_id, timestamp, used_bytes, total_bytes)
        VALUES (?, ?, ?, ?)`,
		pollerID, timestamp, fmt.Sprintf("%d", metrics.Memory.UsedBytes), fmt.Sprintf("%d", metrics.Memory.TotalBytes))
	if err != nil {
		return fmt.Errorf("failed to store memory metric: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("failed to commit transaction: %w", err)
	}

	log.Printf("Stored sysmon metrics for poller %s: %d CPUs, %d disks, 1 memory", pollerID, len(metrics.CPUs), len(metrics.Disks))
	return nil
}

// GetAllMountPoints retrieves all unique mount points for a poller
func (db *DB) GetAllMountPoints(pollerID string) ([]string, error) {
	log.Printf("Querying all mount points for poller %s", pollerID)

	query := `
		SELECT DISTINCT mount_point
		FROM disk_metrics
		WHERE poller_id = ?
		ORDER BY mount_point ASC
	`

	rows, err := db.Query(query, pollerID)
	if err != nil {
		log.Printf("Error querying mount points: %v", err)
		return nil, fmt.Errorf("failed to query mount points: %w", err)
	}
	defer CloseRows(rows)

	var mountPoints []string

	for rows.Next() {
		var mountPoint string
		if err := rows.Scan(&mountPoint); err != nil {
			log.Printf("Error scanning mount point: %v", err)
			continue
		}

		mountPoints = append(mountPoints, mountPoint)
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating mount points rows: %v", err)
		return mountPoints, err
	}

	log.Printf("Found %d unique mount points for poller %s", len(mountPoints), pollerID)

	return mountPoints, nil
}

// SysmonCPUResponse represents a CPU metrics response grouped by timestamp.
type SysmonCPUResponse struct {
	Cpus      []models.CPUMetric `json:"cpus"`
	Timestamp time.Time          `json:"timestamp"`
}

// GetAllCPUMetrics retrieves all CPU metrics for a poller within a time range, grouped by timestamp.
func (db *DB) GetAllCPUMetrics(pollerID string, start, end time.Time) ([]SysmonCPUResponse, error) {
	log.Printf("Querying all CPU metrics for poller %s between %s and %s",
		pollerID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	query := `
        SELECT timestamp, core_id, usage_percent
        FROM cpu_metrics
        WHERE poller_id = ? AND timestamp BETWEEN ? AND ?
        ORDER BY timestamp DESC, core_id ASC
    `

	rows, err := db.Query(query, pollerID, start, end)
	if err != nil {
		log.Printf("Error querying all CPU metrics: %v", err)
		return nil, fmt.Errorf("failed to query all CPU metrics: %w", err)
	}
	defer CloseRows(rows)

	// Group metrics by timestamp
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

	// Convert to response format
	var result []SysmonCPUResponse
	for ts, cpus := range data {
		result = append(result, SysmonCPUResponse{
			Cpus:      cpus,
			Timestamp: ts,
		})
	}

	// Sort by timestamp descending
	for i := 0; i < len(result)-1; i++ {
		for j := i + 1; j < len(result); j++ {
			if result[i].Timestamp.Before(result[j].Timestamp) {
				result[i], result[j] = result[j], result[i]
			}
		}
	}

	log.Printf("Retrieved %d CPU metric timestamps for poller %s", len(result), pollerID)
	return result, nil
}

// SysmonDiskResponse represents a disk metrics response grouped by timestamp
type SysmonDiskResponse struct {
	Disks     []models.DiskMetric `json:"disks"`
	Timestamp time.Time           `json:"timestamp"`
}

// SysmonMemoryResponse represents a memory metrics response.
type SysmonMemoryResponse struct {
	Memory    models.MemoryMetric `json:"memory"`
	Timestamp time.Time           `json:"timestamp"`
}

func (db *DB) GetAllDiskMetrics(pollerID string, start, end time.Time) ([]models.DiskMetric, error) {
	log.Printf("Querying all disk metrics for poller %s between %s and %s",
		pollerID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	query := `
        SELECT mount_point, used_bytes, total_bytes, timestamp
        FROM disk_metrics
        WHERE poller_id = ? AND timestamp BETWEEN ? AND ?
        ORDER BY timestamp DESC, mount_point ASC
    `

	rows, err := db.Query(query, pollerID, start, end)
	if err != nil {
		log.Printf("Error querying all disk metrics: %v", err)
		return nil, fmt.Errorf("failed to query all disk metrics: %w", err)
	}
	defer CloseRows(rows)

	var metrics []models.DiskMetric
	for rows.Next() {
		var m models.DiskMetric
		var usedBytesStr, totalBytesStr string
		if err := rows.Scan(&m.MountPoint, &usedBytesStr, &totalBytesStr, &m.Timestamp); err != nil {
			log.Printf("Error scanning disk metric row: %v", err)
			continue
		}
		m.UsedBytes, err = strconv.ParseUint(usedBytesStr, 10, 64)
		if err != nil {
			log.Printf("Error parsing used_bytes: %v", err)
			continue
		}
		m.TotalBytes, err = strconv.ParseUint(totalBytesStr, 10, 64)
		if err != nil {
			log.Printf("Error parsing total_bytes: %v", err)
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

func (db *DB) GetDiskMetrics(pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error) {
	rows, err := db.Query(`
        SELECT timestamp, mount_point, used_bytes, total_bytes
        FROM disk_metrics
        WHERE poller_id = ? AND mount_point = ? AND timestamp BETWEEN ? AND ?
        ORDER BY timestamp`,
		pollerID, mountPoint, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query disk metrics: %w", err)
	}
	defer CloseRows(rows)

	var metrics []models.DiskMetric
	for rows.Next() {
		var m models.DiskMetric
		var usedBytesStr, totalBytesStr string
		if err := rows.Scan(&m.Timestamp, &m.MountPoint, &usedBytesStr, &totalBytesStr); err != nil {
			log.Printf("Error scanning disk metric row: %v", err)
			continue
		}
		m.UsedBytes, err = strconv.ParseUint(usedBytesStr, 10, 64)
		if err != nil {
			log.Printf("Error parsing used_bytes: %v", err)
			continue
		}
		m.TotalBytes, err = strconv.ParseUint(totalBytesStr, 10, 64)
		if err != nil {
			log.Printf("Error parsing total_bytes: %v", err)
			continue
		}
		metrics = append(metrics, m)
	}

	return metrics, nil
}

func (db *DB) GetMemoryMetrics(pollerID string, start, end time.Time) ([]models.MemoryMetric, error) {
	rows, err := db.Query(`
        SELECT timestamp, used_bytes, total_bytes
        FROM memory_metrics
        WHERE poller_id = ? AND timestamp BETWEEN ? AND ?
        ORDER BY timestamp`,
		pollerID, start, end)
	if err != nil {
		return nil, fmt.Errorf("failed to query memory metrics: %w", err)
	}
	defer CloseRows(rows)

	var metrics []models.MemoryMetric
	for rows.Next() {
		var m models.MemoryMetric
		var usedBytesStr, totalBytesStr string
		if err := rows.Scan(&m.Timestamp, &usedBytesStr, &totalBytesStr); err != nil {
			log.Printf("Error scanning memory metric row: %v", err)
			continue
		}
		m.UsedBytes, err = strconv.ParseUint(usedBytesStr, 10, 64)
		if err != nil {
			log.Printf("Error parsing used_bytes: %v", err)
			continue
		}
		m.TotalBytes, err = strconv.ParseUint(totalBytesStr, 10, 64)
		if err != nil {
			log.Printf("Error parsing total_bytes: %v", err)
			continue
		}
		metrics = append(metrics, m)
	}

	return metrics, nil
}

// pkg/db/metrics.go
func (db *DB) GetAllDiskMetricsGrouped(pollerID string, start, end time.Time) ([]SysmonDiskResponse, error) {
	log.Printf("Querying all disk metrics for poller %s between %s and %s",
		pollerID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	query := `
        SELECT timestamp, mount_point, used_bytes, total_bytes
        FROM disk_metrics
        WHERE poller_id = ? AND timestamp BETWEEN ? AND ?
        ORDER BY timestamp DESC, mount_point ASC
    `

	rows, err := db.Query(query, pollerID, start, end)
	if err != nil {
		log.Printf("Error querying all disk metrics: %v", err)
		return nil, fmt.Errorf("failed to query all disk metrics: %w", err)
	}
	defer CloseRows(rows)

	data := make(map[time.Time][]models.DiskMetric)
	for rows.Next() {
		var m models.DiskMetric
		var timestamp time.Time
		var usedBytesStr, totalBytesStr string
		if err := rows.Scan(&timestamp, &m.MountPoint, &usedBytesStr, &totalBytesStr); err != nil {
			log.Printf("Error scanning disk metric row: %v", err)
			continue
		}
		m.UsedBytes, err = strconv.ParseUint(usedBytesStr, 10, 64)
		if err != nil {
			log.Printf("Error parsing used_bytes: %v", err)
			continue
		}
		m.TotalBytes, err = strconv.ParseUint(totalBytesStr, 10, 64)
		if err != nil {
			log.Printf("Error parsing total_bytes: %v", err)
			continue
		}
		m.Timestamp = timestamp
		data[timestamp] = append(data[timestamp], m)
	}

	if err := rows.Err(); err != nil {
		log.Printf("Error iterating disk metrics rows: %v", err)
		return nil, err
	}

	var result []SysmonDiskResponse
	for ts, disks := range data {
		result = append(result, SysmonDiskResponse{
			Disks:     disks,
			Timestamp: ts,
		})
	}

	for i := 0; i < len(result)-1; i++ {
		for j := i + 1; j < len(result); j++ {
			if result[i].Timestamp.Before(result[j].Timestamp) {
				result[i], result[j] = result[j], result[i]
			}
		}
	}

	log.Printf("Retrieved %d disk metric timestamps for poller %s", len(result), pollerID)
	return result, nil
}

func (db *DB) GetMemoryMetricsGrouped(pollerID string, start, end time.Time) ([]SysmonMemoryResponse, error) {
	log.Printf("Querying memory metrics for poller %s between %s and %s",
		pollerID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	query := `
        SELECT timestamp, used_bytes, total_bytes
        FROM memory_metrics
        WHERE poller_id = ? AND timestamp BETWEEN ? AND ?
        ORDER BY timestamp DESC
    `

	rows, err := db.Query(query, pollerID, start, end)
	if err != nil {
		log.Printf("Error querying memory metrics: %v", err)
		return nil, fmt.Errorf("failed to query memory metrics: %w", err)
	}
	defer CloseRows(rows)

	var result []SysmonMemoryResponse
	for rows.Next() {
		var m models.MemoryMetric
		var timestamp time.Time
		var usedBytesStr, totalBytesStr string
		if err := rows.Scan(&timestamp, &usedBytesStr, &totalBytesStr); err != nil {
			log.Printf("Error scanning memory metric row: %v", err)
			continue
		}
		m.UsedBytes, err = strconv.ParseUint(usedBytesStr, 10, 64)
		if err != nil {
			log.Printf("Error parsing used_bytes: %v", err)
			continue
		}
		m.TotalBytes, err = strconv.ParseUint(totalBytesStr, 10, 64)
		if err != nil {
			log.Printf("Error parsing total_bytes: %v", err)
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
