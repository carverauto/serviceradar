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
	"encoding/json"
	"fmt"
	"strings"
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// pluginResultItemFromPayload maps one normalized plugin-result
// payload (the serviceradar.plugin_result.v1 JSON core ingests today) onto
// its typed edge item. Fields with a typed home are lifted; JSON sub-bodies
// core stores or correlates on (event bodies, advisory source/snapshot,
// device metadata) ride verbatim in their *_json fields. Schema'd contract
// payloads that travel inside `details` today stay inside details verbatim.
func pluginResultItemFromPayload(payload map[string]interface{}, result PluginResult) *edgev1.WasmPluginResultItemV1 {
	item := &edgev1.WasmPluginResultItemV1{
		SchemaVersion:      uint32(payloadNumber(payload, "schema_version")),
		Status:             pluginResultStatus(payloadString(payload, "status")),
		Summary:            payloadString(payload, "summary"),
		Details:            payloadDetails(payload),
		Perfdata:           payloadString(payload, "perfdata"),
		Labels:             payloadLabels(payload),
		AlertHint:          payloadBool(payload, "alert_hint"),
		ConditionId:        payloadString(payload, "condition_id"),
		CheckInstanceId:    payloadString(payload, "check_instance_id"),
		MonitoredServiceId: payloadString(payload, "monitored_service_id"),
		DeviceUid:          payloadString(payload, "device_uid"),
		ServiceName:        pluginServiceName(result),
		ServiceType:        "plugin",
	}
	if item.SchemaVersion == 0 {
		item.SchemaVersion = 1
	}
	if item.Summary == "" {
		item.Summary = payloadString(payload, "message")
	}
	if ts, err := time.Parse(time.RFC3339Nano, payloadString(payload, "observed_at")); err == nil {
		item.ObservedAtUnixNano = ts.UnixNano()
	}
	if acks := payloadStringList(payload, runOverridesAckKey); len(acks) > 0 {
		item.RunOverridesAcknowledged = acks
	}
	for _, raw := range payloadList(payload, "display") {
		widget, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		item.Display = append(item.Display, &edgev1.PluginDisplayInstructionV1{
			Widget:   payloadString(widget, "widget"),
			Label:    payloadString(widget, "label"),
			Value:    payloadString(widget, "value"),
			Tone:     payloadString(widget, "tone"),
			Layout:   payloadString(widget, "layout"),
			DataJson: payloadRawJSON(widget["data"]),
		})
	}
	for _, raw := range payloadList(payload, "events") {
		event, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		envelope := &edgev1.PluginEventEnvelopeV1{
			Id:           payloadString(event, "id"),
			ClassUid:     uint32(payloadNumber(event, "class_uid")),
			CategoryUid:  uint32(payloadNumber(event, "category_uid")),
			TypeUid:      uint32(payloadNumber(event, "type_uid")),
			ActivityId:   uint32(payloadNumber(event, "activity_id")),
			ActivityName: payloadString(event, "activity_name"),
			SeverityId:   uint32(payloadNumber(event, "severity_id")),
			Severity:     payloadString(event, "severity"),
			Message:      payloadString(event, "message"),
			PayloadJson:  payloadRawJSON(event),
		}
		if ts, err := time.Parse(time.RFC3339Nano, payloadString(event, "time")); err == nil {
			envelope.TimeUnixNano = ts.UnixNano()
		}
		item.Events = append(item.Events, envelope)
	}
	for _, raw := range payloadList(payload, "device_discovery") {
		envelope, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		item.DeviceDiscovery = append(item.DeviceDiscovery, pluginDiscoveryItem(envelope))
	}
	for _, key := range []string{"advisory_feeds", "advisory_feed", "vulnerability_advisories"} {
		for _, raw := range payloadList(payload, key) {
			batch, ok := raw.(map[string]interface{})
			if !ok {
				continue
			}
			item.AdvisoryFeeds = append(item.AdvisoryFeeds, pluginAdvisoryBatch(batch))
		}
	}
	if page, ok := payload["threat_intel"].(map[string]interface{}); ok {
		item.ThreatIntelPage = &edgev1.PluginContractPayloadV1{
			Schema:      payloadString(page, "schema"),
			PayloadJson: payloadRawJSON(page),
		}
	}
	return item
}

func pluginDiscoveryItem(envelope map[string]interface{}) *edgev1.PluginDeviceDiscoveryItemV1 {
	item := &edgev1.PluginDeviceDiscoveryItemV1{
		Schema:        payloadString(envelope, "schema"),
		CollectionId:  payloadString(envelope, "collection_id"),
		Source:        payloadString(envelope, "source"),
		ObservedAt:    payloadString(envelope, "observed_at"),
		ReferenceHash: payloadString(envelope, "reference_hash"),
		MetadataJson:  payloadRawJSON(envelope["metadata"]),
	}
	for _, raw := range payloadList(envelope, "devices") {
		device, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		item.Devices = append(item.Devices, pluginDiscoveredDevice(device))
	}
	return item
}

