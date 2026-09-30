package main

import "testing"

func TestParseConfigDefaultsAndInvocationOverlay(t *testing.T) {
	cfg := mustConfig(t, `{"timeout_ms":9000,"action_invocation":{"action_id":"starlink.telemetry.collect",`+
		`"input_values":{"timeout_ms":30000,"telemetry_batch_size":999999}}}`)

	if cfg.ActionID != "starlink.telemetry.collect" {
		t.Fatalf("action id = %q", cfg.ActionID)
	}
	if cfg.TimeoutMS != 30000 {
		t.Fatalf("invocation input must win over plugin config, got %d", cfg.TimeoutMS)
	}
	if cfg.TelemetryBatchSize != maxTelemetryBatchSize {
		t.Fatalf("batch size not clamped: %d", cfg.TelemetryBatchSize)
	}
	if cfg.MaxRequestsPerRun != defaultMaxRequestsPerRun {
		t.Fatalf("default requests = %d", cfg.MaxRequestsPerRun)
	}
}

func TestParseConfigLingerFitsInsideTimeout(t *testing.T) {
	cfg := mustConfig(t, `{"timeout_ms":6000,"telemetry_max_linger_ms":15000}`)
	if cfg.TelemetryMaxLingerMS != 6000-telemetryLingerHeadroomMS {
		t.Fatalf("linger %d must leave headroom under timeout %d", cfg.TelemetryMaxLingerMS, cfg.TimeoutMS)
	}
}

func TestParseConfigRefusesCredentialMaterial(t *testing.T) {
	for _, raw := range []string{
		`{"client_secret":"not-a-real-secret"}`,
		`{"action_invocation":{"input_values":{"access_token":"not-a-real-token"}}}`,
	} {
		if _, err := parseConfig([]byte(raw)); err != errConfigSecret {
			t.Fatalf("parseConfig(%s) err = %v, want errConfigSecret", raw, err)
		}
	}
}

func TestTerminalIDFormsConverge(t *testing.T) {
	bare := terminalDeviceID(testTerminalA)
	prefixed := terminalDeviceID("ut" + testTerminalA)
	upper := terminalDeviceID("UT" + "A1A1A1A1-00000001-00000001")
	if bare == "" || bare != prefixed || bare != upper {
		t.Fatalf("management, telemetry and case variants must converge: %q %q %q", bare, prefixed, upper)
	}
}

func TestRouterDeviceID(t *testing.T) {
	if got, want := routerDeviceID(testRouterA), "starlink:router:0000000000000000000000a1"; got != want {
		t.Fatalf("routerDeviceID = %q, want %q", got, want)
	}
	if got := routerDeviceID("router-0000000000000000000000A1"); got != routerDeviceID(testRouterA) {
		t.Fatalf("case variants diverge: %q", got)
	}
	if routerDeviceID("not-a-router") != "" {
		t.Fatal("non-router id accepted")
	}
}

func TestPlaceholderIdentifiersDropped(t *testing.T) {
	for _, v := range []string{"", "  ", "00000000-00000000-00000000", "unknown", "null", "0"} {
		if terminalDeviceID(v) != "" {
			t.Fatalf("placeholder terminal id %q produced an identity", v)
		}
		if normalizeSerial(v) != "" {
			t.Fatalf("placeholder serial %q kept", v)
		}
	}
	if routerDeviceID("Router-000000000000000000000000") != "" {
		t.Fatal("all-zero router id produced an identity")
	}
}

func TestSourceInstanceHidesAccountNumber(t *testing.T) {
	got := sourceInstance(testAccountNumber)
	if got == "" || got == testAccountNumber || sourceInstance(" acc-000000-00000-01 ") != got {
		t.Fatalf("sourceInstance must be stable, normalized and not the raw number: %q", got)
	}
}
