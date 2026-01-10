package dbeventwriter

import (
	"encoding/json"
	"errors"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errOCSFEventMissingID        = errors.New("ocsf event missing id")
	errOCSFEventMissingTenantID  = errors.New("ocsf event missing tenant_id")
	errOCSFEventMissingClassUID  = errors.New("ocsf event missing class_uid")
	errOCSFEventMissingCategory  = errors.New("ocsf event missing category_uid")
	errOCSFEventMissingTypeUID   = errors.New("ocsf event missing type_uid")
	errOCSFEventMissingActivity  = errors.New("ocsf event missing activity_id")
)

func parseOCSFEvent(payload []byte, fallbackTenantID string) (*models.OCSFEventRow, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return nil, err
	}

	row := models.OCSFEventRow{
		ID:           rawString(raw, "id"),
		Time:         parseOCSFTime(raw["time"]),
		ClassUID:     rawInt32(raw, "class_uid"),
		CategoryUID:  rawInt32(raw, "category_uid"),
		TypeUID:      rawInt32(raw, "type_uid"),
		ActivityID:   rawInt32(raw, "activity_id"),
		ActivityName: rawString(raw, "activity_name"),
		SeverityID:   rawInt32(raw, "severity_id"),
		Severity:     rawString(raw, "severity"),
		Message:      rawString(raw, "message"),
		StatusID:     rawInt32Ptr(raw, "status_id"),
		Status:       rawString(raw, "status"),
		StatusCode:   rawString(raw, "status_code"),
		StatusDetail: rawString(raw, "status_detail"),
		Metadata:     rawJSON(raw, "metadata"),
		Observables:  rawJSON(raw, "observables"),
		TraceID:      rawString(raw, "trace_id", "traceId"),
		SpanID:       rawString(raw, "span_id", "spanId"),
		Actor:        rawJSON(raw, "actor"),
		Device:       rawJSON(raw, "device"),
		SrcEndpoint:  rawJSON(raw, "src_endpoint"),
		DstEndpoint:  rawJSON(raw, "dst_endpoint"),
		LogName:      rawString(raw, "log_name"),
		LogProvider:  rawString(raw, "log_provider"),
		LogLevel:     rawString(raw, "log_level"),
		LogVersion:   rawString(raw, "log_version"),
		Unmapped:     rawJSON(raw, "unmapped"),
		RawData:      rawString(raw, "raw_data"),
		TenantID:     rawString(raw, "tenant_id", "tenantId"),
		CreatedAt:    time.Now().UTC(),
	}

	if row.RawData == "" {
		row.RawData = string(payload)
	}

	if row.Time.IsZero() {
		row.Time = time.Now().UTC()
	}

	if row.SeverityID == 0 {
		row.SeverityID = 1
	}

	if row.TenantID == "" {
		row.TenantID = fallbackTenantID
	}

	switch {
	case row.ID == "":
		return nil, errOCSFEventMissingID
	case row.TenantID == "":
		return nil, errOCSFEventMissingTenantID
	case row.ClassUID == 0:
		return nil, errOCSFEventMissingClassUID
	case row.CategoryUID == 0:
		return nil, errOCSFEventMissingCategory
	case row.TypeUID == 0:
		return nil, errOCSFEventMissingTypeUID
	case row.ActivityID == 0:
		return nil, errOCSFEventMissingActivity
	}

	return &row, nil
}

func rawString(raw map[string]json.RawMessage, keys ...string) string {
	for _, key := range keys {
		value, ok := raw[key]
		if !ok || len(value) == 0 {
			continue
		}

		var out string
		if err := json.Unmarshal(value, &out); err == nil {
			if out != "" {
				return out
			}
		}
	}

	return ""
}

func rawInt32(raw map[string]json.RawMessage, key string) int32 {
	value, ok := raw[key]
	if !ok || len(value) == 0 {
		return 0
	}

	var decoded interface{}
	if err := json.Unmarshal(value, &decoded); err != nil {
		return 0
	}

	if numeric, ok := parseNumeric(decoded); ok {
		return int32(numeric)
	}

	return 0
}

func rawInt32Ptr(raw map[string]json.RawMessage, key string) *int32 {
	value, ok := raw[key]
	if !ok || len(value) == 0 {
		return nil
	}

	var decoded interface{}
	if err := json.Unmarshal(value, &decoded); err != nil {
		return nil
	}

	if numeric, ok := parseNumeric(decoded); ok {
		out := int32(numeric)
		return &out
	}

	return nil
}

func rawJSON(raw map[string]json.RawMessage, key string) json.RawMessage {
	value, ok := raw[key]
	if !ok || len(value) == 0 {
		return nil
	}

	clone := make([]byte, len(value))
	copy(clone, value)
	return clone
}

func parseOCSFTime(raw json.RawMessage) time.Time {
	if len(raw) == 0 {
		return time.Time{}
	}

	var decoded interface{}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return time.Time{}
	}

	if parsed, ok := parseFlexibleTime(decoded); ok {
		return parsed.UTC()
	}

	return time.Time{}
}
