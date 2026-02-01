package dbeventwriter

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// Severity level string constants.
const (
	severityINFO  = "INFO"
	severityFATAL = "FATAL"
	severityERROR = "ERROR"
	severityWARN  = "WARN"
	severityDEBUG = "DEBUG"
)

//nolint:gochecknoglobals // package-level lookup table for performance
var jsonLogReservedKeys = map[string]struct{}{
	"@timestamp":              {},
	"body":                    {},
	"attributes":              {},
	"event_name":              {},
	"eventName":               {},
	"event":                   {},
	"host":                    {},
	"hostname":                {},
	"ip":                      {},
	"ip_address":              {},
	"level":                   {},
	"log":                     {},
	"message":                 {},
	"msg":                     {},
	"observed_time_unix_nano": {},
	"observedTimeUnixNano":    {},
	"observed_timestamp":      {},
	"observedTimestamp":       {},
	"remote_addr":             {},
	"resource":                {},
	"resource_attributes":     {},
	"resourceAttributes":      {},
	"scope":                   {},
	"scope_attributes":        {},
	"scopeAttributes":         {},
	"scope.name":              {},
	"scope.version":           {},
	"scopeName":               {},
	"scopeVersion":            {},
	"scope_name":              {},
	"scope_version":           {},
	"service.instance":        {},
	"service.instance.id":     {},
	"service.name":            {},
	"service.version":         {},
	"service_instance":        {},
	"service_instance_id":     {},
	"service_name":            {},
	"service_version":         {},
	"severity":                {},
	"severity_number":         {},
	"severity_text":           {},
	"short_message":           {},
	"source":                  {},
	"span_id":                 {},
	"spanId":                  {},
	"summary":                 {},
	"time":                    {},
	"timestamp":               {},
	"trace_flags":             {},
	"traceFlags":              {},
	"trace_id":                {},
	"traceId":                 {},
	"ts":                      {},
}

func parseJSONLogs(payload []byte, subject string) ([]models.OTELLogRow, bool) {
	var decoded interface{}
	if err := json.Unmarshal(payload, &decoded); err != nil {
		return nil, false
	}

	switch value := decoded.(type) {
	case map[string]interface{}:
		return []models.OTELLogRow{buildJSONLogRow(value, subject)}, true
	case []interface{}:
		rows := make([]models.OTELLogRow, 0, len(value))
		for _, entry := range value {
			item, ok := entry.(map[string]interface{})
			if !ok {
				continue
			}
			rows = append(rows, buildJSONLogRow(item, subject))
		}

		if len(rows) == 0 {
			return nil, false
		}

		return rows, true
	default:
		return nil, false
	}
}

