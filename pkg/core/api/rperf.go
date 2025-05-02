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

// Package api provides the HTTP API server for ServiceRadar
package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/gorilla/mux"
)

// @Summary Get rperf metrics
// @Description Retrieves network performance metrics measured by rperf for a specific poller within a time range
// @Tags Rperf
// @Accept json
// @Produce json
// @Param id path string true "Poller ID"
// @Param start query string false "Start time in RFC3339 format (default: 24h ago)"
// @Param end query string false "End time in RFC3339 format (default: now)"
// @Success 200 {array} models.RperfMetric "Network performance metrics data"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 404 {object} models.ErrorResponse "No rperf metrics found"
// @Failure 500 {object} models.ErrorResponse "Internal server error or rperf manager not configured"
// @Router /pollers/{id}/rperf [get]
// @Security ApiKeyAuth
func (s *APIServer) getRperfMetrics(w http.ResponseWriter, r *http.Request) {
	pollerID := mux.Vars(r)["id"]

	// set a context with a timeout of 10 seconds
	ctx, cancel := context.WithTimeout(r.Context(), defaultTimeout)
	defer cancel()

	if s.rperfManager == nil {
		writeError(w, "Rperf manager not configured", http.StatusInternalServerError)
		return
	}

	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		writeError(w, err.Error(), http.StatusBadRequest)
		return
	}

	log.Printf("Querying rperf metrics for poller %s from %s to %s",
		pollerID, startTime.Format(time.RFC3339), endTime.Format(time.RFC3339))

	resp := s.processRperfMetrics(ctx, pollerID, startTime, endTime)
	if resp.Err != nil {
		writeError(w, "Failed to fetch rperf metrics", http.StatusInternalServerError)
		return
	}

	if len(resp.Metrics) == 0 {
		writeError(w, "No rperf metrics found", http.StatusNotFound)
		return
	}

	writeJSONResponse(w, resp.Metrics, pollerID)
}

// processRperfMetrics fetches and processes rperf metrics for a poller.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func (s *APIServer) processRperfMetrics(
	ctx context.Context, pollerID string, startTime, endTime time.Time) models.RperfMetricResponse {
	rperfMetrics, err := s.rperfManager.GetRperfMetrics(ctx, pollerID, startTime, endTime)
	if err != nil {
		log.Printf("Error fetching rperf metrics for poller %s: %v", pollerID, err)

		return models.RperfMetricResponse{Err: err}
	}

	response := convertToAPIMetrics(rperfMetrics, pollerID)

	return models.RperfMetricResponse{Metrics: response}
}

// convertToAPIMetrics converts db.TimeseriesMetric to RperfMetric.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func convertToAPIMetrics(rperfMetrics []*db.TimeseriesMetric, pollerID string) []models.RperfMetric {
	response := make([]models.RperfMetric, 0, len(rperfMetrics))

	for _, rm := range rperfMetrics {
		metric := models.RperfMetric{
			Timestamp: rm.Timestamp,
			Name:      rm.Name,
		}

		// Handle metadata based on its actual type
		var metadata map[string]interface{}

		switch md := rm.Metadata.(type) {
		case map[string]interface{}:
			// If it's already a map, use it directly
			metadata = md
		case json.RawMessage:
			// If it's a json.RawMessage, unmarshal it
			if err := json.Unmarshal(md, &metadata); err != nil {
				log.Printf("Error unmarshaling json.RawMessage metadata for metric %s on poller %s: %v",
					rm.Name, pollerID, err)

				continue
			}
		default:
			// For any other type, log the error and skip
			log.Printf("Unsupported metadata type for metric %s on poller %s: %T",
				rm.Name, pollerID, rm.Metadata)

			continue
		}

		// Now that we have a map of metadata, populate the metric fields
		populateMetricFields(&metric, metadata)

		response = append(response, metric)
	}

	return response
}

// populateMetricFields populates an RperfMetric from metadata.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func populateMetricFields(metric *models.RperfMetric, metadata map[string]interface{}) {
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

// setStringField sets a string field from metadata.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func setStringField(field *string, metadata map[string]interface{}, key string) {
	if val, ok := metadata[key].(string); ok {
		*field = val
	}
}

// setBoolField sets a boolean field from metadata.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func setBoolField(field *bool, metadata map[string]interface{}, key string) {
	if val, ok := metadata[key].(bool); ok {
		*field = val
	}
}

// setErrorField sets an error field from metadata.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
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

// setFloat64Field sets a float64 field from metadata.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func setFloat64Field(field *float64, metadata map[string]interface{}, key string) {
	if val, ok := metadata[key].(float64); ok {
		*field = val
	}
}

// setInt64Field sets an int64 field from metadata.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func setInt64Field(field *int64, metadata map[string]interface{}, key string) {
	if val, ok := metadata[key].(float64); ok {
		*field = int64(val)
	}
}
