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
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// createSNMPMetric creates a new timeseries metric from SNMP data
func createSNMPMetric(
	pollerID string,
	partition string,
	targetName string,
	oidConfigName string,
	oidStatus snmp.OIDStatus,
	targetData *snmp.TargetStatus,
	baseMetricName string,
	parsedIfIndex int32,
	timestamp time.Time,
) *models.TimeseriesMetric {
	valueStr := fmt.Sprintf("%v", oidStatus.LastValue)

	remainingMetadata := make(map[string]string)
	remainingMetadata["original_oid_config_name"] = oidConfigName
	remainingMetadata["target_last_poll_timestamp"] = targetData.LastPoll.Format(time.RFC3339Nano)
	remainingMetadata["oid_last_update_timestamp"] = oidStatus.LastUpdate.Format(time.RFC3339Nano)

	if oidStatus.ErrorCount > 0 {
		remainingMetadata["oid_error_count"] = fmt.Sprintf("%d", oidStatus.ErrorCount)
		remainingMetadata["oid_last_error"] = oidStatus.LastError
	}

	// Marshal metadata to JSON string
	metadataBytes, err := json.Marshal(remainingMetadata)
	if err != nil {
		log.Printf("Failed to marshal SNMP metadata for poller %s, OID %s: %v", pollerID, oidConfigName, err)

		// Return a metric with empty metadata to avoid skipping valid data
		remainingMetadata = map[string]string{}
		metadataBytes, _ = json.Marshal(remainingMetadata)
	}

	metadataStr := string(metadataBytes)

	// Use the timestamp from the OID status if available and valid, otherwise fallback
	metricTimestamp := timestamp
	if !oidStatus.LastUpdate.IsZero() {
		metricTimestamp = oidStatus.LastUpdate
	}

	return &models.TimeseriesMetric{
		PollerID:       pollerID,
		TargetDeviceIP: targetName,
		DeviceID:       fmt.Sprintf("%s:%s", partition, targetName),
		Partition:      partition,
		IfIndex:        parsedIfIndex,
		Name:           baseMetricName,
		Type:           "snmp",
		Value:          valueStr,
		Timestamp:      metricTimestamp,
		Metadata:       metadataStr, // Use JSON string
	}
}

// bufferMetrics adds metrics to the server's metric buffer for a specific poller
func (s *Server) bufferMetrics(pollerID string, metrics []*models.TimeseriesMetric) {
	if len(metrics) == 0 {
		return
	}

	s.bufferMu.Lock()
	defer s.bufferMu.Unlock()

	// Ensure the buffer for this pollerID exists
	if _, ok := s.metricBuffers[pollerID]; !ok {
		s.metricBuffers[pollerID] = []*models.TimeseriesMetric{}
	}

	s.metricBuffers[pollerID] = append(s.metricBuffers[pollerID], metrics...)
}

