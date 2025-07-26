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

package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"reflect"
	"sort"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/gorilla/mux"
)

// fetchMetrics is a generic helper to fetch metrics and handle errors.
func fetchMetrics[T any](
	ctx context.Context,
	pollerID string,
	startTime, endTime time.Time,
	getMetrics func(context.Context, string, time.Time, time.Time) ([]T, error),
) (interface{}, error) {
	metrics, err := getMetrics(ctx, pollerID, startTime, endTime)
	if err != nil {
		return nil, &httpError{"Internal server error", http.StatusInternalServerError}
	}

	if len(metrics) == 0 {
		return nil, &httpError{"No metrics found", http.StatusNotFound}
	}

	return metrics, nil
}

// getSysmonMetrics is a generic handler for system metrics requests.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func (s *APIServer) getSysmonMetrics(
	w http.ResponseWriter,
	r *http.Request,
	fetchMetrics func(
		ctx context.Context,
		provider db.SysmonMetricsProvider,
		pollerID string,
		startTime, endTime time.Time) (interface{}, error),
	metricType string,
) {
	ctx := r.Context()

	vars := mux.Vars(r)

	pollerID := vars["id"]

	// Parse time range
	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		writeError(w, err.Error(), http.StatusBadRequest)

		return
	}

	// Validate metrics provider
	metricsProvider, ok := s.metricsManager.(db.SysmonMetricsProvider)
	if !ok {
		s.logger.Warn().Str("poller_id", pollerID).Msg("Metrics manager does not implement SysmonMetricsProvider")
		writeError(w, "System metrics not supported by this server", http.StatusNotImplemented)

		return
	}

	// Fetch metrics
	metrics, err := fetchMetrics(ctx, metricsProvider, pollerID, startTime, endTime)
	if err != nil {
		var httpErr *httpError

		if errors.As(err, &httpErr) {
			s.logger.Error().
				Err(err).
				Str("metric_type", metricType).
				Str("poller_id", pollerID).
				Msg("Error fetching metrics")
			writeError(w, httpErr.Message, httpErr.Status)
		} else {
			s.logger.Error().
				Err(err).
				Str("metric_type", metricType).
				Str("poller_id", pollerID).
				Msg("Unexpected error fetching metrics")
			writeError(w, "Internal server error", http.StatusInternalServerError)
		}

		return
	}

	// log metrics based on type
	switch metricType {
	case "CPU":
		s.logger.Debug().
			Int("metric_count", len(metrics.([]models.SysmonCPUResponse))).
			Str("poller_id", pollerID).
			Msg("Fetched CPU metrics")
	case "memory":
		s.logger.Debug().
			Int("metric_count", len(metrics.([]models.SysmonMemoryResponse))).
			Str("poller_id", pollerID).
			Msg("Fetched memory metrics")
	case "disk":
		s.logger.Debug().
			Int("metric_count", len(metrics.([]models.SysmonDiskResponse))).
			Str("poller_id", pollerID).
			Msg("Fetched disk metrics")
	case "process":
		s.logger.Debug().
			Int("metric_count", len(metrics.([]models.SysmonProcessResponse))).
			Str("poller_id", pollerID).
			Msg("Fetched process metrics")
	default:
		s.logger.Debug().
			Int("metric_count", len(metrics.([]models.SysmonDiskResponse))).
			Str("poller_id", pollerID).
			Msg("Fetched unknown metrics")

		return
	}

	// Encode response
	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(metrics); err != nil {
		log.Printf("Error encoding %s metrics response: %v", metricType, pollerID)
		writeError(w, "Error encoding response", http.StatusInternalServerError)
	}
}

