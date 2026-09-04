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

package agent

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	"github.com/carverauto/serviceradar/go/pkg/sysmon"
	"github.com/carverauto/serviceradar/proto"
	gproto "google.golang.org/protobuf/proto"
)

const (
	sysmonMetricTargetBatchMessageBytes = 6 * 1024 * 1024
	// The gateway synchronously commits each retry-capable plugin result. Keep
	// streams small and budget ten seconds per result so modest handler latency
	// cannot repeatedly time out the same large prefix after partial progress.
	maxPluginResultsPerStream                = 10
	minPluginResultStreamTimeout             = 30 * time.Second
	pluginResultStreamTimeoutPerWave         = 30 * time.Second
	pluginResultStreamTimeoutGrace           = 15 * time.Second
	pluginResultRetainedDeliveryCapabilityV1 = "plugin-result-retained:v1"
)

// pushRegularStatuses sends non-sysmon statuses via PushStatus.
func (p *PushLoop) pushRegularStatuses(ctx context.Context, statuses []*proto.GatewayServiceStatus, reason statusPushReason) bool {
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()
	gatewayID := p.gateway.GetGatewayID()
	runtimeMetadata := currentRuntimeMetadata()

	if len(statuses) > 0 {
		var invalidNames int
		serviceNames := make([]string, 0, len(statuses))

		for i, status := range statuses {
			if status == nil {
				p.logger.Warn().
					Int("index", i).
					Msg("Detected nil status in batch before push")
				serviceNames = append(serviceNames, "")
				continue
			}
			name := strings.TrimSpace(status.ServiceName)
			serviceNames = append(serviceNames, name)
			if name == "" {
				invalidNames++
				p.logger.Warn().
					Int("index", i).
					Str("service_type", status.ServiceType).
					Str("source", status.Source).
					Bool("available", status.Available).
					Int("message_bytes", len(status.Message)).
					Msg("Detected status with empty service_name before push")
			}
		}

		if invalidNames > 0 {
			p.logger.Warn().
				Int("invalid_service_names", invalidNames).
				Strs("service_names", serviceNames).
				Msg("Status batch contains empty service_name values")
		}
	}

	req := &proto.GatewayStatusRequest{
		Services:                                statuses,
		GatewayId:                               gatewayID,
		AgentId:                                 agentID,
		Timestamp:                               time.Now().UnixNano(),
		Partition:                               partition,
		SourceIp:                                p.getSourceIP(),
		KvStoreId:                               kvStoreID,
		Version:                                 runtimeMetadata.Version,
		Hostname:                                runtimeMetadata.Hostname,
		Os:                                      runtimeMetadata.Os,
		Arch:                                    runtimeMetadata.Arch,
		EndpointInventoryStandingQuestionCounts: endpointInventoryStandingQuestionCountsFromStatuses(statuses),
	}

	resp, err := p.gateway.PushStatus(ctx, req)
	if err != nil {
		p.logger.Error().Err(err).Int("status_count", len(statuses)).Msg("Failed to push status to gateway")
		p.recordEndpointInventoryUploadFailures(statuses, err)
		return false
	}

	if resp.Received {
		p.recordEndpointInventoryUploadSuccesses(statuses, resp)
		logEvent := p.logger.Info()
		if reason == statusPushReasonHeartbeat {
			logEvent = p.logger.Debug()
		}
		logEvent.
			Int("status_count", len(statuses)).
			Str("reason", string(reason)).
			Msg("Pushed status to gateway")
		return true
	}

	p.logger.Warn().Msg("Gateway did not acknowledge status push")
	p.recordEndpointInventoryUploadFailures(statuses, errGatewayStatusNotAcknowledged)
	return false
}

