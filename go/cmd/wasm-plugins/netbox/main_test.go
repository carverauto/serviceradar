package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

type fakeHTTP struct {
	requests  []sdk.HTTPRequest
	responses map[string]fakeResponse
}

type fakeResponse struct {
	status int
	body   string
	err    error
}

func (f *fakeHTTP) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	f.requests = append(f.requests, req)

	resp, ok := f.responses[req.URL]
	if !ok {
		return &sdk.HTTPResponse{Status: 404, Body: []byte("not found")}, nil
	}
	if resp.err != nil {
		return nil, resp.err
	}

	status := resp.status
	if status == 0 {
		status = 200
	}

	return &sdk.HTTPResponse{Status: status, Body: []byte(resp.body)}, nil
}

func swapHTTP(t *testing.T, fake *fakeHTTP) {
	t.Helper()

	prev := netboxHTTP
	netboxHTTP = fake
	t.Cleanup(func() { netboxHTTP = prev })
}

func testSource() SourceConfig {
	return SourceConfig{
		SourceID: "lab",
		BaseURL:  "https://netbox.example.com",
		APIToken: "secret-token",
	}
}

func deviceJSON(id int, name, ip4 string) string {
	primary := "null"
	if ip4 != "" {
		primary = fmt.Sprintf(`{"id": %d, "address": %q}`, id+1000, ip4)
	}

	return fmt.Sprintf(`{
		"id": %d,
		"name": %q,
		"device_type": {"id": 1, "manufacturer": {"id": 1, "name": "Cisco"}, "model": "C9300"},
		"role": {"id": 2, "name": "access-switch"},
		"site": {"id": 3, "name": "austin-dc"},
		"status": {"value": "active", "label": "Active"},
		"primary_ip4": %s,
		"primary_ip6": null,
		"description": "",
		"created": "2026-01-01T00:00:00Z",
		"last_updated": "2026-06-01T00:00:00Z"
	}`, id, name, primary)
}

func pageJSON(count int, next string, devices ...string) string {
	nextJSON := "null"
	if next != "" {
		nextJSON = fmt.Sprintf("%q", next)
	}

	return fmt.Sprintf(`{"count": %d, "next": %s, "previous": null, "results": [%s]}`,
		count, nextJSON, strings.Join(devices, ","))
}

func TestInventorySyncFetchesAllPages(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=100": {
			body: pageJSON(3, "https://netbox.example.com/api/dcim/devices/?limit=100&offset=2",
				deviceJSON(1, "sw-1", "10.0.0.1/24"), deviceJSON(2, "sw-2", "10.0.0.2/24")),
		},
		"https://netbox.example.com/api/dcim/devices/?limit=100&offset=2": {
			body: pageJSON(3, "", deviceJSON(3, "sw-3", "10.0.0.3/24")),
		},
	}}
	swapHTTP(t, fake)

	result := runInventorySyncSource(testSource())

	if result.Status != sdk.StatusOK {
		t.Fatalf("expected OK result, got %v: %s", result.Status, result.Summary)
	}
	if len(result.DeviceDiscovery) != 1 {
		t.Fatalf("expected one discovery envelope, got %d", len(result.DeviceDiscovery))
	}

	discovery := result.DeviceDiscovery[0]
	if len(discovery.Devices) != 3 {
		t.Fatalf("expected 3 devices across pages, got %d", len(discovery.Devices))
	}
	if discovery.Source != "netbox" {
		t.Fatalf("expected source netbox, got %q", discovery.Source)
	}
	if discovery.Metadata["snapshot_complete"] != true {
		t.Fatalf("expected snapshot_complete=true, got %v", discovery.Metadata["snapshot_complete"])
	}
	if discovery.Metadata["source_instance"] != "lab" {
		t.Fatalf("expected source_instance lab, got %v", discovery.Metadata["source_instance"])
	}
	if discovery.CollectionID == "" || len(discovery.CollectionID) > 160 {
		t.Fatalf("collection id missing or unbounded: %q", discovery.CollectionID)
	}
	if len(discovery.ReferenceHash) != 64 || strings.ContainsAny(discovery.ReferenceHash, ":ghijklmnopqrstuvwxyz") {
		t.Fatalf("reference_hash must be a bare 64-hex digest, got %q", discovery.ReferenceHash)
	}

	wantIDs := []string{"netbox:lab:device:1", "netbox:lab:device:2", "netbox:lab:device:3"}
	for i, want := range wantIDs {
		if discovery.Devices[i].DeviceID != want {
			t.Fatalf("device %d: expected id %q, got %q", i, want, discovery.Devices[i].DeviceID)
		}
	}

	for _, req := range fake.requests {
		if req.Headers["Authorization"] != "Token secret-token" {
			t.Fatalf("expected NetBox token auth header, got %q", req.Headers["Authorization"])
		}
		if req.Headers["Accept"] != "application/json" {
			t.Fatalf("expected JSON accept header, got %q", req.Headers["Accept"])
		}
	}
}

