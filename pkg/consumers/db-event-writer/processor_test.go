package dbeventwriter

import "testing"

func TestParseCloudEvent(t *testing.T) {
	msg := []byte(`{"specversion":"1.0","id":"1","type":"cef_severity","source":"nats://events/events.syslog","datacontenttype":"application/json","data":{"foo":"bar"}}`)
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
