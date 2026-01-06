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
	"context"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

func (s *Server) ensureServiceDevice(
	ctx context.Context,
	agentID, gatewayID, partition string,
	svc *proto.GatewayServiceStatus,
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

	// Check if the reported host_ip matches the collector's (agent/gateway) registered IP.
	// If so, skip device creation - this is the collector itself, not a monitoring target.
	collectorIP := s.getCollectorIP(ctx, agentID, gatewayID)
	if collectorIP != "" && hostIP == collectorIP {
		s.logger.Debug().
			Str("host_ip", hostIP).
			Str("collector_ip", collectorIP).
			Str("agent_id", agentID).
			Str("gateway_id", gatewayID).
			Str("service_name", svc.ServiceName).
			Msg("Skipping device creation: host_ip matches collector IP (this is the collector, not a target)")
		return
	}

	// Also skip if the IP is in a common Docker bridge network range and matches agent/gateway characteristics.
	// This catches cases where the collector IP couldn't be looked up but the IP is clearly ephemeral.
	if s.isEphemeralCollectorIP(hostIP, hostname, hostID) {
		s.logger.Debug().
			Str("host_ip", hostIP).
			Str("hostname", hostname).
			Str("host_id", hostID).
			Str("service_name", svc.ServiceName).
			Msg("Skipping device creation: detected ephemeral collector IP with agent/gateway hostname")
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

	if gatewayID != "" {
		metadata["collector_gateway_id"] = gatewayID
	}

	if hostID != "" {
		metadata["checker_host_id"] = hostID
	}

	metadata["checker_host_ip"] = hostIP

	deviceUpdate := &models.DeviceUpdate{
		AgentID:     agentID,
		GatewayID:   gatewayID,
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

	capabilities := normalizeCapabilities([]string{svc.ServiceType, svc.ServiceName})
	s.upsertCollectorCapabilities(ctx, deviceID, capabilities, agentID, gatewayID, svc.ServiceName, timestamp)

	eventMetadata := map[string]any{
		"agent_id":             agentID,
		"gateway_id":           gatewayID,
		"partition":            partition,
		"checker_service":      svc.ServiceName,
		"checker_service_type": svc.ServiceType,
		"checker_host_ip":      hostIP,
	}
	if hostID != "" {
		eventMetadata["checker_host_id"] = hostID
	}
	if hostname != "" {
		eventMetadata["checker_hostname"] = hostname
	}

	for _, capability := range capabilities {
		s.recordCapabilityEvent(context.Background(), &capabilityEventInput{
			DeviceID:    deviceID,
			Capability:  capability,
			ServiceID:   svc.ServiceName,
			ServiceType: svc.ServiceType,
			RecordedBy:  gatewayID,
			Enabled:     true,
			Success:     true,
			CheckedAt:   timestamp,
			Metadata:    eventMetadata,
		})
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

// getCollectorIP retrieves the registered IP address for the agent or gateway that is running the checker.
// This is used to detect when a checker is reporting its own collector's IP rather than a monitoring target.
func (s *Server) getCollectorIP(ctx context.Context, agentID, gatewayID string) string {
	// Try to get the agent's IP from the service registry
	if agentID != "" && s.ServiceRegistry != nil {
		if agent, err := s.ServiceRegistry.GetAgent(ctx, agentID); err == nil && agent != nil {
			if ip := extractIPFromMetadata(agent.Metadata); ip != "" {
				return ip
			}
		}
	}

	// Fall back to gateway's IP
	if gatewayID != "" && s.ServiceRegistry != nil {
		if gateway, err := s.ServiceRegistry.GetGateway(ctx, gatewayID); err == nil && gateway != nil {
			if ip := extractIPFromMetadata(gateway.Metadata); ip != "" {
				return ip
			}
		}
	}

	// Try the database as a last resort
	if gatewayID != "" && s.DB != nil {
		if status, err := s.DB.GetGatewayStatus(ctx, gatewayID); err == nil && status != nil {
			if ip := normalizeHostIP(status.HostIP); ip != "" {
				return ip
			}
		}
	}

	return ""
}

// extractIPFromMetadata extracts an IP address from service metadata.
func extractIPFromMetadata(metadata map[string]string) string {
	if metadata == nil {
		return ""
	}

	// Try common metadata keys for IP
	for _, key := range []string{"source_ip", "host_ip", "ip"} {
		if ip := normalizeHostIP(metadata[key]); ip != "" {
			return ip
		}
	}

	return ""
}

// isEphemeralCollectorIP checks if the given IP appears to be an ephemeral container IP
// belonging to the collector (agent/gateway) rather than a monitoring target.
// This is a heuristic to catch phantom devices when the collector IP lookup fails.
func (s *Server) isEphemeralCollectorIP(hostIP, hostname, hostID string) bool {
	// Check if IP is in common Docker bridge network ranges
	if !isDockerBridgeIP(hostIP) {
		return false
	}

	// Check if hostname suggests this is an agent or gateway
	lowerHostname := strings.ToLower(hostname)
	lowerHostID := strings.ToLower(hostID)

	collectorIndicators := []string{"agent", "gateway", "collector"}
	for _, indicator := range collectorIndicators {
		if strings.Contains(lowerHostname, indicator) || strings.Contains(lowerHostID, indicator) {
			return true
		}
	}

	// Also catch empty/generic hostnames with Docker IPs
	if hostname == "" || lowerHostname == statusUnknown || lowerHostname == "localhost" {
		return true
	}

	return false
}

// isDockerBridgeIP checks if an IP is in common Docker bridge network ranges.
func isDockerBridgeIP(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}

	// Common Docker bridge network ranges
	dockerCIDRs := []string{
		"172.17.0.0/16", // Default docker0 bridge
		"172.18.0.0/16", // Docker compose default
		"172.19.0.0/16", // Additional compose networks
		"172.20.0.0/16", // Additional compose networks
		"172.21.0.0/16", // Additional compose networks
	}

	for _, cidr := range dockerCIDRs {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			continue
		}
		if network.Contains(ip) {
			return true
		}
	}

	return false
}

// createSNMPTargetDeviceUpdate creates a DeviceUpdate for an SNMP target device.
// This ensures SNMP targets appear in the unified devices view and can be merged with other discovery sources.
func (s *Server) createSNMPTargetDeviceUpdate(
	agentID, gatewayID, partition, targetIP, hostname string, timestamp time.Time, available bool) *models.DeviceUpdate {
	if targetIP == "" {
		s.logger.Debug().
			Str("agent_id", agentID).
			Str("gateway_id", gatewayID).
			Str("partition", partition).
			Str("target_ip", targetIP).
			Msg("Skipping SNMP target device update due to empty target IP")

		return nil
	}

	deviceID := fmt.Sprintf("%s:%s", partition, targetIP)

	s.logger.Debug().
		Str("agent_id", agentID).
		Str("gateway_id", gatewayID).
		Str("partition", partition).
		Str("target_ip", targetIP).
		Str("device_id", deviceID).
		Str("hostname", hostname).
		Msg("Creating SNMP target device update")

	return &models.DeviceUpdate{
		AgentID:     agentID,
		GatewayID:   gatewayID,
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
