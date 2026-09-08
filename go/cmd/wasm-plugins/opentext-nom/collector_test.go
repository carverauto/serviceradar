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

func TestNormalizeDeviceRowAcceptsHPNAIntegerFlags(t *testing.T) {
	row, ok := normalizeDeviceRow(map[string]any{
		"deviceID":         json.Number("71061"),
		"hostName":         "SITE02-MDF001-CSW001",
		"primaryIPAddress": "10.7.84.1",
		"serialNumber":     "VN4BM3P0W5,VN4BM3P0X3",
		"vendor":           "Aruba",
		"model":            "JL659A 6300M",
		"deviceType":       "Switch",
		"siteName":         "Example Production",
		"managementStatus": json.Number("0"),
		"excludeFromPoll":  json.Number("0"),
	})
	if !ok {
		t.Fatal("normalizeDeviceRow() = false")
	}
	if row.DeviceID != "71061" || row.ManagementStatus != "Managed" {
		t.Fatalf("unexpected normalized row: %#v", row)
	}
	if row.Serial != "VN4BM3P0W5" || len(row.ChassisSerials) != 2 {
		t.Fatalf("serial split = %#v %#v", row.Serial, row.ChassisSerials)
	}
	if row.ExcludeFromPoll == nil || *row.ExcludeFromPoll {
		t.Fatalf("excludeFromPoll = %#v, want false", row.ExcludeFromPoll)
	}

	mapped := inventoryDevice("network-automation-prod", row)
	if mapped.Serial != "VN4BM3P0W5" {
		t.Fatalf("inventory serial = %q", mapped.Serial)
	}
	if osInfo, ok := mapped.Metadata["os"].(map[string]any); ok && osInfo["name"] != nil {
		t.Fatalf("os name = %#v, want empty without driver", osInfo)
	}
	hwInfo, _ := mapped.Metadata["hw_info"].(map[string]any)
	if hwInfo["serial_number"] != "VN4BM3P0W5" {
		t.Fatalf("hw_info = %#v", hwInfo)
	}

	inactive, ok := normalizeDeviceRow(map[string]any{
		"deviceID":         2,
		"hostName":         "inactive-sw",
		"primaryIPAddress": "10.0.0.2",
		"managementStatus": json.Number("1"),
		"excludeFromPoll":  json.Number("1"),
	})
	if !ok {
		t.Fatal("normalizeDeviceRow(inactive) = false")
	}
	if inactive.ManagementStatus != "Unmanaged" {
		t.Fatalf("inactive status = %q", inactive.ManagementStatus)
	}
	if inactive.ExcludeFromPoll == nil || !*inactive.ExcludeFromPoll {
		t.Fatalf("inactive excludeFromPoll = %#v, want true", inactive.ExcludeFromPoll)
	}
}

