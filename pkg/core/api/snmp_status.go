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
	"net/http"
	"time"
)

type snmpStatusRequest struct {
	DeviceIDs []string `json:"deviceIds"`
}

type snmpStatusResponse struct {
	Statuses map[string]struct {
		HasMetrics bool `json:"hasMetrics"`
	} `json:"statuses"`
}

// @Summary Get SNMP metrics status for multiple devices
// @Description Checks for the existence of recent SNMP metrics for a list of device IDs.
// @Tags Devices
// @Accept json
// @Produce json
// @Param body body snmpStatusRequest true "List of Device IDs to check"
// @Success 200 {object} snmpStatusResponse "A map of device IDs to their SNMP metrics status"
// @Failure 400 {object} models.ErrorResponse "Invalid request body"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/devices/snmp/status [post]
// @Security ApiKeyAuth
func (s *APIServer) getDeviceSNMPStatus(w http.ResponseWriter, r *http.Request) {
	var req snmpStatusRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	if len(req.DeviceIDs) == 0 {
		writeError(w, "deviceIds array cannot be empty", http.StatusBadRequest)
		return
	}

	const snmpStatusTimeout = 15 * time.Second

	ctx, cancel := context.WithTimeout(r.Context(), snmpStatusTimeout)
	defer cancel()

	if s.dbService == nil {
		writeError(w, "Database not configured", http.StatusInternalServerError)
		return
	}

	// Delegate the database check to a new method
	devicesWithMetrics, err := s.dbService.GetDevicesWithRecentSNMPMetrics(ctx, req.DeviceIDs)
	if err != nil {
		s.logger.Error().Err(err).Msg("Error checking for recent SNMP metrics")
		writeError(w, "Failed to check SNMP status", http.StatusInternalServerError)

		return
	}

	// Build the response map
	response := snmpStatusResponse{
		Statuses: make(map[string]struct {
			HasMetrics bool `json:"hasMetrics"`
		}),
	}

	for _, deviceID := range req.DeviceIDs {
		response.Statuses[deviceID] = struct {
			HasMetrics bool `json:"hasMetrics"`
		}{
			HasMetrics: devicesWithMetrics[deviceID],
		}
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(response); err != nil {
		s.logger.Error().Err(err).Msg("Error encoding SNMP status response")
		writeError(w, "Failed to encode response", http.StatusInternalServerError)
	}
}
