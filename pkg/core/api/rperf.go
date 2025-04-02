package api

import (
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/gorilla/mux"
)

func (s *APIServer) getRperfMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	nodeID := vars["id"]

	if s.rperfManager == nil {
		log.Printf("Rperf manager not configured for node %s", nodeID)
		http.Error(w, "Rperf manager not configured", http.StatusInternalServerError)
		return
	}

	// Parse time range from query params
	startStr := r.URL.Query().Get("start")
	endStr := r.URL.Query().Get("end")
	startTime := time.Now().Add(-24 * time.Hour) // Default: last 24 hours
	endTime := time.Now()

	if startStr != "" {
		if t, err := time.Parse(time.RFC3339, startStr); err == nil {
			startTime = t
		} else {
			http.Error(w, "Invalid start time format", http.StatusBadRequest)
			return
		}
	}
	if endStr != "" {
		if t, err := time.Parse(time.RFC3339, endStr); err == nil {
			endTime = t
		} else {
			http.Error(w, "Invalid end time format", http.StatusBadRequest)
			return
		}
	}

	log.Printf("Querying rperf metrics for node %s from %s to %s", nodeID, startTime.Format(time.RFC3339), endTime.Format(time.RFC3339))

	// Fetch rperf metrics using the existing interface method
	rperfMetrics, err := s.rperfManager.GetRperfMetrics(nodeID, startTime, endTime)
	if err != nil {
		log.Printf("Error fetching rperf metrics for node %s: %v", nodeID, err)
		http.Error(w, "Failed to fetch rperf metrics", http.StatusInternalServerError)
		return
	}

	// Convert to API response format
	response := make([]RperfMetric, 0, len(rperfMetrics))
	for _, rm := range rperfMetrics {
		// Assert Metadata as map[string]interface{}
		metadata, ok := rm.Metadata.(map[string]interface{})
		if !ok {
			log.Printf("Invalid metadata type for metric %s on node %s: %T", rm.Name, nodeID, rm.Metadata)
			continue // Skip this metric if metadata is malformed
		}

		metric := RperfMetric{
			Timestamp: rm.Timestamp,
			Name:      rm.Name,
		}

		// Safely extract each field with type assertions
		if target, ok := metadata["target"].(string); ok {
			metric.Target = target
		}
		if success, ok := metadata["success"].(bool); ok {
			metric.Success = success
		}
		if errVal, ok := metadata["error"]; ok {
			if errStr, ok := errVal.(*string); ok {
				metric.Error = errStr
			} else if errStr, ok := errVal.(string); ok && errStr != "" {
				metric.Error = &errStr
			}
		}
		if bps, ok := metadata["bits_per_second"].(float64); ok {
			metric.BitsPerSecond = bps
		}
		if br, ok := metadata["bytes_received"].(float64); ok { // JSON numbers unmarshal as float64
			metric.BytesReceived = int64(br)
		}
		if bs, ok := metadata["bytes_sent"].(float64); ok {
			metric.BytesSent = int64(bs)
		}
		if d, ok := metadata["duration"].(float64); ok {
			metric.Duration = d
		}
		if j, ok := metadata["jitter_ms"].(float64); ok {
			metric.JitterMs = j
		}
		if lp, ok := metadata["loss_percent"].(float64); ok {
			metric.LossPercent = lp
		}
		if pl, ok := metadata["packets_lost"].(float64); ok {
			metric.PacketsLost = int64(pl)
		}
		if pr, ok := metadata["packets_received"].(float64); ok {
			metric.PacketsReceived = int64(pr)
		}
		if ps, ok := metadata["packets_sent"].(float64); ok {
			metric.PacketsSent = int64(ps)
		}

		response = append(response, metric)
	}

	if len(response) == 0 {
		log.Printf("No rperf metrics found for node %s in range %s to %s", nodeID, startTime, endTime)
		http.Error(w, "No rperf metrics found", http.StatusNotFound)
		return
	}

	log.Printf("Found %d rperf metrics for node %s", len(rperfMetrics), nodeID)

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("Error encoding rperf metrics response for node %s: %v", nodeID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}
