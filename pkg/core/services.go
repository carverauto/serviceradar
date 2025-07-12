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
	"log"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

func (s *Server) handleService(ctx context.Context, svc *api.ServiceStatus, partition string, now time.Time) error {
	if svc.Type == sweepService {
		if err := s.processSweepData(ctx, svc, partition, now); err != nil {
			return fmt.Errorf("failed to process sweep data: %w", err)
		}
	}

	return nil
}

func (s *Server) processSweepData(ctx context.Context, svc *api.ServiceStatus, partition string, now time.Time) error {
	// Extract enhanced payload if present, or use original data
	enhancedPayload, sweepMessage := s.extractServicePayload(svc.Message)

	// Update context from enhanced payload if available
	contextPollerID, contextPartition, contextAgentID := s.extractContextInfo(svc, enhancedPayload, partition)

	var sweepData struct {
		proto.SweepServiceStatus
		Hosts []models.HostResult `json:"hosts"`
	}

	if err := json.Unmarshal(sweepMessage, &sweepData); err != nil {
		return fmt.Errorf("%w: failed to unmarshal sweep data: %w", errInvalidSweepData, err)
	}

	// Validate and potentially correct timestamp
	if err := s.validateAndCorrectTimestamp(&sweepData, svc, now); err != nil {
		return err
	}

	// Process host results and create sweep results
	resultsToStore := s.processHostResults(sweepData.Hosts, contextPollerID, contextPartition, contextAgentID, now)

	if len(resultsToStore) > 0 {
		// Delegate directly to the new registry
		if err := s.DeviceRegistry.ProcessBatchSightings(ctx, resultsToStore); err != nil {
			log.Printf("Error processing batch sweep results: %v", err)
			return err
		}
	}

	return nil
}

// extractContextInfo extracts context information from service status and enhanced payload
func (*Server) extractContextInfo(
	svc *api.ServiceStatus,
	enhancedPayload *models.ServiceMetricsPayload,
	partition string) (pollerID, partitionID, agentID string) {
	pollerID = svc.PollerID
	partitionID = partition
	agentID = svc.AgentID

	if enhancedPayload != nil {
		pollerID = enhancedPayload.PollerID
		partitionID = enhancedPayload.Partition
		agentID = enhancedPayload.AgentID
	}

	return pollerID, partitionID, agentID
}

// validateAndCorrectTimestamp validates the sweep timestamp and corrects it if necessary
func (*Server) validateAndCorrectTimestamp(sweepData *struct {
	proto.SweepServiceStatus
	Hosts []models.HostResult `json:"hosts"`
}, svc *api.ServiceStatus, now time.Time) error {
	if sweepData.LastSweep > now.Add(oneDay).Unix() {
		log.Printf("Invalid or missing LastSweep timestamp (%d), using current time", sweepData.LastSweep)

		sweepData.LastSweep = now.Unix()

		updatedData := proto.SweepServiceStatus{
			Network:        sweepData.Network,
			TotalHosts:     sweepData.TotalHosts,
			AvailableHosts: sweepData.AvailableHosts,
			LastSweep:      now.Unix(),
		}

		updatedMessage, err := json.Marshal(&updatedData)
		if err != nil {
			return fmt.Errorf("failed to marshal updated sweep data: %w", err)
		}

		svc.Message = updatedMessage
	}

	return nil
}

func (*Server) createAPIService(svc *proto.ServiceStatus) api.ServiceStatus {
	apiService := api.ServiceStatus{
		Name:      svc.ServiceName,
		Type:      svc.ServiceType,
		Available: svc.Available,
		Message:   svc.Message,
		AgentID:   svc.AgentId,
		PollerID:  svc.PollerId,
	}

	// Parse the message to populate Details field for dashboard consumption
	// Handle enhanced payload wrapper for new architecture
	if len(svc.Message) > 0 {
		// Check if this is an enhanced payload by trying to parse it
		var enhancedPayload models.ServiceMetricsPayload
		if err := json.Unmarshal(svc.Message, &enhancedPayload); err == nil {
			// Check if it has the enhanced payload structure
			if enhancedPayload.PollerID != "" && enhancedPayload.AgentID != "" && len(enhancedPayload.Data) > 0 {
				// This is an enhanced payload - use the inner data for Details
				apiService.Details = enhancedPayload.Data
			} else {
				// Not an enhanced payload - use the entire message as details
				apiService.Details = svc.Message
			}
		} else {
			// Failed to parse as JSON - use as raw message
			apiService.Details = svc.Message
		}
	}

	return apiService
}