func TestInventorySyncMidPaginationFailureEmitsNothing(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=100": {
			body: pageJSON(3, "https://netbox.example.com/api/dcim/devices/?limit=100&offset=2",
				deviceJSON(1, "sw-1", "10.0.0.1/24"), deviceJSON(2, "sw-2", "10.0.0.2/24")),
		},
		"https://netbox.example.com/api/dcim/devices/?limit=100&offset=2": {
			status: 500,
			body:   "boom",
		},
	}}
	swapHTTP(t, fake)

	result := runInventorySyncSource(testSource())

	if result.Status != sdk.StatusCritical {
		t.Fatalf("expected Critical on mid-pagination failure, got %v", result.Status)
	}
	if len(result.DeviceDiscovery) != 0 {
		t.Fatalf("partial snapshot must not be emitted, got %d envelopes", len(result.DeviceDiscovery))
	}
}

func TestInventorySyncCountChangeAborts(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=100": {
			body: pageJSON(3, "https://netbox.example.com/api/dcim/devices/?limit=100&offset=2",
				deviceJSON(1, "sw-1", "10.0.0.1/24"), deviceJSON(2, "sw-2", "10.0.0.2/24")),
		},
		"https://netbox.example.com/api/dcim/devices/?limit=100&offset=2": {
			body: pageJSON(5, "", deviceJSON(3, "sw-3", "10.0.0.3/24")),
		},
	}}
	swapHTTP(t, fake)

	result := runInventorySyncSource(testSource())

	if result.Status != sdk.StatusCritical {
		t.Fatalf("expected Critical on count drift, got %v", result.Status)
	}
	if len(result.DeviceDiscovery) != 0 {
		t.Fatalf("expected no envelope on count drift, got %d", len(result.DeviceDiscovery))
	}
}

func TestInventorySyncTransportErrorEmitsNothing(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=100": {err: errors.New("dial timeout")},
	}}
	swapHTTP(t, fake)

	result := runInventorySyncSource(testSource())

	if result.Status != sdk.StatusCritical {
		t.Fatalf("expected Critical on transport error, got %v", result.Status)
	}
	if len(result.DeviceDiscovery) != 0 {
		t.Fatalf("expected no envelope on transport error, got %d", len(result.DeviceDiscovery))
	}
	if strings.Contains(result.Summary, "dial timeout") {
		t.Fatalf("transport error detail must not leak into the result: %q", result.Summary)
	}
}

func TestInventorySyncSkipsDevicesWithoutPrimaryIP(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=100": {
			body: pageJSON(2, "",
				deviceJSON(1, "sw-1", "10.0.0.1/24"), deviceJSON(2, "sw-no-ip", "")),
		},
	}}
	swapHTTP(t, fake)

	result := runInventorySyncSource(testSource())

	discovery := result.DeviceDiscovery[0]
	if len(discovery.Devices) != 1 {
		t.Fatalf("expected 1 device, got %d", len(discovery.Devices))
	}
	if discovery.Metadata["snapshot_complete"] != true {
		t.Fatalf("missing primary IP must not mark the snapshot incomplete")
	}
	if discovery.Metadata["devices_without_primary_ip"] != 1 {
		t.Fatalf("expected devices_without_primary_ip=1, got %v",
			discovery.Metadata["devices_without_primary_ip"])
	}
}

