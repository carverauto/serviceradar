package api

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/gorilla/mux"
)

// getSysmonCPUMetrics handles CPU metrics requests
func (s *APIServer) getSysmonCPUMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]

	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	metricsProvider, ok := s.metricsManager.(db.SysmonMetricsProvider)
	if !ok {
		log.Printf("WARNING: Metrics manager does not implement SysmonMetricsProvider interface for poller %s", pollerID)
		http.Error(w, "System metrics not supported by this server", http.StatusNotImplemented)
		return
	}

	allMetrics, err := metricsProvider.GetAllCPUMetrics(pollerID, startTime, endTime)
	if err != nil {
		log.Printf("Error fetching all CPU metrics for poller %s: %v", pollerID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	if len(allMetrics) == 0 {
		http.Error(w, "No metrics found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(allMetrics); err != nil {
		log.Printf("Error encoding CPU metrics response: %v", err)
		http.Error(w, "Error encoding response", http.StatusInternalServerError)
	}
}

// getSysmonDiskMetrics handles requests for disk metrics with improved type checking
func (s *APIServer) getSysmonDiskMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]
	mountPoint := r.URL.Query().Get("mount_point")

	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	metricsProvider, ok := s.metricsManager.(db.SysmonMetricsProvider)
	if !ok {
		log.Printf("WARNING: Metrics manager does not implement SysmonMetricsProvider interface for poller %s", pollerID)
		http.Error(w, "System metrics not supported by this server", http.StatusNotImplemented)
		return
	}

	var response interface{}
	if mountPoint != "" {
		metrics, err := metricsProvider.GetDiskMetrics(pollerID, mountPoint, startTime, endTime)
		if err != nil {
			log.Printf("Error fetching disk metrics for poller %s, mount point %s: %v", pollerID, mountPoint, err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}

		if len(metrics) == 0 {
			http.Error(w, "No metrics found", http.StatusNotFound)
			return
		}

		response = metrics
	} else {
		allMetrics, err := metricsProvider.GetAllDiskMetricsGrouped(pollerID, startTime, endTime)
		if err != nil {
			log.Printf("Error fetching all disk metrics for poller %s: %v", pollerID, err)
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}

		if len(allMetrics) == 0 {
			http.Error(w, "No metrics found", http.StatusNotFound)
			return
		}

		response = allMetrics
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("Error encoding disk metrics response: %v", err)
		http.Error(w, "Error encoding response", http.StatusInternalServerError)
	}
}

// getSysmonMemoryMetrics handles requests for memory metrics with improved type checking
func (s *APIServer) getSysmonMemoryMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]

	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	metricsProvider, ok := s.metricsManager.(db.SysmonMetricsProvider)
	if !ok {
		log.Printf("WARNING: Metrics manager does not implement SysmonMetricsProvider interface for poller %s", pollerID)
		http.Error(w, "System metrics not supported by this server", http.StatusNotImplemented)
		return
	}

	memoryMetrics, err := metricsProvider.GetMemoryMetricsGrouped(pollerID, startTime, endTime)
	if err != nil {
		log.Printf("Error fetching memory metrics for poller %s: %v", pollerID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	if len(memoryMetrics) == 0 {
		http.Error(w, "No metrics found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(memoryMetrics); err != nil {
		log.Printf("Error encoding memory metrics response: %v", err)
		http.Error(w, "Error encoding response", http.StatusInternalServerError)
	}
}