// @Summary Get CPU metrics
// @Description Retrieves CPU usage metrics for a specific poller within a time range
// @Tags Sysmon
// @Accept json
// @Produce json
// @Param id path string true "Poller ID"
// @Param start query string false "Start time in RFC3339 format (default: 24h ago)"
// @Param end query string false "End time in RFC3339 format (default: now)"
// @Success 200 {array} models.CPUMetric "CPU metrics data"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 404 {object} models.ErrorResponse "No metrics found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Failure 501 {object} models.ErrorResponse "System metrics not supported"
// @Router /pollers/{id}/sysmon/cpu [get]
// @Security ApiKeyAuth
func (s *APIServer) getSysmonCPUMetrics(w http.ResponseWriter, r *http.Request) {
	fetch := func(
		ctx context.Context,
		provider db.SysmonMetricsProvider,
		pollerID string,
		startTime, endTime time.Time) (interface{}, error) {
		return fetchMetrics[models.SysmonCPUResponse](ctx, pollerID, startTime, endTime, provider.GetAllCPUMetrics)
	}
	s.getSysmonMetrics(w, r, fetch, "CPU")
}

// @Summary Get memory metrics
// @Description Retrieves memory usage metrics for a specific poller within a time range
// @Tags Sysmon
// @Accept json
// @Produce json
// @Param id path string true "Poller ID"
// @Param start query string false "Start time in RFC3339 format (default: 24h ago)"
// @Param end query string false "End time in RFC3339 format (default: now)"
// @Success 200 {array} models.SysmonMemoryResponse "Memory metrics data grouped by timestamp"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 404 {object} models.ErrorResponse "No metrics found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Failure 501 {object} models.ErrorResponse "System metrics not supported"
// @Router /pollers/{id}/sysmon/memory [get]
// @Security ApiKeyAuth
func (s *APIServer) getSysmonMemoryMetrics(w http.ResponseWriter, r *http.Request) {
	fetch := func(
		ctx context.Context,
		provider db.SysmonMetricsProvider,
		pollerID string,
		startTime, endTime time.Time) (interface{}, error) {
		return fetchMetrics[models.SysmonMemoryResponse](ctx, pollerID, startTime,
			endTime, provider.GetMemoryMetricsGrouped)
	}

	s.getSysmonMetrics(w, r, fetch, "memory")
}

// fetchDiskMetrics retrieves disk metrics based on mount point presence.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func (*APIServer) fetchDiskMetrics(
	ctx context.Context,
	provider db.SysmonMetricsProvider,
	pollerID, mountPoint string,
	startTime, endTime time.Time,
) (interface{}, error) {
	if mountPoint != "" {
		metrics, err := fetchMetrics[models.DiskMetric](ctx, pollerID, startTime, endTime,
			func(ctx context.Context, pollerID string, startTime, endTime time.Time) ([]models.DiskMetric, error) {
				return provider.GetDiskMetrics(ctx, pollerID, mountPoint, startTime, endTime)
			})
		if err != nil {
			return nil, err
		}

		return groupDiskMetricsByTimestamp(metrics.([]models.DiskMetric)), nil
	}

	return fetchMetrics[models.SysmonDiskResponse](ctx, pollerID, startTime, endTime, provider.GetAllDiskMetricsGrouped)
}

// @Summary Get disk metrics
// @Description Retrieves disk usage metrics for a specific poller within a time range
// @Tags Sysmon
// @Accept json
// @Produce json
// @Param id path string true "Poller ID"
// @Param mount_point query string false "Filter by specific mount point"
// @Param start query string false "Start time in RFC3339 format (default: 24h ago)"
// @Param end query string false "End time in RFC3339 format (default: now)"
// @Success 200 {array} models.SysmonDiskResponse "Disk metrics data grouped by timestamp"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 404 {object} models.ErrorResponse "No metrics found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Failure 501 {object} models.ErrorResponse "System metrics not supported"
// @Router /pollers/{id}/sysmon/disk [get]
// @Security ApiKeyAuth
func (s *APIServer) getSysmonDiskMetrics(w http.ResponseWriter, r *http.Request) {
	fetch := func(
		ctx context.Context,
		provider db.SysmonMetricsProvider,
		pollerID string,
		startTime, endTime time.Time) (interface{}, error) {
		mountPoint := r.URL.Query().Get("mount_point")

		return s.fetchDiskMetrics(ctx, provider, pollerID, mountPoint, startTime, endTime)
	}

	s.getSysmonMetrics(w, r, fetch, "disk")
}

