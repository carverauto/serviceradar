/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package addon

import (
	"reflect"
	"testing"
)

func TestLocalOtlpEndpointFromSpecs(t *testing.T) {
	tests := []struct {
		name  string
		specs []Spec
		want  string
	}{
		{
			name:  "no collector configured",
			specs: []Spec{{ID: "netprobe"}, {ID: "powerdns"}},
			want:  "",
		},
		{
			name:  "collector with default config",
			specs: []Spec{{ID: "netprobe"}, {ID: OtelCollectorAddonID}},
			want:  "http://127.0.0.1:4317",
		},
		{
			name: "collector with explicit port",
			specs: []Spec{{
				ID:         OtelCollectorAddonID,
				ConfigJSON: []byte(`{"server":{"port":14317}}`),
			}},
			want: "http://127.0.0.1:14317",
		},
		{
			name: "malformed config falls back to default port",
			specs: []Spec{{
				ID:         OtelCollectorAddonID,
				ConfigJSON: []byte(`{not json`),
			}},
			want: "http://127.0.0.1:4317",
		},
		{
			name: "out of range port falls back to default",
			specs: []Spec{{
				ID:         OtelCollectorAddonID,
				ConfigJSON: []byte(`{"server":{"port":700000}}`),
			}},
			want: "http://127.0.0.1:4317",
		},
		{
			name: "config without server section uses default",
			specs: []Spec{{
				ID:         OtelCollectorAddonID,
				ConfigJSON: []byte(`{"spool":{"path":"/var/spool"}}`),
			}},
			want: "http://127.0.0.1:4317",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := localOtlpEndpointFromSpecs(tc.specs); got != tc.want {
				t.Fatalf("localOtlpEndpointFromSpecs() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestAddonProcessEnvInjectsOtlpVars(t *testing.T) {
	base := []string{"PATH=/usr/bin", "HOME=/var/lib/serviceradar"}

	got := addonProcessEnv(base, "netprobe", "http://127.0.0.1:4317")

	want := []string{
		"PATH=/usr/bin",
		"HOME=/var/lib/serviceradar",
		"OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317",
		"OTEL_EXPORTER_OTLP_PROTOCOL=grpc",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("addonProcessEnv() = %v, want %v", got, want)
	}

	// The base slice must not be mutated (it is os.Environ()-derived).
	if !reflect.DeepEqual(base, []string{"PATH=/usr/bin", "HOME=/var/lib/serviceradar"}) {
		t.Fatalf("addonProcessEnv mutated base env: %v", base)
	}
}

// TestAddonProcessEnvLoopGuard pins the loop guard: the otel-collector add-on
// must never be pointed at itself.
func TestAddonProcessEnvLoopGuard(t *testing.T) {
	base := []string{"PATH=/usr/bin"}

	got := addonProcessEnv(base, OtelCollectorAddonID, "http://127.0.0.1:4317")

	if !reflect.DeepEqual(got, base) {
		t.Fatalf("loop guard failed: otel-collector env = %v, want unchanged %v", got, base)
	}
}

func TestAddonProcessEnvNoEndpointNoInjection(t *testing.T) {
	base := []string{"PATH=/usr/bin"}

	if got := addonProcessEnv(base, "netprobe", ""); !reflect.DeepEqual(got, base) {
		t.Fatalf("env without endpoint = %v, want unchanged %v", got, base)
	}
}

func TestAddonProcessEnvRespectsTelemetryOptOut(t *testing.T) {
	tests := []struct {
		name   string
		value  string
		expect bool // expect injection
	}{
		{name: "disabled with 1", value: "1", expect: false},
		{name: "disabled with true", value: "true", expect: false},
		{name: "disabled with TRUE", value: "TRUE", expect: false},
		{name: "not disabled with 0", value: "0", expect: true},
		{name: "not disabled with false", value: "false", expect: true},
		{name: "not disabled with empty", value: "", expect: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			base := []string{"SERVICERADAR_TELEMETRY_DISABLED=" + tc.value}

			got := addonProcessEnv(base, "netprobe", "http://127.0.0.1:4317")

			injected := len(got) > len(base)
			if injected != tc.expect {
				t.Fatalf("injection = %v, want %v (env: %v)", injected, tc.expect, got)
			}
		})
	}
}

// TestAddonProcessEnvExplicitEndpointWins pins precedence: an
// OTEL_EXPORTER_OTLP_ENDPOINT already present in the agent's environment is
// explicit operator configuration and is never overridden.
func TestAddonProcessEnvExplicitEndpointWins(t *testing.T) {
	base := []string{"OTEL_EXPORTER_OTLP_ENDPOINT=http://collector.example:4317"}

	got := addonProcessEnv(base, "netprobe", "http://127.0.0.1:4317")

	if !reflect.DeepEqual(got, base) {
		t.Fatalf("explicit endpoint overridden: %v", got)
	}
}

func TestManagerApplyDerivesLocalOtlpEndpoint(t *testing.T) {
	m := NewManager(Config{})
	t.Cleanup(func() {
		_ = m.Stop(t.Context())
	})

	// Specs with no real binaries: runners will fail to launch and back off,
	// which is fine — this test only exercises endpoint derivation.
	specs := []Spec{
		{ID: OtelCollectorAddonID, BinaryPath: "/nonexistent/otel", ConfigJSON: []byte(`{"server":{"port":5317}}`)},
		{ID: "netprobe", BinaryPath: "/nonexistent/netprobe"},
	}
	if err := m.Apply(t.Context(), specs); err != nil {
		t.Fatalf("Apply: %v", err)
	}

	if got, want := m.currentLocalOtlpEndpoint(), "http://127.0.0.1:5317"; got != want {
		t.Fatalf("currentLocalOtlpEndpoint() = %q, want %q", got, want)
	}

	// Removing the collector clears the derived endpoint.
	if err := m.Apply(t.Context(), specs[1:]); err != nil {
		t.Fatalf("Apply without collector: %v", err)
	}

	if got := m.currentLocalOtlpEndpoint(); got != "" {
		t.Fatalf("currentLocalOtlpEndpoint() after collector removal = %q, want \"\"", got)
	}
}

func TestManagerApplyFallsBackToConfigKnob(t *testing.T) {
	m := NewManager(Config{LocalOtlpEndpoint: "http://127.0.0.1:4317"})
	t.Cleanup(func() {
		_ = m.Stop(t.Context())
	})

	if err := m.Apply(t.Context(), []Spec{{ID: "netprobe", BinaryPath: "/nonexistent/netprobe"}}); err != nil {
		t.Fatalf("Apply: %v", err)
	}

	if got, want := m.currentLocalOtlpEndpoint(), "http://127.0.0.1:4317"; got != want {
		t.Fatalf("currentLocalOtlpEndpoint() = %q, want %q", got, want)
	}
}