func (s *Server) processSNMPMetrics(
	ctx context.Context,
	pollerID, partition, sourceIP, agentID string,
	details json.RawMessage,
	timestamp time.Time) error {
	// 'details' may be either enhanced ServiceMetricsPayload data or raw SNMP data
	// Parse directly as SNMP target status map (works for both enhanced and legacy)
	var targetStatusMap map[string]*snmp.TargetStatus

	if err := json.Unmarshal(details, &targetStatusMap); err != nil {
		log.Printf("Error unmarshaling SNMP targets for poller %s: %v. Details: %s",
			pollerID, err, string(details))

		// Check if it's an error message wrapped in JSON
		var errorWrapper map[string]string

		if errParseErr := json.Unmarshal(details, &errorWrapper); errParseErr == nil {
			if msg, exists := errorWrapper["message"]; exists {
				log.Printf("SNMP service returned error for poller %s: %s", pollerID, msg)
				return nil // Don't fail processing for service errors
			}

			if errMsg, exists := errorWrapper["error"]; exists {
				log.Printf("SNMP service returned error for poller %s: %s", pollerID, errMsg)
				return nil // Don't fail processing for service errors
			}
		}

		return fmt.Errorf("failed to parse SNMP targets: %w", err)
	}

	// iterate through the targetStatusMap to log each target's status
	for targetName, targetData := range targetStatusMap {
		log.Printf("SNMP Target: %s, Available: %t, HostIP: %s, HostName: %s",
			targetName, targetData.Available, targetData.HostIP, targetData.HostName)

		// Log OID statuses for each target
		for oidConfigName, oidStatus := range targetData.OIDStatus {
			log.Printf("  OID: %s, LastValue: %v, LastUpdate: %s, ErrorCount: %d",
				oidConfigName, oidStatus.LastValue,
				oidStatus.LastUpdate.Format(time.RFC3339Nano), oidStatus.ErrorCount)
		}
	}

	// Skip processing if no targets (empty map)
	if len(targetStatusMap) == 0 {
		log.Printf("SNMP service for poller %s returned no targets", pollerID)
		return nil
	}

	// Register each SNMP target as a device (for unified devices view integration)
	for targetName, targetData := range targetStatusMap {
		// Use HostIP for device registration, fall back to target name if not available
		deviceIP := targetData.HostIP
		if deviceIP == "" {
			log.Printf("Warning: HostIP missing for target %s, using target name as fallback", targetName)
			deviceIP = targetName
		}

		// Use HostName for display, fall back to target name if not available
		deviceHostname := targetData.HostName
		if deviceHostname == "" {
			deviceHostname = targetName
		}

		s.createSNMPTargetDeviceRecord(
			ctx,
			agentID,        // Use context agentID (enhanced or fallback)
			pollerID,       // Use context pollerID (enhanced or fallback)
			partition,      // Use context partition (enhanced or fallback)
			deviceIP,       // Actual IP address (e.g., "192.168.2.1")
			deviceHostname, // Display name (e.g., "farm01")
			sourceIP,       // Use source IP for logging consistency
			timestamp,
			targetData.Available,
		)
	}

	var newTimeseriesMetrics []*models.TimeseriesMetric

	for targetName, targetData := range targetStatusMap { // targetName is target config name
		if !targetData.Available {
			continue
		}

		// Use HostIP for device ID consistency, fall back to target name if not available
		deviceIP := targetData.HostIP
		if deviceIP == "" {
			deviceIP = targetName
		}

		for oidConfigName, oidStatus := range targetData.OIDStatus { // oidConfigName is like "ifInOctets_4" or "sysUpTimeInstance"
			baseMetricName, parsedIfIndex := parseOIDConfigName(oidConfigName)

			metric := createSNMPMetric(
				pollerID,  // Use context pollerID
				partition, // Use context partition
				deviceIP,  // Use actual IP address for device ID consistency
				oidConfigName,
				oidStatus,
				targetData,
				baseMetricName,
				parsedIfIndex,
				timestamp,
			)

			newTimeseriesMetrics = append(newTimeseriesMetrics, metric)
		}
	}

	s.bufferMetrics(pollerID, newTimeseriesMetrics)

	return nil
}

