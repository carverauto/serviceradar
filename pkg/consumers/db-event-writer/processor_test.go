package dbeventwriter

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestParseCloudEvent(t *testing.T) {
	msg := []byte(`{"specversion":"1.0","id":"1","type":"cef_severity",
		"source":"nats://events/events.syslog","datacontenttype":"application/json","data":{"foo":"bar"}}`)

	data, ok := parseCloudEvent(msg)

	if !ok {
		t.Fatalf("expected ok")
	}

	if data != "{\"foo\":\"bar\"}" {
		t.Fatalf("unexpected data: %s", data)
	}
}

func TestParseCloudEventInvalid(t *testing.T) {
	msg := []byte(`{"id":1}`)

	if _, ok := parseCloudEvent(msg); ok {
		t.Fatalf("expected failure")
	}
}

func TestTryDeviceLifecycleEvent(t *testing.T) {
	now := time.Now().UTC()
	data := models.DeviceLifecycleEventData{
		DeviceID:  "default:10.0.0.1",
		Action:    "Deleted",
		Actor:     "admin@example.com",
		Timestamp: now,
		Severity:  "Medium",
		Level:     5,
	}

	payload, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("failed to marshal test payload: %v", err)
	}

	event := &models.CloudEvent{
		Type:    "com.carverauto.serviceradar.device.lifecycle",
		Subject: "events.devices.lifecycle",
		Data:    data,
	}

	row := &models.EventRow{}

	if !tryDeviceLifecycleEvent(row, event, payload) {
		t.Fatalf("expected device lifecycle event to be handled")
	}

	if row.ShortMessage != "Device default:10.0.0.1 deleted by admin@example.com" {
		t.Fatalf("unexpected short message: %s", row.ShortMessage)
	}

	if row.Severity != "Medium" {
		t.Fatalf("unexpected severity: %s", row.Severity)
	}

	if row.Level != 5 {
		t.Fatalf("unexpected level: %d", row.Level)
	}

	if !row.EventTimestamp.Equal(now) {
		t.Fatalf("expected timestamp %v, got %v", now, row.EventTimestamp)
	}
}
