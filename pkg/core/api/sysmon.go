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
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/gorilla/mux"
)

// getSysmonMetrics is a generic handler for system metrics requests.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func (s *APIServer) getSysmonMetrics(
	w http.ResponseWriter,
	r *http.Request,
	fetchMetrics func(db.SysmonMetricsProvider, string, time.Time, time.Time) (interface{}, error),
	metricType string,
) {
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
		log.Printf("WARNING: Metrics manager does not implement SysmonMetricsProvider for poller %s", pollerID)
		writeError(w, "System metrics not supported by this server", http.StatusNotImplemented)

		return
	}

	// Fetch metrics
	metrics, err := fetchMetrics(metricsProvider, pollerID, startTime, endTime)
	if err != nil {
		var httpErr *httpError

		if errors.As(err, &httpErr) {
			log.Printf("Error fetching %s metrics for poller %s: %v", metricType, pollerID, err)
			writeError(w, httpErr.Message, httpErr.Status)
		} else {
			log.Printf("Unexpected error fetching %s metrics for poller %s: %v", metricType, pollerID, err)
			writeError(w, "Internal server error", http.StatusInternalServerError)
		}

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
	fetch := func(provider db.SysmonMetricsProvider, pollerID string, startTime, endTime time.Time) (interface{}, error) {
		metrics, err := provider.GetAllCPUMetrics(pollerID, startTime, endTime)
		if err != nil {
			return nil, &httpError{"Internal server error", http.StatusInternalServerError}
		}

		if len(metrics) == 0 {
			return nil, &httpError{"No metrics found", http.StatusNotFound}
		}

		return metrics, nil
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
// @Success 200 {array} db.SysmonMemoryResponse "Memory metrics data grouped by timestamp"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 404 {object} models.ErrorResponse "No metrics found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Failure 501 {object} models.ErrorResponse "System metrics not supported"
// @Router /pollers/{id}/sysmon/memory [get]
// @Security ApiKeyAuth
func (s *APIServer) getSysmonMemoryMetrics(w http.ResponseWriter, r *http.Request) {
	fetch := func(provider db.SysmonMetricsProvider, pollerID string, startTime, endTime time.Time) (interface{}, error) {
		metrics, err := provider.GetMemoryMetricsGrouped(pollerID, startTime, endTime)
		if err != nil {
			return nil, &httpError{"Internal server error", http.StatusInternalServerError}
		}

		if len(metrics) == 0 {
			return nil, &httpError{"No metrics found", http.StatusNotFound}
		}

		return metrics, nil
	}

	s.getSysmonMetrics(w, r, fetch, "memory")
}

// fetchDiskMetrics retrieves disk metrics based on mount point presence.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func (*APIServer) fetchDiskMetrics(
	provider db.SysmonMetricsProvider,
	pollerID, mountPoint string,
	startTime, endTime time.Time,
) ([]db.SysmonDiskResponse, error) {
	if mountPoint != "" {
		metrics, err := provider.GetDiskMetrics(pollerID, mountPoint, startTime, endTime)
		if err != nil {
			log.Printf("Error fetching disk metrics for poller %s, mount point %s: %v", pollerID, mountPoint, err)

			return nil, &httpError{"Internal server error", http.StatusInternalServerError}
		}

		if len(metrics) == 0 {
			return nil, &httpError{"No metrics found", http.StatusNotFound}
		}

		grouped := groupDiskMetricsByTimestamp(metrics)

		return grouped, nil
	}

	allMetrics, err := provider.GetAllDiskMetricsGrouped(pollerID, startTime, endTime)
	if err != nil {
		log.Printf("Error fetching all disk metrics for poller %s: %v", pollerID, err)

		return nil, &httpError{"Internal server error", http.StatusInternalServerError}
	}

	if len(allMetrics) == 0 {
		return nil, &httpError{"No metrics found", http.StatusNotFound}
	}

	return allMetrics, nil
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
// @Success 200 {array} db.SysmonDiskResponse "Disk metrics data grouped by timestamp"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 404 {object} models.ErrorResponse "No metrics found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Failure 501 {object} models.ErrorResponse "System metrics not supported"
// @Router /pollers/{id}/sysmon/disk [get]
// @Security ApiKeyAuth
func (s *APIServer) getSysmonDiskMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)

	pollerID := vars["id"]

	mountPoint := r.URL.Query().Get("mount_point")

	// Parse time range
	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		writeError(w, err.Error(), http.StatusBadRequest)

		return
	}

	// Validate metrics provider.
	metricsProvider, ok := s.metricsManager.(db.SysmonMetricsProvider)
	if !ok {
		log.Printf("WARNING: Metrics manager does not implement SysmonMetricsProvider for poller %s", pollerID)
		writeError(w, "System metrics not supported by this server", http.StatusNotImplemented)

		return
	}

	// Fetch metrics based on mount point.
	response, err := s.fetchDiskMetrics(metricsProvider, pollerID, mountPoint, startTime, endTime)
	if err != nil {
		var httpErr *httpError

		if errors.As(err, &httpErr) {
			log.Printf("Error fetching disk metrics for poller %s: %v", pollerID, err)
			writeError(w, httpErr.Message, httpErr.Status)
		} else {
			log.Printf("Unexpected error fetching disk metrics for poller %s: %v", pollerID, err)
			writeError(w, "Internal server error", http.StatusInternalServerError)
		}

		return
	}

	// Encode response
	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("Error encoding disk metrics response: %v", err)
		writeError(w, "Error encoding response", http.StatusInternalServerError)
	}
}

// groupDiskMetricsByTimestamp groups a slice of DiskMetric by timestamp into SysmonDiskResponse.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func groupDiskMetricsByTimestamp(metrics []models.DiskMetric) []db.SysmonDiskResponse {
	// Map to group metrics by timestamp
	timestampMap := make(map[time.Time][]models.DiskMetric)

	for _, metric := range metrics {
		// Truncate to second for consistent grouping
		t := metric.Timestamp.Truncate(time.Second)
		timestampMap[t] = append(timestampMap[t], metric)
	}

	// Convert to SysmonDiskResponse
	result := make([]db.SysmonDiskResponse, 0, len(timestampMap))
	for ts, disks := range timestampMap {
		result = append(result, db.SysmonDiskResponse{
			Timestamp: ts,
			Disks:     disks,
		})
	}

	// Sort by timestamp for consistent output
	// (Optional, depending on requirements)
	// sort.Slice(result, func(i, j int) bool {
	//     return result[i].Timestamp.Before(result[j].Timestamp)
	// })

	return result
}