func (*Server) parseServiceDetails(svc *proto.ServiceStatus) (json.RawMessage, error) {
	var details json.RawMessage

	if err := json.Unmarshal(svc.Message, &details); err != nil {
		log.Printf("Error unmarshaling service details for %s: %v", svc.ServiceName, err)
		return nil, err
	}

	return details, nil
}

const (
	grpcServiceType   = "grpc"
	icmpServiceType   = "icmp"
	snmpServiceType   = "snmp"
	rperfServiceType  = "rperf-checker"
	sysmonServiceType = "sysmon"
	syncServiceType   = "sync"
)

// extractDeviceContext extracts device context for service correlation.
// For services like ping/icmp, this correlates them to the source device (agent).
// Returns the device_id and partition for the device that performed the service check.
func (*Server) extractDeviceContext(
	_ context.Context, agentID, defaultPartition, sourceIP, enhancedPayload string) (deviceID, partition string) {
	// First, try to parse the service message to check for a direct device_id field.
	// This handles ICMP and other service responses that now include device_id directly.
	var directMessage struct {
		DeviceID  string `json:"device_id,omitempty"`
		Partition string `json:"partition,omitempty"`
	}

	if err := json.Unmarshal([]byte(enhancedPayload), &directMessage); err == nil {
		if directMessage.DeviceID != "" {
			partition = directMessage.Partition
			if partition == "" {
				partition = defaultPartition
			}

			return directMessage.DeviceID, partition
		}
	}

	// Fallback to parsing the enhanced payload structure for backward compatibility or proxied checks.
	var payload struct {
		PollerID  string `json:"poller_id"`
		AgentID   string `json:"agent_id"`
		Partition string `json:"partition"`
		Data      struct {
			HostIP string `json:"host_ip,omitempty"`
		} `json:"data,omitempty"`
	}

	// Default to the partition from the gRPC request context.
	partition = defaultPartition

	if err := json.Unmarshal([]byte(enhancedPayload), &payload); err == nil {
		// The payload's partition takes precedence if provided.
		if payload.Partition != "" {
			partition = payload.Partition
		}
		// The payload's HostIP (for proxied checks) is the most specific identifier.
		if payload.Data.HostIP != "" {
			deviceID = fmt.Sprintf("%s:%s", partition, payload.Data.HostIP)
			return deviceID, partition
		}
	}

	// If the payload doesn't specify a device, the service is related to the agent that sent the report.
	// The sourceIP from the gRPC request is the most reliable identifier for this agent's device.
	if sourceIP != "" {
		deviceID = fmt.Sprintf("%s:%s", partition, sourceIP)
		return deviceID, partition
	}

	// If we've reached this point, sourceIP was empty, which is a critical configuration issue.
	log.Printf("CRITICAL: Unable to determine device_id for agent %s in partition %s because "+
		"sourceIP was empty. Service records will not be associated with a device.", agentID, partition)

	return "", partition
}

