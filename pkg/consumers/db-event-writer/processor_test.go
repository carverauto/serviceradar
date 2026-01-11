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
		"tenant_id":"11111111-1111-1111-1111-111111111111"
	}`)

	row, err := parseOCSFEvent(payload, "")
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

	if row.TenantID != "11111111-1111-1111-1111-111111111111" {
		t.Fatalf("unexpected tenant_id: %s", row.TenantID)
	}

	if !row.CreatedAt.Before(time.Now().Add(1 * time.Minute)) {
		t.Fatalf("expected created_at to be near now")
	}
}
