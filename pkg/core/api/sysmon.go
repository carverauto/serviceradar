package api

import (
	"log"
	"net/http"
	"strconv"

	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/gorilla/mux"
)

func (s *APIServer) getSysmonCPUMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)

	pollerID := vars["id"]

	coreIDStr := r.URL.Query().Get("core_id")
	startStr := r.URL.Query().Get("start")
	endStr := r.URL.Query().Get("end")

	if coreIDStr == "" || startStr == "" || endStr == "" {
		http.Error(w, "core_id, start, and end parameters are required", http.StatusBadRequest)

		return
	}

	coreID, err := strconv.Atoi(coreIDStr)
	if err != nil {
		http.Error(w, "Invalid core_id format", http.StatusBadRequest)

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

	// Cast to StructuredMetricCollector
	structuredMetrics, ok := s.metricsManager.(metrics.StructuredMetricCollector)
	if !ok {
		log.Printf("Metrics manager does not support structured cpuMetrics for poller %s", pollerID)
		http.Error(w, "Structured cpuMetrics not supported", http.StatusInternalServerError)

		return
	}

	cpuMetrics, err := structuredMetrics.GetCPUMetrics(pollerID, coreID, startTime, endTime)
	if err != nil {
		log.Printf("Error fetching CPU cpuMetrics for poller %s, core %d: %v", pollerID, coreID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)

		return
	}

	if len(cpuMetrics) == 0 {
		log.Printf("No CPU cpuMetrics found for poller %s, core %d", pollerID, coreID)
		http.Error(w, "No cpuMetrics found", http.StatusNotFound)

		return
	}

	writeJSONResponse(w, cpuMetrics, pollerID)
}

func (s *APIServer) getSysmonDiskMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]
	mountPoint := r.URL.Query().Get("mount_point")
	startStr := r.URL.Query().Get("start")
	endStr := r.URL.Query().Get("end")

	if mountPoint == "" || startStr == "" || endStr == "" {
		http.Error(w, "mount_point, start, and end parameters are required", http.StatusBadRequest)

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
		log.Printf("Metrics manager does not support structured diskMetrics for poller %s", pollerID)
		http.Error(w, "Structured diskMetrics not supported", http.StatusInternalServerError)

		return
	}

	diskMetrics, err := structuredMetrics.GetDiskMetrics(pollerID, mountPoint, startTime, endTime)
	if err != nil {
		log.Printf("Error fetching disk diskMetrics for poller %s, mount %s: %v", pollerID, mountPoint, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)

		return
	}

	if len(diskMetrics) == 0 {
		log.Printf("No disk diskMetrics found for poller %s, mount %s", pollerID, mountPoint)
		http.Error(w, "No diskMetrics found", http.StatusNotFound)

		return
	}

	writeJSONResponse(w, diskMetrics, pollerID)
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
		log.Printf("Metrics manager does not support structured memoryMetrics for poller %s", pollerID)
		http.Error(w, "Structured memoryMetrics not supported", http.StatusInternalServerError)

		return
	}

	memoryMetrics, err := structuredMetrics.GetMemoryMetrics(pollerID, startTime, endTime)
	if err != nil {
		log.Printf("Error fetching memory memoryMetrics for poller %s: %v", pollerID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)

		return
	}

	if len(memoryMetrics) == 0 {
		log.Printf("No memory memoryMetrics found for poller %s", pollerID)
		http.Error(w, "No memoryMetrics found", http.StatusNotFound)

		return
	}

	writeJSONResponse(w, memoryMetrics, pollerID)
}