// pushSysmonStatus sends sysmon metrics via StreamStatus for large payloads.
func (p *PushLoop) pushSysmonStatus(ctx context.Context, _ *proto.GatewayServiceStatus) bool {
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	sysmonSvc := p.server.sysmonService
	p.server.mu.RUnlock()
	gatewayID := p.gateway.GetGatewayID()
	runtimeMetadata := currentRuntimeMetadata()

	var statuses []*proto.GatewayServiceStatus
	sampleCount := 0

	// If service is available, drain buffered metrics for transmission
	if sysmonSvc != nil {
		if samples := sysmonSvc.DrainMetrics(); len(samples) > 0 {
			statuses = p.convertToSysmonGatewayStatusesFromSamples(samples)
			for _, sample := range samples {
				if sample != nil {
					sampleCount++
				}
			}
		}
	}

	if len(statuses) == 0 {
		return false
	}

	chunks := make([]*proto.GatewayStatusChunk, 0, len(statuses))
	for _, status := range statuses {
		p.publishAddonMetricFeed("sysmon", status.Message)
		chunks = append(chunks, &proto.GatewayStatusChunk{
			Services:  []*proto.GatewayServiceStatus{status},
			GatewayId: gatewayID,
			AgentId:   agentID,
			Timestamp: time.Now().UnixNano(),
			Partition: partition,
			SourceIp:  p.getSourceIP(),
			Version:   runtimeMetadata.Version,
			Hostname:  runtimeMetadata.Hostname,
			Os:        runtimeMetadata.Os,
			Arch:      runtimeMetadata.Arch,
		})
	}

	totalChunks := int32(len(chunks))
	for i, chunk := range chunks {
		chunk.ChunkIndex = int32(i)
		chunk.TotalChunks = totalChunks
		chunk.IsFinal = int32(i) == totalChunks-1
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	resp, err := p.gateway.StreamStatus(pushCtx, chunks)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream sysmon metrics to gateway")
		return false
	}

	if resp.Received {
		p.logger.Info().
			Int("sample_count", sampleCount).
			Int("batch_count", len(statuses)).
			Msg("Successfully streamed sysmon metrics to gateway")
		return true
	} else {
		p.logger.Warn().Msg("Gateway did not acknowledge sysmon metrics stream")
		return false
	}
}

func (p *PushLoop) convertToSysmonGatewayStatusesFromSamples(samples []*sysmon.MetricSample) []*proto.GatewayServiceStatus {
	if len(samples) == 0 {
		return nil
	}

	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()
	gatewayID := p.gateway.GetGatewayID()

	ctx := metricEnvelopeContext{
		AgentID:   agentID,
		GatewayID: gatewayID,
		Partition: partition,
		KvStoreID: kvStoreID,
	}

	current := make([]*sysmon.MetricSample, 0, len(samples))
	var currentPayload []byte
	statuses := make([]*proto.GatewayServiceStatus, 0, 1)

	for _, sample := range samples {
		if sample == nil {
			continue
		}

		candidate := append(append([]*sysmon.MetricSample(nil), current...), sample)
		payload, err := marshalSysmonMetricEnvelopeBatch(candidate, ctx)
		if err != nil {
			p.logger.Error().Err(err).Msg("Failed to marshal sysmon metric envelope")

			continue
		}

		if len(current) > 0 && len(payload) > sysmonMetricTargetBatchMessageBytes {
			statuses = append(statuses, p.sysmonGatewayStatusFromPayload(currentPayload, agentID, gatewayID, partition, kvStoreID))
			current = []*sysmon.MetricSample{sample}
			currentPayload, err = marshalSysmonMetricEnvelopeBatch(current, ctx)
			if err != nil {
				p.logger.Error().Err(err).Msg("Failed to marshal single sysmon metric envelope")
				current = current[:0]
				currentPayload = nil
			}

			continue
		}

		current = candidate
		currentPayload = payload
	}

	if len(currentPayload) > 0 {
		statuses = append(statuses, p.sysmonGatewayStatusFromPayload(currentPayload, agentID, gatewayID, partition, kvStoreID))
	}

	return statuses
}

func (p *PushLoop) sysmonGatewayStatusFromPayload(
	messageBytes []byte,
	agentID string,
	gatewayID string,
	partition string,
	kvStoreID string,
) *proto.GatewayServiceStatus {
	return &proto.GatewayServiceStatus{
		ServiceName:  SysmonServiceName,
		Available:    true,
		Message:      messageBytes,
		ServiceType:  SysmonServiceType,
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       "sysmon-metrics",
		KvStoreId:    kvStoreID,
	}
}

