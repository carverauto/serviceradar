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
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/proto"
)

func (p *PushLoop) buildPluginGatewayStatus(
	result PluginResult,
	agentID string,
	partition string,
	kvStoreID string,
) *proto.GatewayServiceStatus {
	payload, available, err := p.normalizePluginPayload(result, agentID, partition)
	if err != nil {
		payload = p.buildPluginErrorPayload(result, err, agentID, partition)
		available = false
	}

	serviceName := pluginServiceName(result)
	gatewayID := gatewayIDFromClient(p.gateway)

	return &proto.GatewayServiceStatus{
		ServiceName:  serviceName,
		Available:    available,
		Message:      payload,
		ServiceType:  "plugin",
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       "plugin-result",
		KvStoreId:    kvStoreID,
	}
}

func (p *PushLoop) normalizePluginPayload(
	result PluginResult,
	agentID string,
	partition string,
) ([]byte, bool, error) {
	if len(result.Payload) == 0 {
		return nil, false, errPluginEmptyPayload
	}

	decoder := json.NewDecoder(bytes.NewReader(result.Payload))
	decoder.UseNumber()

	var payload map[string]interface{}
	if err := decoder.Decode(&payload); err != nil {
		return nil, false, fmt.Errorf("invalid json: %w", err)
	}

	statusRaw, ok := payload["status"].(string)
	if !ok {
		return nil, false, errPluginMissingStatus
	}
	status := normalizePluginStatus(statusRaw)
	if !isValidPluginStatus(status) {
		return nil, false, fmt.Errorf("%w: %s", errPluginInvalidStatus, statusRaw)
	}

	if _, ok := payload["metrics"]; ok {
		// Tolerate plugins built against the pre-cutover SDK that still embed a
		// top-level `metrics` array in the result body: drop it (it was never
		// ingested anyway) and continue, so the check's real status/summary/labels
		// still flow instead of the whole result being discarded as unavailable.
		// Metrics must now be emitted via emit_telemetry (serviceradar metrics).
		delete(payload, "metrics")
		p.logger.Warn().
			Str("plugin", pluginServiceName(result)).
			Msg("dropping legacy 'metrics' in plugin result; emit metrics via emit_telemetry serviceradar metrics")
	}

	summary, ok := payload["summary"].(string)
	if !ok || strings.TrimSpace(summary) == "" {
		return nil, false, errPluginMissingSummary
	}

	payload["status"] = status
	ensureObservedAt(payload, result.ObservedAt)
	labels := normalizePluginLabels(payload)

	if result.AssignmentID != "" {
		labels["assignment_id"] = result.AssignmentID
	}
	if result.PluginID != "" {
		labels["plugin_id"] = result.PluginID
	}
	if result.PluginName != "" {
		labels["plugin_name"] = result.PluginName
	}
	if agentID != "" {
		labels["agent_id"] = agentID
	}
	if partition != "" {
		labels["partition"] = partition
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return nil, false, fmt.Errorf("marshal payload: %w", err)
	}

	return data, pluginStatusAvailable(status), nil
}

func (p *PushLoop) buildPluginErrorPayload(
	result PluginResult,
	err error,
	agentID string,
	partition string,
) []byte {
	summary := "plugin result invalid"
	if err != nil {
		summary = fmt.Sprintf("plugin result invalid: %s", err)
	}

	payload := map[string]interface{}{
		"status":      "UNKNOWN",
		"summary":     summary,
		"observed_at": time.Now().UTC().Format(time.RFC3339Nano),
		"labels":      map[string]interface{}{},
	}

	labels := normalizePluginLabels(payload)
	if result.AssignmentID != "" {
		labels["assignment_id"] = result.AssignmentID
	}
	if result.PluginID != "" {
		labels["plugin_id"] = result.PluginID
	}
	if result.PluginName != "" {
		labels["plugin_name"] = result.PluginName
	}
	if agentID != "" {
		labels["agent_id"] = agentID
	}
	if partition != "" {
		labels["partition"] = partition
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return []byte(`{"status":"UNKNOWN","summary":"plugin result invalid"}`)
	}

	return data
}

func normalizePluginLabels(payload map[string]interface{}) map[string]interface{} {
	if payload == nil {
		return map[string]interface{}{}
	}

	if raw, ok := payload["labels"]; ok {
		if labels, ok := raw.(map[string]interface{}); ok {
			return labels
		}
		if labels, ok := raw.(map[string]string); ok {
			converted := make(map[string]interface{}, len(labels))
			for key, value := range labels {
				converted[key] = value
			}
			payload["labels"] = converted
			return converted
		}
	}

	labels := map[string]interface{}{}
	payload["labels"] = labels
	return labels
}