// processServices processes service statuses for a poller and updates the API status.
func (s *Server) processServices(
	ctx context.Context,
	pollerID string,
	partition string,
	sourceIP string,
	apiStatus *api.PollerStatus,
	services []*proto.ServiceStatus,
	now time.Time) {
	allServicesAvailable := true
	serviceStatuses := make([]*models.ServiceStatus, 0, len(services))
	serviceList := make([]*models.Service, 0, len(services))

	for _, svc := range services {
		log.Printf("Processing Service: %s", svc.ServiceName)

		apiService := s.createAPIService(svc)

		if !svc.Available {
			allServicesAvailable = false
		}

		if err := s.processServiceDetails(ctx, pollerID, partition, sourceIP, &apiService, svc, now); err != nil {
			log.Printf("Error processing details for service %s on poller %s: %v",
				svc.ServiceName, pollerID, err)
		}

		// Extract device context from enhanced payload for device correlation
		deviceID, devicePartition := s.extractDeviceContext(ctx, svc.AgentId, partition, sourceIP, string(apiService.Message))

		serviceStatuses = append(serviceStatuses, &models.ServiceStatus{
			AgentID:     svc.AgentId,
			PollerID:    svc.PollerId,
			ServiceName: apiService.Name,
			ServiceType: apiService.Type,
			Available:   apiService.Available,
			Details:     apiService.Message,
			DeviceID:    deviceID,
			Partition:   devicePartition,
			Timestamp:   now,
		})

		serviceList = append(serviceList, &models.Service{
			PollerID:    pollerID,
			ServiceName: svc.ServiceName,
			ServiceType: svc.ServiceType,
			AgentID:     svc.AgentId,
			DeviceID:    deviceID,
			Partition:   devicePartition,
			Timestamp:   now,
		})

		apiStatus.Services = append(apiStatus.Services, apiService)
	}

	s.bufferMu.Lock()
	s.serviceBuffers[pollerID] = append(s.serviceBuffers[pollerID], serviceStatuses...)
	s.serviceListBuffers[pollerID] = append(s.serviceListBuffers[pollerID], serviceList...)
	s.bufferMu.Unlock()

	apiStatus.IsHealthy = allServicesAvailable
}

// processServiceDetails handles parsing and processing of service details and metrics.
func (s *Server) processServiceDetails(
	ctx context.Context,
	pollerID string,
	partition string,
	sourceIP string,
	apiService *api.ServiceStatus,
	svc *proto.ServiceStatus,
	now time.Time,
) error {
	// Check if svc.Message is nil or empty
	if len(svc.Message) == 0 {
		log.Printf("No message content for service %s on poller %s", svc.ServiceName, pollerID)
		return s.handleService(ctx, apiService, partition, now)
	}

	details, err := s.parseServiceDetails(svc)
	if err != nil {
		log.Printf("Failed to parse details for service %s on poller %s, proceeding without details",
			svc.ServiceName, pollerID)

		if svc.ServiceType == snmpDiscoveryResultsServiceType {
			return fmt.Errorf("failed to parse snmp-discovery-results payload: %w", err)
		}

		return s.handleService(ctx, apiService, partition, now)
	}

	apiService.Details = details

	if err := s.processMetrics(ctx, pollerID, partition, sourceIP, svc, details, now); err != nil {
		log.Printf("Error processing metrics for service %s on poller %s: %v",
			svc.ServiceName, pollerID, err)
		return err
	}

	return s.handleService(ctx, apiService, partition, now)
}

// extractServicePayload extracts the enhanced service payload or returns original details.
// All service messages now include infrastructure context from the poller.
func (*Server) extractServicePayload(details json.RawMessage) (*models.ServiceMetricsPayload, json.RawMessage) {
	// Try to parse as enhanced payload first
	var enhancedPayload models.ServiceMetricsPayload

	if err := json.Unmarshal(details, &enhancedPayload); err == nil {
		// Validate it's actually an enhanced payload by checking required fields
		if enhancedPayload.PollerID != "" && enhancedPayload.AgentID != "" {
			return &enhancedPayload, enhancedPayload.Data
		}
	}

	// Fallback: treat as original non-enhanced payload
	// This handles backwards compatibility during transition
	return nil, details
}

