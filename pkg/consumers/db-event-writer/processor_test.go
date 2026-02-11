package dbeventwriter

import (
	"testing"
	"time"
)

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
