/*
 * Copyright 2026 Carver Automation Corporation.
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
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
	"github.com/tetratelabs/wazero/api"
	gproto "google.golang.org/protobuf/proto"
)

const (
	pluginTelemetryMaxRecords = 256
	unknownTelemetrySource    = "unknown"
)

var (
	errPluginTelemetryMissingRecords = errors.New("plugin telemetry missing records")
	errPluginTelemetryInvalidPayload = errors.New("plugin telemetry invalid payload")
)

// PluginSignalTelemetry captures one plugin-emitted telemetry batch.
type PluginSignalTelemetry struct {
	AssignmentID string
	PluginID     string
	PluginName   string
	Batch        *addonpb.TelemetryBatch
	ObservedAt   time.Time
}

type pluginTelemetryBatchJSON struct {
	Source  pluginTelemetrySourceJSON   `json:"source"`
	Records []pluginTelemetryRecordJSON `json:"records"`
}

type pluginTelemetrySourceJSON struct {
	SourceType     string            `json:"source_type"`
	SourceInstance string            `json:"source_instance"`
	Metadata       map[string]string `json:"metadata"`
}

type pluginTelemetryRecordJSON struct {
	EventID              string            `json:"event_id"`
	ObservedTimeUnixNano int64             `json:"observed_time_unix_nano"`
	EventTimeUnixNano    int64             `json:"event_time_unix_nano"`
	PayloadKind          any               `json:"payload_kind"`
	Payload              json.RawMessage   `json:"payload"`
	Metadata             map[string]string `json:"metadata"`
}

func (e *pluginExecution) hostEmitTelemetry(_ context.Context, mod api.Module, ptr, size uint32) int32 {
	if !e.hasCapability(pluginCapabilityEmitTelemetry) {
		return pluginErrDenied
	}
	if size == 0 {
		return pluginErrInvalid
	}

	payload, ok := readMemory(mod, ptr, size)
	if !ok {
		return pluginErrInvalid
	}
	if len(payload) > pluginMaxPayloadBytes {
		return pluginErrTooLarge
	}

	signal, err := decodePluginTelemetry(payload, e.assignment)
	if err != nil {
		e.manager.logger.Warn().
			Err(err).
			Str("assignment_id", e.assignment.AssignmentID).
			Str("plugin_id", e.assignment.PluginID).
			Msg("Rejected plugin telemetry payload")
		return pluginErrInvalid
	}

	// Collapse per-cycle condition events (Proxmox pressure/bottleneck and
	// similar) down to level transitions. A suppressed batch is accepted but not
	// forwarded — the plugin re-emits the same condition next cycle regardless.
	signal.Batch = e.manager.conditions.filter(signal.AssignmentID, signal.Batch)
	if signal.Batch == nil || len(signal.Batch.Records) == 0 {
		return pluginErrOK
	}

	e.manager.enqueueSignal(signal)
	return pluginErrOK
}

func decodePluginTelemetry(payload []byte, assignment *pluginAssignment) (PluginSignalTelemetry, error) {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()

	var batch pluginTelemetryBatchJSON
	if err := decoder.Decode(&batch); err != nil {
		return PluginSignalTelemetry{}, fmt.Errorf("%w: %w", errPluginTelemetryInvalidPayload, err)
	}
	if len(batch.Records) == 0 {
		return PluginSignalTelemetry{}, errPluginTelemetryMissingRecords
	}
	if len(batch.Records) > pluginTelemetryMaxRecords {
		return PluginSignalTelemetry{}, fmt.Errorf("%w: too many records: %d", errPluginTelemetryInvalidPayload, len(batch.Records))
	}

	now := time.Now().UTC()
	observedUnixNano := now.UnixNano()
	sourceType := strings.TrimSpace(batch.Source.SourceType)
	if sourceType == "" {
		sourceType = firstNonEmptyPluginTelemetry(assignment.Name, assignment.PluginID, "plugin")
	}
	sourceInstance := strings.TrimSpace(batch.Source.SourceInstance)
	if sourceInstance == "" {
		sourceInstance = firstNonEmptyPluginTelemetry(assignment.AssignmentID, assignment.PluginID, unknownTelemetrySource)
	}

	out := &addonpb.TelemetryBatch{
		Source: &addonpb.TelemetrySource{
			SourceType:     sourceType,
			SourceInstance: sourceInstance,
			Metadata:       cleanStringMap(batch.Source.Metadata),
		},
		Records: make([]*addonpb.TelemetryRecord, 0, len(batch.Records)),
	}

	for _, record := range batch.Records {
		payloadKind, err := telemetryPayloadKind(record.PayloadKind)
		if err != nil {
			return PluginSignalTelemetry{}, err
		}
		payloadBytes, err := telemetryRecordPayload(record.Payload, payloadKind)
		if err != nil {
			return PluginSignalTelemetry{}, err
		}

		observedAt := record.ObservedTimeUnixNano
		if observedAt == 0 {
			observedAt = observedUnixNano
		}
		eventAt := record.EventTimeUnixNano
		if eventAt == 0 {
			eventAt = observedAt
		}

		out.Records = append(out.Records, &addonpb.TelemetryRecord{
			EventId:              strings.TrimSpace(record.EventID),
			ObservedTimeUnixNano: observedAt,
			EventTimeUnixNano:    eventAt,
			PayloadKind:          payloadKind,
			Payload:              payloadBytes,
			Metadata:             cleanStringMap(record.Metadata),
		})
	}

	return PluginSignalTelemetry{
		AssignmentID: assignment.AssignmentID,
		PluginID:     assignment.PluginID,
		PluginName:   assignment.Name,
		Batch:        out,
		ObservedAt:   now,
	}, nil
}

func telemetryRecordPayload(raw json.RawMessage, kind addonpb.TelemetryPayloadKind) ([]byte, error) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return nil, errPluginTelemetryInvalidPayload
	}

	if kind == addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS {
		return telemetryMetricPayload(raw)
	}

	if raw[0] != '"' {
		return append([]byte(nil), raw...), nil
	}

	var text string
	if err := json.Unmarshal(raw, &text); err != nil {
		return nil, fmt.Errorf("%w: %w", errPluginTelemetryInvalidPayload, err)
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, errPluginTelemetryInvalidPayload
	}

	return []byte(text), nil
}

func telemetryMetricPayload(raw json.RawMessage) ([]byte, error) {
	if raw[0] != '"' {
		return nil, fmt.Errorf("%w: serviceradar metric payload must be base64 protobuf bytes", errPluginTelemetryInvalidPayload)
	}

	var encoded string
	if err := json.Unmarshal(raw, &encoded); err != nil {
		return nil, fmt.Errorf("%w: %w", errPluginTelemetryInvalidPayload, err)
	}

	payload, err := base64.StdEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return nil, fmt.Errorf("%w: invalid serviceradar metric base64 payload: %w", errPluginTelemetryInvalidPayload, err)
	}

	var batch metricpb.MetricBatch
	if err := gproto.Unmarshal(payload, &batch); err != nil {
		return nil, fmt.Errorf("%w: invalid serviceradar metric protobuf payload: %w", errPluginTelemetryInvalidPayload, err)
	}
	if batch.GetSchemaVersion() != metricEnvelopeSchemaVersion || len(batch.GetMetrics()) == 0 {
		return nil, fmt.Errorf("%w: invalid serviceradar metric batch", errPluginTelemetryInvalidPayload)
	}

	return payload, nil
}

func telemetryPayloadKind(value any) (addonpb.TelemetryPayloadKind, error) {
	switch v := value.(type) {
	case string:
		switch strings.ToLower(strings.TrimSpace(v)) {
		case "ocsf_event", "telemetry_payload_kind_ocsf_event":
			return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT, nil
		case "otel_log", "telemetry_payload_kind_otel_log":
			return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTEL_LOG, nil
		case "serviceradar_metrics", "serviceradar_metric", "serviceradar.metric.v1",
			"telemetry_payload_kind_serviceradar_metrics":
			return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS, nil
		}
	case json.Number:
		i, err := v.Int64()
		if err == nil {
			return telemetryPayloadKindFromInt(i)
		}
	case float64:
		return telemetryPayloadKindFromInt(int64(v))
	}

	return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_UNSPECIFIED,
		fmt.Errorf("%w: unsupported payload_kind", errPluginTelemetryInvalidPayload)
}

func telemetryPayloadKindFromInt(value int64) (addonpb.TelemetryPayloadKind, error) {
	switch addonpb.TelemetryPayloadKind(value) {
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT:
		return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT, nil
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTEL_LOG:
		return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTEL_LOG, nil
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES:
		return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES, nil
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_LOGS:
		return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_LOGS, nil
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_METRICS:
		return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_METRICS, nil
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_DERIVED_METRIC:
		return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_DERIVED_METRIC, nil
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS:
		return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS, nil
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1:
		// Refused deliberately, and named rather than left to the default so the
		// refusal is a decision rather than an oversight.
		//
		// DISCOVERY_V1 carries device observations about OTHER hosts into the
		// inventory pipeline. This function maps a payload kind a WASM PLUGIN
		// asked for; letting a plugin select it would let plugin-supplied bytes
		// mint device identity on the native add-on path. Wasm plugins already
		// have a route to inventory -- `plugin-result` into
		// DeviceDiscoveryIngestor -- which is scoped and authenticated for that
		// purpose. This is not.
		return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_UNSPECIFIED,
			fmt.Errorf("%w: payload_kind discovery_v1 is not available to plugins",
				errPluginTelemetryInvalidPayload)
	case addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_UNSPECIFIED:
		return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_UNSPECIFIED,
			fmt.Errorf("%w: unsupported payload_kind", errPluginTelemetryInvalidPayload)
	default:
		return addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_UNSPECIFIED,
			fmt.Errorf("%w: unsupported payload_kind", errPluginTelemetryInvalidPayload)
	}
}

func cleanStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}

	cleaned := make(map[string]string, len(values))
	for key, value := range values {
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if key == "" || value == "" {
			continue
		}
		cleaned[key] = value
	}
	if len(cleaned) == 0 {
		return nil
	}

	return cleaned
}

func firstNonEmptyPluginTelemetry(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}
