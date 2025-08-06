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
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

func (s *Server) handleService(ctx context.Context, svc *api.ServiceStatus, partition string, now time.Time) error {
	ctx, span := s.tracer.Start(ctx, "handleService")
	defer span.End()
	
	// Add span attributes for traceability
	span.SetAttributes(
		attribute.String("service.name", svc.Name),
		attribute.String("service.type", svc.Type),
		attribute.String("partition", partition),
		attribute.Bool("available", svc.Available),
		attribute.Int("message_length", len(svc.Message)),
	)
	
	s.logger.Debug().
		Str("service_name", svc.Name).
		Str("service_type", svc.Type).
		Str("partition", partition).
		Bool("available", svc.Available).
		Int("message_length", len(svc.Message)).
		Msg("CORE_DEBUG: handleService called")

	if svc.Type == sweepService {
		span.AddEvent("Processing sweep service", trace.WithAttributes(
			attribute.String("service.name", svc.Name),
		))

		if err := s.processSweepData(ctx, svc, partition, now); err != nil {
			span.RecordError(err)
			span.AddEvent("Sweep data processing failed", trace.WithAttributes(
				attribute.String("error", err.Error()),
			))
			s.logger.Error().
				Err(err).
				Str("service_name", svc.Name).
				Str("service_type", svc.Type).
				Msg("CORE_DEBUG: processSweepData failed")

			return fmt.Errorf("failed to process sweep data: %w", err)
		}

		span.AddEvent("Sweep data processing completed")
	} else {
		span.AddEvent("Skipping sweep processing", trace.WithAttributes(
			attribute.String("reason", "not_sweep_service"),
		))
	}

	return nil
}

func (s *Server) processSweepData(ctx context.Context, svc *api.ServiceStatus, partition string, now time.Time) error {
	ctx, span := s.tracer.Start(ctx, "processSweepData")
	defer span.End()
	
	// Add span attributes
	span.SetAttributes(
		attribute.String("service.name", svc.Name),
		attribute.String("partition", partition),
		attribute.Int("message_size", len(svc.Message)),
	)
	
	s.logger.Debug().
		Str("service_name", svc.Name).
		Str("partition", partition).
		Int("message_length", len(svc.Message)).
		Msg("CORE_DEBUG: processSweepData started")

	// Extract enhanced payload if present, or use original data
	enhancedPayload, sweepMessage := s.extractServicePayload(svc.Message)

	const maxPreviewLength = 300

	s.logger.Debug().
		Str("service_name", svc.Name).
		Bool("has_enhanced_payload", enhancedPayload != nil).
		Int("sweep_message_length", len(sweepMessage)).
		Str("sweep_message_preview", func() string {
			if len(sweepMessage) > maxPreviewLength {
				return string(sweepMessage)[:maxPreviewLength] + "..."
			}
			return string(sweepMessage)
		}()).
		Msg("CORE_DEBUG: Extracted sweep message payload")

	// Update context from enhanced payload if available
	contextPollerID, contextPartition, contextAgentID := s.extractContextInfo(svc, enhancedPayload, partition)

	s.logger.Debug().
		Str("service_name", svc.Name).
		Str("context_poller_id", contextPollerID).
		Str("context_partition", contextPartition).
		Str("context_agent_id", contextAgentID).
		Msg("CORE_DEBUG: Extracted context information")

	var sweepData struct {
		proto.SweepServiceStatus
		Hosts []models.HostResult `json:"hosts"`
	}

	// First try to parse as a single JSON object
	s.logger.Debug().
		Str("service_name", svc.Name).
		Msg("CORE_DEBUG: Attempting to parse sweep data as single JSON object")

	parsedData, err := s.parseConcatenatedSweepJSON(ctx, sweepMessage, svc.Name)
	if err != nil {
		return err
	}

	// Copy fields individually to avoid copying embedded mutex
	sweepData.Network = parsedData.Network
	sweepData.TotalHosts = parsedData.TotalHosts
	sweepData.AvailableHosts = parsedData.AvailableHosts
	sweepData.LastSweep = parsedData.LastSweep
	sweepData.Hosts = parsedData.Hosts

	// Validate and potentially correct timestamp
	if err := s.validateAndCorrectTimestamp(&sweepData, svc, now); err != nil {
		return err
	}

	// processHostResults now correctly returns []*models.DeviceUpdate
	s.logger.Debug().
		Str("service_name", svc.Name).
		Int("host_count", len(sweepData.Hosts)).
		Msg("CORE_DEBUG: About to process host results for device updates")

	updatesToStore := s.processHostResults(sweepData.Hosts, contextPollerID, contextPartition, contextAgentID, now)

	// Add span attributes for host processing results
	span.SetAttributes(
		attribute.Int("sweep.total_hosts", len(sweepData.Hosts)),
		attribute.Int("sweep.device_updates", len(updatesToStore)),
		attribute.String("poller_id", contextPollerID),
		attribute.String("agent_id", contextAgentID),
	)

	s.logger.Debug().
		Str("service_name", svc.Name).
		Int("device_updates_count", len(updatesToStore)).
		Msg("CORE_DEBUG: Generated device updates from sweep data")

	if len(updatesToStore) > 0 {
		span.AddEvent("Processing device updates", trace.WithAttributes(
			attribute.Int("update_count", len(updatesToStore)),
		))

		if err := s.DeviceRegistry.ProcessBatchDeviceUpdates(ctx, updatesToStore); err != nil {
			span.RecordError(err)
			span.AddEvent("Device update processing failed", trace.WithAttributes(
				attribute.String("error", err.Error()),
				attribute.Int("failed_update_count", len(updatesToStore)),
			))
			s.logger.Error().
				Err(err).
				Str("service_name", svc.Name).
				Msg("CORE_DEBUG: Error processing batch sweep updates")

			return err
		}

		span.AddEvent("Device updates processed successfully", trace.WithAttributes(
			attribute.Int("processed_count", len(updatesToStore)),
		))
	} else {
		span.AddEvent("No device updates to process")
	}

	s.logger.Debug().
		Str("service_name", svc.Name).
		Msg("CORE_DEBUG: processSweepData completed successfully")

	return nil
}

