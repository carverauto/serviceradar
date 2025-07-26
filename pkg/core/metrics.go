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
		// Note: This function doesn't have access to logger, would need to be passed as parameter
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

	s.metricBufferMu.Lock()
	defer s.metricBufferMu.Unlock()

	// Ensure the buffer for this pollerID exists
	if _, ok := s.metricBuffers[pollerID]; !ok {
		s.metricBuffers[pollerID] = []*models.TimeseriesMetric{}
	}

	s.metricBuffers[pollerID] = append(s.metricBuffers[pollerID], metrics...)
}

func (s *Server) processSNMPMetrics(
	ctx context.Context,
	pollerID, partition, _, agentID string,
	details json.RawMessage,
	timestamp time.Time) error {
	targetStatusMap, err := s.parseSNMPTargetStatus(details, pollerID)
	if err != nil {
		return err
	}

	if len(targetStatusMap) == 0 {
		s.logger.Info().
			Str("poller_id", pollerID).
			Msg("SNMP service returned no targets")

		return nil
	}

	s.logSNMPTargetStatus(targetStatusMap)

	// Process device updates in batch
	if err := s.processSNMPDeviceUpdates(ctx, targetStatusMap, agentID, pollerID, partition, timestamp); err != nil {
		s.logger.Warn().
			Err(err).
			Msg("Failed to process SNMP device updates")
	}

	// Process and buffer metrics
	metrics := s.createSNMPTimeseriesMetrics(targetStatusMap, pollerID, partition, timestamp)
	s.bufferMetrics(pollerID, metrics)

	return nil
}

// parseSNMPTargetStatus parses SNMP target status from JSON details
func (s *Server) parseSNMPTargetStatus(details json.RawMessage, pollerID string) (map[string]*snmp.TargetStatus, error) {
	var targetStatusMap map[string]*snmp.TargetStatus

	if err := json.Unmarshal(details, &targetStatusMap); err != nil {
		s.logger.Error().
			Err(err).
			Str("poller_id", pollerID).
			Str("details", string(details)).
			Msg("Error unmarshaling SNMP targets")

		// Check if it's an error message wrapped in JSON
		var errorWrapper map[string]string

		if errParseErr := json.Unmarshal(details, &errorWrapper); errParseErr == nil {
			if msg, exists := errorWrapper["message"]; exists {
				s.logger.Error().
					Str("poller_id", pollerID).
					Str("message", msg).
					Msg("SNMP service returned error")

				return nil, nil // Don't fail processing for service errors
			}

			if errMsg, exists := errorWrapper["error"]; exists {
				s.logger.Error().
					Str("poller_id", pollerID).
					Str("error", errMsg).
					Msg("SNMP service returned error")

				return nil, nil // Don't fail processing for service errors
			}
		}

		return nil, fmt.Errorf("failed to parse SNMP targets: %w", err)
	}

	return targetStatusMap, nil
}

// logSNMPTargetStatus logs the status of SNMP targets and their OIDs
func (s *Server) logSNMPTargetStatus(targetStatusMap map[string]*snmp.TargetStatus) {
	for targetName, targetData := range targetStatusMap {
		s.logger.Debug().
			Str("target_name", targetName).
			Bool("available", targetData.Available).
			Str("host_ip", targetData.HostIP).
			Str("host_name", targetData.HostName).
			Msg("SNMP Target status")

		// Log OID statuses for each target
		for oidConfigName, oidStatus := range targetData.OIDStatus {
			s.logger.Debug().
				Str("oid_config_name", oidConfigName).
				Interface("last_value", oidStatus.LastValue).
				Str("last_update", oidStatus.LastUpdate.Format(time.RFC3339Nano)).
				Int("error_count", oidStatus.ErrorCount).
				Msg("  OID status")
		}
	}
}

