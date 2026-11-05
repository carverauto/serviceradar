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
	"bytes"
	"context"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/sysmon"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const (
	// maxPluginResultsPerDrain bounds the plugin results one push takes from the
	// plugin manager; the rest wait in its bounded queue for the next push.
	maxPluginResultsPerDrain = 10

	rperfServiceType   = "rperf"
	rperfCheckerName   = "rperf-checker"
	rperfMetricsSource = "rperf-metrics"
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
		Services:  statuses,
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

	resp, err := p.gateway.PushStatus(ctx, req)
	if err != nil {
		p.logger.Error().Err(err).Int("status_count", len(statuses)).Msg("Failed to push status to gateway")
		return false
	}

	if resp.Received {
		p.applyEndpointInventoryDirectives(resp)
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
	return false
}

// pushSysmonMetrics drains the embedded sysmon collector onto the edge spool
// under the metrics grant, or holds the samples until one is held.
func (p *PushLoop) pushSysmonMetrics() bool {
	p.server.mu.RLock()
	sysmonSvc := p.server.sysmonService
	p.server.mu.RUnlock()
	if sysmonSvc == nil {
		return false
	}

	var samples []*sysmon.MetricSample
	for _, sample := range sysmonSvc.DrainMetrics() {
		if sample != nil {
			samples = append(samples, sample)
		}
	}

	capability := p.edgeMetricsCapability(time.Now())
	if capability == nil {
		holdEdgeMetrics(p, sysmonEdgeMetrics(), &p.sysmonEdge, samples)
		return false
	}
	return spoolEdgeMetrics(p, sysmonEdgeMetrics(), &p.sysmonEdge, samples, capability)
}

// pushPluginResults moves drained Wasm plugin results onto the edge spool under
// the plugin results grant. Without one, nothing is drained: the plugin
// manager's bounded result queue makes plugin executions wait for room, so no
// result is lost while the agent waits for the grant.
func (p *PushLoop) pushPluginResults() bool {
	capability := p.edgePluginResultsCapability(time.Now())
	if capability == nil {
		p.holdForGrant(edgeProducerPluginResults)
		return false
	}

	p.server.mu.RLock()
	pluginManager := p.server.pluginManager
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	p.server.mu.RUnlock()

	if pluginManager != nil {
		if results := pluginManager.DrainResults(maxPluginResultsPerDrain); len(results) > 0 {
			dropped := p.pluginResultsEdge.enqueue(groupPluginResults(results))
			p.dropEdgeTelemetry(edgeProducerPluginResults, edgeDropRetryBufferFull, dropped)
		}
	}
	return p.spoolPluginResults(capability, agentID, partition)
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
		p.logger.Warn().Err(err).Msg("Failed to push plugin telemetry; will retry on next push cycle")
		return false
	}

	if resp.Received {
		p.logger.Debug().Msg("Successfully pushed plugin telemetry")
		return true
	}

	p.logger.Warn().Msg("Gateway did not acknowledge plugin telemetry")
	return false
}

// holdForPendingEdgeRecord reports whether svc must not be polled this cycle: an
// rperf metrics status or k8s public endpoints snapshot it produced is still
// pending (held for a grant, or refused by the spool), or, for the k8s service,
// the agent holds no grant to emit a new snapshot under. For the k8s service it
// also returns the grant the snapshot is emitted under.
func (p *PushLoop) holdForPendingEdgeRecord(svc Service, now time.Time) (*edgev1.EdgeSignedCapabilityV1, bool) {
	if isRperfMetricsService(svc) && p.rperfEdge.hasPending() && !p.flushRperfEdgeMetrics(now) {
		return nil, true
	}
	if !isK8sPublicEndpointsService(svc) {
		return nil, false
	}
	if !p.flushPendingK8sPublicEndpointsEdge() {
		return nil, true
	}
	capability := p.edgeK8sPublicEndpointsCapability(now)
	if capability == nil {
		p.holdForGrant(edgeProducerK8sPublicEndpoints)
		return nil, true
	}
	return capability, false
}