// @Summary Get process metrics
// @Description Retrieves process metrics for a specific poller within a time range
// @Tags Sysmon
// @Accept json
// @Produce json
// @Param id path string true "Poller ID"
// @Param start query string false "Start time in RFC3339 format (default: 24h ago)"
// @Param end query string false "End time in RFC3339 format (default: now)"
// @Success 200 {array} models.SysmonProcessResponse "Process metrics data grouped by timestamp"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 404 {object} models.ErrorResponse "No metrics found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Failure 501 {object} models.ErrorResponse "System metrics not supported"
// @Router /pollers/{id}/sysmon/processes [get]
// @Security ApiKeyAuth
func (s *APIServer) getSysmonProcessMetrics(w http.ResponseWriter, r *http.Request) {
	fetch := func(
		ctx context.Context,
		provider db.SysmonMetricsProvider,
		pollerID string,
		startTime, endTime time.Time) (interface{}, error) {
		return fetchMetrics[models.SysmonProcessResponse](ctx, pollerID, startTime, endTime, provider.GetAllProcessMetricsGrouped)
	}
	s.getSysmonMetrics(w, r, fetch, "process")
}

// groupDiskMetricsByTimestamp groups a slice of DiskMetric by timestamp into SysmonDiskResponse.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func groupDiskMetricsByTimestamp(metrics []models.DiskMetric) []models.SysmonDiskResponse {
	// Map to group metrics by timestamp
	timestampMap := make(map[time.Time][]models.DiskMetric)

	for _, metric := range metrics {
		// Truncate to second for consistent grouping
		t := metric.Timestamp.Truncate(time.Second)
		timestampMap[t] = append(timestampMap[t], metric)
	}

	// Convert to SysmonDiskResponse
	result := make([]models.SysmonDiskResponse, 0, len(timestampMap))

	for ts, disks := range timestampMap {
		result = append(result, models.SysmonDiskResponse{
			Timestamp: ts,
			Disks:     disks,
		})
	}

	// Sort by timestamp for consistent output
	sort.Slice(result, func(i, j int) bool {
		return result[i].Timestamp.Before(result[j].Timestamp)
	})

	return result
}

// Device-centric sysmon handlers

// getDeviceSysmonCPUMetrics retrieves CPU metrics for a specific device.
func (s *APIServer) getDeviceSysmonCPUMetrics(w http.ResponseWriter, r *http.Request) {
	s.handleDeviceSysmonMetrics(w, r, "CPU", s.getCPUMetricsForDevice)
}

// getDeviceSysmonMemoryMetrics retrieves memory metrics for a specific device.
func (s *APIServer) getDeviceSysmonMemoryMetrics(w http.ResponseWriter, r *http.Request) {
	s.handleDeviceSysmonMetrics(w, r, "memory", s.getMemoryMetricsForDevice)
}

// getDeviceSysmonDiskMetrics retrieves disk metrics for a specific device.
func (s *APIServer) getDeviceSysmonDiskMetrics(w http.ResponseWriter, r *http.Request) {
	s.handleDeviceSysmonMetrics(w, r, "disk", s.getDiskMetricsForDevice)
}

// getDeviceSysmonProcessMetrics retrieves process metrics for a specific device.
func (s *APIServer) getDeviceSysmonProcessMetrics(w http.ResponseWriter, r *http.Request) {
	s.handleDeviceSysmonMetrics(w, r, "process", s.getProcessMetricsForDevice)
}

