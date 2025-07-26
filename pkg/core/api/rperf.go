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
	"log"
	"net/http"
	"time"

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

	s.logger.Debug().
		Str("poller_id", pollerID).
		Str("start_time", startTime.Format(time.RFC3339)).
		Str("end_time", endTime.Format(time.RFC3339)).
		Msg("Querying rperf metrics")

	resp := s.processRperfMetrics(ctx, pollerID, startTime, endTime)
	if resp.Err != nil {
		writeError(w, "Failed to fetch rperf metrics", http.StatusInternalServerError)
		return
	}

	if len(resp.Metrics) == 0 {
		writeError(w, "No rperf metrics found", http.StatusNotFound)
		return
	}

	s.writeJSONResponse(w, resp.Metrics, pollerID)
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

	response := convertRperfMetricsToAPIMetrics(rperfMetrics)

	return models.RperfMetricResponse{Metrics: response}
}

// convertRperfMetricsToAPIMetrics converts []*models.RperfMetric to []models.RperfMetric.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func convertRperfMetricsToAPIMetrics(rperfMetrics []*models.RperfMetric) []models.RperfMetric {
	response := make([]models.RperfMetric, 0, len(rperfMetrics))

	for _, rm := range rperfMetrics {
		if rm != nil {
			response = append(response, *rm)
		}
	}

	return response
}
