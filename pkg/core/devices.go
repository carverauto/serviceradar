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

package core

import (
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

func (s *Server) ensureServiceDevice(
	agentID, pollerID, partition string,
	svc *proto.ServiceStatus,
	serviceData json.RawMessage,
	timestamp time.Time,
) {
	if svc == nil {
		return
	}

	// Only gRPC checkers embed host context in a way we can reason about; skip other service types.
	if svc.ServiceType != grpcServiceType {
		return
	}

	// Ignore result streams such as sync/multi-part responses; they set Source to "results".
	if strings.EqualFold(svc.Source, "results") {
		return
	}

	hostIP, hostname, hostID := extractCheckerHostIdentity(serviceData)
	hostIP = normalizeHostIdentifier(hostIP)
	if hostIP == "" || strings.EqualFold(hostIP, "unknown") {
		return
	}

	if partition == "" {
		partition = "default"
	}

	deviceID := fmt.Sprintf("%s:%s", partition, hostIP)

	metadata := map[string]string{
		"source":             "checker",
		"checker_service":    svc.ServiceName,
		"checker_service_id": svc.ServiceName,
		"last_update":        timestamp.Format(time.RFC3339),
	}

	if svc.ServiceType != "" {
		metadata["checker_service_type"] = svc.ServiceType
	}

	if agentID != "" {
		metadata["collector_agent_id"] = agentID
	}

	if pollerID != "" {
		metadata["collector_poller_id"] = pollerID
	}

	if hostID != "" {
		metadata["checker_host_id"] = hostID
	}

	metadata["checker_host_ip"] = hostIP

	deviceUpdate := &models.DeviceUpdate{
		AgentID:     agentID,
		PollerID:    pollerID,
		Partition:   partition,
		DeviceID:    deviceID,
		Source:      models.DiscoverySourceSelfReported,
		IP:          hostIP,
		Timestamp:   timestamp,
		IsAvailable: true,
		Metadata:    metadata,
		Confidence:  models.GetSourceConfidence(models.DiscoverySourceSelfReported),
	}

	if hostname != "" {
		deviceUpdate.Hostname = &hostname
	}

	if s.DeviceRegistry != nil {
		s.enqueueServiceDeviceUpdate(deviceUpdate)
	} else {
		s.logger.Warn().
			Str("device_id", deviceID).
			Str("service_name", svc.ServiceName).
			Msg("DeviceRegistry not available for checker device registration")
	}
}

func extractCheckerHostIdentity(serviceData json.RawMessage) (hostIP, hostname, hostID string) {
	if len(serviceData) == 0 {
		return "", "", ""
	}

	var payload any
	if err := json.Unmarshal(serviceData, &payload); err != nil {
		return "", "", ""
	}

	hostIP = firstStringMatch(payload,
		[]string{"status", "host_ip"},
		[]string{"status", "ip"},
		[]string{"status", "ip_address"},
		[]string{"host_ip"},
		[]string{"ip"},
		[]string{"ip_address"},
	)
	if hostIP == "" {
		hostIP = findStringByKeySubstring(payload, "ip")
	}

	hostID = firstStringMatch(payload,
		[]string{"status", "host_id"},
		[]string{"host_id"},
	)

	hostname = firstStringMatch(payload,
		[]string{"status", "hostname"},
		[]string{"status", "host_name"},
		[]string{"hostname"},
		[]string{"host_name"},
	)

	if hostname == "" {
		hostname = hostID
	}

	return hostIP, hostname, hostID
}

func firstStringMatch(node any, paths ...[]string) string {
	for _, path := range paths {
		if value, ok := traverseForString(node, path); ok {
			return value
		}
	}

	return ""
}

func traverseForString(node any, path []string) (string, bool) {
	if len(path) == 0 {
		if str, ok := node.(string); ok {
			trimmed := strings.TrimSpace(str)
			if trimmed != "" {
				return trimmed, true
			}
		}
		return "", false
	}

	switch typed := node.(type) {
	case map[string]any:
		next, ok := typed[path[0]]
		if !ok {
			return "", false
		}
		return traverseForString(next, path[1:])
	case []any:
		for _, item := range typed {
			if value, ok := traverseForString(item, path); ok {
				return value, true
			}
		}
	}

	return "", false
}

func findStringByKeySubstring(node any, substring string) string {
	switch typed := node.(type) {
	case map[string]any:
		for key, value := range typed {
			if strings.Contains(strings.ToLower(key), substring) {
				if str, ok := value.(string); ok && strings.TrimSpace(str) != "" {
					return strings.TrimSpace(str)
				}
			}

			if nested := findStringByKeySubstring(value, substring); nested != "" {
				return nested
			}
		}
	case []any:
		for _, item := range typed {
			if nested := findStringByKeySubstring(item, substring); nested != "" {
				return nested
			}
		}
	}

	return ""
}

func normalizeHostIdentifier(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}

	if host, _, err := net.SplitHostPort(value); err == nil {
		return host
	}

	if strings.HasPrefix(value, "[") && strings.Contains(value, "]") {
		trimmed := strings.TrimSuffix(strings.TrimPrefix(value, "["), "]")
		if trimmed != "" {
			return trimmed
		}
	}

	return value
}

