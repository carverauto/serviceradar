package dbeventwriter

import (
	"strings"
	"testing"
	"time"
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

func TestParseOCSFEvent(t *testing.T) {
	payload := []byte(`{
		"id":"c0b2f5af-7d5d-4c1a-8c5b-7c6a9f4c94b2",
		"time":"2025-01-01T00:00:00Z",
		"class_uid":1008,
		"category_uid":1,
		"type_uid":100800,
		"activity_id":1,
		"severity_id":2,
		"message":"test event"
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

	if !row.CreatedAt.Before(time.Now().Add(1 * time.Minute)) {
		t.Fatalf("expected created_at to be near now")
	}
}
