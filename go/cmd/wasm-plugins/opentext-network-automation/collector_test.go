package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

type fakeHTTPDoer struct {
	responses []HTTPResponse
	errors    []error
	requests  []HTTPRequest
}

func (f *fakeHTTPDoer) Do(_ context.Context, request HTTPRequest) (HTTPResponse, error) {
	f.requests = append(f.requests, request)
	index := len(f.requests) - 1
	if index < len(f.errors) && f.errors[index] != nil {
		return HTTPResponse{}, f.errors[index]
	}
	if index >= len(f.responses) {
		return HTTPResponse{}, errors.New("unexpected request")
	}
	return f.responses[index], nil
}

func TestCollectorPaginatesAndBuildsCompleteDeterministicSnapshot(t *testing.T) {
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(200, []any{
			deviceRow(2, "ORD-ASW002", "10.0.0.2", "SER-2"),
			deviceRow(1, "ORD-ASW001", "10.0.0.1", "SER-1"),
		}),
		jsonResponse(200, map[string]any{"result": []any{
			deviceRow(3, "ORD-ASW003", "10.0.0.3", "SER-3"),
		}}),
	}}
	cfg := validTestConfig()
	collector := testCollector(fake)

	snapshot, err := collector.Collect(context.Background(), cfg)
	if err != nil {
		t.Fatalf("Collect() error = %v", err)
	}
	if !snapshot.SnapshotComplete || len(snapshot.Devices) != 3 || snapshot.Pages != 2 {
		t.Fatalf("unexpected snapshot: %#v", snapshot)
	}
	if snapshot.Devices[0].SourceObjectID != "1" || snapshot.Devices[2].SourceObjectID != "3" {
		t.Fatalf("devices not deterministically sorted: %#v", snapshot.Devices)
	}
	if snapshot.Devices[0].IntegrationID != "opentext-network-automation:v1:network-automation-prod:device:1" {
		t.Fatalf("unexpected integration ID: %s", snapshot.Devices[0].IntegrationID)
	}
	if snapshot.QueryHash == "" || snapshot.ContentHash == "" || snapshot.CollectionID == "" {
		t.Fatalf("snapshot identifiers missing: %#v", snapshot)
	}
	assertNoGuestAuthorization(t, fake.requests)
	var secondPage map[string]any
	if err := json.Unmarshal(fake.requests[1].Body, &secondPage); err != nil {
		t.Fatal(err)
	}
	parameters := secondPage["parameters"].(map[string]any)
	if parameters["startid"] != float64(3) || parameters["limitcount"] != float64(2) {
		t.Fatalf("unexpected pagination parameters: %#v", parameters)
	}
	if command := secondPage["command"]; command != "list device" {
		t.Fatalf("command = %#v, want fixed list device", command)
	}
}

func TestCollectorDeduplicatesIdenticalRowsAcrossQueries(t *testing.T) {
	row := deviceRow(1, "ORD-ASW001", "10.0.0.1", "SER-1")
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(200, []any{row}),
		jsonResponse(200, []any{row}),
	}}
	cfg := validTestConfig()
	cfg.Queries = []Query{
		{Name: "switches", Parameters: map[string]any{"type": "Switch"}},
		{Name: "cisco", Parameters: map[string]any{"vendor": "Cisco"}},
	}

	snapshot, err := testCollector(fake).Collect(context.Background(), cfg)
	if err != nil {
		t.Fatalf("Collect() error = %v", err)
	}
	if len(snapshot.Devices) != 1 || snapshot.DuplicateRows != 1 {
		t.Fatalf("unexpected dedupe result: %#v", snapshot)
	}
}

func TestCollectorRejectsConflictingDuplicateDeviceIDs(t *testing.T) {
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(200, []any{deviceRow(1, "ORD-ASW001", "10.0.0.1", "SER-1")}),
		jsonResponse(200, []any{deviceRow(1, "ORD-ASW001", "10.0.0.99", "SER-1")}),
	}}
	cfg := validTestConfig()
	cfg.Queries = []Query{
		{Name: "switches", Parameters: map[string]any{"type": "Switch"}},
		{Name: "cisco", Parameters: map[string]any{"vendor": "Cisco"}},
	}

	_, err := testCollector(fake).Collect(context.Background(), cfg)
	assertRunError(t, err, "network_automation_duplicate_conflict")
}

func TestCollectorRejectsNonAdvancingFullPage(t *testing.T) {
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(200, []any{
			deviceRow(1, "ASW001", "10.0.0.1", "SER-1"),
			deviceRow(2, "ASW002", "10.0.0.2", "SER-2"),
		}),
		jsonResponse(200, []any{
			deviceRow(1, "ASW001", "10.0.0.1", "SER-1"),
			deviceRow(2, "ASW002", "10.0.0.2", "SER-2"),
		}),
	}}

	_, err := testCollector(fake).Collect(context.Background(), validTestConfig())
	assertRunError(t, err, "network_automation_pagination_invalid")
}

func TestCollectorLeavesAuthenticationToHost(t *testing.T) {
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(401, map[string]any{"error": "expired"}),
	}}

	_, err := testCollector(fake).Collect(context.Background(), validTestConfig())
	assertRunError(t, err, "network_automation_auth_failed")
	if len(fake.requests) != 1 {
		t.Fatalf("guest requests = %d, want one upstream operation", len(fake.requests))
	}
	assertNoGuestAuthorization(t, fake.requests)
}