func (s *Server) enqueueServiceDeviceUpdate(update *models.DeviceUpdate) {
	if update == nil {
		return
	}

	cloned := cloneDeviceUpdate(update)

	s.serviceDeviceMu.Lock()
	defer s.serviceDeviceMu.Unlock()

	if s.serviceDeviceBuffer == nil {
		s.serviceDeviceBuffer = make(map[string]*models.DeviceUpdate)
	}

	if existing, ok := s.serviceDeviceBuffer[cloned.DeviceID]; ok {
		if existing.Timestamp.After(cloned.Timestamp) {
			return
		}
	}

	s.serviceDeviceBuffer[cloned.DeviceID] = cloned
}

func cloneDeviceUpdate(update *models.DeviceUpdate) *models.DeviceUpdate {
	if update == nil {
		return nil
	}

	cloned := *update

	if update.Hostname != nil {
		hostname := *update.Hostname
		cloned.Hostname = &hostname
	}

	if update.MAC != nil {
		mac := *update.MAC
		cloned.MAC = &mac
	}

	if update.Metadata != nil {
		cloned.Metadata = make(map[string]string, len(update.Metadata))
		for k, v := range update.Metadata {
			cloned.Metadata[k] = v
		}
	}

	return &cloned
}

// createSNMPTargetDeviceUpdate creates a DeviceUpdate for an SNMP target device.
// This ensures SNMP targets appear in the unified devices view and can be merged with other discovery sources.
func (s *Server) createSNMPTargetDeviceUpdate(
	agentID, pollerID, partition, targetIP, hostname string, timestamp time.Time, available bool) *models.DeviceUpdate {
	if targetIP == "" {
		s.logger.Debug().
			Str("agent_id", agentID).
			Str("poller_id", pollerID).
			Str("partition", partition).
			Str("target_ip", targetIP).
			Msg("Skipping SNMP target device update due to empty target IP")

		return nil
	}

	deviceID := fmt.Sprintf("%s:%s", partition, targetIP)

	s.logger.Debug().
		Str("agent_id", agentID).
		Str("poller_id", pollerID).
		Str("partition", partition).
		Str("target_ip", targetIP).
		Str("device_id", deviceID).
		Str("hostname", hostname).
		Msg("Creating SNMP target device update")

	return &models.DeviceUpdate{
		AgentID:     agentID,
		PollerID:    pollerID,
		Partition:   partition,
		Source:      models.DiscoverySourceSNMP,
		IP:          targetIP,
		DeviceID:    deviceID,
		Hostname:    &hostname,
		Timestamp:   timestamp,
		IsAvailable: available,
		Metadata: map[string]string{
			"source":          "snmp-target",
			"snmp_monitoring": "active",
			"last_poll":       timestamp.Format(time.RFC3339),
		},
	}
}