// parseRperfPayload unmarshals the rperf payload and extracts the timestamp
func (*Server) parseRperfPayload(details json.RawMessage, timestamp time.Time) (struct {
	Available    bool  `json:"available"`
	ResponseTime int64 `json:"response_time"`
	Status       struct {
		Results []*struct {
			Target  string             `json:"target"`
			Success bool               `json:"success"`
			Error   *string            `json:"error"`
			Status  models.RperfMetric `json:"status"`
		} `json:"results"`
		Timestamp string `json:"timestamp"`
	} `json:"status"`
}, time.Time, error) {
	var rperfPayload struct {
		Available    bool  `json:"available"`
		ResponseTime int64 `json:"response_time"`
		Status       struct {
			Results []*struct {
				Target  string             `json:"target"`
				Success bool               `json:"success"`
				Error   *string            `json:"error"`
				Status  models.RperfMetric `json:"status"` // Updated to match "status" field
			} `json:"results"`
			Timestamp string `json:"timestamp"`
		} `json:"status"`
	}

	if err := json.Unmarshal(details, &rperfPayload); err != nil {
		return rperfPayload, timestamp, fmt.Errorf("failed to parse rperf data: %w", err)
	}

	// Parse the timestamp
	pollerTimestamp, err := time.Parse(time.RFC3339Nano, rperfPayload.Status.Timestamp)
	if err != nil {
		pollerTimestamp = timestamp
	}

	return rperfPayload, pollerTimestamp, nil
}

// processRperfResult processes a single rperf result and returns the corresponding metrics
func (*Server) processRperfResult(result *struct {
	Target  string             `json:"target"`
	Success bool               `json:"success"`
	Error   *string            `json:"error"`
	Status  models.RperfMetric `json:"status"`
}, pollerID string, partition string, responseTime int64, pollerTimestamp time.Time) ([]*models.TimeseriesMetric, error) {
	if !result.Success {
		return nil, fmt.Errorf("skipping failed rperf test (Target: %s). Error: %v", result.Target, result.Error)
	}

	// Create RperfMetric for metadata
	rperfMetric := models.RperfMetric{
		Target:          result.Target,
		Success:         result.Success,
		Error:           result.Error,
		BitsPerSec:      result.Status.BitsPerSec,
		BytesReceived:   result.Status.BytesReceived,
		BytesSent:       result.Status.BytesSent,
		Duration:        result.Status.Duration,
		JitterMs:        result.Status.JitterMs,
		LossPercent:     result.Status.LossPercent,
		PacketsLost:     result.Status.PacketsLost,
		PacketsReceived: result.Status.PacketsReceived,
		PacketsSent:     result.Status.PacketsSent,
		ResponseTime:    responseTime,
	}

	// Marshal the RperfMetric as metadata
	metadataBytes, err := json.Marshal(rperfMetric)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal rperf metadata for target %s: %w", result.Target, err)
	}

	metadataStr := string(metadataBytes)

	var timeseriesMetrics = make([]*models.TimeseriesMetric, 0, 4) // Pre-allocate for 4 metrics

	const (
		defaultFmt                  = "%.2f"
		defaultLossFmt              = "%.1f"
		defaultBitsPerSecondDivisor = 1e6
	)

	metricsToStore := []struct {
		Name  string
		Value string
	}{
		{
			Name:  fmt.Sprintf("rperf_%s_bandwidth_mbps", result.Target),
			Value: fmt.Sprintf(defaultFmt, result.Status.BitsPerSec/defaultBitsPerSecondDivisor),
		},
		{
			Name:  fmt.Sprintf("rperf_%s_jitter_ms", result.Target),
			Value: fmt.Sprintf(defaultFmt, result.Status.JitterMs),
		},
		{
			Name:  fmt.Sprintf("rperf_%s_loss_percent", result.Target),
			Value: fmt.Sprintf(defaultLossFmt, result.Status.LossPercent),
		},
		{
			Name:  fmt.Sprintf("rperf_%s_response_time_ns", result.Target),
			Value: fmt.Sprintf("%d", responseTime),
		},
	}

	for _, m := range metricsToStore {
		metric := &models.TimeseriesMetric{
			Name:           m.Name,
			Value:          m.Value,
			Type:           "rperf",
			Timestamp:      pollerTimestamp,
			Metadata:       metadataStr,
			PollerID:       pollerID,
			TargetDeviceIP: result.Target,
			DeviceID:       fmt.Sprintf("%s:%s", partition, result.Target),
			Partition:      partition,
		}

		timeseriesMetrics = append(timeseriesMetrics, metric)
	}

	return timeseriesMetrics, nil
}