// handleDeviceSysmonMetrics is a generic handler for device-centric sysmon metrics
func (s *APIServer) handleDeviceSysmonMetrics(
	w http.ResponseWriter,
	r *http.Request,
	metricType string,
	fetcher func(context.Context, db.SysmonMetricsProvider, string, time.Time, time.Time) (interface{}, error)) {
	ctx := r.Context()

	vars := mux.Vars(r)

	deviceID := vars["id"]

	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		writeError(w, err.Error(), http.StatusBadRequest)
		return
	}

	metricsProvider, ok := s.metricsManager.(db.SysmonMetricsProvider)
	if !ok {
		log.Printf("WARNING: Metrics manager does not implement SysmonMetricsProvider for device %s", deviceID)
		writeError(w, "System metrics not supported by this server", http.StatusNotImplemented)

		return
	}

	metrics, err := fetcher(ctx, metricsProvider, deviceID, startTime, endTime)
	if err != nil {
		log.Printf("Error fetching %s metrics for device %s: %v", metricType, deviceID, err)
		writeError(w, "Internal server error", http.StatusInternalServerError)

		return
	}

	// Check if metrics slice is empty using reflection since we're dealing with interface{}
	metricsValue := reflect.ValueOf(metrics)
	if metricsValue.Kind() == reflect.Slice && metricsValue.Len() == 0 {
		writeError(w, "No metrics found", http.StatusNotFound)

		return
	}

	log.Printf("Fetched %d %s metrics for device %s", metricsValue.Len(), metricType, deviceID)

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(metrics); err != nil {
		log.Printf("Error encoding %s metrics response for device %s: %v", metricType, deviceID, err)
		writeError(w, "Error encoding response", http.StatusInternalServerError)
	}
}

// Helper functions for device-centric queries

