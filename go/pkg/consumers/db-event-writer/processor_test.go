package dbeventwriter

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	collectlogsv1 "go.opentelemetry.io/proto/otlp/collector/logs/v1"
	commonv1 "go.opentelemetry.io/proto/otlp/common/v1"
	logsv1 "go.opentelemetry.io/proto/otlp/logs/v1"
	resourcev1 "go.opentelemetry.io/proto/otlp/resource/v1"
	tracepbv1 "go.opentelemetry.io/proto/otlp/trace/v1"
	"google.golang.org/protobuf/proto"
)

func TestGetTableForSubject_MultiStreamRouting(t *testing.T) {
	t.Parallel()

	p := &Processor{
		streams: []StreamConfig{
			{Subject: "logs.otel.processed", Table: "logs"},
			{Subject: "otel.metrics", Table: "otel_metrics"},
		},
	}

	tests := []struct {
		name    string
		subject string
		want    string
	}{
		{
			name:    "exact match",
			subject: "logs.otel.processed",
			want:    "logs",
		},
		{
			name:    "suffix namespaced match",
			subject: "demo.logs.otel.processed",
			want:    "logs",
		},
		{
			name:    "nested prefix match",
			subject: "otel.metrics.raw",
			want:    "otel_metrics",
		},
		{
			name:    "legacy fallback when no stream match",
			subject: "unmapped.subject",
			want:    "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			got := p.getTableForSubject(tc.subject)
			if got != tc.want {
				t.Fatalf("expected table %q, got %q", tc.want, got)
			}
		})
	}
}

func TestGetTableForSubject_ExactMatchBeatsPrefixMatch(t *testing.T) {
	t.Parallel()

	// The broad "otel.metrics" mapping is listed first; the exact
	// "otel.metrics.raw" mapping must still win.
	p := &Processor{
		streams: []StreamConfig{
			{Subject: "otel.metrics", Table: "otel_metrics"},
			{Subject: "otel.metrics.raw", Table: "otel_metric_points"},
		},
	}

	tests := []struct {
		subject string
		want    string
	}{
		{subject: "otel.metrics.raw", want: "otel_metric_points"},
		{subject: "demo.otel.metrics.raw", want: "otel_metric_points"},
		{subject: "otel.metrics.derived", want: "otel_metrics"},
		{subject: "otel.metrics", want: "otel_metrics"},
	}

	for _, tc := range tests {
		if got := p.getTableForSubject(tc.subject); got != tc.want {
			t.Fatalf("subject %q: expected table %q, got %q", tc.subject, tc.want, got)
		}
	}
}

func TestGetTableForSubject_LegacyFallback(t *testing.T) {
	t.Parallel()

	p := &Processor{table: " logs "}

	got := p.getTableForSubject("anything")
	if got != "logs" {
		t.Fatalf("expected legacy table fallback to be trimmed %q, got %q", "logs", got)
	}
}

func TestParseJSONLogsSingle(t *testing.T) {
	payload := []byte(`{"message":"test log","severity":"High","timestamp":1700000000,"host":"device-1"}`)

	rows, ok := parseJSONLogs(payload, "logs.syslog.processed")
	if !ok {
		t.Fatalf("expected JSON log parse to succeed")
	}

	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}

	row := rows[0]
	if row.Body != "test log" {
		t.Fatalf("unexpected body: %s", row.Body)
	}

	if row.SeverityText != "ERROR" {
		t.Fatalf("unexpected severity text: %s", row.SeverityText)
	}

	if row.ServiceName != "device-1" {
		t.Fatalf("unexpected service name: %s", row.ServiceName)
	}

	if row.ObservedTimestamp == nil {
		t.Fatalf("expected observed timestamp to be set")
	}
}

func TestParseJSONLogsArray(t *testing.T) {
	payload := []byte(`[
		{"message":"first","severity":"Low","timestamp":"2025-01-01T00:00:00Z"},
		{"message":"second","severity":"Medium","timestamp":"2025-01-01T01:00:00Z"}
	]`)

	rows, ok := parseJSONLogs(payload, "logs.syslog.processed")
	if !ok {
		t.Fatalf("expected JSON array parse to succeed")
	}

	if len(rows) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(rows))
	}
}

