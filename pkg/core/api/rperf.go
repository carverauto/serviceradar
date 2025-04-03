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
	"net/url"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/gorilla/mux"
)

var (
	// ErrInvalidStartTimeFormat is returned when the start time format is invalid.
	ErrInvalidStartTimeFormat = errors.New("invalid start time format")
	// ErrInvalidEndTimeFormat is returned when the end time format is invalid.
	ErrInvalidEndTimeFormat = errors.New("invalid end time format")
)

func (s *APIServer) getRperfMetrics(w http.ResponseWriter, r *http.Request) {
	nodeID := mux.Vars(r)["id"]

	if s.rperfManager == nil {
		writeError(w, "Rperf manager not configured", http.StatusInternalServerError, nodeID)

		return
	}

	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		writeError(w, err.Error(), http.StatusBadRequest, nodeID)

		return
	}

	log.Printf("Querying rperf metrics for node %s from %s to %s",
		nodeID, startTime.Format(time.RFC3339), endTime.Format(time.RFC3339))

	resp := s.processRperfMetrics(nodeID, startTime, endTime)
	if resp.Err != nil {
		writeError(w, "Failed to fetch rperf metrics", http.StatusInternalServerError, nodeID)

		return
	}

	if len(resp.Metrics) == 0 {
		writeError(w, "No rperf metrics found", http.StatusNotFound, nodeID)

		return
	}

	writeJSONResponse(w, resp.Metrics, nodeID)
}

// parseTimeRange parses start and end times from query parameters.
func parseTimeRange(query url.Values) (start, end time.Time, err error) {
	startStr := query.Get("start")
	endStr := query.Get("end")

	start = time.Now().Add(-24 * time.Hour)
	end = time.Now()

	if startStr != "" {
		t, err := time.Parse(time.RFC3339, startStr)
		if err != nil {
			return time.Time{}, time.Time{}, ErrInvalidStartTimeFormat
		}

		start = t
	}

	if endStr != "" {
		t, err := time.Parse(time.RFC3339, endStr)
		if err != nil {
			return time.Time{}, time.Time{}, ErrInvalidEndTimeFormat
		}

		end = t
	}

	return start, end, nil
}

func (s *APIServer) processRperfMetrics(nodeID string, startTime, endTime time.Time) RperfMetricResponse {
	rperfMetrics, err := s.rperfManager.GetRperfMetrics(nodeID, startTime, endTime)
	if err != nil {
		log.Printf("Error fetching rperf metrics for node %s: %v", nodeID, err)

		return RperfMetricResponse{Err: err}
	}

	response := convertToAPIMetrics(rperfMetrics, nodeID)

	return RperfMetricResponse{Metrics: response}
}

// convertToAPIMetrics converts db.TimeseriesMetric to RperfMetric.
func convertToAPIMetrics(rperfMetrics []*db.TimeseriesMetric, nodeID string) []RperfMetric {
	response := make([]RperfMetric, 0, len(rperfMetrics))

	for _, rm := range rperfMetrics {
		metric := RperfMetric{
			Timestamp: rm.Timestamp,
			Name:      rm.Name,
		}

		// Declare metadata outside the if statement
		metadata, ok := rm.Metadata.(map[string]interface{})
		if !ok {
			log.Printf("Invalid metadata type for metric %s on node %s: %T", rm.Name, nodeID, rm.Metadata)

			continue
		}

		populateMetricFields(&metric, metadata)
		response = append(response, metric)
	}

	return response
}

// populateMetricFields populates an RperfMetric from metadata.
func populateMetricFields(metric *RperfMetric, metadata map[string]interface{}) {
	setStringField(&metric.Target, metadata, "target")
	setBoolField(&metric.Success, metadata, "success")
	setErrorField(&metric.Error, metadata, "error")
	setFloat64Field(&metric.BitsPerSecond, metadata, "bits_per_second")
	setInt64Field(&metric.BytesReceived, metadata, "bytes_received")
	setInt64Field(&metric.BytesSent, metadata, "bytes_sent")
	setFloat64Field(&metric.Duration, metadata, "duration")
	setFloat64Field(&metric.JitterMs, metadata, "jitter_ms")
	setFloat64Field(&metric.LossPercent, metadata, "loss_percent")
	setInt64Field(&metric.PacketsLost, metadata, "packets_lost")
	setInt64Field(&metric.PacketsReceived, metadata, "packets_received")
	setInt64Field(&metric.PacketsSent, metadata, "packets_sent")
}

func setStringField(field *string, metadata map[string]interface{}, key string) {
	if val, ok := metadata[key].(string); ok {
		*field = val
	}
}

func setBoolField(field *bool, metadata map[string]interface{}, key string) {
	if val, ok := metadata[key].(bool); ok {
		*field = val
	}
}

func setErrorField(field **string, metadata map[string]interface{}, key string) {
	if errVal, ok := metadata[key]; ok {
		switch v := errVal.(type) {
		case *string:
			*field = v
		case string:
			if v != "" {
				*field = &v
			}
		}
	}
}

func setFloat64Field(field *float64, metadata map[string]interface{}, key string) {
	if val, ok := metadata[key].(float64); ok {
		*field = val
	}
}

func setInt64Field(field *int64, metadata map[string]interface{}, key string) {
	if val, ok := metadata[key].(float64); ok {
		*field = int64(val)
	}
}

func writeError(w http.ResponseWriter, message string, status int, nodeID string) {
	log.Printf("%s for node %s", message, nodeID)

	http.Error(w, message, status)
}

func writeJSONResponse(w http.ResponseWriter, data interface{}, nodeID string) {
	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("Error encoding response for node %s: %v", nodeID, err)

		http.Error(w, "Internal server error", http.StatusInternalServerError)
	} else {
		log.Printf("Found %d rperf metrics for node %s", len(data.([]RperfMetric)), nodeID)
	}
}
