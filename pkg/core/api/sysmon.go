package api

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/gorilla/mux"
)

func (s *APIServer) getSysmonCPUMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]
	startStr := r.URL.Query().Get("start")
	endStr := r.URL.Query().Get("end")
	coreIDStr := r.URL.Query().Get("core_id")

	if startStr == "" || endStr == "" {
		http.Error(w, "start and end parameters are required", http.StatusBadRequest)
		return
	}

	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if s.metricsManager == nil {
		log.Printf("Metrics manager not configured for poller %s", pollerID)
		http.Error(w, "Metrics not configured", http.StatusInternalServerError)
		return
	}

	structuredMetrics, ok := s.metricsManager.(metrics.StructuredMetricCollector)
	if !ok {
		log.Printf("Metrics manager does not support structured metrics for poller %s", pollerID)
		http.Error(w, "Structured metrics not supported", http.StatusInternalServerError)
		return
	}

	var cpuMetrics []models.CPUMetric

	// If core_id is specified, get metrics for that specific core
	// Otherwise, get metrics for all cores
	if coreIDStr != "" {
		coreID, err := strconv.Atoi(coreIDStr)
		if err != nil {
			http.Error(w, "Invalid core_id format", http.StatusBadRequest)
			return
		}

		cpuMetrics, err = structuredMetrics.GetCPUMetrics(pollerID, coreID, startTime, endTime)
	} else {
		// Get metrics for all cores (you may need to implement this method)
		// For now, we'll just use core 0 as a placeholder
		cpuMetrics, err = structuredMetrics.GetCPUMetrics(pollerID, 0, startTime, endTime)
	}

	if err != nil {
		log.Printf("Error fetching CPU metrics for poller %s: %v", pollerID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	if len(cpuMetrics) == 0 {
		log.Printf("No CPU metrics found for poller %s", pollerID)
		http.Error(w, "No metrics found", http.StatusNotFound)
		return
	}

	// Create a map to group metrics by timestamp
	metricsByTimestamp := make(map[time.Time][]models.CPUMetric)
	var latestTimestamp time.Time

	for _, metric := range cpuMetrics {
		metricsByTimestamp[metric.Timestamp] = append(metricsByTimestamp[metric.Timestamp], metric)
		if metric.Timestamp.After(latestTimestamp) {
			latestTimestamp = metric.Timestamp
		}
	}

	// Use the metrics from the latest timestamp
	latestMetrics := metricsByTimestamp[latestTimestamp]

	// Format the metrics as expected by the frontend
	cpus := make([]map[string]interface{}, len(latestMetrics))
	for i, metric := range latestMetrics {
		cpus[i] = map[string]interface{}{
			"core_id":       metric.CoreID,
			"usage_percent": metric.UsagePercent,
		}
	}

	response := map[string]interface{}{
		"cpus":      cpus,
		"timestamp": latestTimestamp.Format(time.RFC3339),
	}

	// Write the response
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("Error encoding CPU metrics response for poller %s: %v", pollerID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	log.Printf("Successfully wrote CPU metrics response for poller %s with %d cores",
		pollerID, len(cpus))
}

func (s *APIServer) getSysmonDiskMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]
	mountPoint := r.URL.Query().Get("mount_point")
	startStr := r.URL.Query().Get("start")
	endStr := r.URL.Query().Get("end")

	// Only require start and end parameters
	if startStr == "" || endStr == "" {
		http.Error(w, "start and end parameters are required", http.StatusBadRequest)
		return
	}

	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if s.metricsManager == nil {
		log.Printf("Metrics manager not configured for poller %s", pollerID)
		http.Error(w, "Metrics not configured", http.StatusInternalServerError)
		return
	}

	// Try to cast the metrics manager to a DB interface that supports GetAllDiskMetrics
	dbMetricsProvider, ok := s.metricsManager.(interface {
		GetAllDiskMetrics(pollerID string, start, end time.Time) ([]models.DiskMetric, error)
		GetDiskMetrics(pollerID, mountPoint string, start, end time.Time) ([]models.DiskMetric, error)
	})

	if !ok {
		log.Printf("Metrics manager does not support required disk metrics methods for poller %s", pollerID)
		http.Error(w, "Disk metrics not supported", http.StatusInternalServerError)
		return
	}

	// Get disk metrics based on whether a mount point was specified
	var diskMetrics []models.DiskMetric

	if mountPoint != "" {
		// If mount point is specified, get metrics for that specific mount point
		log.Printf("Fetching disk metrics for poller %s, mount point %s", pollerID, mountPoint)
		diskMetrics, err = dbMetricsProvider.GetDiskMetrics(pollerID, mountPoint, startTime, endTime)
	} else {
		// If no mount point is specified, get metrics for all mount points
		log.Printf("Fetching disk metrics for all mount points for poller %s", pollerID)
		diskMetrics, err = dbMetricsProvider.GetAllDiskMetrics(pollerID, startTime, endTime)
	}

	if err != nil {
		log.Printf("Error fetching disk metrics for poller %s: %v", pollerID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	if len(diskMetrics) == 0 {
		log.Printf("No disk metrics found for poller %s", pollerID)
		http.Error(w, "No metrics found", http.StatusNotFound)
		return
	}

	// Format the response to match what the frontend expects
	// Group metrics by mount point, using the most recent data point for each
	mountPointMap := make(map[string]models.DiskMetric)
	latestTimestamp := diskMetrics[0].Timestamp

	for _, metric := range diskMetrics {
		// Track the latest timestamp
		if metric.Timestamp.After(latestTimestamp) {
			latestTimestamp = metric.Timestamp
		}

		// For each mount point, keep only the most recent metric
		existingMetric, ok := mountPointMap[metric.MountPoint]
		if !ok || metric.Timestamp.After(existingMetric.Timestamp) {
			mountPointMap[metric.MountPoint] = metric
		}
	}

	// Build the response in the format expected by the frontend
	disks := make([]map[string]interface{}, 0, len(mountPointMap))
	for _, metric := range mountPointMap {
		disks = append(disks, map[string]interface{}{
			"mount_point": metric.MountPoint,
			"used_bytes":  metric.UsedBytes,
			"total_bytes": metric.TotalBytes,
		})
	}

	response := map[string]interface{}{
		"disks":     disks,
		"timestamp": latestTimestamp.Format(time.RFC3339),
	}

	// Write the response
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("Error encoding disk metrics response for poller %s: %v", pollerID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	log.Printf("Successfully wrote disk metrics response for poller %s with %d mount points",
		pollerID, len(disks))
}

func (s *APIServer) getSysmonMemoryMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]
	startStr := r.URL.Query().Get("start")
	endStr := r.URL.Query().Get("end")

	if startStr == "" || endStr == "" {
		http.Error(w, "start and end parameters are required", http.StatusBadRequest)
		return
	}

	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if s.metricsManager == nil {
		log.Printf("Metrics manager not configured for poller %s", pollerID)
		http.Error(w, "Metrics not configured", http.StatusInternalServerError)
		return
	}

	structuredMetrics, ok := s.metricsManager.(metrics.StructuredMetricCollector)
	if !ok {
		log.Printf("Metrics manager does not support structured metrics for poller %s", pollerID)
		http.Error(w, "Structured metrics not supported", http.StatusInternalServerError)
		return
	}

	memoryMetrics, err := structuredMetrics.GetMemoryMetrics(pollerID, startTime, endTime)
	if err != nil {
		log.Printf("Error fetching memory metrics for poller %s: %v", pollerID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	if len(memoryMetrics) == 0 {
		log.Printf("No memory metrics found for poller %s", pollerID)
		http.Error(w, "No metrics found", http.StatusNotFound)
		return
	}

	// Use the most recent memory metric
	latestMetric := memoryMetrics[0]
	for _, metric := range memoryMetrics {
		if metric.Timestamp.After(latestMetric.Timestamp) {
			latestMetric = metric
		}
	}

	// Format response to match what the frontend expects
	response := map[string]interface{}{
		"memory": map[string]interface{}{
			"used_bytes":  latestMetric.UsedBytes,
			"total_bytes": latestMetric.TotalBytes,
		},
		"timestamp": latestMetric.Timestamp.Format(time.RFC3339),
	}

	// Write the response
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("Error encoding memory metrics response for poller %s: %v", pollerID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	log.Printf("Successfully wrote memory metrics response for poller %s", pollerID)
}
