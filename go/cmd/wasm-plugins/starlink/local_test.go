package main

import (
	"context"
	"encoding/binary"
	"errors"
	"math"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

// Test-side protobuf encoders build synthetic device responses by field
// number, the same way the decoder reads them.
func pbBytes(num uint64, b []byte) []byte {
	out := binary.AppendUvarint(nil, num<<3|wireBytes)
	out = binary.AppendUvarint(out, uint64(len(b)))
	return append(out, b...)
}
func pbString(num uint64, s string) []byte { return pbBytes(num, []byte(s)) }
func pbVarint(num, v uint64) []byte {
	return binary.AppendUvarint(binary.AppendUvarint(nil, num<<3|wireVarint), v)
}
func pbFloat(num uint64, f float32) []byte {
	out := binary.AppendUvarint(nil, num<<3|wireFixed32)
	return binary.LittleEndian.AppendUint32(out, math.Float32bits(f))
}
func cat(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func dishDiagnostics() []byte {
	alerts := cat(pbVarint(5, 1), pbVarint(7, 1), pbVarint(1, 0))
	alignment := cat(pbFloat(1, 350), pbFloat(2, 60), pbFloat(3, 10), pbFloat(4, 62.5))
	dish := cat(
		pbString(1, "ut"+testTerminalA),
		pbString(3, "example-build"),
		pbBytes(5, alerts),
		pbVarint(6, 10), // ROAM_RESTRICTED
		pbVarint(7, 2),  // self test FAILED
		pbBytes(9, alignment),
		pbVarint(10, 0),
		pbString(99, "a field this decoder does not know"),
	)
	return pbBytes(fieldResponseDishGetDiagnostics, dish)
}

func TestDecodeDishDiagnostics(t *testing.T) {
	d, err := decodeDiagnosticsResponse(dishDiagnostics())
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if d.DeviceRef != "starlink:ut:"+testTerminalA {
		t.Fatalf("local identity must converge with the cloud identity, got %q", d.DeviceRef)
	}
	want := "actuator_motor_stuck,disabled_roam_restricted,hardware_self_test_failed,slow_ethernet_speeds"
	if got := strings.Join(d.Alerts, ","); got != want {
		t.Fatalf("alerts = %q, want %q (motors_stuck maps to the cloud name)", got, want)
	}
	// 350 -> 10 degrees is a 20 degree error across north, not -340.
	if az := d.Metrics["starlink_local_azimuth_error_deg"]; az != 20 {
		t.Fatalf("azimuth error = %v", az)
	}
	if el := d.Metrics["starlink_local_elevation_error_deg"]; el != 2.5 {
		t.Fatalf("elevation error = %v", el)
	}
	if d.Metrics["starlink_local_self_test_passed"] != 0 || d.Metrics["starlink_local_stowed"] != 0 {
		t.Fatalf("metrics = %v", d.Metrics)
	}
}

func TestDecodeRouterDiagnostics(t *testing.T) {
	network := cat(pbString(1, "lan"), pbVarint(10, 2), pbVarint(11, 3), pbVarint(12, 4))
	wifi := cat(pbString(1, testRouterA), pbBytes(4, network), pbBytes(4, pbVarint(12, 1)))
	d, err := decodeDiagnosticsResponse(pbBytes(fieldResponseWifiGetDiagnostics, wifi))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if d.DeviceRef != routerDeviceID(testRouterA) || d.Metrics["starlink_router_clients_5ghz"] != 5 ||
		d.Metrics["starlink_router_clients_ethernet"] != 2 {
		t.Fatalf("router diagnostics = %+v", d)
	}
}

func TestDecodeDiagnosticsRejectsBadInput(t *testing.T) {
	good := dishDiagnostics()
	if _, err := decodeDiagnosticsResponse(good[:len(good)-3]); err == nil {
		t.Fatal("a truncated message must not decode")
	}
	anonymous := pbBytes(fieldResponseDishGetDiagnostics, pbString(3, "example-build"))
	if _, err := decodeDiagnosticsResponse(anonymous); err == nil {
		t.Fatal("diagnostics without a device id must not be attributed to anything")
	}
}

type fakeGRPC struct {
	byHost map[string][]byte
	seen   []sdk.GRPCRequest
}

func (f *fakeGRPC) Unary(_ context.Context, req sdk.GRPCRequest) (*sdk.GRPCResponse, error) {
	f.seen = append(f.seen, req)
	msg, ok := f.byHost[req.TargetHost]
	if !ok {
		return nil, errors.New("unreachable")
	}
	return &sdk.GRPCResponse{Status: sdk.GRPCCodeOK, Message: msg}, nil
}

func TestRunLocalPartialFailureEmitsNoScopeMarker(t *testing.T) {
	grpc := &fakeGRPC{byHost: map[string][]byte{"192.0.2.10": dishDiagnostics()}}
	raw := []byte(`{"targets":[{"kind":"dish","host":"192.0.2.10","port":9200},{"kind":"router","host":"192.0.2.11","port":9000}]}`)
	var emitted []sdk.TelemetryRecord
	result := runLocal(raw, grpc, newFakeHTTP(t), func(r []sdk.TelemetryRecord) error { emitted = append(emitted, r...); return nil })

	if result.Status != sdk.StatusWarning {
		t.Fatalf("one unreachable device must degrade the run to warning, got %q", result.Status)
	}
	req := grpc.seen[0]
	if req.Method != deviceHandleMethod || req.Transport != sdk.GRPCTransportH2C ||
		string(req.Message) != string(protoAppendEmptyMessage(nil, fieldRequestGetDiagnostics)) {
		t.Fatalf("diagnostics request = %+v", req)
	}
	for _, r := range emitted {
		if strings.Contains(string(mustJSON(t, r.Payload)), "condition_scope_complete") {
			t.Fatal("an incomplete run must not emit the scope marker, or it would clear the unreachable device's alerts")
		}
	}
}

func TestParseLocalConfigRefusesCredentialsAndBadTargets(t *testing.T) {
	for _, raw := range []string{
		`{"targets":[{"kind":"dish","host":"192.0.2.10","port":9200}],"client_secret":"not-real"}`,
		`{"targets":[{"kind":"modem","host":"192.0.2.10","port":9200}]}`,
		`{"targets":[{"kind":"dish","host":"","port":9200}]}`,
		`{"router_diagnostics_url":"http://router.example.com/starlinkrouter/diagnostics"}`,
		`{}`,
	} {
		if _, err := parseLocalConfig([]byte(raw)); err == nil {
			t.Fatalf("parseLocalConfig(%s) must fail", raw)
		}
	}
}

func TestDecodeRouterHTTPSDiagnostics(t *testing.T) {
	body := `{"dish":{"id":"ut` + testTerminalA + `","alerts":{"motorsStuck":true,"dishIsHeating":false,"obstructed":true},` +
		`"disablementCode":"okay","hardwareSelfTest":"passed"},"router":{"sandboxDisabled":false}}`
	devices := decodeRouterHTTPSDiagnostics([]byte(body))
	if len(devices) != 1 || strings.Join(devices[0].Alerts, ",") != "actuator_motor_stuck,obstructed" {
		t.Fatalf("devices = %+v", devices)
	}
}

func TestAngleDeltaWrapsBothWays(t *testing.T) {
	for _, c := range []struct{ want, got, delta float64 }{
		{10, 350, 20}, {350, 10, -20}, {90, 45, 45}, {180, -180, 0},
	} {
		if d := angleDelta(c.want, c.got); d != c.delta {
			t.Fatalf("angleDelta(%v, %v) = %v, want %v", c.want, c.got, d, c.delta)
		}
	}
}