func pluginDiscoveredDevice(device map[string]interface{}) *edgev1.PluginDiscoveredDeviceV1 {
	out := &edgev1.PluginDiscoveredDeviceV1{
		DeviceId:     payloadString(device, "device_id"),
		Hostname:     payloadString(device, "hostname"),
		Ip:           payloadString(device, "ip"),
		Mac:          payloadString(device, "mac"),
		Serial:       payloadString(device, "serial"),
		VendorName:   payloadString(device, "vendor_name"),
		Model:        payloadString(device, "model"),
		Type:         payloadString(device, "type"),
		Role:         payloadString(device, "role"),
		Status:       payloadString(device, "status"),
		Labels:       payloadStringMap(device["labels"]),
		MetadataJson: payloadRawJSON(device["metadata"]),
	}
	if value, ok := device["is_available"].(bool); ok {
		out.HasIsAvailable = true
		out.IsAvailable = value
	}
	if location, ok := device["location"].(map[string]interface{}); ok {
		loc := &edgev1.PluginDeviceLocationV1{
			SiteCode: payloadString(location, "site_code"),
			SiteName: payloadString(location, "site_name"),
		}
		if _, ok := location["latitude"]; ok {
			loc.HasLatitude = true
			loc.Latitude = payloadFloat(location, "latitude")
		}
		if _, ok := location["longitude"]; ok {
			loc.HasLongitude = true
			loc.Longitude = payloadFloat(location, "longitude")
		}
		out.Location = loc
	}
	return out
}

func pluginAdvisoryBatch(batch map[string]interface{}) *edgev1.PluginAdvisoryFeedBatchV1 {
	out := &edgev1.PluginAdvisoryFeedBatchV1{
		SchemaVersion: payloadString(batch, "schema_version"),
		ProducerId:    payloadString(batch, "producer_id"),
		SourceJson:    payloadRawJSON(batch["source"]),
		SnapshotJson:  payloadRawJSON(batch["snapshot"]),
		MetadataJson:  payloadRawJSON(batch["metadata"]),
	}
	for _, raw := range payloadList(batch, "advisories") {
		out.AdvisoriesJson = append(out.AdvisoriesJson, payloadRawJSON(raw))
	}
	return out
}

func pluginResultStatus(status string) edgev1.PluginResultStatus {
	switch normalizePluginStatus(status) {
	case pluginStatusOK:
		return edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_OK
	case pluginStatusWarning:
		return edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_WARNING
	case pluginStatusCritical:
		return edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_CRITICAL
	default:
		return edgev1.PluginResultStatus_PLUGIN_RESULT_STATUS_UNKNOWN
	}
}

func payloadString(payload map[string]interface{}, key string) string {
	if value, ok := payload[key].(string); ok {
		return value
	}
	return ""
}

func payloadDetails(payload map[string]interface{}) string {
	switch value := payload["details"].(type) {
	case string:
		return value
	case nil:
		return ""
	default:
		return string(payloadRawJSON(value))
	}
}

func payloadBool(payload map[string]interface{}, key string) bool {
	value, _ := payload[key].(bool)
	return value
}

func payloadNumber(payload map[string]interface{}, key string) int64 {
	switch value := payload[key].(type) {
	case json.Number:
		n, _ := value.Int64()
		return n
	case float64:
		return int64(value)
	case int:
		return int64(value)
	case int64:
		return value
	default:
		return 0
	}
}

func payloadFloat(payload map[string]interface{}, key string) float64 {
	switch value := payload[key].(type) {
	case json.Number:
		f, _ := value.Float64()
		return f
	case float64:
		return value
	default:
		return 0
	}
}

func payloadList(payload map[string]interface{}, key string) []interface{} {
	if list, ok := payload[key].([]interface{}); ok {
		return list
	}
	return nil
}

func payloadStringList(payload map[string]interface{}, key string) []string {
	// The host stamps its acknowledgement list as a []string on the shared
	// payload map; guest JSON lists arrive as []interface{}.
	if values, ok := payload[key].([]string); ok {
		out := make([]string, 0, len(values))
		for _, value := range values {
			if value != "" {
				out = append(out, value)
			}
		}
		return out
	}
	var out []string
	for _, raw := range payloadList(payload, key) {
		if value, ok := raw.(string); ok && value != "" {
			out = append(out, value)
		}
	}
	return out
}

func payloadLabels(payload map[string]interface{}) map[string]string {
	return payloadStringMap(payload["labels"])
}

func payloadStringMap(raw interface{}) map[string]string {
	labels, ok := raw.(map[string]interface{})
	if !ok || len(labels) == 0 {
		return nil
	}
	out := make(map[string]string, len(labels))
	for key, value := range labels {
		if text, ok := value.(string); ok {
			out[key] = text
		} else {
			out[key] = strings.TrimSpace(fmt.Sprint(value))
		}
	}
	return out
}

func payloadRawJSON(value interface{}) []byte {
	if value == nil {
		return nil
	}
	data, err := json.Marshal(value)
	if err != nil {
		return nil
	}
	return data
}