// processSNMPDeviceUpdates processes SNMP target device updates in batch
func (s *Server) processSNMPDeviceUpdates(
	ctx context.Context,
	targetStatusMap map[string]*snmp.TargetStatus,
	agentID, pollerID, partition string,
	timestamp time.Time) error {
	var deviceUpdates []*models.DeviceUpdate

	for targetName, targetData := range targetStatusMap {
		deviceIP := targetData.HostIP
		if deviceIP == "" {
			s.logger.Warn().
				Str("target_name", targetName).
				Msg("HostIP missing for target, using target name as fallback")

			deviceIP = targetName
		}

		deviceHostname := targetData.HostName
		if deviceHostname == "" {
			deviceHostname = targetName
		}

		deviceUpdate := s.createSNMPTargetDeviceUpdate(
			agentID, pollerID, partition, deviceIP, deviceHostname, timestamp, targetData.Available)
		if deviceUpdate != nil {
			deviceUpdates = append(deviceUpdates, deviceUpdate)
		}
	}

	if len(deviceUpdates) > 0 && s.DeviceRegistry != nil {
		if err := s.DeviceRegistry.ProcessBatchDeviceUpdates(ctx, deviceUpdates); err != nil {
			return fmt.Errorf("failed to process batch SNMP target devices: %w", err)
		}

		s.logger.Info().
			Int("device_count", len(deviceUpdates)).
			Msg("Successfully processed SNMP target device updates in batch")
	}

	return nil
}

// createSNMPTimeseriesMetrics creates timeseries metrics from SNMP target data
func (*Server) createSNMPTimeseriesMetrics(
	targetStatusMap map[string]*snmp.TargetStatus,
	pollerID, partition string,
	timestamp time.Time) []*models.TimeseriesMetric {
	var metrics []*models.TimeseriesMetric

	for targetName, targetData := range targetStatusMap {
		if !targetData.Available {
			continue
		}

		deviceIP := targetData.HostIP
		if deviceIP == "" {
			deviceIP = targetName
		}

		for oidConfigName, oidStatus := range targetData.OIDStatus {
			baseMetricName, parsedIfIndex := parseOIDConfigName(oidConfigName)

			metric := createSNMPMetric(
				pollerID, partition, deviceIP, oidConfigName, oidStatus,
				targetData, baseMetricName, parsedIfIndex, timestamp)

			metrics = append(metrics, metric)
		}
	}

	return metrics
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
	s.metricBufferMu.Lock()
	s.metricBuffers[pollerID] = append(s.metricBuffers[pollerID], metrics...)
	s.metricBufferMu.Unlock()
}

func (s *Server) processRperfMetrics(pollerID, partition string, details json.RawMessage, timestamp time.Time) error {
	rperfPayload, pollerTimestamp, err := s.parseRperfPayload(details, timestamp)
	if err != nil {
		s.logger.Error().
			Err(err).
			Str("poller_id", pollerID).
			Msg("Error unmarshaling rperf data")

		return err
	}

	var allMetrics []*models.TimeseriesMetric

	for i := range rperfPayload.Status.Results {
		rperfResult, err := s.processRperfResult(rperfPayload.Status.Results[i], pollerID, partition, rperfPayload.ResponseTime, pollerTimestamp)
		if err != nil {
			s.logger.Warn().
				Err(err).
				Msg("Failed to process rperf result")

			continue
		}

		allMetrics = append(allMetrics, rperfResult...)
	}

	// Buffer rperf timeseriesMetrics
	s.bufferRperfMetrics(pollerID, allMetrics)

	s.logger.Info().
		Int("metric_count", len(allMetrics)).
		Str("poller_id", pollerID).
		Str("timestamp", pollerTimestamp.Format(time.RFC3339)).
		Msg("Parsed rperf metrics")

	return nil
}