// parseConcatenatedSweepJSON parses sweep data that may be a single JSON object or multiple concatenated objects
func (s *Server) parseConcatenatedSweepJSON(ctx context.Context, sweepMessage []byte, serviceName string) (*struct {
	proto.SweepServiceStatus
	Hosts []models.HostResult `json:"hosts"`
}, error) {
	var sweepData struct {
		proto.SweepServiceStatus
		Hosts []models.HostResult `json:"hosts"`
	}

	err := json.Unmarshal(sweepMessage, &sweepData)
	if err != nil {
		// If that fails, try to parse as multiple concatenated JSON objects from chunked streaming
		s.logger.Debug().
			Err(err).
			Str("service_name", serviceName).
			Msg("CORE_DEBUG: Single object parse failed for sweep data, trying to parse concatenated objects")

		// Try to parse as concatenated JSON objects
		decoder := json.NewDecoder(strings.NewReader(string(sweepMessage)))

		var allHosts []models.HostResult

		var lastSweepData *proto.SweepServiceStatus

		for decoder.More() {
			var chunkData struct {
				proto.SweepServiceStatus
				Hosts []models.HostResult `json:"hosts"`
			}

			if chunkErr := decoder.Decode(&chunkData); chunkErr != nil {
				s.logger.Error().
					Err(chunkErr).
					Str("service_name", serviceName).
					Msg("Failed to decode chunk in sweep data")

				return nil, fmt.Errorf("%w: failed to unmarshal sweep data: %w", errInvalidSweepData, err)
			}

			// Accumulate hosts from all chunks
			allHosts = append(allHosts, chunkData.Hosts...)

			// Use the last chunk's sweep status data
			lastSweepData = &chunkData.SweepServiceStatus
		}

		// Combine all the data
		if lastSweepData != nil {
			// Copy fields individually to avoid copying embedded mutex
			sweepData.Network = lastSweepData.Network
			sweepData.TotalHosts = lastSweepData.TotalHosts
			sweepData.AvailableHosts = lastSweepData.AvailableHosts
			sweepData.LastSweep = lastSweepData.LastSweep
		}

		sweepData.Hosts = allHosts

		s.logger.Debug().
			Int("host_count", len(allHosts)).
			Str("service_name", serviceName).
			Msg("CORE_DEBUG: Successfully parsed sweep data from multiple JSON chunks")
	} else {
		s.logger.Debug().
			Str("service_name", serviceName).
			Int("host_count", len(sweepData.Hosts)).
			Str("network", sweepData.Network).
			Int32("total_hosts", sweepData.TotalHosts).
			Int32("available_hosts", sweepData.AvailableHosts).
			Msg("CORE_DEBUG: Successfully parsed sweep data as single JSON object")
	}

	return &sweepData, nil
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
func (s *Server) validateAndCorrectTimestamp(sweepData *struct {
	proto.SweepServiceStatus
	Hosts []models.HostResult `json:"hosts"`
}, svc *api.ServiceStatus, now time.Time) error {
	if sweepData.LastSweep > now.Add(oneDay).Unix() {
		s.logger.Warn().
			Int64("last_sweep", sweepData.LastSweep).
			Msg("Invalid or missing LastSweep timestamp, using current time")

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

func (s *Server) parseServiceDetails(svc *proto.ServiceStatus) (json.RawMessage, error) {
	var details json.RawMessage

	if err := json.Unmarshal(svc.Message, &details); err != nil {
		s.logger.Error().
			Err(err).
			Str("service_name", svc.ServiceName).
			Msg("Error unmarshaling service details")

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

func (s *Server) extractDeviceContext(
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

		if payload.AgentID == "" {
			payload.AgentID = agentID
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

	s.logger.Warn().
		Str("agent_id", agentID).
		Str("partition", partition).
		Str("source_ip", sourceIP).
		Msg("CRITICAL: Unable to determine device_id for agent in partition because sourceIP was empty. " +
			"Service records will not be associated with a device.")

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
	ctx, span := s.tracer.Start(ctx, "processServices")
	defer span.End()
	
	// Add span attributes for the batch processing
	span.SetAttributes(
		attribute.String("poller_id", pollerID),
		attribute.String("partition", partition),
		attribute.String("source_ip", sourceIP),
		attribute.Int("service_count", len(services)),
	)
	
	s.logger.Debug().
		Str("poller_id", pollerID).
		Str("partition", partition).
		Str("source_ip", sourceIP).
		Int("service_count", len(services)).
		Msg("CORE_DEBUG: Starting processServices")

	allServicesAvailable := true
	bufferedServiceStatuses := make([]*models.ServiceStatus, 0, len(services))
	bufferedServiceList := make([]*models.Service, 0, len(services))

	for _, svc := range services {
		// Create a child span for each service
		serviceName := fmt.Sprintf("service.%s", svc.ServiceName)
		serviceCtx, serviceSpan := s.tracer.Start(ctx, serviceName)
		
		// Add attributes to the service span
		serviceSpan.SetAttributes(
			attribute.String("service.name", svc.ServiceName),
			attribute.String("service.type", svc.ServiceType),
			attribute.Bool("service.available", svc.Available),
			attribute.String("agent_id", svc.AgentId),
			attribute.Int("message_size", len(svc.Message)),
		)
		
		s.logger.Debug().
			Str("poller_id", pollerID).
			Str("service_name", svc.ServiceName).
			Str("service_type", svc.ServiceType).
			Bool("available", svc.Available).
			Int("message_length", len(svc.Message)).
			Msg("CORE_DEBUG: Processing individual service in processServices")

		// Special debug logging for sweep services
		if svc.ServiceType == "sweep" {
			const maxMessagePreview = 500

			s.logger.Debug().
				Str("poller_id", pollerID).
				Str("service_name", svc.ServiceName).
				Str("service_type", svc.ServiceType).
				Str("message_preview", func() string {
					if len(svc.Message) > maxMessagePreview {
						return string(svc.Message)[:maxMessagePreview] + "..."
					}
					return string(svc.Message)
				}()).
				Msg("CORE_DEBUG: Sweep service being processed in processServices")
		}

		apiService := s.createAPIService(svc)

		if !svc.Available {
			allServicesAvailable = false
		}

		// DEBUG: Log before calling processServiceDetails (this is where handleService gets called)
		s.logger.Debug().
			Str("poller_id", pollerID).
			Str("service_name", svc.ServiceName).
			Str("service_type", svc.ServiceType).
			Msg("CORE_DEBUG: About to call processServiceDetails (this calls handleService)")

		if err := s.processServiceDetails(serviceCtx, pollerID, partition, sourceIP, &apiService, svc, now); err != nil {
			serviceSpan.RecordError(err)
			serviceSpan.AddEvent("Service processing failed", trace.WithAttributes(
				attribute.String("error", err.Error()),
			))
			s.logger.Error().
				Err(err).
				Str("service_name", svc.ServiceName).
				Str("poller_id", pollerID).
				Msg("Error processing details for service")
		} else {
			serviceSpan.AddEvent("Service processed successfully")
		}

		// DEBUG: Log after processServiceDetails completes
		s.logger.Debug().
			Str("poller_id", pollerID).
			Str("service_name", svc.ServiceName).
			Str("service_type", svc.ServiceType).
			Msg("CORE_DEBUG: Completed processServiceDetails call")

		serviceStatus, serviceRecord := s.createServiceRecords(serviceCtx, svc, &apiService, pollerID, partition, sourceIP, now)

		// Buffer all services for processing
		bufferedServiceStatuses = append(bufferedServiceStatuses, serviceStatus)
		bufferedServiceList = append(bufferedServiceList, serviceRecord)

		apiStatus.Services = append(apiStatus.Services, apiService)
		
		// End the service span
		serviceSpan.End()
	}

	// Only buffer non-sync services
	if len(bufferedServiceStatuses) > 0 {
		s.serviceBufferMu.Lock()
		s.serviceBuffers[pollerID] = append(s.serviceBuffers[pollerID], bufferedServiceStatuses...)
		s.serviceBufferMu.Unlock()
	}

	if len(bufferedServiceList) > 0 {
		s.serviceListBufferMu.Lock()
		s.serviceListBuffers[pollerID] = append(s.serviceListBuffers[pollerID], bufferedServiceList...)
		s.serviceListBufferMu.Unlock()
	}

	apiStatus.IsHealthy = allServicesAvailable
}

// createServiceRecords creates service status and service records for a given service
func (s *Server) createServiceRecords(
	ctx context.Context,
	svc *proto.ServiceStatus,
	apiService *api.ServiceStatus,
	pollerID, partition, sourceIP string,
	now time.Time,
) (*models.ServiceStatus, *models.Service) {
	deviceID, devicePartition := s.extractDeviceContext(ctx, svc.AgentId, partition, sourceIP, string(apiService.Message))

	serviceStatus := &models.ServiceStatus{
		AgentID:     svc.AgentId,
		PollerID:    svc.PollerId,
		ServiceName: apiService.Name,
		ServiceType: apiService.Type,
		Available:   apiService.Available,
		Details:     apiService.Message,
		DeviceID:    deviceID,
		Partition:   devicePartition,
		Timestamp:   now,
	}

	// For sync services, clear the details after discovery processing to avoid storing large payloads
	if apiService.Type == "sync" {
		serviceStatus.Details = []byte(`{"status":"processed"}`)
	}

	serviceRecord := &models.Service{
		PollerID:    pollerID,
		ServiceName: svc.ServiceName,
		ServiceType: svc.ServiceType,
		AgentID:     svc.AgentId,
		DeviceID:    deviceID,
		Partition:   devicePartition,
		Timestamp:   now,
	}

	return serviceStatus, serviceRecord
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
		s.logger.Debug().
			Str("service_name", svc.ServiceName).
			Str("poller_id", pollerID).
			Msg("No message content for service")

		return s.handleService(ctx, apiService, partition, now)
	}

	var details json.RawMessage

	var err error

	// Special handling for sync and sweep services, which may send concatenated JSON objects from chunking.
	// We pass their payload directly without trying to parse it as a single JSON object.
	if svc.ServiceType == syncServiceType || svc.ServiceType == "sweep" {
		details = svc.Message
	} else {
		// For all other services, use the standard parsing logic.
		details, err = s.parseServiceDetails(svc)
		if err != nil {
			s.logger.Warn().
				Str("service_name", svc.ServiceName).
				Str("poller_id", pollerID).
				Msg("Failed to parse details for service, proceeding without details")

			if svc.ServiceType == snmpDiscoveryResultsServiceType {
				return fmt.Errorf("failed to parse snmp-discovery-results payload: %w", err)
			}

			return s.handleService(ctx, apiService, partition, now)
		}
	}

	apiService.Details = details

	if err := s.processServicePayload(ctx, pollerID, partition, sourceIP, svc, details, now); err != nil {
		s.logger.Error().
			Err(err).
			Str("service_name", svc.ServiceName).
			Str("poller_id", pollerID).
			Msg("Error processing metrics for service")

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
		s.logger.Warn().
			Msg("DeviceRegistry not available for device registration")
	}

	s.logger.Info().
		Str("device_id", deviceID).
		Interface("service_types", serviceTypes).
		Str("poller_id", pollerID).
		Msg("Successfully registered host device")

	return nil
}

func (*Server) getServiceHostname(serviceID, hostIP string) string {
	if serviceID != "" && (len(serviceID) > 7) {
		return serviceID
	}

	return hostIP
}

