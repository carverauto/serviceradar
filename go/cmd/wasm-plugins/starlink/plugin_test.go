package main

import (
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func actionConfig(t *testing.T, actionID string) Config {
	return mustConfig(t, `{"action_invocation":{"action_id":"`+actionID+`","input_values":{"telemetry_batch_size":2}}}`)
}

func TestDispatchInventoryRefreshEmitsDiscovery(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodGet, "/account", 200, accountFixture())
	fake.on(http.MethodGet, "/user-terminals?page=0", 200, terminalsPage(0, true, terminalRowA+","+terminalRowB))
	fake.on(http.MethodGet, "/service-lines?page=0", 200, envelope(serviceLinesPage))
	fake.on(http.MethodPost, "/data-usage/query", 200, envelope(`{"dataUsages":[]}`))
	fake.on(http.MethodGet, "/data-pools", 200, envelope(`{"dataPools":[]}`))

	result := dispatch(actionConfig(t, actionInventoryRefresh), fake, testObservedAt)
	if result.Status != sdk.StatusOK || len(result.DeviceDiscovery) != 1 {
		t.Fatalf("status %q discovery %d: %s", result.Status, len(result.DeviceDiscovery), result.Summary)
	}
	if got := len(result.DeviceDiscovery[0].Devices); got != 3 {
		t.Fatalf("devices = %d, want 2 terminals + 1 router", got)
	}
	if strings.Contains(result.Summary+result.Details, testAccountNumber) {
		t.Fatal("the account number must not appear in the viewer-readable summary or details")
	}
}

// The vendor's rate limit is per account and shared with every other client,
// so one 429 ends the run's requests instead of spending more of it.
func TestRateLimitedRunStopsRequesting(t *testing.T) {
	fake := newFakeHTTP(t)
	fake.on(http.MethodGet, "/account", 200, accountFixture())
	fake.onRateLimited(http.MethodGet, "/user-terminals?page=0", "60")

	result := dispatch(actionConfig(t, actionInventoryRefresh), fake, testObservedAt)
	if len(fake.requests) != 2 {
		t.Fatalf("requests after the 429 = %d, want none", len(fake.requests)-2)
	}
	if result.Status != sdk.StatusWarning || !strings.Contains(result.Summary, "starlink_rate_limited") {
		t.Fatalf("status %q summary %q", result.Status, result.Summary)
	}
}

// sampleAtNs is the timestamp of the fixture telemetry rows.
const sampleAtNs = 1700000000000000000

func terminalRow(atNs int64) string {
	return `["u",` + strconv.FormatInt(atNs, 10) + `,"ut` + testTerminalA + `",1,2,[],"x"]`
}

// runTelemetryFixture runs one telemetry collection against a single-terminal
// account whose stream returns rows, as of now.
func runTelemetryFixture(t *testing.T, rows string, now time.Time) (*sdk.Result, []sdk.TelemetryRecord) {
	t.Helper()
	fake := &cacheHTTP{fakeHTTP: newFakeHTTP(t), wantBody: cacheQueryPage0, status: 200}
	fake.on(http.MethodGet, "/account", 200, accountFixture())
	fake.on(http.MethodGet, "/user-terminals?page=0", 200, terminalsPage(0, true, terminalRowA))
	// collectFlightStatus fetches service-lines to find aviation (tail number) terminals;
	// the fixture has none so it short-circuits after this page.
	fake.on(http.MethodGet, "/service-lines?page=0", 200, envelope(serviceLinesPage))
	stream := &streamThenFake{inner: fake, bodies: []string{streamBody(terminalColumns, rows)}}

	var emitted []sdk.TelemetryRecord
	cfg := actionConfig(t, actionTelemetryCollect)
	result := runTelemetry(newAPIClient(stream, cfg), cfg, now,
		func(string) func([]sdk.TelemetryRecord) error {
			return func(r []sdk.TelemetryRecord) error { emitted = append(emitted, r...); return nil }
		})
	return result, emitted
}

func TestDispatchTelemetryCollectEmitsMetricsAlertsAndMarker(t *testing.T) {
	result, emitted := runTelemetryFixture(t, terminalRow(sampleAtNs), time.Unix(0, sampleAtNs).Add(time.Minute))

	if result.Status != sdk.StatusOK {
		t.Fatalf("status %q: %s", result.Status, result.Summary)
	}
	var metrics, events int
	for _, r := range emitted {
		switch r.PayloadKind {
		case sdk.SignalSchemaPayloadKindServiceRadarMetrics:
			metrics++
		case sdk.SignalSchemaPayloadKindOCSFEvent:
			events++
		}
	}
	// One metric batch for terminal A, one reporting record per listed device
	// (terminal A and router A); three active alerts from the cache fixture
	// plus the scope-complete marker.
	if metrics != 3 || events != 4 {
		t.Fatalf("metrics %d events %d", metrics, events)
	}
}

