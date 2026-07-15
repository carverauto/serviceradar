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
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"strings"
	"time"
)

const (
	actionResultAckSchema = "serviceradar.action_result_ingest_ack.v1"
	deviceDiscoverySchema = "serviceradar.device_discovery.v1"
)

func (m *PluginManager) enqueueActionResult(
	ctx context.Context,
	assignment *pluginAssignment,
	payload []byte,
) ([]byte, error) {
	if assignment == nil || len(payload) == 0 || len(payload) > pluginMaxActionIngestResultBytes {
		return nil, errPluginActionResultInvalid
	}

	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	var result map[string]any
	if err := decoder.Decode(&result); err != nil {
		return nil, errPluginActionResultInvalid
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return nil, errPluginActionResultInvalid
	}
	status, _ := result["status"].(string)
	summary, _ := result["summary"].(string)
	status = normalizePluginStatus(status)
	if !isValidPluginStatus(status) || strings.TrimSpace(summary) == "" {
		return nil, errPluginActionResultInvalid
	}

	ack := boundedActionResultAck(result, status)
	if err := m.enqueueResult(ctx, PluginResult{
		AssignmentID: assignment.AssignmentID,
		PluginID:     assignment.PluginID,
		PluginName:   assignment.Name,
		Payload:      append([]byte(nil), payload...),
		ObservedAt:   time.Now().UTC(),
	}); err != nil {
		return nil, fmt.Errorf("%w: %w", errPluginActionResultBackpressure, err)
	}

	encoded, err := json.Marshal(ack)
	if err != nil {
		return nil, errPluginActionResultInvalid
	}
	return encoded, nil
}

func boundedActionResultAck(result map[string]any, pluginStatus string) map[string]any {
	status := commandStatusSucceeded
	if pluginStatus == pluginStatusCritical || pluginStatus == pluginStatusUnknown {
		status = commandStatusFailed
	}

	ack := map[string]any{
		"schema":        actionResultAckSchema,
		"status":        status,
		"plugin_status": pluginStatus,
		"result_queued": true,
	}

	for _, discovery := range actionDeviceDiscoveries(result) {
		if stringField(discovery, "schema") != deviceDiscoverySchema {
			continue
		}
		copyBoundedString(ack, "collection_id", discovery, "collection_id", 160)
		copyBoundedString(ack, "content_hash", discovery, "reference_hash", 128)
		if devices, ok := discovery["devices"].([]any); ok {
			ack["device_count"] = len(devices)
		}
		if metadata, ok := discovery["metadata"].(map[string]any); ok {
			copySafeCount(ack, metadata, "page_count")
			copySafeCount(ack, metadata, "received_rows")
			copySafeCount(ack, metadata, "invalid_rows")
			copySafeCount(ack, metadata, "duplicate_rows")
			if complete, ok := metadata["snapshot_complete"].(bool); ok {
				ack["snapshot_complete"] = complete
			}
		}
		break
	}

	return ack
}

func actionDeviceDiscoveries(result map[string]any) []map[string]any {
	raw, ok := result["device_discovery"].([]any)
	if !ok {
		return nil
	}
	discoveries := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		if discovery, ok := item.(map[string]any); ok {
			discoveries = append(discoveries, discovery)
		}
	}
	return discoveries
}

func copyBoundedString(target map[string]any, targetKey string, source map[string]any, sourceKey string, max int) {
	value := stringField(source, sourceKey)
	if value != "" && len(value) <= max {
		target[targetKey] = value
	}
}

func copySafeCount(target, source map[string]any, key string) {
	switch value := source[key].(type) {
	case json.Number:
		if parsed, err := value.Int64(); err == nil && parsed >= 0 {
			target[key] = parsed
		}
	case float64:
		if value >= 0 && value <= float64(^uint32(0)) && value == math.Trunc(value) {
			target[key] = int64(value)
		}
	case int:
		if value >= 0 {
			target[key] = value
		}
	}
}

func stringField(values map[string]any, key string) string {
	value, _ := values[key].(string)
	return strings.TrimSpace(value)
}
