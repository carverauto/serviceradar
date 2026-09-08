package main

import (
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func defaultConfig() Config {
	return Config{TimeoutMS: defaultTimeoutMS}
}

func newPluginResult(status sdk.Status, summary string) *pluginResult {
	if status == "" {
		status = sdk.StatusUnknown
	}
	if strings.TrimSpace(summary) == "" {
		summary = string(status)
	}

	return &pluginResult{
		Status:        status,
		Summary:       summary,
		SchemaVersion: 1,
		ObservedAt:    time.Now().UTC().Format(time.RFC3339Nano),
	}
}

func (r *pluginResult) AddLabel(key, value string) {
	if r == nil || strings.TrimSpace(key) == "" {
		return
	}
	if r.Labels == nil {
		r.Labels = map[string]string{}
	}
	r.Labels[key] = value
}

// EmitConditionEvent emits an OCSF condition event that carries its discrete
// LEVEL (ok/warning/critical) in `unmapped` alongside the condition key. This
// plugin is re-instantiated every check cycle and keeps no state across cycles,
// so it cannot itself suppress a condition that simply stays in the same level.
// Emitting the level (plus the numeric ratio/thresholds in `extra`) lets the
// long-lived host de-duplicate on (condition_key, level) and apply hysteresis,
// collapsing per-cycle repeats into a single event per level transition.
func (r *pluginResult) EmitConditionEvent(
	severity sdk.Severity,
	summary, conditionKey, level string,
	extra map[string]any,
) {
	if r == nil || strings.TrimSpace(summary) == "" {
		return
	}

	event := sdk.NewOCSFEventLogActivity(summary, severity)
	if conditionKey != "" || level != "" || len(extra) > 0 {
		if event.Unmapped == nil {
			event.Unmapped = map[string]any{}
		}
		if conditionKey != "" {
			event.Unmapped["condition_key"] = conditionKey
		}
		if level != "" {
			event.Unmapped["level"] = level
		}
		for k, v := range extra {
			event.Unmapped[k] = v
		}
	}
	r.TelemetryEvents = append(r.TelemetryEvents, event)
}

func (r *pluginResult) AddDeviceDiscovery(discovery sdk.DeviceDiscovery) {
	if r == nil {
		return
	}
	if discovery.Schema == "" {
		discovery.Schema = sdk.DeviceDiscoverySchemaV1
	}
	r.DeviceDiscovery = append(r.DeviceDiscovery, discovery)
}

func submitPluginResult(result *pluginResult) error {
	if result == nil {
		result = newPluginResult(sdk.StatusUnknown, "")
	}
	if result.SchemaVersion == 0 {
		result.SchemaVersion = 1
	}
	if result.ObservedAt == "" {
		result.ObservedAt = time.Now().UTC().Format(time.RFC3339Nano)
	}
	emitProxmoxTelemetry(result.TelemetryEvents, pluginID)

	return sdk.SubmitResult(result.JSON())
}

func (r *pluginResult) JSON() []byte {
	var b strings.Builder
	b.WriteString(`{"status":`)
	b.WriteString(strconv.Quote(string(r.Status)))
	b.WriteString(`,"summary":`)
	b.WriteString(strconv.Quote(r.Summary))
	if r.Details != "" {
		b.WriteString(`,"details":`)
		b.WriteString(strconv.Quote(r.Details))
	}
	if len(r.Labels) > 0 {
		b.WriteString(`,"labels":{`)
		keys := make([]string, 0, len(r.Labels))
		for key := range r.Labels {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for i, key := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(strconv.Quote(key))
			b.WriteByte(':')
			b.WriteString(strconv.Quote(r.Labels[key]))
		}
		b.WriteByte('}')
	}
	if len(r.DeviceDiscovery) > 0 {
		b.WriteString(`,"device_discovery":`)
		appendDeviceDiscoveriesJSON(&b, r.DeviceDiscovery)
	}
	if r.ObservedAt != "" {
		b.WriteString(`,"observed_at":`)
		b.WriteString(strconv.Quote(r.ObservedAt))
	}
	if r.SchemaVersion > 0 {
		b.WriteString(`,"schema_version":`)
		b.WriteString(strconv.Itoa(r.SchemaVersion))
	}
	b.WriteByte('}')

	return []byte(b.String())
}

func appendEventsJSON(b *strings.Builder, events []sdk.OCSFEvent) {
	b.WriteByte('[')
	for i, event := range events {
		if i > 0 {
			b.WriteByte(',')
		}
		appendEventJSON(b, event)
	}
	b.WriteByte(']')
}

func appendEventJSON(b *strings.Builder, event sdk.OCSFEvent) {
	b.WriteByte('{')
	first := true
	appendStringField(b, &first, "id", event.ID)
	if !event.Time.IsZero() {
		appendFieldName(b, &first, "time")
		b.WriteString(strconv.Quote(event.Time.UTC().Format(time.RFC3339Nano)))
	}
	appendIntField(b, &first, "class_uid", event.ClassUID)
	appendIntField(b, &first, "category_uid", event.CategoryUID)
	appendIntField(b, &first, "type_uid", event.TypeUID)
	appendIntField(b, &first, "activity_id", event.ActivityID)
	appendStringField(b, &first, "activity_name", event.ActivityName)
	appendIntField(b, &first, "severity_id", event.SeverityID)
	appendStringField(b, &first, "severity", event.Severity)
	appendStringField(b, &first, "message", event.Message)
	if event.StatusID != nil {
		appendFieldName(b, &first, "status_id")
		b.WriteString(strconv.Itoa(*event.StatusID))
	}
	appendStringField(b, &first, "status", event.Status)
	appendStringField(b, &first, "status_code", event.StatusCode)
	appendStringField(b, &first, "status_detail", event.StatusDetail)
	if len(event.Metadata) > 0 {
		appendFieldName(b, &first, "metadata")
		appendAnyMapJSON(b, event.Metadata)
	}
	if len(event.Unmapped) > 0 {
		appendFieldName(b, &first, "unmapped")
		appendAnyMapJSON(b, event.Unmapped)
	}
	appendStringField(b, &first, "raw_data", event.RawData)
	appendStringField(b, &first, "log_name", event.LogName)
	appendStringField(b, &first, "log_provider", event.LogProvider)
	appendStringField(b, &first, "log_level", event.LogLevel)
	appendStringField(b, &first, "log_version", event.LogVersion)
	b.WriteByte('}')
}

func appendDeviceDiscoveriesJSON(b *strings.Builder, discoveries []sdk.DeviceDiscovery) {
	b.WriteByte('[')
	for i, discovery := range discoveries {
		if i > 0 {
			b.WriteByte(',')
		}
		appendDeviceDiscoveryJSON(b, discovery)
	}
	b.WriteByte(']')
}

func appendDeviceDiscoveryJSON(b *strings.Builder, discovery sdk.DeviceDiscovery) {
	b.WriteByte('{')
	first := true
	appendStringField(b, &first, "schema", discovery.Schema)
	appendStringField(b, &first, "collection_id", discovery.CollectionID)
	appendStringField(b, &first, "source", discovery.Source)
	appendStringField(b, &first, "observed_at", discovery.ObservedAt)
	if len(discovery.Devices) > 0 {
		appendFieldName(b, &first, "devices")
		appendDiscoveredDevicesJSON(b, discovery.Devices)
	}
	appendStringField(b, &first, "reference_hash", discovery.ReferenceHash)
	if len(discovery.Metadata) > 0 {
		appendFieldName(b, &first, "metadata")
		appendAnyMapJSON(b, discovery.Metadata)
	}
	b.WriteByte('}')
}

func appendDiscoveredDevicesJSON(b *strings.Builder, devices []sdk.DiscoveredDevice) {
	b.WriteByte('[')
	for i, device := range devices {
		if i > 0 {
			b.WriteByte(',')
		}
		appendDiscoveredDeviceJSON(b, device)
	}
	b.WriteByte(']')
}

func appendDiscoveredDeviceJSON(b *strings.Builder, device sdk.DiscoveredDevice) {
	b.WriteByte('{')
	first := true
	appendStringField(b, &first, "device_id", device.DeviceID)
	appendStringField(b, &first, "hostname", device.Hostname)
	appendStringField(b, &first, "ip", device.IP)
	appendStringField(b, &first, "mac", device.MAC)
	appendStringField(b, &first, "serial", device.Serial)
	appendStringField(b, &first, "vendor_name", device.VendorName)
	appendStringField(b, &first, "model", device.Model)
	appendStringField(b, &first, "type", device.Type)
	appendStringField(b, &first, "role", device.Role)
	appendStringField(b, &first, "status", device.Status)
	if device.IsAvailable != nil {
		appendFieldName(b, &first, "is_available")
		b.WriteString(strconv.FormatBool(*device.IsAvailable))
	}
	if device.Location != nil {
		appendFieldName(b, &first, "location")
		appendDeviceLocationJSON(b, *device.Location)
	}
	if len(device.Labels) > 0 {
		appendFieldName(b, &first, "labels")
		appendStringMapJSON(b, device.Labels)
	}
	if len(device.Metadata) > 0 {
		appendFieldName(b, &first, "metadata")
		appendAnyMapJSON(b, device.Metadata)
	}
	b.WriteByte('}')
}

func appendDeviceLocationJSON(b *strings.Builder, location sdk.DeviceLocation) {
	b.WriteByte('{')
	first := true
	appendStringField(b, &first, "site_code", location.SiteCode)
	appendStringField(b, &first, "site_name", location.SiteName)
	appendFloatField(b, &first, "latitude", location.Latitude)
	appendFloatField(b, &first, "longitude", location.Longitude)
	b.WriteByte('}')
}