func TestCollectorReturnsStableAuthenticationAndAuthorizationErrors(t *testing.T) {
	tests := []struct {
		name   string
		status int
		want   string
	}{
		{name: "unauthorized", status: 401, want: "network_automation_auth_failed"},
		{name: "forbidden", status: 403, want: "network_automation_forbidden"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := &fakeHTTPDoer{responses: []HTTPResponse{
				jsonResponse(test.status, map[string]any{"message": "upstream detail must stay hidden"}),
			}}
			_, err := testCollector(fake).Collect(context.Background(), validTestConfig())
			assertRunError(t, err, test.want)
			if strings.Contains(err.Error(), "upstream detail") {
				t.Fatalf("error leaked upstream response: %v", err)
			}
		})
	}
}

func TestCollectorRetriesTransientFailuresWithoutLeakingDetails(t *testing.T) {
	fake := &fakeHTTPDoer{
		responses: []HTTPResponse{
			{},
			jsonResponse(503, map[string]any{"stack": "sensitive internal trace"}),
		},
		errors: []error{errors.New("dial tcp secret.internal: connection refused")},
	}
	cfg := validTestConfig()
	cfg.MaxRetries = 1

	_, err := testCollector(fake).Collect(context.Background(), cfg)
	if err == nil || strings.Contains(err.Error(), "secret.internal") || strings.Contains(err.Error(), "trace") {
		t.Fatalf("unsafe error = %v", err)
	}
	assertRunError(t, err, "network_automation_upstream_unavailable")
}

func TestCollectorRejectsMalformedResponsesAndDeviceRows(t *testing.T) {
	tests := []struct {
		name     string
		response HTTPResponse
		want     string
	}{
		{name: "not array", response: jsonResponse(200, map[string]any{"result": "bad"}), want: "network_automation_response_invalid"},
		{name: "not json", response: HTTPResponse{Status: 200, Body: []byte("<html>login</html>")}, want: "network_automation_response_invalid"},
		{name: "missing ID full page", response: jsonResponse(200, []any{
			map[string]any{"hostName": "ASW001", "primaryIPAddress": "10.0.0.1"},
			deviceRow(2, "ASW002", "10.0.0.2", "SER-2"),
		}), want: "network_automation_device_invalid"},
		{name: "missing ID final page", response: jsonResponse(200, []any{
			map[string]any{"hostName": "ASW001", "primaryIPAddress": "10.0.0.1"},
		}), want: "network_automation_device_invalid"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := &fakeHTTPDoer{responses: []HTTPResponse{
				test.response,
			}}
			_, err := testCollector(fake).Collect(context.Background(), validTestConfig())
			assertRunError(t, err, test.want)
		})
	}
}

func TestPluginResultIsBoundedAndSatisfiesInventoryContract(t *testing.T) {
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(200, []any{deviceRow(1, "ASW001", "10.0.0.1", "SER-1")}),
	}}
	snapshot, err := testCollector(fake).Collect(context.Background(), validTestConfig())
	if err != nil {
		t.Fatal(err)
	}
	result, err := buildPluginResult(snapshot, 1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(payload), `"snapshot_complete":true`) {
		t.Fatalf("result missing complete snapshot marker: %s", payload)
	}
	if !strings.Contains(string(payload), `"device_id":"1"`) ||
		!strings.Contains(string(payload), `"integration_type":"opentext-network-automation"`) ||
		!strings.Contains(string(payload), `"source_metadata"`) {
		t.Fatalf("result does not satisfy generic inventory contract: %s", payload)
	}
	if _, err := buildPluginResult(snapshot, 100); err == nil {
		t.Fatal("expected result-size bound to fail")
	} else {
		assertRunError(t, err, "network_automation_result_too_large")
	}
}

func assertNoGuestAuthorization(t *testing.T, requests []HTTPRequest) {
	t.Helper()
	for _, request := range requests {
		for key := range request.Headers {
			if strings.EqualFold(key, "Authorization") {
				t.Fatalf("guest supplied authorization material for %s", request.URL)
			}
		}
		if request.URL == validTestConfig().TokenURL {
			t.Fatalf("guest called the token endpoint: %s", request.URL)
		}
	}
}

func testCollector(httpClient HTTPDoer) *Collector {
	collector := NewCollector(httpClient)
	collector.Now = func() time.Time { return time.Date(2026, 7, 13, 12, 0, 0, 123, time.UTC) }
	collector.Sleep = func(context.Context, time.Duration) error { return nil }
	return collector
}

func jsonResponse(status int, value any) HTTPResponse {
	payload, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return HTTPResponse{Status: status, Body: payload}
}

func deviceRow(id int, hostname, ip, serial string) map[string]any {
	return map[string]any{
		"deviceID":         id,
		"hostName":         hostname,
		"primaryIPAddress": ip,
		"serialNumber":     serial,
		"vendor":           "Cisco",
		"model":            "Nexus 9300",
		"deviceType":       "Switch",
		"siteName":         "ORD",
		"managementStatus": "Managed",
		"excludeFromPoll":  false,
	}
}

func assertRunError(t *testing.T, err error, code string) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error %q", code)
	}
	if got := safeErrorCode(err); got != code {
		t.Fatalf("safeErrorCode(%v) = %q, want %q", err, got, code)
	}
}