func TestInventorySyncMalformedRowMarksIncomplete(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=100": {
			body: pageJSON(2, "",
				deviceJSON(1, "sw-1", "10.0.0.1/24"), `{"name": "row-without-id"}`),
		},
	}}
	swapHTTP(t, fake)

	result := runInventorySyncSource(testSource())

	discovery := result.DeviceDiscovery[0]
	if len(discovery.Devices) != 1 {
		t.Fatalf("expected 1 device, got %d", len(discovery.Devices))
	}
	if discovery.Metadata["snapshot_complete"] != false {
		t.Fatalf("malformed row must mark the snapshot incomplete so absence marking is skipped")
	}
}

func TestInventorySyncAppliesNetworkBlacklist(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=100": {
			body: pageJSON(2, "",
				deviceJSON(1, "keep", "10.0.0.1/24"), deviceJSON(2, "drop", "192.168.50.7/24")),
		},
	}}
	swapHTTP(t, fake)

	src := testSource()
	src.NetworkBlacklist = []string{"192.168.0.0/16"}

	result := runInventorySyncSource(src)

	discovery := result.DeviceDiscovery[0]
	if len(discovery.Devices) != 1 || discovery.Devices[0].Hostname != "keep" {
		t.Fatalf("expected only the non-blacklisted device, got %+v", discovery.Devices)
	}
	if discovery.Metadata["snapshot_complete"] != true {
		t.Fatalf("blacklist filtering must not mark the snapshot incomplete")
	}
}

func TestBuildDiscoveredDeviceMapping(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=100": {
			body: pageJSON(1, "", deviceJSON(42, "core-sw", "10.1.2.3/24")),
		},
	}}
	swapHTTP(t, fake)

	result := runInventorySyncSource(testSource())

	device := result.DeviceDiscovery[0].Devices[0]
	if device.DeviceID != "netbox:lab:device:42" {
		t.Fatalf("unexpected device id %q", device.DeviceID)
	}
	if device.IP != "10.1.2.3" {
		t.Fatalf("expected CIDR-stripped IP, got %q", device.IP)
	}
	if device.Hostname != "core-sw" || device.VendorName != "Cisco" || device.Model != "C9300" {
		t.Fatalf("unexpected identity mapping: %+v", device)
	}
	if device.Role != "access-switch" || device.Status != "active" {
		t.Fatalf("unexpected role/status mapping: %+v", device)
	}
	if device.Location == nil || device.Location.SiteName != "austin-dc" {
		t.Fatalf("expected site location, got %+v", device.Location)
	}
	if device.Metadata["netbox_device_id"] != "lab:42" {
		t.Fatalf("netbox_device_id must be source-scoped to prevent cross-instance merges, got %+v", device.Metadata)
	}
	if device.Metadata["integration_id"] != "netbox:lab:device:42" {
		t.Fatalf("integration_id must carry the netbox: source prefix, got %+v", device.Metadata)
	}
	if device.Metadata["integration_type"] != "netbox" {
		t.Fatalf("expected integration_type netbox, got %+v", device.Metadata)
	}
	if device.Metadata["role"] != "access-switch" || device.Metadata["site"] != "austin-dc" {
		t.Fatalf("expected role/site metadata for UI provenance, got %+v", device.Metadata)
	}
	if device.Labels["provider"] != "netbox" || device.Labels["source_id"] != "lab" {
		t.Fatalf("unexpected labels: %+v", device.Labels)
	}
}