// The stream delivers at most once, so a stretch with no telemetry is data
// that will never arrive; the run names how long it was.
func TestTelemetryCollectNamesAGapLongerThanTheThreshold(t *testing.T) {
	minute := int64(time.Minute)
	cases := map[string]struct {
		rows string
		now  time.Time
		want string
	}{
		"stream drained but stale": {
			rows: terminalRow(sampleAtNs),
			now:  time.Unix(0, sampleAtNs).Add(10 * time.Minute),
			want: "starlink_telemetry_gap_600s",
		},
		"hole between one device's samples": {
			rows: terminalRow(sampleAtNs) + "," + terminalRow(sampleAtNs+15*minute),
			now:  time.Unix(0, sampleAtNs+16*minute),
			want: "starlink_telemetry_gap_900s",
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			result, _ := runTelemetryFixture(t, tc.rows, tc.now)
			if result.Status != sdk.StatusWarning || !strings.Contains(result.Summary, tc.want) {
				t.Fatalf("status %q summary %q, want a warning naming %s", result.Status, result.Summary, tc.want)
			}
		})
	}
}

// Carrier-grade NAT gives many terminals one public address, so an address is
// metadata on each terminal and never an identifier that could merge them.
func TestSharedPublicAddressNeverMergesTerminals(t *testing.T) {
	shared := `["192.0.2.10"]`
	rows := terminalRow(sampleAtNs) + "," +
		`["i",` + strconv.FormatInt(sampleAtNs, 10) + `,"ut` + testTerminalA + `","` + testAccountNumber + `",` + shared + `],` +
		`["i",` + strconv.FormatInt(sampleAtNs, 10) + `,"ut` + testTerminalB + `","` + testAccountNumber + `",` + shared + `]`
	result, _ := runTelemetryFixture(t, rows, time.Unix(0, sampleAtNs).Add(time.Minute))

	if len(result.DeviceDiscovery) != 1 || len(result.DeviceDiscovery[0].Devices) != 2 {
		t.Fatalf("want one enrichment with both terminals, got %+v", result.DeviceDiscovery)
	}
	for i, want := range []string{terminalDeviceID(testTerminalA), terminalDeviceID(testTerminalB)} {
		device := result.DeviceDiscovery[0].Devices[i]
		if device.DeviceID != want || device.Metadata["integration_id"] != want {
			t.Fatalf("device %d identity %q / %v, want %q", i, device.DeviceID, device.Metadata["integration_id"], want)
		}
		if device.IP != "" || device.Metadata["public_ipv4"] != "192.0.2.10" {
			t.Fatalf("device %d ip %q public_ipv4 %v: a shared address must be metadata only", i, device.IP, device.Metadata["public_ipv4"])
		}
	}
}

// A device that sends nothing produces no metric of its own, so silence is only
// visible if every listed device is reported each run, zero included.
func TestTelemetryReportsEveryListedDeviceIncludingSilentOnes(t *testing.T) {
	_, emitted := runTelemetryFixture(t, terminalRow(sampleAtNs), time.Unix(0, sampleAtNs).Add(time.Minute))

	reported := map[string]bool{}
	for _, r := range emitted {
		for _, ref := range []string{terminalDeviceID(testTerminalA), routerDeviceID(testRouterA)} {
			if strings.HasPrefix(r.EventID, "starlink-reporting-"+ref+"-") {
				reported[ref] = true
			}
		}
	}
	if !reported[terminalDeviceID(testTerminalA)] || !reported[routerDeviceID(testRouterA)] {
		t.Fatalf("reporting records for %v; want the sampled terminal and the silent router", reported)
	}
}

func TestDispatchWithoutActionIsUnknown(t *testing.T) {
	if r := dispatch(mustConfig(t, `{}`), newFakeHTTP(t), testObservedAt); r.Status != sdk.StatusUnknown {
		t.Fatalf("a plain scheduled check has no token and must not call the API: %q", r.Status)
	}
}

// streamThenFake serves telemetry stream bodies in order and delegates every
// other request.
type streamThenFake struct {
	inner  httpDoer
	bodies []string
	served int
}

func (s *streamThenFake) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	if strings.HasSuffix(req.URL, "/telemetry/stream") {
		body := `{"data":{"columnNamesByDeviceType":{},"values":[]},"metadata":{}}`
		if s.served < len(s.bodies) {
			body = s.bodies[s.served]
		}
		s.served++
		return &sdk.HTTPResponse{Status: 200, Body: []byte(body)}, nil
	}
	return s.inner.Do(req)
}
