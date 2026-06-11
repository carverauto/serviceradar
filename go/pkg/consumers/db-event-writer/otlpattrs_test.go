package dbeventwriter

import (
	"bytes"
	"encoding/json"
	"reflect"
	"testing"

	commonv1 "go.opentelemetry.io/proto/otlp/common/v1"
	resourcev1 "go.opentelemetry.io/proto/otlp/resource/v1"
	tracepbv1 "go.opentelemetry.io/proto/otlp/trace/v1"
)

// --- AnyValue builders ---

func otlpKV(key string, value *commonv1.AnyValue) *commonv1.KeyValue {
	return &commonv1.KeyValue{Key: key, Value: value}
}

func otlpString(v string) *commonv1.AnyValue {
	return &commonv1.AnyValue{Value: &commonv1.AnyValue_StringValue{StringValue: v}}
}

func otlpBool(v bool) *commonv1.AnyValue {
	return &commonv1.AnyValue{Value: &commonv1.AnyValue_BoolValue{BoolValue: v}}
}

func otlpInt(v int64) *commonv1.AnyValue {
	return &commonv1.AnyValue{Value: &commonv1.AnyValue_IntValue{IntValue: v}}
}

func otlpDouble(v float64) *commonv1.AnyValue {
	return &commonv1.AnyValue{Value: &commonv1.AnyValue_DoubleValue{DoubleValue: v}}
}

func otlpBytes(v []byte) *commonv1.AnyValue {
	return &commonv1.AnyValue{Value: &commonv1.AnyValue_BytesValue{BytesValue: v}}
}

func otlpArray(values ...*commonv1.AnyValue) *commonv1.AnyValue {
	return &commonv1.AnyValue{Value: &commonv1.AnyValue_ArrayValue{
		ArrayValue: &commonv1.ArrayValue{Values: values},
	}}
}

func otlpKVList(values ...*commonv1.KeyValue) *commonv1.AnyValue {
	return &commonv1.AnyValue{Value: &commonv1.AnyValue_KvlistValue{
		KvlistValue: &commonv1.KeyValueList{Values: values},
	}}
}

// assertJSONEqual compares two JSON documents structurally, preserving
// integer precision via json.Number so int64 attributes above 2^53 are
// compared exactly.
func assertJSONEqual(t *testing.T, got, want string) {
	t.Helper()

	decode := func(raw string) interface{} {
		dec := json.NewDecoder(bytes.NewReader([]byte(raw)))
		dec.UseNumber()

		var value interface{}
		if err := dec.Decode(&value); err != nil {
			t.Fatalf("failed to decode JSON %q: %v", raw, err)
		}

		return value
	}

	if gotValue, wantValue := decode(got), decode(want); !reflect.DeepEqual(gotValue, wantValue) {
		t.Fatalf("unexpected JSON:\n got: %s\nwant: %s", got, want)
	}
}

func TestAttrsToJSONFullFidelity(t *testing.T) {
	t.Parallel()

	attrs := []*commonv1.KeyValue{
		otlpKV("str", otlpString("hello")),
		otlpKV("empty_str", otlpString("")),
		otlpKV("flag_true", otlpBool(true)),
		otlpKV("flag_false", otlpBool(false)),
		otlpKV("zero_int", otlpInt(0)),
		otlpKV("neg_int", otlpInt(-42)),
		otlpKV("big_int", otlpInt(9007199254740993)), // > 2^53: must keep exact precision
		otlpKV("zero_double", otlpDouble(0)),
		otlpKV("ratio", otlpDouble(0.25)),
		otlpKV("blob", otlpBytes([]byte{0x01, 0x02, 0xff})),
		otlpKV("arr", otlpArray(otlpString("a"), otlpInt(0), otlpBool(false))),
		otlpKV("nested", otlpKVList(
			otlpKV("count", otlpInt(0)),
			otlpKV("inner", otlpKVList(otlpKV("deep", otlpString("v")))),
		)),
		otlpKV("unset", nil),
		otlpKV("", otlpString("dropped: empty key")),
		nil,
	}

	assertJSONEqual(t, attrsToJSON(attrs), `{
		"str": "hello",
		"empty_str": "",
		"flag_true": true,
		"flag_false": false,
		"zero_int": 0,
		"neg_int": -42,
		"big_int": 9007199254740993,
		"zero_double": 0,
		"ratio": 0.25,
		"blob": "AQL/",
		"arr": ["a", 0, false],
		"nested": {"count": 0, "inner": {"deep": "v"}},
		"unset": null
	}`)
}

func TestAttrsToJSONEmpty(t *testing.T) {
	t.Parallel()

	if got := attrsToJSON(nil); got != "{}" {
		t.Fatalf("expected empty attributes to encode as {}, got %q", got)
	}
}