func ensureObservedAt(payload map[string]interface{}, observed time.Time) {
	raw, ok := payload["observed_at"].(string)
	if ok && strings.TrimSpace(raw) != "" {
		return
	}

	if observed.IsZero() {
		observed = time.Now().UTC()
	}
	payload["observed_at"] = observed.Format(time.RFC3339Nano)
}

func pluginServiceName(result PluginResult) string {
	if result.PluginName != "" {
		return result.PluginName
	}
	if result.PluginID != "" {
		return result.PluginID
	}
	if result.AssignmentID != "" {
		return result.AssignmentID
	}
	return "plugin"
}

const (
	pluginStatusOK       = "OK"
	pluginStatusWarning  = "WARNING"
	pluginStatusCritical = "CRITICAL"
	pluginStatusUnknown  = "UNKNOWN"
)

func isValidPluginStatus(status string) bool {
	switch status {
	case pluginStatusOK, pluginStatusWarning, pluginStatusCritical, pluginStatusUnknown:
		return true
	default:
		return false
	}
}

func normalizePluginStatus(status string) string {
	switch strings.ToUpper(strings.TrimSpace(status)) {
	case "FAILED", "FAIL", "ERROR":
		return pluginStatusCritical
	default:
		return strings.ToUpper(strings.TrimSpace(status))
	}
}

func pluginStatusAvailable(status string) bool {
	switch status {
	case pluginStatusOK, pluginStatusWarning:
		return true
	case pluginStatusCritical, pluginStatusUnknown:
		return false
	default:
		return false
	}
}

func shouldSendPluginTelemetry(snapshot PluginEngineSnapshot) bool {
	if snapshot.AssignmentsTotal > 0 ||
		snapshot.AssignmentsAdmitted > 0 ||
		snapshot.ExecTotal > 0 ||
		snapshot.Limits.MaxMemoryMB > 0 ||
		snapshot.Limits.MaxCPUMS > 0 ||
		snapshot.Limits.MaxConcurrent > 0 ||
		snapshot.Limits.MaxOpenConnections > 0 {
		return true
	}
	return false
}

func buildPluginTelemetryPayload(
	snapshot PluginEngineSnapshot,
	agentID string,
	partition string,
) ([]byte, bool) {
	healthy, reason := pluginTelemetryHealth(snapshot)

	payload := map[string]interface{}{
		"schema":      "serviceradar.plugin_engine_telemetry.v1",
		"observed_at": snapshot.ObservedAt.Format(time.RFC3339Nano),
		"agent_id":    agentID,
		"partition":   partition,
		"health":      map[string]interface{}{"status": healthStatusLabel(healthy), "reason": reason},
		"limits": map[string]interface{}{
			"max_memory_mb":        snapshot.Limits.MaxMemoryMB,
			"max_cpu_ms":           snapshot.Limits.MaxCPUMS,
			"max_concurrent":       snapshot.Limits.MaxConcurrent,
			"max_open_connections": snapshot.Limits.MaxOpenConnections,
		},
		"requested": map[string]interface{}{
			"memory_mb":        snapshot.RequestedMemoryMB,
			"cpu_ms":           snapshot.RequestedCPUMS,
			"open_connections": snapshot.RequestedConnections,
		},
		"runtime": map[string]interface{}{
			"active_executions": snapshot.ActiveExecutions,
			"open_connections":  snapshot.OpenConnections,
		},
		"assignments": map[string]interface{}{
			"total":    snapshot.AssignmentsTotal,
			"admitted": snapshot.AssignmentsAdmitted,
			"rejected": snapshot.AssignmentsRejected,
		},
		"executions": map[string]interface{}{
			"total":           snapshot.ExecTotal,
			"failures":        snapshot.ExecFailures,
			"last_exec_at":    formatTimestamp(snapshot.LastExecAt),
			"last_failure_at": formatTimestamp(snapshot.LastFailureAt),
		},
		"config": map[string]interface{}{
			"last_updated_at": formatTimestamp(snapshot.LastConfigAt),
		},
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return []byte(`{"schema":"serviceradar.plugin_engine_telemetry.v1","health":{"status":"unknown"}}`), false
	}

	return data, healthy
}

func pluginTelemetryHealth(snapshot PluginEngineSnapshot) (bool, string) {
	if snapshot.AssignmentsRejected > 0 {
		return false, "admission_denied"
	}

	if snapshot.ExecFailures > 0 && time.Since(snapshot.LastFailureAt) < 5*time.Minute {
		return false, "recent_execution_failures"
	}

	return true, ""
}

func healthStatusLabel(healthy bool) string {
	if healthy {
		return "ok"
	}
	return "degraded"
}

func formatTimestamp(ts time.Time) string {
	if ts.IsZero() {
		return ""
	}
	return ts.UTC().Format(time.RFC3339Nano)
}