func (p *PushLoop) pushPluginResults(ctx context.Context) bool {
	p.pluginResultDeliveryMu.Lock()
	defer p.pluginResultDeliveryMu.Unlock()

	p.server.mu.RLock()
	pluginManager := p.server.pluginManager
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()
	gatewayID := gatewayIDFromClient(p.gateway)
	runtimeMetadata := currentRuntimeMetadata()

	results := p.pendingPluginResults
	if len(results) == 0 && pluginManager != nil {
		results = pluginManager.DrainResults(maxPluginResultsPerStream)
		p.pendingPluginResults = results
	}
	if len(results) == 0 {
		return false
	}

	// Build status chunks - one per result to isolate failures and handle
	// potentially large payloads (e.g., error messages with stack traces).
	chunks := make([]*proto.GatewayStatusChunk, 0, len(results))
	timestamp := time.Now().UnixNano()
	sourceIP := p.getSourceIP()

	for i, result := range results {
		status := p.buildPluginGatewayStatus(result, agentID, partition, kvStoreID)
		if status == nil {
			continue
		}

		chunk := &proto.GatewayStatusChunk{
			Services:     []*proto.GatewayServiceStatus{status},
			GatewayId:    gatewayID,
			AgentId:      agentID,
			Timestamp:    timestamp,
			Partition:    partition,
			SourceIp:     sourceIP,
			IsFinal:      i == len(results)-1,
			ChunkIndex:   int32(i),
			TotalChunks:  int32(len(results)),
			KvStoreId:    kvStoreID,
			Version:      runtimeMetadata.Version,
			Hostname:     runtimeMetadata.Hostname,
			Os:           runtimeMetadata.Os,
			Arch:         runtimeMetadata.Arch,
			Capabilities: pluginResultTransportCapabilities(),
		}
		chunks = append(chunks, chunk)
	}

	if len(chunks) == 0 {
		return false
	}

	// Update chunk metadata after filtering nil statuses
	for i, chunk := range chunks {
		chunk.ChunkIndex = int32(i)
		chunk.TotalChunks = int32(len(chunks))
		chunk.IsFinal = i == len(chunks)-1
	}

	pushCtx, cancel := context.WithTimeout(ctx, pluginResultStreamTimeout(len(chunks)))
	defer cancel()

	resp, err := p.streamPluginResultStatus(pushCtx, chunks)
	if err != nil {
		if reason, terminal := retainedPoisonDropReason(err); terminal {
			recordAgentRetainedPoisonDrop("plugin-result", reason, len(chunks), encodedStatusChunkBytes(chunks))
			p.pendingPluginResults = nil
			p.logger.Error().Err(err).
				Str("reason", reason).
				Int("plugin_results", len(results)).
				Msg("Poison-dropped terminally invalid plugin result stream")
			return false
		}

		p.logger.Error().Err(err).Int("plugin_results", len(chunks)).Msg("Failed to stream plugin results to gateway")
		return false
	}

	if resp != nil && resp.Received {
		p.pendingPluginResults = nil
		p.logger.Info().Int("plugin_results", len(chunks)).Msg("Successfully streamed plugin results to gateway")
		return true
	}

	p.logger.Warn().Msg("Gateway did not acknowledge plugin result stream")
	return false
}

// pluginResultTransportCapabilities returns capabilities implemented by the
// agent binary and asserted on the transport envelope. They must not be
// derived from plugin-controlled result labels. Return a fresh slice for each
// chunk so one stream consumer cannot mutate another chunk's assertion.
func pluginResultTransportCapabilities() []string {
	return []string{
		pluginResultRetainedDeliveryCapabilityV1,
		pluginHostAuthorityCapabilityV1,
		proxmoxSemanticConnectorCapabilityV1,
		proxmoxIdentityCapabilityV3,
	}
}

func pluginResultStreamTimeout(chunkCount int) time.Duration {
	waves := (chunkCount + 1) / 2
	timeout := time.Duration(waves)*pluginResultStreamTimeoutPerWave + pluginResultStreamTimeoutGrace
	if timeout < minPluginResultStreamTimeout {
		return minPluginResultStreamTimeout
	}

	return timeout
}

func encodedStatusChunkBytes(chunks []*proto.GatewayStatusChunk) int {
	total := 0
	for _, chunk := range chunks {
		total += gproto.Size(chunk)
	}
	return total
}

func (p *PushLoop) streamPluginResultStatus(
	ctx context.Context,
	chunks []*proto.GatewayStatusChunk,
) (*proto.GatewayStatusResponse, error) {
	if p.pluginResultStreamStatus != nil {
		return p.pluginResultStreamStatus(ctx, chunks)
	}
	if p.gateway == nil {
		return nil, agentgateway.ErrGatewayNotConnected
	}

	return p.gateway.StreamStatus(ctx, chunks)
}

