package main

import (
	"net/http"
	"testing"
)

// Core matches a plugin's discovered device only through
// metadata.integration_id; a bare device_id is not an identifier, so an
// enrichment without it is minted as a new device on every run.
func TestFlightEnrichmentAttachesToTheTerminalsInventoryIdentity(t *testing.T) {
	const tail = "N000TST"
	fake := newFakeHTTP(t)
	fake.on(http.MethodGet, "/service-lines?page=0", 200, envelope(`{"isLastPage":true,"results":[`+
		`{"serviceLineNumber":"`+testServiceLine+`","tailNumber":"`+tail+`"}]}`))
	fake.on(http.MethodGet, "/user-terminals?page=0", 200, terminalsPage(0, true, terminalRowA))
	fake.on(http.MethodPost, "/flights/status", 200, envelope(`{"flightStatuses":[`+
		`{"tailNumber":"`+tail+`","altitudeFeet":35000,"groundSpeedKnots":450,"headingDegrees":90,`+
		`"flightPhase":"cruise","departureAirport":"KSEA","arrivalAirport":"KDEN","inFlight":true}]}`))

	_, discovery := collectFlightStatus(newAPIClient(fake, actionConfig(t, actionTelemetryCollect)), "test-instance", testObservedAt)
	if discovery == nil || len(discovery.Devices) != 1 {
		t.Fatalf("want one flight enrichment device, got %+v", discovery)
	}
	device := discovery.Devices[0]
	want := terminalDeviceID(testTerminalA)
	if device.DeviceID != want || device.Metadata["integration_id"] != want {
		t.Fatalf("enrichment device_id %q integration_id %v, want both %q",
			device.DeviceID, device.Metadata["integration_id"], want)
	}
}