// processSweepService handles processing for sweep service.
func (s *Server) processSweepService(
	ctx context.Context,
	pollerID string,
	partition string,
	agentID string,
	svc *proto.ServiceStatus,
	serviceData json.RawMessage,
	now time.Time) error {
	s.logger.Info().
		Str("poller_id", pollerID).
		Int("data_size", len(serviceData)).
		Msg("Processing sweep service data")
	s.logger.Debug().
		Str("service_name", svc.ServiceName).
		Str("service_type", svc.ServiceType).
		Msg("Service details")

	// Unmarshal as SweepSummary which contains HostResults
	var sweepSummary models.SweepSummary

	if err := json.Unmarshal(serviceData, &sweepSummary); err != nil {
		s.logger.Debug().
			Err(err).
			Msg("Failed to unmarshal sweep data as SweepSummary")

		return nil
	}

	s.logger.Info().
		Int("host_count", len(sweepSummary.Hosts)).
		Str("poller_id", pollerID).
		Msg("Processing sweep summary")

	// Use the result processor to convert HostResults to DeviceUpdates
	// This ensures ICMP metadata is properly extracted and availability is correctly set
	deviceUpdates := s.processHostResults(sweepSummary.Hosts, pollerID, partition, agentID, now)

	// Directly process the device updates without redundant JSON marshaling
	if len(deviceUpdates) > 0 {
		if err := s.DeviceRegistry.ProcessBatchDeviceUpdates(ctx, deviceUpdates); err != nil {
			s.logger.Error().
				Err(err).
				Msg("Error processing batch sweep updates")

			return err
		}
	}

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
		s.logger.Error().
			Err(err).
			Str("service_name", svc.ServiceName).
			Msg("Failed to parse ICMP response JSON")

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
		s.logger.Error().
			Err(err).
			Str("service_name", svc.ServiceName).
			Str("poller_id", pollerID).
			Msg("Failed to marshal ICMP metadata")

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
	s.metricBufferMu.Lock()
	s.metricBuffers[pollerID] = append(s.metricBuffers[pollerID], metric)
	s.metricBufferMu.Unlock()

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
			s.logger.Error().
				Err(err).
				Str("service_name", svc.ServiceName).
				Msg("Failed to add ICMP metric to in-memory buffer")
		}
	} else {
		s.logger.Error().
			Str("poller_id", pollerID).
			Msg("Metrics manager is nil in processICMPMetrics")
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

	memoryCount := 0
	if sysmonPayload.Status.Memory.TotalBytes > 0 || sysmonPayload.Status.Memory.UsedBytes > 0 {
		memoryCount = 1
	}

	s.logger.Info().
		Int("cpu_count", len(sysmonPayload.Status.CPUs)).
		Int("disk_count", len(sysmonPayload.Status.Disks)).
		Int("memory_count", memoryCount).
		Int("process_count", len(sysmonPayload.Status.Processes)).
		Str("poller_id", pollerID).
		Str("device_id", deviceID).
		Str("host_ip", sysmonPayload.Status.HostIP).
		Str("partition", partition).
		Str("timestamp", sysmonPayload.Status.Timestamp).
		Msg("Parsed sysmon metrics")

	s.createSysmonDeviceRecord(ctx, agentID, pollerID, partition, deviceID, sysmonPayload, pollerTimestamp)

	return nil
}

type sysmonPayload struct {
	Available    bool  `json:"available"`
	ResponseTime int64 `json:"response_time"`
	Status       struct {
		Timestamp string                 `json:"timestamp"`
		HostID    string                 `json:"host_id"`
		HostIP    string                 `json:"host_ip"`
		CPUs      []models.CPUMetric     `json:"cpus"`
		Disks     []models.DiskMetric    `json:"disks"`
		Memory    models.MemoryMetric    `json:"memory"`
		Processes []models.ProcessMetric `json:"processes"`
	} `json:"status"`
}

func (s *Server) parseSysmonPayload(details json.RawMessage, pollerID string, timestamp time.Time) (*sysmonPayload, time.Time, error) {
	var payload sysmonPayload

	if err := json.Unmarshal(details, &payload); err != nil {
		s.logger.Error().
			Err(err).
			Str("poller_id", pollerID).
			Msg("Error unmarshaling sysmon data")

		return nil, time.Time{}, fmt.Errorf("failed to parse sysmon data: %w", err)
	}

	pollerTimestamp, err := time.Parse(time.RFC3339Nano, payload.Status.Timestamp)
	if err != nil {
		s.logger.Warn().
			Err(err).
			Str("poller_id", pollerID).
			Msg("Invalid timestamp in sysmon data, using server timestamp")

		pollerTimestamp = timestamp
	}

	return &payload, pollerTimestamp, nil
}