func TestPrimaryIPFallsBackToIPv6(t *testing.T) {
	row := `{
		"id": 7,
		"name": "v6-only",
		"primary_ip4": null,
		"primary_ip6": {"id": 1, "address": "2001:db8::7/64"},
		"role": {"name": "server"},
		"site": {"name": "lab"},
		"status": {"value": "active"},
		"device_type": {"manufacturer": {"name": "Dell"}, "model": "R650"}
	}`
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=100": {body: pageJSON(1, "", row)},
	}}
	swapHTTP(t, fake)

	result := runInventorySyncSource(testSource())

	device := result.DeviceDiscovery[0].Devices[0]
	if device.IP != "2001:db8::7" {
		t.Fatalf("expected IPv6 fallback, got %q", device.IP)
	}
}

func TestInventorySyncHonorsPageSizeAndInsecure(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=25": {
			body: pageJSON(1, "", deviceJSON(1, "sw-1", "10.0.0.1/24")),
		},
	}}
	swapHTTP(t, fake)

	src := testSource()
	src.PageSize = 25
	src.InsecureSkipVerify = true

	result := runInventorySyncSource(src)

	if result.Status != sdk.StatusOK {
		t.Fatalf("expected OK, got %v: %s", result.Status, result.Summary)
	}
	if len(fake.requests) != 1 {
		t.Fatalf("expected one request, got %d", len(fake.requests))
	}
	if !fake.requests[0].InsecureSkipVerify {
		t.Fatalf("expected insecure_skip_verify to pass through to the host request")
	}
}

func TestRunInventorySyncMultiSourcePartialFailureStaysOK(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://good.example.com/api/dcim/devices/?limit=100": {
			body: pageJSON(1, "", deviceJSON(1, "sw-1", "10.0.0.1/24")),
		},
		"https://bad.example.com/api/dcim/devices/?limit=100": {status: 500, body: "boom"},
	}}
	swapHTTP(t, fake)

	cfg := Config{Sources: []SourceConfig{
		{SourceID: "good", BaseURL: "https://good.example.com", APIToken: "t"},
		{SourceID: "bad", BaseURL: "https://bad.example.com", APIToken: "t"},
	}}

	result := runInventorySync(cfg)

	if result.Status != sdk.StatusOK {
		t.Fatalf("partial failure must stay OK so healthy sources ingest, got %v", result.Status)
	}
	if len(result.DeviceDiscovery) != 1 {
		t.Fatalf("expected one healthy envelope, got %d", len(result.DeviceDiscovery))
	}
	if result.Labels["sources_failed"] != "1" {
		t.Fatalf("expected sources_failed=1 label, got %+v", result.Labels)
	}
}

func TestRunInventorySyncAllSourcesFailedIsCritical(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{}}
	swapHTTP(t, fake)

	cfg := Config{Sources: []SourceConfig{
		{SourceID: "a", BaseURL: "https://a.example.com", APIToken: "t"},
		{SourceID: "b", BaseURL: "https://b.example.com", APIToken: "t"},
	}}

	result := runInventorySync(cfg)

	if result.Status != sdk.StatusCritical {
		t.Fatalf("expected Critical when every source fails, got %v", result.Status)
	}
}

func TestRunInventorySyncFlatSingleSourceConfig(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=100": {
			body: pageJSON(1, "", deviceJSON(1, "sw-1", "10.0.0.1/24")),
		},
	}}
	swapHTTP(t, fake)

	cfg := Config{SourceID: "lab", BaseURL: "https://netbox.example.com", APIToken: "secret-token"}

	result := runInventorySync(cfg)

	if result.Status != sdk.StatusOK {
		t.Fatalf("expected OK for flat config, got %v: %s", result.Status, result.Summary)
	}
	if len(result.DeviceDiscovery) != 1 {
		t.Fatalf("expected one envelope, got %d", len(result.DeviceDiscovery))
	}
}