func TestInventoryDeviceMapsOCSFFieldsFromHPNARow(t *testing.T) {
	row, ok := normalizeDeviceRow(map[string]any{
		"deviceID":             json.Number("71061"),
		"hostName":             "SITE02-MDF001-CSW001",
		"primaryIPAddress":     "10.7.84.1",
		"serialNumber":         "VN4BM3P0W5,VN4BM3P0X3",
		"vendor":               "Aruba",
		"model":                "JL659A 6300M",
		"deviceType":           "Switch",
		"siteName":             "Example Production",
		"managementStatus":     json.Number("0"),
		"excludeFromPoll":      json.Number("0"),
		"softwareVersion":      "FL.10.13.1161",
		"firmwareVersion":      "FL.10.13.1161",
		"driverName":           "ArubaOS-CX",
		"processor":            "WS-C3750-24P (PowerPC405)",
		"memory":               json.Number("7973057331"),
		"totalPorts":           json.Number("120"),
		"freePorts":            json.Number("11"),
		"contact":              "Example NOC          ",
		"geographicalLocation": "TPECS_MDF1                    ",
		"rOMVersion":           "KB.16.01.0008",
	})
	if !ok {
		t.Fatal("normalizeDeviceRow() = false")
	}
	device := inventoryDevice("network-automation-prod", row)
	if device.Serial != "VN4BM3P0W5" {
		t.Fatalf("serial = %q", device.Serial)
	}
	osInfo := device.Metadata["os"].(map[string]any)
	if osInfo["name"] != "ArubaOS-CX" || osInfo["version"] != "FL.10.13.1161" {
		t.Fatalf("os = %#v", osInfo)
	}
	hwInfo := device.Metadata["hw_info"].(map[string]any)
	if hwInfo["memory_bytes"].(*int64) == nil || *hwInfo["memory_bytes"].(*int64) != 7973057331 {
		t.Fatalf("memory = %#v", hwInfo["memory_bytes"])
	}
	if hwInfo["total_ports"].(*int64) == nil || *hwInfo["total_ports"].(*int64) != 120 {
		t.Fatalf("total_ports = %#v", hwInfo["total_ports"])
	}
	if got, _ := hwInfo["chassis_serials"].([]string); len(got) != 2 || got[0] != "VN4BM3P0W5" {
		t.Fatalf("chassis_serials = %#v", hwInfo["chassis_serials"])
	}
	owner := device.Metadata["owner"].(map[string]any)
	if owner["name"] != "Example NOC" {
		t.Fatalf("owner = %#v", owner)
	}
	if managed, _ := device.Metadata["is_managed"].(*bool); managed == nil || !*managed {
		t.Fatalf("is_managed = %#v", device.Metadata["is_managed"])
	}
	source := device.Metadata["source_metadata"].(map[string]any)
	if source["geographical_location"] != "TPECS_MDF1" || source["driver_name"] != "ArubaOS-CX" {
		t.Fatalf("source_metadata = %#v", source)
	}

	snapshot := Snapshot{
		InstanceID:       "network-automation-prod",
		CollectionID:     "col-1",
		ObservedAt:       time.Date(2026, 8, 29, 17, 0, 0, 0, time.UTC),
		Devices:          []InventoryDevice{device},
		SnapshotComplete: true,
	}
	result, err := buildPluginResult(snapshot, 1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	payload, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(payload), `"serial":"VN4BM3P0W5"`) {
		t.Fatalf("result missing first serial: %s", payload)
	}
	if strings.Contains(string(payload), `"serial":"VN4BM3P0W5,VN4BM3P0X3"`) {
		t.Fatalf("result used stacked serial as identity: %s", payload)
	}
	if !strings.Contains(string(payload), `"name":"ArubaOS-CX"`) ||
		!strings.Contains(string(payload), `"memory_bytes":7973057331`) {
		t.Fatalf("result missing os/hw_info: %s", payload)
	}
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
	if snapshot.Devices[0].IntegrationID != "opentext-nom:v1:network-automation-prod:device:1" {
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

func TestCollectorEncodesIDsAsCommaSeparatedString(t *testing.T) {
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(200, []any{deviceRow(1, "ORD-ASW001", "10.0.0.1", "SER-1")}),
	}}
	cfg := validTestConfig()
	cfg.Queries = []Query{{Name: "sample", Parameters: map[string]any{"ids": []any{json.Number("1"), json.Number("2")}}}}

	if _, err := testCollector(fake).Collect(context.Background(), cfg); err != nil {
		t.Fatalf("Collect() error = %v", err)
	}
	var body map[string]any
	if err := json.Unmarshal(fake.requests[0].Body, &body); err != nil {
		t.Fatal(err)
	}
	parameters := body["parameters"].(map[string]any)
	if parameters["ids"] != "1,2" {
		t.Fatalf("ids wire format = %#v, want comma-separated string", parameters["ids"])
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
	assertRunError(t, err, "opentext_nom_duplicate_conflict")
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
	assertRunError(t, err, "opentext_nom_pagination_invalid")
}

func TestCollectorLeavesAuthenticationToHost(t *testing.T) {
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(401, map[string]any{"error": "expired"}),
	}}

	_, err := testCollector(fake).Collect(context.Background(), validTestConfig())
	assertRunError(t, err, "opentext_nom_auth_failed")
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
		{name: "unauthorized", status: 401, want: "opentext_nom_auth_failed"},
		{name: "forbidden", status: 403, want: "opentext_nom_forbidden"},
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
	assertRunError(t, err, "opentext_nom_upstream_unavailable")
}

func TestCollectorRejectsMalformedResponsesAndDeviceRows(t *testing.T) {
	tests := []struct {
		name     string
		response HTTPResponse
		want     string
	}{
		{name: "not array", response: jsonResponse(200, map[string]any{"result": "bad"}), want: "opentext_nom_response_invalid"},
		{name: "not json", response: HTTPResponse{Status: 200, Body: []byte("<html>login</html>")}, want: "opentext_nom_response_invalid"},
		{name: "missing ID full page", response: jsonResponse(200, []any{
			map[string]any{"hostName": "ASW001", "primaryIPAddress": "10.0.0.1"},
			deviceRow(2, "ASW002", "10.0.0.2", "SER-2"),
		}), want: "opentext_nom_device_invalid"},
		{name: "missing ID final page", response: jsonResponse(200, []any{
			map[string]any{"hostName": "ASW001", "primaryIPAddress": "10.0.0.1"},
		}), want: "opentext_nom_device_invalid"},
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
		!strings.Contains(string(payload), `"integration_type":"opentext-nom"`) ||
		!strings.Contains(string(payload), `"source_metadata"`) {
		t.Fatalf("result does not satisfy generic inventory contract: %s", payload)
	}
	if _, err := buildPluginResult(snapshot, 100); err == nil {
		t.Fatal("expected result-size bound to fail")
	} else {
		assertRunError(t, err, "opentext_nom_result_too_large")
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
		"siteName":         "ZZD",
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

func TestCollectorPropagatesInsecureSkipVerify(t *testing.T) {
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(200, []any{deviceRow(1, "ORD-ASW001", "10.0.0.1", "SER-1")}),
	}}
	cfg := validTestConfig()
	cfg.InsecureSkipVerify = true
	if _, err := testCollector(fake).Collect(context.Background(), cfg); err != nil {
		t.Fatal(err)
	}
	if len(fake.requests) == 0 {
		t.Fatal("expected inventory request")
	}
	for _, request := range fake.requests {
		if !request.InsecureSkipVerify {
			t.Fatalf("request to %s did not skip TLS verify", request.URL)
		}
	}
}

func TestCollectorSkipsL2WithoutEndpoints(t *testing.T) {
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(200, []any{deviceRow(1, "ORD-ASW001", "10.0.0.1", "SER-1")}),
	}}
	cfg := validTestConfig()
	if _, err := testCollector(fake).Collect(context.Background(), cfg); err != nil {
		t.Fatal(err)
	}
	for _, request := range fake.requests {
		if strings.Contains(request.URL, "attachedSwitchPort") {
			t.Fatalf("queried attachedSwitchPort without l2_endpoints: %s", request.URL)
		}
	}
}