func TestParseJSONLogsCharCodeBody(t *testing.T) {
	payload := []byte(`{"body":[84,101,115,116],"severity_text":"info","timestamp":1700000000,"service.name":"core-elx"}`)

	rows, ok := parseJSONLogs(payload, "logs.otel.processed")
	if !ok {
		t.Fatalf("expected JSON log parse to succeed")
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0].Body != "Test" {
		t.Fatalf("unexpected body: %q", rows[0].Body)
	}
	if rows[0].ServiceName != "core-elx" {
		t.Fatalf("unexpected service name: %q", rows[0].ServiceName)
	}
}

func TestParseJSONLogsPreservesSignalSchemaAttributes(t *testing.T) {
	payload := []byte(`{
		"body":"PowerDNS RPZ block",
		"attributes":{
			"service_radar":{
				"signal_schema":{
					"producer_id":"powerdns",
					"producer_version":"0.1.0",
					"schema_id":"com.carverauto.powerdns.dns_activity",
					"schema_version":"1.0.0"
				}
			}
		}
	}`)

	rows, ok := parseJSONLogs(payload, "logs.otel.processed")
	if !ok {
		t.Fatalf("expected JSON log parse to succeed")
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}

	var attributes map[string]any
	if err := json.Unmarshal([]byte(rows[0].Attributes), &attributes); err != nil {
		t.Fatalf("expected attributes JSON to decode: %v", err)
	}

	serviceRadar, ok := attributes["service_radar"].(map[string]any)
	if !ok {
		t.Fatalf("expected service_radar metadata to be preserved, got %s", rows[0].Attributes)
	}

	signalSchema, ok := serviceRadar["signal_schema"].(map[string]any)
	if !ok {
		t.Fatalf("expected signal_schema metadata to be preserved, got %s", rows[0].Attributes)
	}

	if got := signalSchema["schema_id"]; got != "com.carverauto.powerdns.dns_activity" {
		t.Fatalf("unexpected schema_id: %v", got)
	}
}