func buildJSONLogRow(entry map[string]interface{}, subject string) models.OTELLogRow {
	timestamp := time.Now().UTC()
	if value, ok := firstValue(entry, "timestamp", "time", "ts", "@timestamp"); ok {
		if parsed, ok := parseFlexibleTime(value); ok {
			timestamp = parsed
		}
	}

	body := firstString(entry, "message", "short_message", "msg", "body", "event", "log", "summary")
	if body == "" {
		body = subject
	}

	severityText, severityNumber := normalizeSeverity(entry)
	observedTimestamp := parseObservedTimestamp(entry)
	traceFlags := parseTraceFlags(entry)
	eventName := firstString(entry, "event_name", "eventName")

	resourceMap := extractAttributesMap(entry, "resource_attributes", "resourceAttributes", "resource")
	resourceAttribs := resourceMap
	if len(resourceAttribs) == 0 {
		resourceAttribs = buildResourceAttributesMap(entry)
	}

	attributesMap := extractAttributesMap(entry, "attributes")
	extraAttributes := buildAttributesMap(entry, jsonLogReservedKeys)
	attributesMap = mergeAttributeMaps(attributesMap, extraAttributes)

	scopeName := firstString(entry, "scope.name", "scope_name", "scopeName")
	scopeVersion := firstString(entry, "scope.version", "scope_version", "scopeVersion")

	if len(resourceAttribs) == 0 {
		resourceValue, updated := popAttribute(attributesMap, "resource_attributes", "resourceAttributes", "resource")
		attributesMap = updated
		if parsed := parseAttributeValue(resourceValue); len(parsed) > 0 {
			resourceAttribs = parsed
		}
	}

	scopeName, scopeVersion = applyScopeFallbacks(entry, scopeName, scopeVersion)
	if scopeName == "" || scopeVersion == "" {
		scopeValue, updated := popAttribute(attributesMap, "scope")
		attributesMap = updated
		scopeName, scopeVersion = applyScopeValue(scopeValue, scopeName, scopeVersion)

		if scopeVersion == "" {
			if value, updated := popAttribute(attributesMap, "scope_version", "scopeVersion"); value != nil {
				attributesMap = updated
				scopeVersion = stringFromValue(value)
			}
		}
	}

	serviceName := firstString(entry, "service.name", "service_name", "service", "serviceName")
	host := firstString(entry, "host", "hostname")
	if serviceName == "" {
		serviceName = host
	}
	if serviceName == "" {
		serviceName = firstStringFromMap(resourceAttribs, "service.name", "service_name", "serviceName")
	}

	serviceVersion := firstString(entry, "service.version", "service_version", "serviceVersion")
	if serviceVersion == "" {
		serviceVersion = firstStringFromMap(resourceAttribs, "service.version", "service_version", "serviceVersion")
	}

	serviceInstance := firstString(entry, "service.instance.id", "service_instance", "service_instance_id", "serviceInstance")
	if serviceInstance == "" {
		serviceInstance = firstStringFromMap(
			resourceAttribs,
			"service.instance.id",
			"service.instance",
			"service_instance",
			"service_instance_id",
			"serviceInstance",
		)
	}

	scopeAttributes := extractAttributesMap(entry, "scope_attributes", "scopeAttributes")
	if len(scopeAttributes) == 0 {
		scopeValue, updated := popAttribute(attributesMap, "scope_attributes", "scopeAttributes")
		attributesMap = updated
		if parsed := parseAttributeValue(scopeValue); len(parsed) > 0 {
			scopeAttributes = parsed
		}
	}

	attributes := encodeAttributes(attributesMap)
	resourceAttributes := encodeAttributes(resourceAttribs)
	scopeAttributesEncoded := encodeAttributes(scopeAttributes)
	source := firstString(entry, "source")
	if source == "" {
		source = inferLogSource(subject)
	}

	return models.OTELLogRow{
		Timestamp:          timestamp,
		ObservedTimestamp:  observedTimestamp,
		TraceID:            firstString(entry, "trace_id", "traceId"),
		SpanID:             firstString(entry, "span_id", "spanId"),
		TraceFlags:         traceFlags,
		SeverityText:       severityText,
		SeverityNumber:     severityNumber,
		Body:               body,
		EventName:          eventName,
		Source:             source,
		ServiceName:        serviceName,
		ServiceVersion:     serviceVersion,
		ServiceInstance:    serviceInstance,
		ScopeName:          scopeName,
		ScopeVersion:       scopeVersion,
		ScopeAttributes:    scopeAttributesEncoded,
		Attributes:         attributes,
		ResourceAttributes: resourceAttributes,
	}
}

func inferLogSource(subject string) string {
	subject = strings.ToLower(strings.TrimSpace(subject))
	if strings.HasPrefix(subject, "logs.") {
		parts := strings.Split(subject, ".")
		if len(parts) > 1 && parts[1] != "" {
			return parts[1]
		}
	}
	switch {
	case strings.Contains(subject, "syslog"):
		return "syslog"
	case strings.Contains(subject, "snmp"):
		return "snmp"
	case strings.Contains(subject, "otel"):
		return "otel"
	case strings.Contains(subject, "internal"):
		return "internal"
	default:
		return ""
	}
}

func buildResourceAttributesMap(entry map[string]interface{}) map[string]interface{} {
	keys := []string{"host", "hostname", "remote_addr", "source", "ip", "ip_address"}
	resource := make(map[string]interface{})
	for _, key := range keys {
		value := firstString(entry, key)
		if value == "" {
			continue
		}

		resource[key] = value
	}

	return resource
}

func buildAttributesMap(entry map[string]interface{}, reserved map[string]struct{}) map[string]interface{} {
	attributes := make(map[string]interface{})
	for key, value := range entry {
		if _, skip := reserved[key]; skip {
			continue
		}

		if isEmptyAttributeValue(value) {
			continue
		}

		attributes[key] = value
	}

	return attributes
}

func normalizeSeverity(entry map[string]interface{}) (string, int32) {
	if severity := firstString(entry, "severity_text"); severity != "" {
		return normalizeSeverityText(severity)
	}

	if severity := firstString(entry, "severity"); severity != "" {
		return normalizeSeverityText(severity)
	}

	if level, ok := entry["level"]; ok {
		return severityFromLevel(level)
	}

	if severityNum, ok := entry["severity_number"]; ok {
		if value, ok := parseNumeric(severityNum); ok {
			text := severityTextFromNumber(int32(value))
			return text, int32(value)
		}
	}

	return severityINFO, severityNumberForText(severityINFO)
}