// bufferRperfMetrics adds the metrics to the buffer for the given poller
func (s *Server) bufferRperfMetrics(pollerID string, metrics []*models.TimeseriesMetric) {
	s.bufferMu.Lock()
	s.metricBuffers[pollerID] = append(s.metricBuffers[pollerID], metrics...)
	s.bufferMu.Unlock()
}

func (s *Server) processRperfMetrics(pollerID, partition string, details json.RawMessage, timestamp time.Time) error {
	rperfPayload, pollerTimestamp, err := s.parseRperfPayload(details, timestamp)
	if err != nil {
		log.Printf("Error unmarshaling rperf data for poller %s: %v", pollerID, err)
		return err
	}

	var allMetrics []*models.TimeseriesMetric

	for i := range rperfPayload.Status.Results {
		rperfResult, err := s.processRperfResult(rperfPayload.Status.Results[i], pollerID, partition, rperfPayload.ResponseTime, pollerTimestamp)
		if err != nil {
			log.Printf("%v", err)
			continue
		}

		allMetrics = append(allMetrics, rperfResult...)
	}

	// Buffer rperf timeseriesMetrics
	s.bufferRperfMetrics(pollerID, allMetrics)

	log.Printf("Parsed %d rperf metrics for poller %s with timestamp %s",
		len(allMetrics), pollerID, pollerTimestamp.Format(time.RFC3339))

	return nil
}

func (s *Server) processICMPMetrics(
	pollerID string, partition string, sourceIP string, agentID string,
	svc *proto.ServiceStatus,
	details json.RawMessage,
	now time.Time) error {
	var pingResult struct {
		Host         string  `json:"host"`
		ResponseTime int64   `json:"response_time"`
		PacketLoss   float64 `json:"packet_loss"`
		Available    bool    `json:"available"`
		DeviceID     string  `json:"device_id,omitempty"`
	}

	if err := json.Unmarshal(details, &pingResult); err != nil {
		log.Printf("Failed to parse ICMP response JSON for service %s: %v", svc.ServiceName, err)
		return fmt.Errorf("failed to parse ICMP data: %w", err)
	}

	// build deviceId based on "partition:sourceIP"
	deviceID := fmt.Sprintf("%s:%s", partition, sourceIP)

	// Create metadata map
	metadata := map[string]string{
		"device_id":     deviceID,
		"host":          pingResult.Host,
		"response_time": fmt.Sprintf("%d", pingResult.ResponseTime),
		"packet_loss":   fmt.Sprintf("%f", pingResult.PacketLoss),
		"available":     fmt.Sprintf("%t", pingResult.Available),
	}

	// Marshal metadata to JSON string
	metadataBytes, err := json.Marshal(metadata)
	if err != nil {
		log.Printf("Failed to marshal ICMP metadata for service %s, poller %s: %v",
			svc.ServiceName, pollerID, err)
		return fmt.Errorf("failed to marshal ICMP metadata: %w", err)
	}

	metadataStr := string(metadataBytes)

	metric := &models.TimeseriesMetric{
		Name:           fmt.Sprintf("icmp_%s_response_time_ms", svc.ServiceName),
		Value:          fmt.Sprintf("%d", pingResult.ResponseTime),
		Type:           "icmp",
		Timestamp:      now,
		Metadata:       metadataStr, // Use JSON string
		TargetDeviceIP: pingResult.Host,
		DeviceID:       deviceID,
		Partition:      partition,
		IfIndex:        0,
		PollerID:       pollerID,
	}

	// Buffer ICMP metric
	s.bufferMu.Lock()
	s.metricBuffers[pollerID] = append(s.metricBuffers[pollerID], metric)
	s.bufferMu.Unlock()

	if s.metrics != nil {
		err := s.metrics.AddMetric(
			pollerID,
			now,
			pingResult.ResponseTime,
			svc.ServiceName,
			deviceID,
			partition,
			agentID,
		)
		if err != nil {
			log.Printf("ERROR: Failed to add ICMP metric to in-memory buffer for %s: %v", svc.ServiceName, err)
		}
	} else {
		log.Printf("ERROR: Metrics manager is nil in processICMPMetrics for poller %s", pollerID)
	}

	return nil
}