func TestParseOTELLogsStoresSignalSchemaAttributesAsJSON(t *testing.T) {
	req := &collectlogsv1.ExportLogsServiceRequest{
		ResourceLogs: []*logsv1.ResourceLogs{
			{
				Resource: &resourcev1.Resource{
					Attributes: []*commonv1.KeyValue{
						stringKeyValue("service.name", "test-addon"),
					},
				},
				ScopeLogs: []*logsv1.ScopeLogs{
					{
						LogRecords: []*logsv1.LogRecord{
							{
								Body: &commonv1.AnyValue{
									Value: &commonv1.AnyValue_StringValue{StringValue: "schema-backed log"},
								},
								Attributes: []*commonv1.KeyValue{
									stringKeyValue("service_radar.signal_schema.producer_id", "test-addon"),
									stringKeyValue("service_radar.signal_schema.producer_version", "0.1.0"),
									stringKeyValue("service_radar.signal_schema.schema_id", "com.carverauto.test.log"),
									stringKeyValue("service_radar.signal_schema.schema_version", "1.0.0"),
								},
							},
						},
					},
				},
			},
		},
	}

	payload, err := proto.Marshal(req)
	if err != nil {
		t.Fatalf("failed to marshal OTEL logs request: %v", err)
	}

	rows, err := parseOTELLogs(payload, "logs.otel.processed")
	if err != nil {
		t.Fatalf("expected OTEL log parse to succeed: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}

	var attrs map[string]any
	if err := json.Unmarshal([]byte(rows[0].Attributes), &attrs); err != nil {
		t.Fatalf("expected attributes to be JSON, got %s: %v", rows[0].Attributes, err)
	}

	if got := attrs["service_radar.signal_schema.schema_id"]; got != "com.carverauto.test.log" {
		t.Fatalf("expected signal schema attributes to be preserved as JSON, got %s", rows[0].Attributes)
	}

	var resourceAttrs map[string]any
	if err := json.Unmarshal([]byte(rows[0].ResourceAttributes), &resourceAttrs); err != nil {
		t.Fatalf("expected resource attributes to be JSON, got %s: %v", rows[0].ResourceAttributes, err)
	}

	if got := resourceAttrs["service.name"]; got != "test-addon" {
		t.Fatalf("expected resource attributes to be preserved as JSON, got %s", rows[0].ResourceAttributes)
	}
}

func TestParseJSONLogsCorazaProcessedPayload(t *testing.T) {
	payload := []byte(`{
		"attributes":{
			"event_type":"waf.finding",
			"security":{"signal":{"kind":"waf","source":"coraza-proxy-wasm"}},
			"waf":{
				"client_ip":"192.168.1.218",
				"request_id":"req-1",
				"request_path":"/live/longpoll",
				"request_query":"<redacted>",
				"rule_id":"932370",
				"rule_message":"Remote Command Execution: Windows Command Injection",
				"rule_severity":"critical",
				"source":"coraza-proxy-wasm",
				"waf_policy":"serviceradar-shared-coraza-waf"
			}
		},
		"body":"WAF critical rule 932370: Remote Command Execution: Windows Command Injection /live/longpoll",
		"event_name":"waf.finding",
		"full_message":"<132>Apr 30 00:28:31 serviceradar-edge envoy-coraza-waf: {\"request_query\":\"<redacted>\"}",
		"host":"serviceradar-edge",
		"level":4,
		"service_name":"envoy-coraza-waf",
		"severity":"Unknown",
		"severity_text":"critical",
		"short_message":"envoy-coraza-waf: {\"request_query\":\"<redacted>\",\"summary\":\"wrong body if chosen\"}",
		"source":"waf",
		"timestamp":1777508911,
		"version":"1.1"
	}`)

	rows, ok := parseJSONLogs(payload, "logs.syslog.processed")
	if !ok {
		t.Fatalf("expected JSON log parse to succeed")
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}

	row := rows[0]
	if row.Body != "WAF critical rule 932370: Remote Command Execution: Windows Command Injection /live/longpoll" {
		t.Fatalf("expected normalized WAF body, got %q", row.Body)
	}
	if row.Source != "waf" {
		t.Fatalf("expected WAF source to override syslog subject source, got %q", row.Source)
	}
	if row.SeverityText != securitySeverityCritical {
		t.Fatalf("expected WAF severity text to stay critical, got %q", row.SeverityText)
	}
	if row.SeverityNumber != 21 {
		t.Fatalf("expected WAF severity number 21, got %d", row.SeverityNumber)
	}
	if row.ServiceName != "envoy-coraza-waf" {
		t.Fatalf("unexpected service name: %q", row.ServiceName)
	}
	if strings.Contains(row.Attributes, "full_message") {
		t.Fatalf("expected full_message to be omitted from metadata, got %s", row.Attributes)
	}
	if !strings.Contains(row.Attributes, `"waf"`) {
		t.Fatalf("expected WAF attributes to be preserved, got %s", row.Attributes)
	}
}

func TestParseJSONLogsPrefersSubjectSourceForSNMP(t *testing.T) {
	payload := []byte(`{
		"body":"I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable.",
		"source":"192.168.10.154:161",
		"resource":{"source":"192.168.10.154:161"},
		"community":"public",
		"varbinds":[
			{
				"oid":"1.3.6.1.2.1.16.9.1.1.2.4911",
				"value":"OCTET STRING: I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable."
			}
		]
	}`)

	rows, ok := parseJSONLogs(payload, "logs.snmp.processed")
	if !ok {
		t.Fatalf("expected JSON log parse to succeed")
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}

	row := rows[0]
	if row.Source != "snmp" {
		t.Fatalf("expected source %q, got %q", "snmp", row.Source)
	}
	if row.Body != "I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable." {
		t.Fatalf("unexpected body: %q", row.Body)
	}
	if row.ResourceAttributes == "" {
		t.Fatalf("expected resource attributes to be preserved")
	}
	if row.Attributes == "" {
		t.Fatalf("expected attributes to be preserved")
	}
	if strings.Contains(row.Attributes, "community") {
		t.Fatalf("expected community to be dropped from attributes, got %s", row.Attributes)
	}
}

func TestParseJSONLogsDerivesSNMPBodyFromVarbindWhenBodyMissing(t *testing.T) {
	payload := []byte(`{
		"source":"192.168.10.154:161",
		"varbinds":[
			{
				"oid":"1.3.6.1.2.1.16.9.1.1.2.4911",
				"value":"OCTET STRING: I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable."
			}
		]
	}`)

	rows, ok := parseJSONLogs(payload, "logs.snmp.processed")
	if !ok {
		t.Fatalf("expected JSON log parse to succeed")
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}

	if rows[0].Body != "I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable." {
		t.Fatalf("unexpected body: %q", rows[0].Body)
	}
}

func TestParseOCSFEvent(t *testing.T) {
	payload := []byte(`{
		"id":"c0b2f5af-7d5d-4c1a-8c5b-7c6a9f4c94b2",
		"time":"2025-01-01T00:00:00Z",
		"class_uid":1008,
		"category_uid":1,
		"type_uid":100800,
		"activity_id":1,
		"severity_id":2,
		"message":"test event",
		"metadata":{
			"service_radar":{
				"signal_schema":{
					"producer_id":"powerdns",
					"producer_version":"0.1.0",
					"schema_id":"com.carverauto.powerdns.dns_activity",
					"schema_version":"1.0.0",
					"display_contract_id":"com.carverauto.powerdns.dns_activity.display",
					"display_contract_version":"1.0.0",
					"display_contract":"display/dns_activity.display.json",
					"signal_type":"event",
					"payload_kind":"ocsf_event"
				}
			}
		}
	}`)

	row, err := parseOCSFEvent(payload)
	if err != nil {
		t.Fatalf("expected OCSF event parse to succeed: %v", err)
	}

	if row.ID == "" {
		t.Fatalf("expected id to be set")
	}

	if row.Time.IsZero() {
		t.Fatalf("expected time to be set")
	}

	if row.ClassUID != 1008 {
		t.Fatalf("unexpected class_uid: %d", row.ClassUID)
	}

	assertRawJSON(t, row.Metadata, `{
		"service_radar":{
			"signal_schema":{
				"producer_id":"powerdns",
				"producer_version":"0.1.0",
				"schema_id":"com.carverauto.powerdns.dns_activity",
				"schema_version":"1.0.0",
				"display_contract_id":"com.carverauto.powerdns.dns_activity.display",
				"display_contract_version":"1.0.0",
				"display_contract":"display/dns_activity.display.json",
				"signal_type":"event",
				"payload_kind":"ocsf_event"
			}
		}
	}`)
	assertRawJSON(t, row.Observables, `[]`)
	assertRawJSON(t, row.Actor, `{}`)
	assertRawJSON(t, row.Device, `{}`)
	assertRawJSON(t, row.SrcEndpoint, `{}`)
	assertRawJSON(t, row.DstEndpoint, `{}`)
	assertRawJSON(t, row.Unmapped, `{}`)

	if !row.CreatedAt.Before(time.Now().Add(1 * time.Minute)) {
		t.Fatalf("expected created_at to be near now")
	}
}

func TestParseJSONLogsMarshalsStructuredBody(t *testing.T) {
	payload := []byte(`{"body":{"action":"login","count":2},"timestamp":1700000000}`)

	rows, ok := parseJSONLogs(payload, "logs.otel.processed")
	if !ok {
		t.Fatalf("expected JSON log parse to succeed")
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}

	if rows[0].Body != `{"action":"login","count":2}` {
		t.Fatalf("expected structured body to be JSON-encoded, got %q", rows[0].Body)
	}
}

func TestParseJSONLogsMarshalsArrayBody(t *testing.T) {
	payload := []byte(`{"body":[{"step":"first"},{"step":"second"}],"timestamp":1700000000}`)

	rows, ok := parseJSONLogs(payload, "logs.otel.processed")
	if !ok {
		t.Fatalf("expected JSON log parse to succeed")
	}

	if rows[0].Body != `[{"step":"first"},{"step":"second"}]` {
		t.Fatalf("expected array body to be JSON-encoded, got %q", rows[0].Body)
	}
}

func TestParseJSONLogsPreservesNanosecondTimestampPrecision(t *testing.T) {
	payload := []byte(`{"message":"precise","timestamp":1705315800123456789}`)

	rows, ok := parseJSONLogs(payload, "logs.otel.processed")
	if !ok {
		t.Fatalf("expected JSON log parse to succeed")
	}

	if got := rows[0].Timestamp.UnixNano(); got != 1705315800123456789 {
		t.Fatalf("expected nanosecond-precise timestamp 1705315800123456789, got %d", got)
	}
}

func TestNormalizeSeverityFallbacks(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name       string
		entry      map[string]interface{}
		wantText   string
		wantNumber int32
	}{
		{
			name:       "number only trace band",
			entry:      map[string]interface{}{"severity_number": 3},
			wantText:   "TRACE",
			wantNumber: 3,
		},
		{
			name:       "number only debug band",
			entry:      map[string]interface{}{"severity_number": 7},
			wantText:   "DEBUG",
			wantNumber: 7,
		},
		{
			name:       "number only info band",
			entry:      map[string]interface{}{"severity_number": 12},
			wantText:   "INFO",
			wantNumber: 12,
		},
		{
			name:       "number only warn band",
			entry:      map[string]interface{}{"severity_number": 16},
			wantText:   "WARN",
			wantNumber: 16,
		},
		{
			name:       "number only error band",
			entry:      map[string]interface{}{"severity_number": 20},
			wantText:   "ERROR",
			wantNumber: 20,
		},
		{
			name:       "number only fatal band",
			entry:      map[string]interface{}{"severity_number": 24},
			wantText:   "FATAL",
			wantNumber: 24,
		},
		{
			name:       "unrecognized text falls back to sender number",
			entry:      map[string]interface{}{"severity_text": "weirdlevel", "severity_number": 18},
			wantText:   "ERROR",
			wantNumber: 18,
		},
		{
			name:       "recognized text never overwrites sender number",
			entry:      map[string]interface{}{"severity_text": "error", "severity_number": 17},
			wantText:   "ERROR",
			wantNumber: 17,
		},
		{
			name:       "java severe maps to error",
			entry:      map[string]interface{}{"severity_text": "SEVERE"},
			wantText:   "ERROR",
			wantNumber: 19,
		},
		{
			name:       "java warning maps to warn",
			entry:      map[string]interface{}{"severity_text": "WARNING"},
			wantText:   "WARN",
			wantNumber: 15,
		},
		{
			name:       "java fine maps to debug",
			entry:      map[string]interface{}{"severity_text": "FINE"},
			wantText:   "DEBUG",
			wantNumber: 7,
		},
		{
			name:       "java finest maps to trace",
			entry:      map[string]interface{}{"severity_text": "FINEST"},
			wantText:   "TRACE",
			wantNumber: 3,
		},
		{
			name:       "no severity signal stays empty instead of INFO",
			entry:      map[string]interface{}{"message": "hello"},
			wantText:   "",
			wantNumber: 0,
		},
		{
			name:       "unspecified zero number stays empty",
			entry:      map[string]interface{}{"severity_number": 0},
			wantText:   "",
			wantNumber: 0,
		},
		{
			name:       "json number severity_number is honored",
			entry:      map[string]interface{}{"severity_number": json.Number("14")},
			wantText:   "WARN",
			wantNumber: 14,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			text, number := normalizeSeverity(tc.entry)
			if text != tc.wantText || number != tc.wantNumber {
				t.Fatalf("expected (%q, %d), got (%q, %d)", tc.wantText, tc.wantNumber, text, number)
			}
		})
	}
}