func normalizeSeverityText(text string) (string, int32) {
	normalized := strings.ToLower(strings.TrimSpace(text))

	switch normalized {
	case "fatal", "critical", "emergency", "alert", "very high", "very_high":
		return severityFATAL, severityNumberForText(severityFATAL)
	case "high", "error":
		return severityERROR, severityNumberForText(severityERROR)
	case "medium", "warn", "warning":
		return severityWARN, severityNumberForText(severityWARN)
	case "low", "info", "informational", "notice", "unknown":
		return severityINFO, severityNumberForText(severityINFO)
	case "debug", "trace":
		return severityDEBUG, severityNumberForText(severityDEBUG)
	default:
		return severityINFO, severityNumberForText(severityINFO)
	}
}

func severityFromLevel(level interface{}) (string, int32) {
	if value, ok := parseNumeric(level); ok {
		return severityFromGELF(int(value))
	}

	if levelText, ok := level.(string); ok && levelText != "" {
		return normalizeSeverityText(levelText)
	}

	return severityINFO, severityNumberForText(severityINFO)
}

func severityFromGELF(level int) (string, int32) {
	switch level {
	case 0, 1, 2:
		return severityFATAL, severityNumberForText(severityFATAL)
	case 3:
		return severityERROR, severityNumberForText(severityERROR)
	case 4:
		return severityWARN, severityNumberForText(severityWARN)
	case 5, 6:
		return severityINFO, severityNumberForText(severityINFO)
	case 7:
		return severityDEBUG, severityNumberForText(severityDEBUG)
	default:
		return severityINFO, severityNumberForText(severityINFO)
	}
}

func severityTextFromNumber(value int32) string {
	switch {
	case value >= 21:
		return severityFATAL
	case value >= 17:
		return severityERROR
	case value >= 13:
		return severityWARN
	case value >= 9:
		return severityINFO
	case value >= 5:
		return severityDEBUG
	default:
		return severityINFO
	}
}

func severityNumberForText(text string) int32 {
	switch strings.ToUpper(strings.TrimSpace(text)) {
	case severityFATAL:
		return 23
	case severityERROR:
		return 19
	case severityWARN, "WARNING":
		return 15
	case severityDEBUG:
		return 7
	case "TRACE":
		return 3
	default:
		return 11
	}
}

func firstValue(entry map[string]interface{}, keys ...string) (interface{}, bool) {
	for _, key := range keys {
		if value, ok := entry[key]; ok {
			return value, true
		}
	}
	return nil, false
}

func firstString(entry map[string]interface{}, keys ...string) string {
	for _, key := range keys {
		if value, ok := entry[key]; ok {
			if text, ok := value.(string); ok {
				text = strings.TrimSpace(text)
				if text != "" {
					return text
				}
			}
		}
	}
	return ""
}

func parseFlexibleTime(value interface{}) (time.Time, bool) {
	switch typed := value.(type) {
	case string:
		text := strings.TrimSpace(typed)
		if text == "" {
			return time.Time{}, false
		}
		if parsed, err := time.Parse(time.RFC3339Nano, text); err == nil {
			return parsed, true
		}
		if parsed, err := time.Parse(time.RFC3339, text); err == nil {
			return parsed, true
		}
		if numeric, err := strconv.ParseFloat(text, 64); err == nil {
			return timeFromNumeric(numeric), true
		}
	case json.Number:
		if numeric, err := typed.Float64(); err == nil {
			return timeFromNumeric(numeric), true
		}
	case float64:
		return timeFromNumeric(typed), true
	case int64:
		return timeFromNumeric(float64(typed)), true
	case int:
		return timeFromNumeric(float64(typed)), true
	}

	return time.Time{}, false
}

func timeFromNumeric(value float64) time.Time {
	if value <= 0 {
		return time.Time{}
	}

	switch {
	case value > 1e18:
		return time.Unix(0, int64(value))
	case value > 1e15:
		return time.Unix(0, int64(value)*int64(time.Microsecond))
	case value > 1e12:
		return time.Unix(0, int64(value)*int64(time.Millisecond))
	default:
		secs := int64(value)
		nsecs := int64((value - float64(secs)) * float64(time.Second))
		return time.Unix(secs, nsecs)
	}
}

func parseNumeric(value interface{}) (float64, bool) {
	switch typed := value.(type) {
	case float64:
		return typed, true
	case int:
		return float64(typed), true
	case int64:
		return float64(typed), true
	case json.Number:
		if parsed, err := typed.Float64(); err == nil {
			return parsed, true
		}
	case string:
		if parsed, err := strconv.ParseFloat(strings.TrimSpace(typed), 64); err == nil {
			return parsed, true
		}
	}

	return 0, false
}

func parseObservedTimestamp(entry map[string]interface{}) *time.Time {
	value, ok := firstValue(
		entry,
		"observed_timestamp",
		"observedTimestamp",
		"observed_time_unix_nano",
		"observedTimeUnixNano",
	)
	if !ok {
		return nil
	}

	if parsed, ok := parseFlexibleTime(value); ok {
		if parsed.IsZero() {
			return nil
		}
		return &parsed
	}

	return nil
}

