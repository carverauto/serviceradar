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
	"log"
	"net/http"
	"sort"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/gorilla/mux"
)

// fetchMetrics is a generic helper to fetch metrics and handle errors.
func fetchMetrics[T any](
	ctx context.Context,
	agentID string,
	startTime, endTime time.Time,
	getMetrics func(context.Context, string, time.Time, time.Time) ([]T, error),
) (interface{}, error) {
	metrics, err := getMetrics(ctx, agentID, startTime, endTime)
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
	agentID string,
	hostID *string,
	startTime, endTime time.Time) (interface{}, error),
	metricType string,
) {
	ctx := r.Context()

	vars := mux.Vars(r)

	agentID := vars["id"]

	// Extract optional host_id from query parameters
	var hostID *string
	if h := r.URL.Query().Get("host_id"); h != "" {
		hostID = &h
	}

	// Parse time range
	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		writeError(w, err.Error(), http.StatusBadRequest)

		return
	}

	// Validate metrics provider
	metricsProvider, ok := s.metricsManager.(db.SysmonMetricsProvider)
	if !ok {
		log.Printf("WARNING: Metrics manager does not implement SysmonMetricsProvider for agent %s", agentID)
		writeError(w, "System metrics not supported by this server", http.StatusNotImplemented)

		return
	}

	// debug log for metrics provider
	if hostID != nil {
		log.Printf("Using SysmonMetricsProvider for agent %s, host %s", agentID, *hostID)
	} else {
		log.Printf("Using SysmonMetricsProvider for agent %s (all hosts)", agentID)
	}

	// Fetch metrics
	metrics, err := fetchMetrics(ctx, metricsProvider, agentID, hostID, startTime, endTime)
	if err != nil {
		var httpErr *httpError

		if errors.As(err, &httpErr) {
			log.Printf("Error fetching %s metrics for agent %s: %v", metricType, agentID, err)
			writeError(w, httpErr.Message, httpErr.Status)
		} else {
			log.Printf("Unexpected error fetching %s metrics for agent %s: %v", metricType, agentID, err)
			writeError(w, "Internal server error", http.StatusInternalServerError)
		}

		return
	}

	// log metrics based on type
	switch metricType {
	case "CPU":
		log.Printf("Fetched %d CPU metrics for agent %s", len(metrics.([]models.SysmonCPUResponse)), agentID)
	case "memory":
		log.Printf("Fetched %d memory metrics for agent %s", len(metrics.([]models.SysmonMemoryResponse)), agentID)
	case "disk":
		log.Printf("Fetched %d disk metrics for agent %s", len(metrics.([]models.SysmonDiskResponse)), agentID)
	default:
		log.Printf("Fetched %d unknown metrics for agent %s", len(metrics.([]models.SysmonDiskResponse)), agentID)
		return
	}

	// Encode response
	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(metrics); err != nil {
		log.Printf("Error encoding %s metrics response: %v", metricType, agentID)
		writeError(w, "Error encoding response", http.StatusInternalServerError)
	}
}

// @Summary Get CPU metrics
// @Description Retrieves CPU usage metrics for a specific agent within a time range
// @Tags Sysmon
// @Accept json
// @Produce json
// @Param id path string true "Agent ID"
// @Param host_id query string false "Filter by specific host ID (optional)"
// @Param start query string false "Start time in RFC3339 format (default: 24h ago)"
// @Param end query string false "End time in RFC3339 format (default: now)"
// @Success 200 {array} models.CPUMetric "CPU metrics data"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 404 {object} models.ErrorResponse "No metrics found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Failure 501 {object} models.ErrorResponse "System metrics not supported"
// @Router /agents/{id}/sysmon/cpu [get]
// @Security ApiKeyAuth
func (s *APIServer) getSysmonCPUMetrics(w http.ResponseWriter, r *http.Request) {
	fetch := func(ctx context.Context, provider db.SysmonMetricsProvider, agentID string, hostID *string, startTime, endTime time.Time) (interface{}, error) {
		return provider.GetAllCPUMetrics(ctx, agentID, hostID, startTime, endTime)
	}
	s.getSysmonMetrics(w, r, fetch, "CPU")
}

// @Summary Get memory metrics
// @Description Retrieves memory usage metrics for a specific agent within a time range
// @Tags Sysmon
// @Accept json
// @Produce json
// @Param id path string true "Agent ID"
// @Param host_id query string false "Filter by specific host ID (optional)"
// @Param start query string false "Start time in RFC3339 format (default: 24h ago)"
// @Param end query string false "End time in RFC3339 format (default: now)"
// @Success 200 {array} models.SysmonMemoryResponse "Memory metrics data grouped by timestamp"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 404 {object} models.ErrorResponse "No metrics found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Failure 501 {object} models.ErrorResponse "System metrics not supported"
// @Router /agents/{id}/sysmon/memory [get]
// @Security ApiKeyAuth
func (s *APIServer) getSysmonMemoryMetrics(w http.ResponseWriter, r *http.Request) {
	fetch := func(ctx context.Context, provider db.SysmonMetricsProvider, agentID string, hostID *string, startTime, endTime time.Time) (interface{}, error) {
		return provider.GetMemoryMetricsGrouped(ctx, agentID, hostID, startTime, endTime)
	}

	s.getSysmonMetrics(w, r, fetch, "memory")
}

// fetchDiskMetrics retrieves disk metrics based on mount point presence.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func (*APIServer) fetchDiskMetrics(
	ctx context.Context,
	provider db.SysmonMetricsProvider,
	agentID string,
	hostID *string,
	mountPoint string,
	startTime, endTime time.Time,
) (interface{}, error) {
	if mountPoint != "" {
		metrics, err := fetchMetrics[models.DiskMetric](ctx, agentID, startTime, endTime,
			func(ctx context.Context, agentID string, startTime, endTime time.Time) ([]models.DiskMetric, error) {
				return provider.GetDiskMetrics(ctx, agentID, mountPoint, startTime, endTime)
			})
		if err != nil {
			return nil, err
		}

		return groupDiskMetricsByTimestamp(metrics.([]models.DiskMetric)), nil
	}

	return provider.GetAllDiskMetricsGrouped(ctx, agentID, hostID, startTime, endTime)
}

// @Summary Get disk metrics
// @Description Retrieves disk usage metrics for a specific agent within a time range
// @Tags Sysmon
// @Accept json
// @Produce json
// @Param id path string true "Agent ID"
// @Param host_id query string false "Filter by specific host ID (optional)"
// @Param mount_point query string false "Filter by specific mount point"
// @Param start query string false "Start time in RFC3339 format (default: 24h ago)"
// @Param end query string false "End time in RFC3339 format (default: now)"
// @Success 200 {array} models.SysmonDiskResponse "Disk metrics data grouped by timestamp"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 404 {object} models.ErrorResponse "No metrics found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Failure 501 {object} models.ErrorResponse "System metrics not supported"
// @Router /agents/{id}/sysmon/disk [get]
// @Security ApiKeyAuth
func (s *APIServer) getSysmonDiskMetrics(w http.ResponseWriter, r *http.Request) {
	fetch := func(ctx context.Context, provider db.SysmonMetricsProvider, agentID string, hostID *string, startTime, endTime time.Time) (interface{}, error) {
		mountPoint := r.URL.Query().Get("mount_point")

		return s.fetchDiskMetrics(ctx, provider, agentID, hostID, mountPoint, startTime, endTime)
	}

	s.getSysmonMetrics(w, r, fetch, "disk")
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