func TestProcessSpanEventsShape(t *testing.T) {
	t.Parallel()

	events := []*tracepbv1.Span_Event{
		{
			TimeUnixNano: 1718000000000000001,
			Name:         "exception",
			Attributes: []*commonv1.KeyValue{
				otlpKV("exception.type", otlpString("boom")),
				otlpKV("retryable", otlpBool(false)),
			},
			DroppedAttributesCount: 2,
		},
		nil,
		{Name: "empty"},
	}

	assertJSONEqual(t, processSpanEvents(events), `[
		{
			"time_unix_nano": 1718000000000000001,
			"name": "exception",
			"attributes": {"exception.type": "boom", "retryable": false},
			"dropped_attributes_count": 2
		},
		{
			"time_unix_nano": 0,
			"name": "empty",
			"attributes": {},
			"dropped_attributes_count": 0
		}
	]`)

	if got := processSpanEvents(nil); got != "[]" {
		t.Fatalf("expected empty events to encode as [], got %q", got)
	}
}

func TestProcessSpanLinksShape(t *testing.T) {
	t.Parallel()

	rawTraceID := []byte{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10}
	rawSpanID := []byte{0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18}

	links := []*tracepbv1.Span_Link{
		{
			TraceId:    rawTraceID,
			SpanId:     rawSpanID,
			TraceState: "vendor=1",
			Attributes: []*commonv1.KeyValue{otlpKV("attempt", otlpInt(0))},
		},
		{
			// All-zero ids normalize to null (canonical id contract).
			TraceId: make([]byte, 16),
			SpanId:  make([]byte, 8),
		},
		nil,
	}

	assertJSONEqual(t, processSpanLinks(links), `[
		{
			"trace_id": "0102030405060708090a0b0c0d0e0f10",
			"span_id": "1112131415161718",
			"trace_state": "vendor=1",
			"attributes": {"attempt": 0}
		},
		{
			"trace_id": null,
			"span_id": null,
			"trace_state": "",
			"attributes": {}
		}
	]`)

	if got := processSpanLinks(nil); got != "[]" {
		t.Fatalf("expected empty links to encode as [], got %q", got)
	}
}

func TestProcessResourceSpansEncodesJSONAttributeColumns(t *testing.T) {
	t.Parallel()

	rawTraceID := []byte{0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a}
	rawSpanID := []byte{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}

	resourceSpan := &tracepbv1.ResourceSpans{
		Resource: &resourcev1.Resource{
			Attributes: []*commonv1.KeyValue{
				otlpKV("service.name", otlpString("postgres")),
				otlpKV("service.version", otlpString("16.1")),
				otlpKV("deployment.canary", otlpBool(false)),
			},
		},
		ScopeSpans: []*tracepbv1.ScopeSpans{
			{
				Scope: &commonv1.InstrumentationScope{Name: "pg-otel", Version: "0.2.0"},
				Spans: []*tracepbv1.Span{
					{
						TraceId:           rawTraceID,
						SpanId:            rawSpanID,
						Name:              "query",
						StartTimeUnixNano: 1718000000000000000,
						EndTimeUnixNano:   1718000000000196400,
						Attributes: []*commonv1.KeyValue{
							otlpKV("decode_time_microseconds", otlpInt(3)),
							otlpKV("query_time_microseconds", otlpInt(1964)),
							otlpKV("rows_returned", otlpInt(0)),
						},
					},
				},
			},
		},
	}

	rows := processResourceSpans(resourceSpan)
	if len(rows) != 1 {
		t.Fatalf("expected 1 trace row, got %d", len(rows))
	}

	row := rows[0]
	if row.ServiceName != "postgres" || row.ServiceVersion != "16.1" {
		t.Fatalf("unexpected service identity: %q %q", row.ServiceName, row.ServiceVersion)
	}

	assertJSONEqual(t, row.Attributes, `{
		"decode_time_microseconds": 3,
		"query_time_microseconds": 1964,
		"rows_returned": 0
	}`)

	assertJSONEqual(t, row.ResourceAttributes, `{
		"service.name": "postgres",
		"service.version": "16.1",
		"deployment.canary": false
	}`)

	assertJSONEqual(t, row.Events, `[]`)
	assertJSONEqual(t, row.Links, `[]`)
}

func TestExtractAttributeValuePreservesZeroValues(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		attr *commonv1.KeyValue
		want string
	}{
		{"int zero", otlpKV("k", otlpInt(0)), "0"},
		{"bool false", otlpKV("k", otlpBool(false)), "false"},
		{"double zero", otlpKV("k", otlpDouble(0)), "0"},
		{"empty string", otlpKV("k", otlpString("")), ""},
		{"http status", otlpKV("http.status_code", otlpInt(200)), "200"},
		{"nil value", otlpKV("k", nil), ""},
		{"nil attr", nil, ""},
	}

	for _, tc := range cases {
		if got := extractAttributeValue(tc.attr); got != tc.want {
			t.Fatalf("%s: expected %q, got %q", tc.name, tc.want, got)
		}
	}
}

func TestParseJSONLogsStoresAttributesVerbatim(t *testing.T) {
	t.Parallel()

	payload := []byte(`{
		"body": "zen event",
		"attributes": {
			"count": 0,
			"ok": false,
			"label": "",
			"nested": {"ids": [1, 2], "ratio": 0.5}
		}
	}`)

	rows, ok := parseJSONLogs(payload, "logs.otel.processed")
	if !ok {
		t.Fatalf("expected JSON log parse to succeed")
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}

	assertJSONEqual(t, rows[0].Attributes, `{
		"count": 0,
		"ok": false,
		"label": "",
		"nested": {"ids": [1, 2], "ratio": 0.5}
	}`)
}