func TestRunInventorySyncMissingConfigNamesTheMissingPiece(t *testing.T) {
	cases := []struct {
		name    string
		cfg     Config
		summary string
	}{
		{
			name:    "nothing configured",
			cfg:     Config{},
			summary: "has no source configured",
		},
		{
			name:    "token without base_url",
			cfg:     Config{SourceID: "lab", APIToken: "secret-token"},
			summary: "NetBox source lab has no base_url configured",
		},
		{
			name:    "base_url without token",
			cfg:     Config{SourceID: "lab", BaseURL: "https://netbox.example.com"},
			summary: "NetBox source lab has no api_token configured",
		},
		{
			name:    "base_url without a scheme",
			cfg:     Config{SourceID: "lab", BaseURL: "netbox.example.com", APIToken: "t"},
			summary: "NetBox source lab has an invalid base_url: base url must be http or https",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			result := runInventorySync(tc.cfg)

			if result.Status != sdk.StatusUnknown {
				t.Fatalf("expected Unknown, got %v", result.Status)
			}
			if !strings.Contains(result.Summary, tc.summary) {
				t.Fatalf("summary must name the missing piece %q, got %q", tc.summary, result.Summary)
			}
		})
	}
}

func TestRunInventorySyncMissingBaseURLInSourcesEntry(t *testing.T) {
	cfg := Config{Sources: []SourceConfig{{SourceID: "lab", APIToken: "secret-token"}}}

	result := runInventorySync(cfg)

	if result.Status != sdk.StatusUnknown {
		t.Fatalf("expected Unknown, got %v", result.Status)
	}
	if !strings.Contains(result.Summary, "NetBox source lab has no base_url configured") {
		t.Fatalf("summary must name base_url, got %q", result.Summary)
	}
}

func TestRelativizePath(t *testing.T) {
	cases := map[string]string{
		"":                             "",
		"/api/dcim/devices/?offset=50": "/api/dcim/devices/?offset=50",
		"https://netbox.example.com/api/dcim/devices/?offset=50":  "/api/dcim/devices/?offset=50",
		"http://netbox.example.com:8000/api/dcim/devices/?page=2": "/api/dcim/devices/?page=2",
		"https://netbox.example.com":                              "",
		"//evil.example.com/path":                                 "",
		"ftp://x/path":                                            "",
	}

	for input, want := range cases {
		if got := relativizePath(input); got != want {
			t.Fatalf("relativizePath(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestNormalizeSourceInstance(t *testing.T) {
	cases := map[string]string{
		"lab":           "lab",
		"Lab 01":        "lab-01",
		"":              "netbox.example.com",
		"--weird--":     "weird",
		"UPPER_case.ok": "upper_case.ok",
		"@@@":           "netbox",
	}

	for input, want := range cases {
		if got := normalizeSourceInstance(input, "https://netbox.example.com"); got != want {
			t.Fatalf("normalizeSourceInstance(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestSnapshotHashIsOrderStableBareHex(t *testing.T) {
	a := sdk.DiscoveredDevice{DeviceID: "netbox:lab:device:1"}
	b := sdk.DiscoveredDevice{DeviceID: "netbox:lab:device:2"}

	one := snapshotHash("lab", []sdk.DiscoveredDevice{a, b})
	two := snapshotHash("lab", []sdk.DiscoveredDevice{b, a})

	if one != two {
		t.Fatalf("snapshot hash must be order independent: %q vs %q", one, two)
	}
	if len(one) != 64 || strings.Contains(one, ":") {
		t.Fatalf("snapshot hash must be a bare 64-hex digest, got %q", one)
	}
}

func TestInventorySyncBasePathPagination(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://tools.example.com/netbox/api/dcim/devices/?limit=100": {
			body: pageJSON(2, "https://tools.example.com/netbox/api/dcim/devices/?limit=100&offset=1",
				deviceJSON(1, "sw-1", "10.0.0.1/24")),
		},
		"https://tools.example.com/netbox/api/dcim/devices/?limit=100&offset=1": {
			body: pageJSON(2, "", deviceJSON(2, "sw-2", "10.0.0.2/24")),
		},
	}}
	swapHTTP(t, fake)

	src := testSource()
	src.BaseURL = "https://tools.example.com/netbox"

	result := runInventorySyncSource(src)

	if result.Status != sdk.StatusOK {
		t.Fatalf("BASE_PATH deployment must paginate, got %v: %s", result.Status, result.Summary)
	}
	if len(result.DeviceDiscovery[0].Devices) != 2 {
		t.Fatalf("expected 2 devices across subpath pages, got %d", len(result.DeviceDiscovery[0].Devices))
	}
	if len(fake.requests) != 2 {
		t.Fatalf("expected 2 requests, got %d", len(fake.requests))
	}
	if fake.requests[1].URL != "https://tools.example.com/netbox/api/dcim/devices/?limit=100&offset=1" {
		t.Fatalf("page-2 URL must not double the base path, got %q", fake.requests[1].URL)
	}
}

func TestRunInventorySyncMisconfiguredSourcesAreNotHealthy(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://good.example.com/api/dcim/devices/?limit=100": {
			body: pageJSON(1, "", deviceJSON(1, "sw-1", "10.0.0.1/24")),
		},
	}}
	swapHTTP(t, fake)

	mixed := Config{Sources: []SourceConfig{
		{SourceID: "good", BaseURL: "https://good.example.com", APIToken: "t"},
		{SourceID: "tokenless", BaseURL: "https://tokenless.example.com"},
	}}

	result := runInventorySync(mixed)
	if result.Status != sdk.StatusOK {
		t.Fatalf("healthy source must keep the run OK, got %v", result.Status)
	}
	if result.Labels["sources_misconfigured"] != "1" {
		t.Fatalf("expected sources_misconfigured=1, got %+v", result.Labels)
	}
	if !strings.Contains(result.Summary, "1/2 sources") {
		t.Fatalf("summary must not count misconfigured sources as healthy: %q", result.Summary)
	}

	allBad := Config{Sources: []SourceConfig{
		{SourceID: "a", BaseURL: "https://a.example.com"},
		{SourceID: "b"},
	}}

	result = runInventorySync(allBad)
	if result.Status != sdk.StatusUnknown {
		t.Fatalf("all-misconfigured run must be Unknown, not OK/Critical, got %v", result.Status)
	}
}