func (*Server) buildSysmonMetrics(
	payload *sysmonPayload, pollerTimestamp time.Time, agentID string) *models.SysmonMetrics {
	hasMemoryData := payload.Status.Memory.TotalBytes > 0 || payload.Status.Memory.UsedBytes > 0

	m := &models.SysmonMetrics{
		CPUs:      make([]models.CPUMetric, len(payload.Status.CPUs)),
		Disks:     make([]models.DiskMetric, len(payload.Status.Disks)),
		Memory:    &models.MemoryMetric{},
		Processes: make([]models.ProcessMetric, len(payload.Status.Processes)),
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

	for i := range payload.Status.Processes {
		process := &payload.Status.Processes[i]
		m.Processes[i] = models.ProcessMetric{
			PID:         process.PID,
			Name:        process.Name,
			CPUUsage:    process.CPUUsage,
			MemoryUsage: process.MemoryUsage,
			Status:      process.Status,
			StartTime:   process.StartTime,
			Timestamp:   pollerTimestamp,
			HostID:      payload.Status.HostID,
			HostIP:      payload.Status.HostIP,
			AgentID:     agentID,
		}
	}

	return m
}

func (s *Server) bufferSysmonMetrics(pollerID, partition string, metrics *models.SysmonMetrics) {
	s.sysmonBufferMu.Lock()
	s.sysmonBuffers[pollerID] = append(s.sysmonBuffers[pollerID], &sysmonMetricBuffer{
		Metrics:   metrics,
		Partition: partition,
	})
	s.sysmonBufferMu.Unlock()
}

// processGRPCService handles processing for GRPC service.
func (s *Server) processGRPCService(
	ctx context.Context,
	pollerID string,
	partition string,
	_ string,
	agentID string,
	svc *proto.ServiceStatus,
	serviceData json.RawMessage,
	now time.Time) error {
	switch svc.ServiceName {
	case rperfServiceType:
		return s.processRperfMetrics(pollerID, partition, serviceData, now)
	case sysmonServiceType:
		return s.processSysmonMetrics(ctx, pollerID, partition, agentID, serviceData, now)
	case syncServiceType:
		s.logger.Debug().
			Str("poller_id", pollerID).
			Int("data_size", len(serviceData)).
			Msg("CORE DEBUG: Processing GRPC sync service data")

		return s.discoveryService.ProcessSyncResults(ctx, pollerID, partition, svc, serviceData, now)
	default:
		s.logger.Warn().
			Str("service_name", svc.ServiceName).
			Str("poller_id", pollerID).
			Msg("Unknown GRPC service name")
	}

	return nil
}

// processServicePayload handles service payload processing for all service types including metrics, discovery results, and sync data.
func (s *Server) processServicePayload(
	ctx context.Context,
	pollerID string,
	partition string,
	sourceIP string,
	svc *proto.ServiceStatus,
	details json.RawMessage,
	now time.Time) error {
	s.logger.Debug().
		Str("service_name", svc.ServiceName).
		Str("service_type", svc.ServiceType).
		Int("data_size", len(details)).
		Msg("processServicePayload")

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
		return s.processGRPCService(ctx, contextPollerID, contextPartition, sourceIP, contextAgentID, svc, serviceData, now)
	case icmpServiceType:
		return s.processICMPMetrics(contextPollerID, contextPartition, sourceIP, contextAgentID, svc, serviceData, now)
	case snmpDiscoveryResultsServiceType, mapperDiscoveryServiceType:
		return s.discoveryService.ProcessSNMPDiscoveryResults(ctx, contextPollerID, contextPartition, svc, serviceData, now)
	case sweepService:
		return s.processSweepService(ctx, contextPollerID, contextPartition, contextAgentID, svc, serviceData, now)
	case syncServiceType:
		return s.discoveryService.ProcessSyncResults(ctx, contextPollerID, contextPartition, svc, serviceData, now)
	default:
		s.logger.Warn().
			Str("service_type", svc.ServiceType).
			Str("poller_id", pollerID).
			Msg("Unknown service type")
	}

	return nil
}