func TestProcessResourceSpansNilResourceIngestsAsUnknown(t *testing.T) {
	t.Parallel()

	resourceSpan := &tracepbv1.ResourceSpans{
		Resource: nil,
		ScopeSpans: []*tracepbv1.ScopeSpans{
			{
				Spans: []*tracepbv1.Span{
					{
						TraceId:           []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
						SpanId:            []byte{1, 2, 3, 4, 5, 6, 7, 8},
						Name:              "orphan-span",
						StartTimeUnixNano: 1705315800123456789,
						EndTimeUnixNano:   1705315800123456999,
					},
				},
			},
		},
	}

	rows := processResourceSpans(resourceSpan)
	if len(rows) != 1 {
		t.Fatalf("expected nil-resource span to be ingested, got %d rows", len(rows))
	}

	if rows[0].ServiceName != "unknown" {
		t.Fatalf("expected service name %q, got %q", "unknown", rows[0].ServiceName)
	}

	if rows[0].ResourceAttributes != "{}" {
		t.Fatalf("expected empty resource attributes object, got %q", rows[0].ResourceAttributes)
	}

	// Absent resource: the promoted columns fall back to their NOT NULL
	// DEFAULT '' contract values, and the nullable columns stay "" (NULL).
	if rows[0].ServiceNamespace != "" || rows[0].DeploymentEnvironment != "" {
		t.Fatalf("expected empty namespace/environment defaults, got %q %q",
			rows[0].ServiceNamespace, rows[0].DeploymentEnvironment)
	}

	if rows[0].TraceState != "" || rows[0].ScopeAttributes != "" {
		t.Fatalf("expected empty trace state and scope attributes, got %q %q",
			rows[0].TraceState, rows[0].ScopeAttributes)
	}

	if rows[0].DroppedAttributesCount != 0 || rows[0].DroppedEventsCount != 0 || rows[0].DroppedLinksCount != 0 {
		t.Fatalf("expected zero dropped counts, got %d %d %d",
			rows[0].DroppedAttributesCount, rows[0].DroppedEventsCount, rows[0].DroppedLinksCount)
	}
}

