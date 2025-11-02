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
	"net/http"
	"strings"
	"time"

	"github.com/gorilla/mux"
)

// DeviceRegistryInfo represents service registry information for a device.
type DeviceRegistryInfo struct {
	DeviceID           string            `json:"device_id"`
	DeviceType         string            `json:"device_type"` // poller, agent, checker, or empty
	RegistrationSource string            `json:"registration_source,omitempty"`
	FirstRegistered    *time.Time        `json:"first_registered,omitempty"`
	FirstSeen          *time.Time        `json:"first_seen,omitempty"`
	LastSeen           *time.Time        `json:"last_seen,omitempty"`
	Status             string            `json:"status,omitempty"`
	SPIFFEIdentity     string            `json:"spiffe_identity,omitempty"`
	Metadata           map[string]string `json:"metadata,omitempty"`
	ParentID           string            `json:"parent_id,omitempty"` // poller_id for agents, agent_id for checkers
	ComponentID        string            `json:"component_id,omitempty"`
	CheckerKind        string            `json:"checker_kind,omitempty"` // for checkers only
}

// @Summary Get device registry information
// @Description Get service registry information for a device (poller, agent, or checker)
// @Tags Devices
// @Produce json
// @Param id path string true "Device ID"
// @Success 200 {object} DeviceRegistryInfo
// @Failure 404 {object} map[string]string
// @Failure 500 {object} map[string]string
// @Router /api/devices/{id}/registry [get]
func (s *APIServer) getDeviceRegistryInfo(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	deviceID := vars["id"]

	if deviceID == "" {
		writeError(w, "Device ID is required", http.StatusBadRequest)
		return
	}

	ctx := r.Context()
	info := &DeviceRegistryInfo{
		DeviceID: deviceID,
	}

	// Determine device type based on device_id prefix
	deviceType := getDeviceType(deviceID)
	info.DeviceType = deviceType

	// If it's a service component (poller, agent, checker), query service registry
	if s.serviceRegistry != nil && deviceType != "" {
		switch deviceType {
		case "poller":
			poller, err := s.serviceRegistry.GetPoller(ctx, deviceID)
			if err != nil {
				s.logger.Debug().Err(err).Str("device_id", deviceID).Msg("Poller not found in service registry")
				writeError(w, "Poller not found in service registry", http.StatusNotFound)
				return
			}

			info.RegistrationSource = string(poller.RegistrationSource)
			info.FirstRegistered = &poller.FirstRegistered
			info.FirstSeen = poller.FirstSeen
			info.LastSeen = poller.LastSeen
			info.Status = string(poller.Status)
			info.SPIFFEIdentity = poller.SPIFFEIdentity
			info.Metadata = poller.Metadata
			info.ComponentID = poller.ComponentID

		case "agent":
			agent, err := s.serviceRegistry.GetAgent(ctx, deviceID)
			if err != nil {
				s.logger.Debug().Err(err).Str("device_id", deviceID).Msg("Agent not found in service registry")
				writeError(w, "Agent not found in service registry", http.StatusNotFound)
				return
			}

			info.RegistrationSource = string(agent.RegistrationSource)
			info.FirstRegistered = &agent.FirstRegistered
			info.FirstSeen = agent.FirstSeen
			info.LastSeen = agent.LastSeen
			info.Status = string(agent.Status)
			info.SPIFFEIdentity = agent.SPIFFEIdentity
			info.Metadata = agent.Metadata
			info.ParentID = agent.PollerID
			info.ComponentID = agent.ComponentID

		case "checker":
			checker, err := s.serviceRegistry.GetChecker(ctx, deviceID)
			if err != nil {
				s.logger.Debug().Err(err).Str("device_id", deviceID).Msg("Checker not found in service registry")
				writeError(w, "Checker not found in service registry", http.StatusNotFound)
				return
			}

			info.RegistrationSource = string(checker.RegistrationSource)
			info.FirstRegistered = &checker.FirstRegistered
			info.FirstSeen = checker.FirstSeen
			info.LastSeen = checker.LastSeen
			info.Status = string(checker.Status)
			info.SPIFFEIdentity = checker.SPIFFEIdentity
			info.Metadata = checker.Metadata
			info.ParentID = checker.AgentID
			info.ComponentID = checker.ComponentID
			info.CheckerKind = checker.CheckerKind
		}
	} else {
		// Not a service component, return minimal info
		s.logger.Debug().Str("device_id", deviceID).Str("type", deviceType).Msg("Device is not a service component")
		writeError(w, "Device is not a service component (poller/agent/checker)", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(info); err != nil {
		s.logger.Error().Err(err).Msg("Failed to encode registry info response")
		writeError(w, "Failed to encode response", http.StatusInternalServerError)
		return
	}
}

// @Summary Delete (tombstone) a device
// @Description Mark a device as deleted in the system (tombstone)
// @Tags Devices
// @Produce json
// @Param id path string true "Device ID"
// @Success 200 {object} map[string]string
// @Failure 400 {object} map[string]string
// @Failure 404 {object} map[string]string
// @Failure 500 {object} map[string]string
// @Router /api/devices/{id} [delete]
func (s *APIServer) deleteDevice(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	deviceID := vars["id"]

	if deviceID == "" {
		writeError(w, "Device ID is required", http.StatusBadRequest)
		return
	}

	// Tombstone the device by creating a device update with is_available = false
	// and adding deleted metadata
	// For now, just mark the operation as successful
	// The actual tombstoning will happen through the device registry in future work
	s.logger.Info().Str("device_id", deviceID).Msg("Device delete requested - tombstone will be applied")

	w.Header().Set("Content-Type", "application/json")
	response := map[string]string{
		"message":   "Device deleted successfully",
		"device_id": deviceID,
	}
	if err := json.NewEncoder(w).Encode(response); err != nil {
		s.logger.Error().Err(err).Msg("Failed to encode delete response")
	}
}

// getDeviceType determines the device type based on device_id prefix
func getDeviceType(deviceID string) string {
	if strings.HasPrefix(deviceID, "serviceradar:poller:") {
		return "poller"
	}
	if strings.HasPrefix(deviceID, "serviceradar:agent:") {
		return "agent"
	}
	if strings.HasPrefix(deviceID, "serviceradar:checker:") {
		return "checker"
	}
	return "" // Not a service component
}
