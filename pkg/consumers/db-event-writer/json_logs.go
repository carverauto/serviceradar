package dbeventwriter

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

var jsonLogReservedKeys = map[string]struct{}{
	"@timestamp":        {},
	"body":              {},
	"event":             {},
	"host":              {},
	"hostname":          {},
	"ip":                {},
	"ip_address":        {},
	"level":             {},
	"log":               {},
	"message":           {},
	"msg":               {},
	"remote_addr":       {},
	"scope.name":        {},
	"scope.version":     {},
	"scope_name":        {},
	"scope_version":     {},
	"service.instance":  {},
	"service.instance.id": {},
	"service.name":      {},
	"service.version":   {},
	"service_instance":  {},
	"service_instance_id": {},
	"service_name":      {},
	"service_version":   {},
	"severity":          {},
	"severity_number":   {},
	"severity_text":     {},
	"short_message":     {},
	"source":            {},
	"span_id":           {},
	"spanId":            {},
	"summary":           {},
	"time":              {},
	"timestamp":         {},
	"trace_id":          {},
	"traceId":           {},
	"ts":                {},
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

	serviceName := firstString(entry, "service.name", "service_name", "service")
	host := firstString(entry, "host", "hostname")
	if serviceName == "" {
		serviceName = host
	}

	serviceVersion := firstString(entry, "service.version", "service_version")
	serviceInstance := firstString(entry, "service.instance.id", "service_instance", "service_instance_id")
	scopeName := firstString(entry, "scope.name", "scope_name")
	scopeVersion := firstString(entry, "scope.version", "scope_version")

	attributes := buildAttributes(entry, jsonLogReservedKeys)
	resourceAttributes := buildResourceAttributes(entry)

	return models.OTELLogRow{
		Timestamp:          timestamp,
		TraceID:            firstString(entry, "trace_id", "traceId"),
		SpanID:             firstString(entry, "span_id", "spanId"),
		SeverityText:       severityText,
		SeverityNumber:     severityNumber,
		Body:               body,
		ServiceName:        serviceName,
		ServiceVersion:     serviceVersion,
		ServiceInstance:    serviceInstance,
		ScopeName:          scopeName,
		ScopeVersion:       scopeVersion,
		Attributes:         attributes,
		ResourceAttributes: resourceAttributes,
	}
}

func buildResourceAttributes(entry map[string]interface{}) string {
	keys := []string{"host", "hostname", "remote_addr", "source", "ip", "ip_address"}
	pairs := make([]string, 0, len(keys))
	for _, key := range keys {
		value := firstString(entry, key)
		if value == "" {
			continue
		}

		pairs = append(pairs, fmt.Sprintf("%s=%s", key, value))
	}

	return strings.Join(pairs, ",")
}

func buildAttributes(entry map[string]interface{}, reserved map[string]struct{}) string {
	pairs := make([]string, 0, len(entry))
	for key, value := range entry {
		if _, skip := reserved[key]; skip {
			continue
		}

		strValue := stringifyValue(value)
		if strValue == "" {
			continue
		}

		pairs = append(pairs, fmt.Sprintf("%s=%s", key, strValue))
	}

	sort.Strings(pairs)
	return strings.Join(pairs, ",")
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

	return "INFO", severityNumberForText("INFO")
}

func normalizeSeverityText(text string) (string, int32) {
	normalized := strings.ToLower(strings.TrimSpace(text))

	switch normalized {
	case "fatal", "critical", "emergency", "alert", "very high", "very_high":
		return "FATAL", severityNumberForText("FATAL")
	case "high", "error":
		return "ERROR", severityNumberForText("ERROR")
	case "medium", "warn", "warning":
		return "WARN", severityNumberForText("WARN")
	case "low", "info", "informational", "notice", "unknown":
		return "INFO", severityNumberForText("INFO")
	case "debug", "trace":
		return "DEBUG", severityNumberForText("DEBUG")
	default:
		return "INFO", severityNumberForText("INFO")
	}
}

func severityFromLevel(level interface{}) (string, int32) {
	if value, ok := parseNumeric(level); ok {
		return severityFromGELF(int(value))
	}

	if levelText, ok := level.(string); ok && levelText != "" {
		return normalizeSeverityText(levelText)
	}

	return "INFO", severityNumberForText("INFO")
}

func severityFromGELF(level int) (string, int32) {
	switch level {
	case 0, 1, 2:
		return "FATAL", severityNumberForText("FATAL")
	case 3:
		return "ERROR", severityNumberForText("ERROR")
	case 4:
		return "WARN", severityNumberForText("WARN")
	case 5, 6:
		return "INFO", severityNumberForText("INFO")
	case 7:
		return "DEBUG", severityNumberForText("DEBUG")
	default:
		return "INFO", severityNumberForText("INFO")
	}
}

func severityTextFromNumber(value int32) string {
	switch {
	case value >= 21:
		return "FATAL"
	case value >= 17:
		return "ERROR"
	case value >= 13:
		return "WARN"
	case value >= 9:
		return "INFO"
	case value >= 5:
		return "DEBUG"
	default:
		return "INFO"
	}
}

func severityNumberForText(text string) int32 {
	switch strings.ToUpper(strings.TrimSpace(text)) {
	case "FATAL":
		return 23
	case "ERROR":
		return 19
	case "WARN", "WARNING":
		return 15
	case "DEBUG":
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

func stringifyValue(value interface{}) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return strings.TrimSpace(typed)
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case json.Number:
		return typed.String()
	case bool:
		return strconv.FormatBool(typed)
	default:
		encoded, err := json.Marshal(typed)
		if err != nil {
			return fmt.Sprint(typed)
		}
		return string(encoded)
	}
}