func (s *Server) processSysmonMetrics(
	ctx context.Context,
	pollerID, partition, agentID string,
	details json.RawMessage,
	timestamp time.Time) error {
	sysmonPayload, pollerTimestamp, err := s.parseSysmonPayload(details, pollerID, timestamp)
	if err != nil {
		return err
	}

	m := s.buildSysmonMetrics(sysmonPayload, pollerTimestamp, agentID)

	// Create device_id for logging and device registration
	deviceID := fmt.Sprintf("%s:%s", partition, sysmonPayload.Status.HostIP)

	s.bufferSysmonMetrics(pollerID, partition, m)

	log.Printf("Parsed %d CPU metrics for poller %s (device_id: %s, host_ip: %s, partition: %s) with timestamp %s",
		len(sysmonPayload.Status.CPUs), pollerID, deviceID, sysmonPayload.Status.HostIP, partition, sysmonPayload.Status.Timestamp)

	s.createSysmonDeviceRecord(ctx, agentID, pollerID, partition, deviceID, sysmonPayload, pollerTimestamp)

	return nil
}

type sysmonPayload struct {
	Available    bool  `json:"available"`
	ResponseTime int64 `json:"response_time"`
	Status       struct {
		Timestamp string              `json:"timestamp"`
		HostID    string              `json:"host_id"`
		HostIP    string              `json:"host_ip"`
		CPUs      []models.CPUMetric  `json:"cpus"`
		Disks     []models.DiskMetric `json:"disks"`
		Memory    models.MemoryMetric `json:"memory"`
	} `json:"status"`
}

func (*Server) parseSysmonPayload(details json.RawMessage, pollerID string, timestamp time.Time) (*sysmonPayload, time.Time, error) {
	var payload sysmonPayload

	if err := json.Unmarshal(details, &payload); err != nil {
		log.Printf("Error unmarshaling sysmon data for poller %s: %v", pollerID, err)
		return nil, time.Time{}, fmt.Errorf("failed to parse sysmon data: %w", err)
	}

	pollerTimestamp, err := time.Parse(time.RFC3339Nano, payload.Status.Timestamp)
	if err != nil {
		log.Printf("Invalid timestamp in sysmon data for poller %s: %v, using server timestamp", pollerID, err)

		pollerTimestamp = timestamp
	}

	return &payload, pollerTimestamp, nil
}

func (*Server) buildSysmonMetrics(payload *sysmonPayload, pollerTimestamp time.Time, agentID string) *models.SysmonMetrics {
	hasMemoryData := payload.Status.Memory.TotalBytes > 0 || payload.Status.Memory.UsedBytes > 0

	m := &models.SysmonMetrics{
		CPUs:   make([]models.CPUMetric, len(payload.Status.CPUs)),
		Disks:  make([]models.DiskMetric, len(payload.Status.Disks)),
		Memory: &models.MemoryMetric{},
	}

	for i, cpu := range payload.Status.CPUs {
		m.CPUs[i] = models.CPUMetric{
			CoreID:       cpu.CoreID,
			UsagePercent: cpu.UsagePercent,
			Timestamp:    pollerTimestamp,
			HostID:       payload.Status.HostID,
			HostIP:       payload.Status.HostIP,
			AgentID:      agentID,
		}
	}

	for i, disk := range payload.Status.Disks {
		m.Disks[i] = models.DiskMetric{
			MountPoint: disk.MountPoint,
			UsedBytes:  disk.UsedBytes,
			TotalBytes: disk.TotalBytes,
			Timestamp:  pollerTimestamp,
			HostID:     payload.Status.HostID,
			HostIP:     payload.Status.HostIP,
			AgentID:    agentID,
		}
	}

	if hasMemoryData {
		m.Memory = &models.MemoryMetric{
			UsedBytes:  payload.Status.Memory.UsedBytes,
			TotalBytes: payload.Status.Memory.TotalBytes,
			Timestamp:  pollerTimestamp,
			HostID:     payload.Status.HostID,
			HostIP:     payload.Status.HostIP,
			AgentID:    agentID,
		}
	}

	return m
}