func (p *PushLoop) pushPluginTelemetry(ctx context.Context) bool {
	p.server.mu.RLock()
	pluginManager := p.server.pluginManager
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()
	gatewayID := p.gateway.GetGatewayID()
	runtimeMetadata := currentRuntimeMetadata()

	if pluginManager == nil {
		return false
	}

	snapshot := pluginManager.Snapshot()
	if !shouldSendPluginTelemetry(snapshot) {
		return false
	}

	payload, available := buildPluginTelemetryPayload(snapshot, agentID, partition)
	status := &proto.GatewayServiceStatus{
		ServiceName:  "plugin_engine",
		Available:    available,
		Message:      payload,
		ServiceType:  "plugin-engine",
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       "plugin-telemetry",
		KvStoreId:    kvStoreID,
	}

	req := &proto.GatewayStatusRequest{
		Services:  []*proto.GatewayServiceStatus{status},
		GatewayId: gatewayID,
		AgentId:   agentID,
		Timestamp: time.Now().UnixNano(),
		Partition: partition,
		SourceIp:  p.getSourceIP(),
		KvStoreId: kvStoreID,
		Version:   runtimeMetadata.Version,
		Hostname:  runtimeMetadata.Hostname,
		Os:        runtimeMetadata.Os,
		Arch:      runtimeMetadata.Arch,
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	resp, err := p.gateway.PushStatus(pushCtx, req)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to push plugin telemetry")
		return false
	}

	if resp.Received {
		p.logger.Debug().Msg("Successfully pushed plugin telemetry")
		return true
	}

	p.logger.Warn().Msg("Gateway did not acknowledge plugin telemetry")
	return false
}

// collectAllStatusesSeparated gathers status from all services, separating sysmon from others.
// Sysmon is returned separately because it uses StreamStatus with Source: "sysmon-metrics".
func (p *PushLoop) collectAllStatusesSeparated(ctx context.Context) ([]*proto.GatewayServiceStatus, *proto.GatewayServiceStatus) {
	var statuses []*proto.GatewayServiceStatus
	var sysmonStatus *proto.GatewayServiceStatus

	// Collect from sweep services (SweepStatusProvider)
	p.server.mu.RLock()
	services := append([]Service(nil), p.server.services...)
	sysmonSvc := p.server.sysmonService
	cfg := p.server.config
	sidecarStatus := p.server.sidecarStatus
	addonManager := p.server.addonManager
	p.server.mu.RUnlock()

	if status := p.buildAgentCapabilityGatewayStatus(cfg, sidecarStatus, addonManager); status != nil {
		statuses = append(statuses, status)
	}

	for _, svc := range services {
		if provider, ok := svc.(SweepStatusProvider); ok {
			var metricPayload map[string]any
			var status *proto.StatusResponse
			var err error

			if metricProvider, ok := svc.(SweepStatusMetricPayloadProvider); ok {
				status, metricPayload, err = metricProvider.GetStatusWithMetricPayload(ctx)
			} else {
				status, err = provider.GetStatus(ctx)
			}

			if err != nil {
				p.logger.Warn().Err(err).Str("service", svc.Name()).Msg("Failed to get status from service")
				continue
			}
			if status == nil {
				p.logger.Warn().Str("service", svc.Name()).Msg("Status provider returned nil response")
				continue
			}
			serviceType := sweepType
			source := "status"
			if routing, ok := svc.(StatusRoutingProvider); ok {
				if value := strings.TrimSpace(routing.StatusServiceType()); value != "" {
					serviceType = value
				}
				if value := strings.TrimSpace(routing.StatusSource()); value != "" {
					source = value
				}
			}

			converted := p.convertToGatewayStatusWithSource(status, svc.Name(), serviceType, source)
			if converted == nil {
				p.logger.Warn().Str("service", svc.Name()).Msg("Converted status is nil")
				continue
			}
			if telemetry, ok := svc.(StatusAddonTelemetryProvider); ok {
				if addonID, batch := telemetry.AddonTelemetryBatch(status); addonID != "" && batch != nil {
					p.server.handleAddonTelemetry(addonID, batch)
				}
			}
			statuses = append(statuses, converted)

			if serviceType == sweepType {
				if metricPayload == nil {
					p.logger.Warn().
						Str("service", svc.Name()).
						Msg("Sweep status provider did not expose typed metric payload; skipping sweep status metrics")
					continue
				}

				metricStatus, err := p.sweepMetricStatusFromMap(metricPayload)
				if err != nil {
					p.logger.Warn().Err(err).Str("service", svc.Name()).Msg("Failed to marshal sweep status metric envelope")
					continue
				}
				statuses = append(statuses, metricStatus)
			}
		}
	}

	// Collect from embedded sysmon service - separate from regular statuses
	if sysmonSvc != nil && sysmonSvc.IsEnabled() {
		sysmonStatus = &proto.GatewayServiceStatus{}
	}

	if status, err := p.server.GetSNMPStatus(ctx); err == nil && status != nil {
		converted := p.convertToGatewayStatus(status, status.ServiceName, status.ServiceType)
		if converted == nil {
			p.logger.Warn().Msg("Converted SNMP status is nil")
		} else {
			statuses = append(statuses, converted)
		}
	} else if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to get SNMP status")
	}

	return statuses, sysmonStatus
}