// routeEndpointInventoryEdgeStatus carries the endpoint inventory service on the
// edge-record path, which is its only path: a pending scan is appended first,
// and without a grant the service is not polled, so its spooled scan waits on
// disk for one.
func (p *PushLoop) routeEndpointInventoryEdgeStatus(ctx context.Context, svc Service, provider SweepStatusProvider) {
	now := time.Now()
	if p.endpointInventoryEdge.built != nil && !p.flushEndpointInventoryEdge(now) {
		return
	}
	capability := p.edgeEndpointInventoryCapability(now)
	if capability == nil {
		p.holdForGrant(edgeProducerEndpointInventory)
		return
	}
	status, err := provider.GetStatus(ctx)
	if err != nil {
		p.logger.Warn().Err(err).Str("service", svc.Name()).Msg("Failed to get status from service")
		return
	}
	if status == nil {
		p.logger.Warn().Str("service", svc.Name()).Msg("Status provider returned nil response")
		return
	}
	p.emitEndpointInventoryEdgeStatus(status, capability, now)
}

// resolveServiceStatusRouting derives the service name, service type, and
// status source used to route a collected service status.
func resolveServiceStatusRouting(svc Service, status *proto.StatusResponse) (string, string, string) {
	serviceName := firstMetricNonEmpty(svc.Name(), status.GetServiceName())
	serviceType := strings.TrimSpace(status.GetServiceType())
	var source string
	if routing, ok := svc.(StatusRoutingProvider); ok {
		if value := strings.TrimSpace(routing.StatusServiceType()); value != "" {
			serviceType = value
		}
		source = strings.TrimSpace(routing.StatusSource())
	}
	if serviceType == "" {
		if rperfStatus(serviceName, "") {
			serviceType = rperfServiceType
		} else {
			serviceType = sweepType
		}
	}
	if source == "" {
		source = defaultStatusSource(status, serviceName, serviceType)
	}
	return serviceName, serviceType, source
}

// forwardStatusAddonTelemetry hands addon telemetry carried on a service status
// to the server's addon telemetry handler.
func (p *PushLoop) forwardStatusAddonTelemetry(svc Service, status *proto.StatusResponse) {
	telemetry, ok := svc.(StatusAddonTelemetryProvider)
	if !ok {
		return
	}
	if addonID, batch := telemetry.AddonTelemetryBatch(status); addonID != "" && batch != nil {
		p.server.handleAddonTelemetry(addonID, batch)
	}
}

