package dbeventwriter

// OTLP attribute conversion (refactor-otel-signal-correlation).
//
// Converts OTLP KeyValue/AnyValue structures into standards-shaped JSON that
// is byte-for-byte compatible with the Elixir EventWriter
// (ServiceRadar.EventWriter.OtlpAttributes): string→string, bool→bool,
// int→int64, double→float64, bytes→base64 string, ArrayValue→array,
// KvlistValue→nested object. Zero, false, and empty values are preserved —
// flattening attributes into "k=v,k=v" text loses type information and
// silently drops falsy values, which breaks external OTLP producers.

import (
	"encoding/base64"
	"encoding/json"

	commonv1 "go.opentelemetry.io/proto/otlp/common/v1"
)

// attrsToMap converts OTLP KeyValue pairs into a plain map suitable for JSON
// marshaling. Entries with empty keys are skipped, matching
// ServiceRadar.EventWriter.OtlpAttributes.key_values_to_map/1. The result is
// never nil so it always marshals to a JSON object.
func attrsToMap(attrs []*commonv1.KeyValue) map[string]interface{} {
	result := make(map[string]interface{}, len(attrs))

	for _, attr := range attrs {
		if attr == nil || attr.Key == "" {
			continue
		}

		result[attr.Key] = anyValueToInterface(attr.Value)
	}

	return result
}

// anyValueToInterface converts an OTLP AnyValue into a JSON-marshalable Go
// value per the OTLP spec. Unset values become nil (JSON null). Zero, false,
// and empty-string values are preserved.
func anyValueToInterface(value *commonv1.AnyValue) interface{} {
	if value == nil {
		return nil
	}

	switch v := value.Value.(type) {
	case *commonv1.AnyValue_StringValue:
		return v.StringValue
	case *commonv1.AnyValue_BoolValue:
		return v.BoolValue
	case *commonv1.AnyValue_IntValue:
		return v.IntValue
	case *commonv1.AnyValue_DoubleValue:
		return v.DoubleValue
	case *commonv1.AnyValue_BytesValue:
		return base64.StdEncoding.EncodeToString(v.BytesValue)
	case *commonv1.AnyValue_ArrayValue:
		if v.ArrayValue == nil {
			return []interface{}{}
		}

		items := make([]interface{}, 0, len(v.ArrayValue.Values))
		for _, item := range v.ArrayValue.Values {
			items = append(items, anyValueToInterface(item))
		}

		return items
	case *commonv1.AnyValue_KvlistValue:
		if v.KvlistValue == nil {
			return map[string]interface{}{}
		}

		return attrsToMap(v.KvlistValue.Values)
	default:
		return nil
	}
}

// attrsToJSON converts OTLP KeyValue pairs into JSON object text for TEXT
// columns ("{}" when there are no attributes).
func attrsToJSON(attrs []*commonv1.KeyValue) string {
	return marshalJSONObject(attrsToMap(attrs))
}

// marshalJSONObject marshals an attribute map to JSON object text, falling
// back to "{}" if marshaling fails (it cannot for values produced by
// attrsToMap, but callers must always receive valid JSON).
func marshalJSONObject(m map[string]interface{}) string {
	if m == nil {
		return "{}"
	}

	encoded, err := json.Marshal(m)
	if err != nil {
		return "{}"
	}

	return string(encoded)
}

// stringAttr returns the first non-empty string-typed value among keys.
// Non-string values are ignored: scalar identity fields like service.name
// are string-typed per OTel semantic conventions.
func stringAttr(attrs map[string]interface{}, keys ...string) string {
	for _, key := range keys {
		if value, ok := attrs[key].(string); ok && value != "" {
			return value
		}
	}

	return ""
}

// jsonOTELID converts a normalized OTel id ("" for absent/invalid) into its
// JSON representation: null when absent, matching the Elixir writer where
// OtelId normalization yields nil.
func jsonOTELID(id string) interface{} {
	if id == "" {
		return nil
	}

	return id
}
