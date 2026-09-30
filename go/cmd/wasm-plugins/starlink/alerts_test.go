package main

import (
	"net/http"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const cacheQueryPage0 = `{"includeUserTerminals":true,"userTerminalIds":["` + testTerminalA + `"],` +
	`"includeRouters":true,"routerIds":["` + testRouterA + `"]}`

func cacheResponse() string {
	return envelope(`{"userTerminals":{"` + testTerminalA + `":{"userTerminalId":"` + testTerminalA + `",` +
		`"alertActuatorMotorStuck":true,"alertMastNotVertical":false,"alertPopChange":null,` +
		`"alertDisabledNoActiveServiceLine":true,"alertEthernetSlowLink100":true}},` +
		`"routers":{"` + testRouterA + `":{"routerId":"` + testRouterA + `","alertSandboxDisabled":false}}}`)
}

// cacheHTTP extends fakeHTTP with body assertions for the cache query.
type cacheHTTP struct {
	*fakeHTTP
	wantBody string
	status   int
}

func (c *cacheHTTP) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	if req.Method == http.MethodPost && strings.HasSuffix(req.URL, "/telemetry/query") {
		c.requests = append(c.requests, req)
		if string(req.Body) != c.wantBody {
			c.t.Fatalf("cache query body = %s, want %s", req.Body, c.wantBody)
		}
		if c.status != 200 {
			return &sdk.HTTPResponse{Status: c.status, Body: []byte("error")}, nil
		}
		return &sdk.HTTPResponse{Status: 200, Body: []byte(cacheResponse())}, nil
	}
	return c.fakeHTTP.Do(req)
}

func TestCollectAlertsReadsTrueFlagsOnly(t *testing.T) {
	fake := &cacheHTTP{fakeHTTP: newFakeHTTP(t), wantBody: cacheQueryPage0, status: 200}
	fake.on(http.MethodGet, "/user-terminals?page=0", 200, terminalsPage(0, true, terminalRowA))

	snap := collectAlerts(newAPIClient(fake, mustConfig(t, `{}`)))
	if !snap.Complete || len(snap.Devices) != 2 {
		t.Fatalf("snapshot = %+v", snap)
	}
	router, terminal := snap.Devices[0], snap.Devices[1]
	if terminal.DeviceRef != "starlink:ut:"+testTerminalA {
		t.Fatalf("terminal ref = %q", terminal.DeviceRef)
	}
	// false and null flags are not active; null means the vendor does not know.
	want := "actuator_motor_stuck,disabled_no_active_service_line,ethernet_slow_link100"
	if got := strings.Join(terminal.Active, ","); got != want {
		t.Fatalf("active = %q, want %q", got, want)
	}
	if router.DeviceRef != routerDeviceID(testRouterA) || len(router.Active) != 0 {
		t.Fatalf("router = %+v", router)
	}
}

func TestCollectAlertsQueryFailureIsIncomplete(t *testing.T) {
	fake := &cacheHTTP{fakeHTTP: newFakeHTTP(t), wantBody: cacheQueryPage0, status: 500}
	fake.on(http.MethodGet, "/user-terminals?page=0", 200, terminalsPage(0, true, terminalRowA))

	snap := collectAlerts(newAPIClient(fake, mustConfig(t, `{}`)))
	if snap.Complete {
		t.Fatal("a failed cache query must make the alert snapshot incomplete so nothing is cleared")
	}
}

func TestSeverityClassification(t *testing.T) {
	cases := map[string]sdk.Severity{
		"thermal_shutdown":                 sdk.SeverityCritical,
		"disabled_roam_restricted":         sdk.SeverityCritical,
		"software_update_reboot_pending":   sdk.SeverityInfo,
		"a_future_alert_nobody_mapped_yet": sdk.SeverityWarning,
	}
	for name, want := range cases {
		if got := severityFor(name); got != want {
			t.Fatalf("severityFor(%q) = %q, want %q", name, got, want)
		}
	}
}

func TestSnakeCase(t *testing.T) {
	for in, want := range map[string]string{
		"ActuatorMotorStuck": "actuator_motor_stuck",
		"EthernetSlowLink10": "ethernet_slow_link10",
		"PsuOtpThrottling":   "psu_otp_throttling",
	} {
		if got := snakeCase(in); got != want {
			t.Fatalf("snakeCase(%q) = %q, want %q", in, got, want)
		}
	}
}
