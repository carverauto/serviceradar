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

func TestParseOTELLogsPreservesFlattenedSignalSchemaAttributes(t *testing.T) {
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

	if !strings.Contains(rows[0].Attributes, "service_radar.signal_schema.schema_id=com.carverauto.test.log") {
		t.Fatalf("expected flattened signal schema attributes to be preserved, got %s", rows[0].Attributes)
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