func (s *Server) bufferSysmonMetrics(pollerID, partition string, metrics *models.SysmonMetrics) {
	s.bufferMu.Lock()
	s.sysmonBuffers[pollerID] = append(s.sysmonBuffers[pollerID], &sysmonMetricBuffer{
		Metrics:   metrics,
		Partition: partition,
	})
	s.bufferMu.Unlock()
}

// processMetrics handles metrics processing for all service types.
func (s *Server) processMetrics(
	ctx context.Context,
	pollerID string,
	partition string,
	sourceIP string,
	svc *proto.ServiceStatus,
	details json.RawMessage,
	now time.Time) error {
	log.Println("processMetrics - ServiceName: ", svc.ServiceName)

	// Extract enhanced payload if present, or use original data
	enhancedPayload, serviceData := s.extractServicePayload(details)

	// Use enhanced context if available, otherwise fall back to gRPC parameters
	contextPollerID := pollerID
	contextPartition := partition
	contextAgentID := svc.AgentId

	if enhancedPayload != nil {
		contextPollerID = enhancedPayload.PollerID
		contextPartition = enhancedPayload.Partition
		contextAgentID = enhancedPayload.AgentID
	}

	switch svc.ServiceType {
	case snmpServiceType:
		return s.processSNMPMetrics(ctx, contextPollerID, contextPartition, sourceIP, contextAgentID, serviceData, now)
	case grpcServiceType:
		switch svc.ServiceName {
		case rperfServiceType:
			return s.processRperfMetrics(contextPollerID, contextPartition, serviceData, now)
		case sysmonServiceType:
			return s.processSysmonMetrics(ctx, contextPollerID, contextPartition, contextAgentID, serviceData, now)
		case syncServiceType:
			// Attempt to unmarshal as a slice of DeviceUpdate, which is what the sync service returns
			// Note: serviceData is already unwrapped from ServiceMetricsPayload by extractServicePayload
			var deviceUpdates []*models.DeviceUpdate

			if err := json.Unmarshal(serviceData, &deviceUpdates); err == nil && len(deviceUpdates) > 0 {
				// Successfully parsed as device updates. Process them.
				log.Printf("Processing %d sync device updates for poller %s", len(deviceUpdates), contextPollerID)
				return s.discoveryService.ProcessSyncResults(ctx, contextPollerID, contextPartition, svc, serviceData, now)
			}

			// If it fails to unmarshal or is empty, it's likely a health check payload from GetStatus
			log.Printf("Skipping sync service payload for poller %s (likely a health check)", contextPollerID)

			return nil
		default:
			log.Printf("Unknown GRPC service type %s on poller %s", svc.ServiceType, pollerID)
		}
	case icmpServiceType:
		return s.processICMPMetrics(contextPollerID, contextPartition, sourceIP, contextAgentID, svc, serviceData, now)
	case snmpDiscoveryResultsServiceType, mapperDiscoveryServiceType:
		return s.discoveryService.ProcessSNMPDiscoveryResults(ctx, contextPollerID, contextPartition, svc, serviceData, now)
	case sweepService:
		log.Print("no-op for sweep service, handled in separate flow")

		return nil
	default:
		log.Printf("Unknown service type %s on poller %s", svc.ServiceType, pollerID)
	}

	return nil
}