// collectAllStatuses gathers the status summaries of every service for the
// status push. Services whose payload is durable data (endpoint inventory,
// bumblebee, k8s public endpoints, rperf metrics, and the sweep summary metric
// sample) are carried on the edge-record path instead and add no status.
func (p *PushLoop) collectAllStatuses(ctx context.Context) []*proto.GatewayServiceStatus {
	var statuses []*proto.GatewayServiceStatus

	p.server.mu.RLock()
	services := append([]Service(nil), p.server.services...)
	cfg := p.server.config
	sidecarStatus := p.server.sidecarStatus
	addonManager := p.server.addonManager
	p.server.mu.RUnlock()

	if status := p.buildAgentCapabilityGatewayStatus(cfg, sidecarStatus, addonManager); status != nil {
		statuses = append(statuses, status)
	}

	now := time.Now()
	for _, svc := range services {
		provider, ok := svc.(SweepStatusProvider)
		if !ok {
			continue
		}
		if status := p.collectServiceStatus(ctx, svc, provider, cfg, now); status != nil {
			statuses = append(statuses, status)
		}
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

	return statuses
}

// collectServiceStatus polls one service and returns its status summary for the
// status push, or nil when the service has none this cycle: it is held for a
// grant or a pending edge record, or its payload went to the edge spool.
func (p *PushLoop) collectServiceStatus(
	ctx context.Context,
	svc Service,
	provider SweepStatusProvider,
	cfg *ServerConfig,
	now time.Time,
) *proto.GatewayServiceStatus {
	k8sCapability, held := p.holdForPendingEdgeRecord(svc, now)
	if held {
		return nil
	}
	if isEndpointInventoryService(svc) {
		p.routeEndpointInventoryEdgeStatus(ctx, svc, provider)
		return nil
	}
	if isBumblebeeService(svc) {
		p.routeBumblebeeEdgeStatus(ctx, svc, provider, now)
		return nil
	}

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
		return nil
	}
	if status == nil {
		p.logger.Warn().Str("service", svc.Name()).Msg("Status provider returned nil response")
		return nil
	}
	serviceName, serviceType, source := resolveServiceStatusRouting(svc, status)
	if k8sCapability != nil {
		p.spoolK8sPublicEndpointsStatus(status, k8sCapability, cfg)
		return nil
	}
	p.forwardStatusAddonTelemetry(svc, status)
	if isRperfMetricsPayload(status, serviceName, serviceType, source) {
		p.spoolRperfMetricsStatus(status, serviceName, serviceType, now)
		return nil
	}

	converted := p.convertToGatewayStatusWithSource(status, svc.Name(), serviceType, source)
	if converted == nil {
		p.logger.Warn().Str("service", svc.Name()).Msg("Converted status is nil")
		return nil
	}
	if serviceType == sweepType {
		if metricPayload == nil {
			p.logger.Warn().
				Str("service", svc.Name()).
				Msg("Sweep status provider did not expose typed metric payload; skipping sweep status metrics")
		} else {
			p.pushSweepSummaryMetrics(metricPayload)
		}
	}
	return converted
}

// pushSweepSummaryMetrics carries the periodic sweep summary sample onto the
// edge spool under the metrics grant, or holds it until one is held.
func (p *PushLoop) pushSweepSummaryMetrics(payload map[string]any) {
	capability := p.edgeMetricsCapability(time.Now())
	if capability == nil {
		holdEdgeMetrics(p, sweepSummaryEdgeMetrics(), &p.sweepSummary, []map[string]any{payload})
		return
	}
	spoolEdgeMetrics(p, sweepSummaryEdgeMetrics(), &p.sweepSummary, []map[string]any{payload}, capability)
}

func (p *PushLoop) findSweepResultsProvider() SweepResultsProvider {
	if p.server == nil {
		return nil
	}
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
		return rperfMetricsSource
	}

	return "status"
}

func rperfStatus(serviceName string, serviceType string) bool {
	serviceName = strings.ToLower(strings.TrimSpace(serviceName))
	serviceType = strings.ToLower(strings.TrimSpace(serviceType))

	return serviceType == rperfServiceType ||
		serviceType == rperfCheckerName ||
		serviceType == "network_performance" ||
		serviceName == rperfServiceType ||
		serviceName == rperfCheckerName
}

func isRperfMetricsService(svc Service) bool {
	if svc == nil {
		return false
	}
	if rperfStatus(svc.Name(), "") {
		return true
	}
	if routing, ok := svc.(StatusRoutingProvider); ok {
		if rperfStatus(svc.Name(), routing.StatusServiceType()) {
			return true
		}
		if strings.EqualFold(strings.TrimSpace(routing.StatusSource()), rperfMetricsSource) {
			return true
		}
	}
	return false
}

func isRperfMetricsPayload(resp *proto.StatusResponse, serviceName, serviceType, source string) bool {
	if source == rperfMetricsSource {
		return true
	}
	if !rperfStatus(serviceName, serviceType) || resp == nil {
		return false
	}
	trimmed := bytes.TrimSpace(resp.GetMessage())
	return len(trimmed) > 0 && trimmed[0] != '{'
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