func TestBlacklistAcceptsBareIPsAndSurfacesInvalidEntries(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=100": {
			body: pageJSON(2, "",
				deviceJSON(1, "keep", "10.0.0.1/24"), deviceJSON(2, "drop", "10.0.0.2/24")),
		},
	}}
	swapHTTP(t, fake)

	src := testSource()
	src.NetworkBlacklist = []string{"10.0.0.2", "not-a-cidr"}

	result := runInventorySyncSource(src)

	discovery := result.DeviceDiscovery[0]
	if len(discovery.Devices) != 1 || discovery.Devices[0].Hostname != "keep" {
		t.Fatalf("bare-IP blacklist entry must drop its device, got %+v", discovery.Devices)
	}
	if discovery.Metadata["invalid_blacklist_entries"] != 1 {
		t.Fatalf("invalid blacklist entries must be surfaced, got %v",
			discovery.Metadata["invalid_blacklist_entries"])
	}
}

func TestDiscoveryEnvelopeMarshals(t *testing.T) {
	fake := &fakeHTTP{responses: map[string]fakeResponse{
		"https://netbox.example.com/api/dcim/devices/?limit=100": {
			body: pageJSON(1, "", deviceJSON(1, "sw-1", "10.0.0.1/24")),
		},
	}}
	swapHTTP(t, fake)

	result := runInventorySyncSource(testSource())

	payload, err := json.Marshal(result.DeviceDiscovery[0])
	if err != nil {
		t.Fatalf("envelope must marshal cleanly: %v", err)
	}
	if !strings.Contains(string(payload), "serviceradar.device_discovery.v1") {
		t.Fatalf("expected v1 schema marker in payload")
	}
}
