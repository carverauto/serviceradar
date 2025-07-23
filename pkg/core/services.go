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

	// processHostResults now correctly returns []*models.DeviceUpdate
	updatesToStore := s.processHostResults(sweepData.Hosts, contextPollerID, contextPartition, contextAgentID, now)

	if len(updatesToStore) > 0 {
		if err := s.DeviceRegistry.ProcessBatchDeviceUpdates(ctx, updatesToStore); err != nil {
			log.Printf("Error processing batch sweep updates: %v", err)
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

	if len(svc.Message) > 0 {
		var enhancedPayload models.ServiceMetricsPayload
		if err := json.Unmarshal(svc.Message, &enhancedPayload); err == nil {
			if enhancedPayload.PollerID != "" && enhancedPayload.AgentID != "" && len(enhancedPayload.Data) > 0 {
				apiService.Details = enhancedPayload.Data
			} else {
				apiService.Details = svc.Message
			}
		} else {
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

func (*Server) extractDeviceContext(
	_ context.Context, agentID, defaultPartition, sourceIP, enhancedPayload string) (deviceID, partition string) {
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

	var payload struct {
		PollerID  string `json:"poller_id"`
		AgentID   string `json:"agent_id"`
		Partition string `json:"partition"`
		Data      struct {
			HostIP string `json:"host_ip,omitempty"`
		} `json:"data,omitempty"`
	}

	partition = defaultPartition

	if err := json.Unmarshal([]byte(enhancedPayload), &payload); err == nil {
		if payload.Partition != "" {
			partition = payload.Partition
		}

		if payload.Data.HostIP != "" {
			deviceID = fmt.Sprintf("%s:%s", partition, payload.Data.HostIP)
			return deviceID, partition
		}
	}

	if sourceIP != "" {
		deviceID = fmt.Sprintf("%s:%s", partition, sourceIP)
		return deviceID, partition
	}

	log.Printf("CRITICAL: Unable to determine device_id for agent %s in partition %s because "+
		"sourceIP was empty. Service records will not be associated with a device.", agentID, partition)

	return "", partition
}

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

	s.serviceBufferMu.Lock()
	s.serviceBuffers[pollerID] = append(s.serviceBuffers[pollerID], serviceStatuses...)
	s.serviceBufferMu.Unlock()

	s.serviceListBufferMu.Lock()
	s.serviceListBuffers[pollerID] = append(s.serviceListBuffers[pollerID], serviceList...)
	s.serviceListBufferMu.Unlock()

	apiStatus.IsHealthy = allServicesAvailable
}

func (s *Server) processServiceDetails(
	ctx context.Context,
	pollerID string,
	partition string,
	sourceIP string,
	apiService *api.ServiceStatus,
	svc *proto.ServiceStatus,
	now time.Time,
) error {
	if len(svc.Message) == 0 {
		log.Printf("No message content for service %s on poller %s", svc.ServiceName, pollerID)
		return s.handleService(ctx, apiService, partition, now)
	}

	var details json.RawMessage

	var err error

	// Special handling for the sync service, which sends a top-level JSON array.
	// We pass its payload directly without trying to parse it as a single JSON object.
	if svc.ServiceType == syncServiceType {
		details = svc.Message
	} else {
		// For all other services, use the standard parsing logic.
		details, err = s.parseServiceDetails(svc)
		if err != nil {
			log.Printf("Failed to parse details for service %s on poller %s, proceeding without details",
				svc.ServiceName, pollerID)

			if svc.ServiceType == snmpDiscoveryResultsServiceType {
				return fmt.Errorf("failed to parse snmp-discovery-results payload: %w", err)
			}

			return s.handleService(ctx, apiService, partition, now)
		}
	}

	apiService.Details = details

	if err := s.processServicePayload(ctx, pollerID, partition, sourceIP, svc, details, now); err != nil {
		log.Printf("Error processing metrics for service %s on poller %s: %v",
			svc.ServiceName, pollerID, err)
		return err
	}

	return s.handleService(ctx, apiService, partition, now)
}

func (*Server) extractServicePayload(details json.RawMessage) (*models.ServiceMetricsPayload, json.RawMessage) {
	var enhancedPayload models.ServiceMetricsPayload

	if err := json.Unmarshal(details, &enhancedPayload); err == nil {
		if enhancedPayload.PollerID != "" && enhancedPayload.AgentID != "" {
			return &enhancedPayload, enhancedPayload.Data
		}
	}

	return nil, details
}

func (s *Server) registerServiceDevice(
	ctx context.Context, pollerID, agentID, partition, sourceIP string, timestamp time.Time) error {
	if partition == "" || sourceIP == "" {
		return fmt.Errorf("CRITICAL: Cannot register device for poller %s - "+
			"missing required location data (partition=%q, source_ip=%q)",
			pollerID, partition, sourceIP)
	}

	deviceID := fmt.Sprintf("%s:%s", partition, sourceIP)

	var serviceTypes []string

	var primaryServiceID string

	if agentID == "" {
		serviceTypes = []string{"poller"}
		primaryServiceID = pollerID
	} else if agentID == pollerID {
		serviceTypes = []string{"poller", "agent"}
		primaryServiceID = pollerID
	} else {
		serviceTypes = []string{"agent"}
		primaryServiceID = agentID
	}

	metadata := map[string]string{
		"device_type":     "host",
		"service_types":   strings.Join(serviceTypes, ","),
		"service_status":  "online",
		"last_heartbeat":  timestamp.Format(time.RFC3339),
		"primary_service": primaryServiceID,
	}

	if pollerID != "" {
		metadata["poller_id"] = pollerID
		metadata["poller_status"] = "active"
	}

	if agentID != "" && agentID != pollerID {
		metadata["agent_id"] = agentID
		metadata["agent_status"] = "active"
	}

	hostname := s.getServiceHostname(primaryServiceID, sourceIP)

	deviceUpdate := &models.DeviceUpdate{
		DeviceID:    deviceID,
		IP:          sourceIP,
		Source:      models.DiscoverySourceSelfReported,
		AgentID:     agentID,
		PollerID:    pollerID,
		Timestamp:   timestamp,
		IsAvailable: true,
		Metadata:    metadata,
		Confidence:  models.GetSourceConfidence(models.DiscoverySourceSelfReported),
	}

	if hostname != "" {
		deviceUpdate.Hostname = &hostname
	}

	if s.DeviceRegistry != nil {
		if err := s.DeviceRegistry.ProcessDeviceUpdate(ctx, deviceUpdate); err != nil {
			return fmt.Errorf("failed to register service device: %w", err)
		}
	} else {
		log.Printf("Warning: DeviceRegistry not available for device registration")
	}

	log.Printf("Successfully registered host device %s (services: %v) for poller %s",
		deviceID, serviceTypes, pollerID)

	return nil
}

func (*Server) getServiceHostname(serviceID, hostIP string) string {
	if serviceID != "" && (len(serviceID) > 7) {
		return serviceID
	}

	return hostIP
}