// getCPUMetricsForDevice queries CPU metrics by device_id from cpu_metrics table
func (s *APIServer) getCPUMetricsForDevice(
	ctx context.Context, _ db.SysmonMetricsProvider, deviceID string, start, end time.Time) (interface{}, error) {
	// Query cpu_metrics table directly for per-core data by device_id
	query := fmt.Sprintf(`
		SELECT timestamp, agent_id, host_id, core_id, usage_percent
		FROM table(cpu_metrics)
		WHERE device_id = '%s' AND timestamp BETWEEN '%s' AND '%s'
		ORDER BY timestamp DESC, core_id ASC`,
		deviceID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	rows, err := s.dbService.(*db.DB).Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to query CPU metrics for device %s: %w", deviceID, err)
	}
	defer rows.Close()

	data := make(map[time.Time][]models.CPUMetric)

	for rows.Next() {
		var timestamp time.Time

		var agentID, hostID string

		var coreID int32

		var usagePercent float64

		if err := rows.Scan(&timestamp, &agentID, &hostID, &coreID, &usagePercent); err != nil {
			log.Printf("Error scanning CPU metric row for device %s: %v", deviceID, err)
			continue
		}

		cpu := models.CPUMetric{
			Timestamp:    timestamp,
			AgentID:      agentID,
			HostID:       hostID,
			CoreID:       coreID,
			UsagePercent: usagePercent,
		}

		data[timestamp] = append(data[timestamp], cpu)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating CPU metrics rows for device %s: %w", deviceID, err)
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

// getMemoryMetricsForDevice queries memory metrics by device_id from memory_metrics table
func (s *APIServer) getMemoryMetricsForDevice(
	ctx context.Context, _ db.SysmonMetricsProvider, deviceID string, start, end time.Time) (interface{}, error) {
	query := fmt.Sprintf(`
		SELECT timestamp, agent_id, host_id, used_bytes, total_bytes
		FROM table(memory_metrics)
		WHERE device_id = '%s' AND timestamp BETWEEN '%s' AND '%s'
		ORDER BY timestamp DESC`,
		deviceID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	rows, err := s.dbService.(*db.DB).Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to query memory metrics for device %s: %w", deviceID, err)
	}
	defer rows.Close()

	var result []models.SysmonMemoryResponse

	for rows.Next() {
		var timestamp time.Time

		var agentID, hostID string

		var usedBytes, totalBytes uint64

		if err := rows.Scan(&timestamp, &agentID, &hostID, &usedBytes, &totalBytes); err != nil {
			log.Printf("Error scanning memory metric row for device %s: %v", deviceID, err)
			continue
		}

		memory := models.MemoryMetric{
			Timestamp:  timestamp,
			AgentID:    agentID,
			HostID:     hostID,
			UsedBytes:  usedBytes,
			TotalBytes: totalBytes,
		}

		result = append(result, models.SysmonMemoryResponse{
			Memory:    memory,
			Timestamp: timestamp,
		})
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating memory metrics rows for device %s: %w", deviceID, err)
	}

	return result, nil
}

// getDiskMetricsForDevice queries disk metrics by device_id from disk_metrics table
func (s *APIServer) getDiskMetricsForDevice(
	ctx context.Context, _ db.SysmonMetricsProvider, deviceID string, start, end time.Time) (interface{}, error) {
	query := fmt.Sprintf(`
		SELECT timestamp, agent_id, host_id, mount_point, used_bytes, total_bytes
		FROM table(disk_metrics)
		WHERE device_id = '%s' AND timestamp BETWEEN '%s' AND '%s'
		ORDER BY timestamp DESC, mount_point ASC`,
		deviceID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	rows, err := s.dbService.(*db.DB).Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to query disk metrics for device %s: %w", deviceID, err)
	}
	defer rows.Close()

	data := make(map[time.Time][]models.DiskMetric)

	for rows.Next() {
		var timestamp time.Time

		var agentID, hostID, mountPoint string

		var usedBytes, totalBytes uint64

		if err := rows.Scan(&timestamp, &agentID, &hostID, &mountPoint, &usedBytes, &totalBytes); err != nil {
			log.Printf("Error scanning disk metric row for device %s: %v", deviceID, err)
			continue
		}

		disk := models.DiskMetric{
			Timestamp:  timestamp,
			AgentID:    agentID,
			HostID:     hostID,
			MountPoint: mountPoint,
			UsedBytes:  usedBytes,
			TotalBytes: totalBytes,
		}
		data[timestamp] = append(data[timestamp], disk)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating disk metrics rows for device %s: %w", deviceID, err)
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

// getProcessMetricsForDevice queries process metrics by device_id from process_metrics table
func (s *APIServer) getProcessMetricsForDevice(
	ctx context.Context, _ db.SysmonMetricsProvider, deviceID string, start, end time.Time) (interface{}, error) {
	query := fmt.Sprintf(`
		SELECT timestamp, agent_id, host_id, pid, name, cpu_usage, memory_usage, status, start_time
		FROM table(process_metrics)
		WHERE device_id = '%s' AND timestamp BETWEEN '%s' AND '%s'
		ORDER BY timestamp DESC, pid ASC`,
		deviceID, start.Format(time.RFC3339), end.Format(time.RFC3339))

	rows, err := s.dbService.(*db.DB).Conn.Query(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("failed to query process metrics for device %s: %w", deviceID, err)
	}
	defer rows.Close()

	data := make(map[time.Time][]models.ProcessMetric)

	for rows.Next() {
		var timestamp time.Time

		var agentID, hostID, name, status, startTime string

		var pid uint32

		var cpuUsage float32

		var memoryUsage uint64

		if err := rows.Scan(&timestamp, &agentID, &hostID, &pid, &name, &cpuUsage, &memoryUsage, &status, &startTime); err != nil {
			log.Printf("Error scanning process metric row for device %s: %v", deviceID, err)
			continue
		}

		process := models.ProcessMetric{
			Timestamp:   timestamp,
			AgentID:     agentID,
			HostID:      hostID,
			PID:         pid,
			Name:        name,
			CPUUsage:    cpuUsage,
			MemoryUsage: memoryUsage,
			Status:      status,
			StartTime:   startTime,
		}
		data[timestamp] = append(data[timestamp], process)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("error iterating process metrics rows for device %s: %w", deviceID, err)
	}

	result := make([]models.SysmonProcessResponse, 0, len(data))
	for ts, processes := range data {
		result = append(result, models.SysmonProcessResponse{
			Processes: processes,
			Timestamp: ts,
		})
	}

	// Sort by timestamp descending
	sort.Slice(result, func(i, j int) bool {
		return result[i].Timestamp.After(result[j].Timestamp)
	})

	return result, nil
}