func TestCollectorSkipsL2WithoutNNMURL(t *testing.T) {
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(200, []any{deviceRow(1, "ORD-ASW001", "10.0.0.1", "SER-1")}),
	}}
	cfg := validTestConfig()
	cfg.NNMURL = ""
	cfg.TokenURL = "https://na.example.com/nom-na/idp/oauth2/token"
	cfg.tokenAuthMode = tokenAuthNA
	cfg.L2Endpoints = []L2Endpoint{{MAC: "B8:A4:4F:82:EF:F9", IP: "10.208.230.4"}}
	if _, err := testCollector(fake).Collect(context.Background(), cfg); err != nil {
		t.Fatal(err)
	}
	for _, request := range fake.requests {
		if strings.Contains(request.URL, "attachedSwitchPort") {
			t.Fatalf("queried attachedSwitchPort without nnm_url: %s", request.URL)
		}
	}
}

func TestCollectorLooksUpAttachedSwitchPortByEndpointMAC(t *testing.T) {
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(200, []any{deviceRow(1, "ORD-ASW001", "10.0.0.1", "SER-1")}),
		jsonResponse(200, map[string]any{
			"items": []any{
				map[string]any{
					"_links": map[string]any{
						"self": map[string]any{"href": "https://nnm.example.com/nnmi/api/disco/v1/attachedSwitchPort/ent-1"},
					},
				},
			},
		}),
		jsonResponse(200, map[string]any{
			"_links": map[string]any{
				"interface": map[string]any{
					"title": "3/1/28",
					"href":  "https://nnm.example.com/nnmi/api/topo/v1/interface/if-1",
				},
				"vlan": map[string]any{"title": "561"},
			},
		}),
		jsonResponse(200, map[string]any{
			"ifName":  "3/1/28",
			"ifAlias": "CCTV",
			"_links": map[string]any{
				"hostedOn": map[string]any{"title": "SITE01-IDFC08-ASW002"},
			},
		}),
	}}
	cfg := validTestConfig()
	cfg.L2Endpoints = []L2Endpoint{{MAC: "B8:A4:4F:82:EF:F9", IP: "10.208.230.4"}}
	snapshot, err := testCollector(fake).Collect(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Devices) != 1 || snapshot.Devices[0].IP != "10.0.0.1" {
		t.Fatalf("NA inventory mutated by L2: %#v", snapshot.Devices)
	}
	if len(snapshot.AttachmentDevices) != 1 {
		t.Fatalf("attachment devices = %#v", snapshot.AttachmentDevices)
	}
	attachment := snapshot.AttachmentDevices[0]
	facts := attachment.Metadata["facts"].(map[string]any)
	port := facts["switch_port_attachment"].(map[string]any)
	if port["switch_hostname"] != "SITE01-IDFC08-ASW002" || port["port"] != "3/1/28" {
		t.Fatalf("attachment facts = %#v", port)
	}
	if facts["vlan_uid"] != "561" {
		t.Fatalf("vlan_uid = %#v", facts["vlan_uid"])
	}
	if !strings.Contains(fake.requests[1].URL, "mac=B8A44F82EFF9") {
		t.Fatalf("MAC lookup was not separator-free uppercase: %s", fake.requests[1].URL)
	}
	if strings.Contains(fake.requests[1].URL, "10.0.0.1") {
		t.Fatal("L2 lookup used NA switch IP")
	}
	result, err := buildPluginResult(snapshot, 1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	payload, _ := json.Marshal(result)
	if !strings.Contains(string(payload), `"snapshot_complete":false`) {
		t.Fatalf("L2 envelope should not be a complete snapshot: %s", payload)
	}
}

func TestCollectorTreatsEmptyNNMiItemsAsNoMatch(t *testing.T) {
	fake := &fakeHTTPDoer{responses: []HTTPResponse{
		jsonResponse(200, []any{deviceRow(1, "ORD-ASW001", "10.0.0.1", "SER-1")}),
		jsonResponse(200, map[string]any{"items": []any{}}),
	}}
	cfg := validTestConfig()
	cfg.L2Endpoints = []L2Endpoint{{MAC: "B8A44F82EFF9"}}
	snapshot, err := testCollector(fake).Collect(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.AttachmentDevices) != 0 {
		t.Fatalf("empty items should be no match: %#v", snapshot.AttachmentDevices)
	}
}