func TestSafeUint32ToInt32CapsAtMaxInt32(t *testing.T) {
	t.Parallel()

	cases := []struct {
		input uint32
		want  int32
	}{
		{0, 0},
		{42, 42},
		{2147483647, 2147483647},
		{2147483648, 2147483647},
		{4294967295, 2147483647},
	}

	for _, tc := range cases {
		if got := safeUint32ToInt32(tc.input); got != tc.want {
			t.Fatalf("safeUint32ToInt32(%d): expected %d, got %d", tc.input, tc.want, got)
		}
	}
}

func TestParseOTELLogsNilResourceIngestsAsUnknown(t *testing.T) {
	t.Parallel()

	req := &collectlogsv1.ExportLogsServiceRequest{
		ResourceLogs: []*logsv1.ResourceLogs{
			{
				Resource: nil,
				ScopeLogs: []*logsv1.ScopeLogs{
					{
						LogRecords: []*logsv1.LogRecord{
							{
								Body: &commonv1.AnyValue{
									Value: &commonv1.AnyValue_StringValue{StringValue: "orphan log"},
								},
							},
						},
					},
				},
			},
		},
	}

	payload, err := proto.Marshal(req)
	if err != nil {
		t.Fatalf("failed to marshal OTEL logs request: %v", err)
	}

	rows, err := parseOTELLogs(payload, "logs.otel.processed")
	if err != nil {
		t.Fatalf("expected OTEL log parse to succeed: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected nil-resource log to be ingested, got %d rows", len(rows))
	}

	if rows[0].ServiceName != "unknown" {
		t.Fatalf("expected service name %q, got %q", "unknown", rows[0].ServiceName)
	}

	if rows[0].Body != "orphan log" {
		t.Fatalf("unexpected body: %q", rows[0].Body)
	}
}

func stringKeyValue(key, value string) *commonv1.KeyValue {
	return &commonv1.KeyValue{
		Key: key,
		Value: &commonv1.AnyValue{
			Value: &commonv1.AnyValue_StringValue{StringValue: value},
		},
	}
}

func assertRawJSON(t *testing.T, got json.RawMessage, want string) {
	t.Helper()

	var gotValue interface{}
	if err := json.Unmarshal(got, &gotValue); err != nil {
		t.Fatalf("failed to decode json %q: %v", string(got), err)
	}

	var wantValue interface{}
	if err := json.Unmarshal([]byte(want), &wantValue); err != nil {
		t.Fatalf("failed to decode expected json %q: %v", want, err)
	}

	gotBytes, gotErr := json.Marshal(gotValue)
	wantBytes, wantErr := json.Marshal(wantValue)
	if gotErr != nil || wantErr != nil || string(gotBytes) != string(wantBytes) {
		t.Fatalf("unexpected json: got %s want %s", string(got), want)
	}
}