func (p *PushLoop) findSweepResultsProvider() SweepResultsProvider {
	p.server.mu.RLock()
	services := append([]Service(nil), p.server.services...)
	p.server.mu.RUnlock()

	for _, svc := range services {
		if sweepSvc, ok := svc.(SweepResultsProvider); ok {
			return sweepSvc
		}
	}

	return nil
}

// convertToGatewayStatus converts a StatusResponse to a GatewayServiceStatus.
func (p *PushLoop) convertToGatewayStatus(resp *proto.StatusResponse, serviceName, serviceType string) *proto.GatewayServiceStatus {
	return p.convertToGatewayStatusWithSource(resp, serviceName, serviceType, defaultStatusSource(resp, serviceName, serviceType))
}

func defaultStatusSource(resp *proto.StatusResponse, serviceName string, serviceType string) string {
	if rperfStatus(serviceName, serviceType) && metricEnvelopePayload(resp.GetMessage()) {
		return "rperf-metrics"
	}

	return "status"
}

func rperfStatus(serviceName string, serviceType string) bool {
	serviceName = strings.ToLower(strings.TrimSpace(serviceName))
	serviceType = strings.ToLower(strings.TrimSpace(serviceType))

	return serviceType == "rperf" ||
		serviceType == "network_performance" ||
		serviceName == "rperf" ||
		serviceName == "rperf-checker"
}

func (p *PushLoop) convertToGatewayStatusWithSource(
	resp *proto.StatusResponse,
	serviceName string,
	serviceType string,
	source string,
) *proto.GatewayServiceStatus {
	if resp == nil {
		return nil
	}

	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()
	gatewayID := gatewayIDFromClient(p.gateway)

	return &proto.GatewayServiceStatus{
		ServiceName:  serviceName,
		Available:    resp.Available,
		Message:      resp.Message,
		ServiceType:  serviceType,
		ResponseTime: resp.ResponseTime,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       source,
		KvStoreId:    kvStoreID,
	}
}

func (p *PushLoop) buildResultsStatusChunks(
	chunks []*proto.ResultsChunk,
	serviceName string,
	serviceType string,
) []*proto.GatewayStatusChunk {
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	p.server.mu.RUnlock()
	gatewayID := p.gateway.GetGatewayID()
	return buildResultsStatusChunksForAgent(chunks, serviceName, serviceType, agentID, partition, gatewayID)
}

func buildResultsStatusChunksForAgent(
	chunks []*proto.ResultsChunk,
	serviceName string,
	serviceType string,
	agentID string,
	partition string,
	gatewayID string,
) []*proto.GatewayStatusChunk {
	if len(chunks) == 0 {
		return nil
	}

	statusChunks := make([]*proto.GatewayStatusChunk, 0, len(chunks))
	runtimeMetadata := currentRuntimeMetadata()

	for _, chunk := range chunks {
		if chunk == nil {
			continue
		}

		status := &proto.GatewayServiceStatus{
			ServiceName:  serviceName,
			Available:    true,
			Message:      chunk.Data,
			ServiceType:  serviceType,
			ResponseTime: 0,
			AgentId:      agentID,
			GatewayId:    gatewayID,
			Partition:    partition,
			Source:       "results",
			KvStoreId:    "",
		}

		statusChunks = append(statusChunks, &proto.GatewayStatusChunk{
			Services:    []*proto.GatewayServiceStatus{status},
			GatewayId:   gatewayID,
			AgentId:     agentID,
			Timestamp:   chunk.Timestamp,
			Partition:   partition,
			IsFinal:     false,
			ChunkIndex:  0,
			TotalChunks: 0,
			KvStoreId:   "",
			Version:     runtimeMetadata.Version,
			Hostname:    runtimeMetadata.Hostname,
			Os:          runtimeMetadata.Os,
			Arch:        runtimeMetadata.Arch,
		})
	}

	// GatewayStatusChunk framing is per StreamStatus RPC. Result payloads may carry
	// their own run-level finality, so keep the outer stream final on every RPC.
	for idx, chunk := range statusChunks {
		chunk.ChunkIndex = int32(idx)
		chunk.TotalChunks = int32(len(statusChunks))
		chunk.IsFinal = idx == len(statusChunks)-1
	}

	return statusChunks
}