// registerServiceDevice creates or updates a device entry for a poller and/or agent
// This treats the agent/poller as a service running on a real host device within a specific partition
//
// Source of Truth Principle:
// The agent/poller is the ONLY reliable source of truth for its location (partition and host IP).
// This information MUST be provided by the client in the status report, not inferred by the server.
//
// Requirements:
// - partition: MUST be provided in the PollerStatusRequest
// - sourceIP: MUST be provided in the PollerStatusRequest
// - If either is missing, the device registration is rejected to prevent orphaned records
//
// This approach ensures:
// - No duplicate devices with placeholder IPs (e.g., 127.0.0.1)
// - Stable device IDs from the first check-in
// - Correct handling of NAT, proxies, and load balancers
// - Simple, reliable logic with no "magic" convergence
func (s *Server) registerServiceDevice(
	ctx context.Context, pollerID, agentID, partition, sourceIP string, timestamp time.Time) error {
	// Validate required fields - the client MUST provide its location
	if partition == "" || sourceIP == "" {
		return fmt.Errorf("CRITICAL: Cannot register device for poller %s - "+
			"missing required location data (partition=%q, source_ip=%q)",
			pollerID, partition, sourceIP)
	}

	// Generate device ID following the partition:ip schema using the reported location
	deviceID := fmt.Sprintf("%s:%s", partition, sourceIP)

	// Determine service types based on the relationship between poller and agent
	var serviceTypes []string

	var primaryServiceID string

	if agentID == "" {
		// Pure poller
		serviceTypes = []string{"poller"}
		primaryServiceID = pollerID
	} else if agentID == pollerID {
		// Combined poller/agent
		serviceTypes = []string{"poller", "agent"}
		primaryServiceID = pollerID
	} else {
		// Separate agent
		serviceTypes = []string{"agent"}
		primaryServiceID = agentID
	}

	// Create the device metadata including service information
	// Note: metadata must be map[string]string per DeviceUpdate schema
	metadata := map[string]string{
		"device_type":     "host",
		"service_types":   strings.Join(serviceTypes, ","), // Convert array to comma-separated string
		"service_status":  "online",
		"last_heartbeat":  timestamp.Format(time.RFC3339),
		"primary_service": primaryServiceID,
	}

	// Add poller-specific metadata if this host runs a poller
	if pollerID != "" {
		metadata["poller_id"] = pollerID
		metadata["poller_status"] = "active"
	}

	// Add agent-specific metadata if this host runs an agent
	if agentID != "" && agentID != pollerID {
		metadata["agent_id"] = agentID
		metadata["agent_status"] = "active"
	}

	// Try to get hostname from the service ID or use IP as fallback
	hostname := s.getServiceHostname(primaryServiceID, sourceIP)

	// Create device update for the unified device registry
	deviceUpdate := &models.DeviceUpdate{
		DeviceID:    deviceID,
		IP:          sourceIP,
		Source:      models.DiscoverySourceSelfReported,
		AgentID:     agentID,
		PollerID:    pollerID,
		Timestamp:   timestamp,
		IsAvailable: true,
		Metadata:    metadata,
	}

	if hostname != "" {
		deviceUpdate.Hostname = &hostname
	}

	// Register through the unified device registry
	if s.DeviceRegistry != nil {
		if err := s.DeviceRegistry.UpdateDevice(ctx, deviceUpdate); err != nil {
			return fmt.Errorf("failed to register service device: %w", err)
		}
	} else {
		log.Printf("Warning: DeviceRegistry not available for device registration")
	}

	log.Printf("Successfully registered host device %s (services: %v) for poller %s",
		deviceID, serviceTypes, pollerID)

	return nil
}

// getServiceHostname attempts to determine the hostname for a service
func (*Server) getServiceHostname(serviceID, hostIP string) string {
	// TODO: In a real implementation, this could:
	// 1. Perform reverse DNS lookup on the IP
	// 2. Query a hostname registry
	// 3. Use the service ID as hostname if it's already a hostname
	// For now, use the service ID as hostname if it looks like one,
	// otherwise use the IP
	if serviceID != "" && (len(serviceID) > 7) { // Simple heuristic
		return serviceID
	}

	return hostIP
}
