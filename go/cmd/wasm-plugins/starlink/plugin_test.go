package main

import (
	"net/http"
	"strings"
	"testing"

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

func TestDispatchTelemetryCollectEmitsMetricsAlertsAndMarker(t *testing.T) {
	row := `["u",1700000000000000000,"ut` + testTerminalA + `",1,2,[],"x"]`
	fake := &cacheHTTP{fakeHTTP: newFakeHTTP(t), wantBody: cacheQueryPage0, status: 200}
	fake.on(http.MethodGet, "/account", 200, accountFixture())
	fake.on(http.MethodGet, "/user-terminals?page=0", 200, terminalsPage(0, true, terminalRowA))
	stream := &streamThenFake{inner: fake, bodies: []string{streamBody(terminalColumns, row)}}

	var emitted []sdk.TelemetryRecord
	result := runTelemetry(newAPIClient(stream, actionConfig(t, actionTelemetryCollect)),
		actionConfig(t, actionTelemetryCollect),
		func(string) func([]sdk.TelemetryRecord) error {
			return func(r []sdk.TelemetryRecord) error { emitted = append(emitted, r...); return nil }
		})

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
	// One metric batch for terminal A; three active alerts from the cache
	// fixture plus the scope-complete marker.
	if metrics != 1 || events != 4 {
		t.Fatalf("metrics %d events %d", metrics, events)
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