type statusRuntimeMetadata struct {
	Version  string
	Hostname string
	Os       string
	Arch     string
}

func currentRuntimeMetadata() statusRuntimeMetadata {
	hostname, err := os.Hostname()
	if err != nil {
		hostname = ""
	}

	return statusRuntimeMetadata{
		Version:  Version,
		Hostname: hostname,
		Os:       runtime.GOOS,
		Arch:     runtime.GOARCH,
	}
}

func endpointInventoryStandingQuestionCountsFromStatuses(
	statuses []*proto.GatewayServiceStatus,
) []*proto.EndpointInventoryStandingQuestionResultCount {
	counts := make([]*proto.EndpointInventoryStandingQuestionResultCount, 0)

	for _, status := range statuses {
		if status == nil || !isEndpointInventoryStatus(status) {
			continue
		}

		var payload endpointinventory.ScanPayload
		if err := json.Unmarshal(status.GetMessage(), &payload); err != nil {
			continue
		}

		for _, count := range payload.StandingQuestionResultCounts {
			if strings.TrimSpace(count.QuestionID) == "" {
				continue
			}
			counts = append(counts, endpointInventoryStandingQuestionCountToProto(count))
		}
	}

	if len(counts) == 0 {
		return nil
	}

	return counts
}

func isEndpointInventoryStatus(status *proto.GatewayServiceStatus) bool {
	return status.GetServiceName() == endpointinventory.ServiceName ||
		status.GetServiceType() == endpointinventory.ServiceType
}

func endpointInventoryStandingQuestionCountToProto(
	count endpointinventory.StandingQuestionResultCount,
) *proto.EndpointInventoryStandingQuestionResultCount {
	evaluatedAtUnix := int64(0)
	if !count.EvaluatedAt.IsZero() {
		evaluatedAtUnix = count.EvaluatedAt.UTC().Unix()
	}

	return &proto.EndpointInventoryStandingQuestionResultCount{
		Schema:          firstNonEmpty(count.Schema, endpointinventory.StandingQuestionResultCountSchema),
		QuestionId:      count.QuestionID,
		QuestionVersion: count.QuestionVersion,
		PredicateHash:   count.PredicateHash,
		Mode:            count.Mode,
		Matched:         count.Matched,
		Count:           boundedInt32(count.Count),
		PackageSetHash:  count.PackageSetHash,
		HashAlgorithm:   firstNonEmpty(count.HashAlgorithm, endpointinventory.HashAlgorithm),
		EvaluatedAtUnix: evaluatedAtUnix,
		Freshness:       endpointInventoryFreshnessToProto(count.Freshness),
		Labels:          copyStringMap(count.Labels),
		Metadata:        copyStringMap(count.Metadata),
	}
}

func endpointInventoryFreshnessToProto(freshness endpointinventory.FreshnessVerdict) *proto.EndpointInventoryFreshness {
	if freshness.Verdict == "" &&
		freshness.AgeSeconds == 0 &&
		freshness.StaleThresholdSeconds == 0 &&
		freshness.LastSuccessfulScanAt == nil {
		return nil
	}

	lastSuccessfulScanAtUnix := int64(0)
	if freshness.LastSuccessfulScanAt != nil {
		lastSuccessfulScanAtUnix = freshness.LastSuccessfulScanAt.UTC().Unix()
	}

	return &proto.EndpointInventoryFreshness{
		Verdict:                  freshness.Verdict,
		AgeSeconds:               freshness.AgeSeconds,
		StaleThresholdSeconds:    freshness.StaleThresholdSeconds,
		LastSuccessfulScanAtUnix: lastSuccessfulScanAtUnix,
	}
}

func boundedInt32(value int) int32 {
	if value < 0 {
		return 0
	}
	if value > math.MaxInt32 {
		return math.MaxInt32
	}

	return int32(value)
}

func copyStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}

	copied := make(map[string]string, len(values))
	for key, value := range values {
		copied[key] = value
	}

	return copied
}