func parseTraceFlags(entry map[string]interface{}) *int32 {
	if value, ok := firstValue(entry, "trace_flags", "traceFlags", "flags"); ok {
		if numeric, ok := parseNumeric(value); ok {
			traceFlags := int32(numeric)
			return &traceFlags
		}
	}

	return nil
}

func extractAttributesMap(entry map[string]interface{}, keys ...string) map[string]interface{} {
	for _, key := range keys {
		if value, ok := entry[key]; ok {
			if parsed := parseAttributeValue(value); len(parsed) > 0 {
				return parsed
			}
		}
	}

	return nil
}

func parseAttributeValue(value interface{}) map[string]interface{} {
	switch typed := value.(type) {
	case map[string]interface{}:
		return typed
	case string:
		text := strings.TrimSpace(typed)
		if text == "" {
			return nil
		}

		var decoded map[string]interface{}
		if err := json.Unmarshal([]byte(text), &decoded); err == nil {
			return decoded
		}

		return parseKeyValueMap(text)
	default:
		return nil
	}
}

func parseKeyValueMap(text string) map[string]interface{} {
	parts := strings.Split(text, ",")
	attributes := make(map[string]interface{})
	for _, part := range parts {
		segment := strings.TrimSpace(part)
		if segment == "" {
			continue
		}

		kv := strings.SplitN(segment, "=", 2)
		if len(kv) != 2 {
			continue
		}

		key := strings.TrimSpace(kv[0])
		value := strings.TrimSpace(kv[1])
		if key == "" || value == "" {
			continue
		}

		if strings.HasPrefix(value, "{") || strings.HasPrefix(value, "[") {
			var decoded interface{}
			if err := json.Unmarshal([]byte(value), &decoded); err == nil {
				attributes[key] = decoded
				continue
			}
		}

		attributes[key] = value
	}

	if len(attributes) == 0 {
		return nil
	}

	return attributes
}

func encodeAttributes(attributes map[string]interface{}) string {
	if len(attributes) == 0 {
		return ""
	}

	encoded, err := json.Marshal(attributes)
	if err != nil {
		return ""
	}

	return string(encoded)
}

func mergeAttributeMaps(base, extra map[string]interface{}) map[string]interface{} {
	if len(base) == 0 && len(extra) == 0 {
		return nil
	}

	merged := make(map[string]interface{})
	for key, value := range base {
		merged[key] = value
	}

	for key, value := range extra {
		if _, exists := merged[key]; exists {
			continue
		}
		merged[key] = value
	}

	return merged
}

func popAttribute(attributes map[string]interface{}, keys ...string) (interface{}, map[string]interface{}) {
	if len(attributes) == 0 {
		return nil, attributes
	}

	for _, key := range keys {
		if value, ok := attributes[key]; ok {
			delete(attributes, key)
			return value, attributes
		}
	}

	return nil, attributes
}

func isEmptyAttributeValue(value interface{}) bool {
	switch typed := value.(type) {
	case nil:
		return true
	case string:
		return strings.TrimSpace(typed) == ""
	default:
		return false
	}
}

func firstStringFromMap(values map[string]interface{}, keys ...string) string {
	for _, key := range keys {
		if value, ok := values[key]; ok {
			if text := stringFromValue(value); text != "" {
				return text
			}
		}
	}
	return ""
}

func stringFromValue(value interface{}) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return strings.TrimSpace(typed)
	default:
		return strings.TrimSpace(fmt.Sprint(typed))
	}
}

func applyScopeFallbacks(entry map[string]interface{}, scopeName, scopeVersion string) (string, string) {
	if scopeName != "" && scopeVersion != "" {
		return scopeName, scopeVersion
	}

	scopeValue, ok := entry["scope"]
	if !ok {
		return scopeName, scopeVersion
	}

	switch typed := scopeValue.(type) {
	case map[string]interface{}:
		if scopeName == "" {
			scopeName = firstStringFromMap(typed, "name", "scope_name", "scopeName")
		}
		if scopeVersion == "" {
			scopeVersion = firstStringFromMap(typed, "version", "scope_version", "scopeVersion")
		}
	case string:
		if scopeName == "" {
			scopeName = strings.TrimSpace(typed)
		}
	}

	return scopeName, scopeVersion
}

func applyScopeValue(scopeValue interface{}, scopeName, scopeVersion string) (string, string) {
	switch typed := scopeValue.(type) {
	case map[string]interface{}:
		if scopeName == "" {
			scopeName = firstStringFromMap(typed, "name", "scope_name", "scopeName")
		}
		if scopeVersion == "" {
			scopeVersion = firstStringFromMap(typed, "version", "scope_version", "scopeVersion")
		}
	case string:
		if scopeName == "" {
			scopeName = strings.TrimSpace(typed)
		}
	}

	return scopeName, scopeVersion
}
