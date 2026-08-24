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

package netprobe

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	monitoringpb "github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

func TestParseVisibilityConfig(t *testing.T) {
	parsed := ParseVisibilityConfig(&monitoringpb.VisibilityConfig{
		Enabled:                 true,
		CaptureInterfaces:       []string{" en0 ", "", "eth1"},
		BinaryOverrides:         &monitoringpb.VisibilityBinaryOverrides{Path: " /tmp/netprobe "},
		DefaultSampleIntervalMs: 250,
		FlowTableMaxEntries:     262_144,
		Dpi: &monitoringpb.VisibilityDpiConfig{
			Enabled:   true,
			Protocols: []string{" dns ", "", "tls"},
		},
		DeviceBindings: []*monitoringpb.VisibilityDeviceBinding{
			nil,
			{
				Ip:               " " + testFingerprintIP + " ",
				ProfileId:        " profile-1 ",
				ProfileName:      " Linux servers ",
				SampleIntervalMs: 500,
				Fingerprint: &monitoringpb.VisibilityFingerprintConfig{
					Tcp:  true,
					Tls:  true,
					Http: false,
				},
				Dpi: &monitoringpb.VisibilityDpiConfig{
					Enabled:   true,
					Protocols: []string{" dns "},
				},
			},
		},
	})

	if parsed.BinaryOverridePath != "/tmp/netprobe" {
		t.Fatalf("BinaryOverridePath = %q, want /tmp/netprobe", parsed.BinaryOverridePath)
	}

	cfg := parsed.NetprobeConfig
	if cfg == nil {
		t.Fatal("NetprobeConfig = nil")
	}
	if !cfg.GetEnabled() {
		t.Fatal("Enabled = false, want true")
	}
	if got := cfg.GetCaptureInterfaces(); len(got) != 3 || got[0] != "en0" || got[1] != "" || got[2] != "eth1" {
		t.Fatalf("CaptureInterfaces = %#v, want [en0 \"\" eth1]", got)
	}
	if cfg.GetDefaultSampleIntervalMs() != 250 {
		t.Fatalf("DefaultSampleIntervalMs = %d, want 250", cfg.GetDefaultSampleIntervalMs())
	}
	if cfg.GetFlowTableMaxEntries() != 262_144 {
		t.Fatalf("FlowTableMaxEntries = %d, want 262144", cfg.GetFlowTableMaxEntries())
	}
	if !cfg.GetFlowAttributionIpcBatch() {
		t.Fatal("FlowAttributionIpcBatch = false, want true")
	}
	if !cfg.GetEmitRawFlowAttributionEvents() {
		t.Fatal("EmitRawFlowAttributionEvents = false, want true")
	}
	if !cfg.GetDpi().GetEnabled() {
		t.Fatal("DPI enabled = false, want true")
	}
	if got := cfg.GetDpi().GetProtocols(); len(got) != 3 || got[0] != "dns" || got[1] != "" || got[2] != "tls" {
		t.Fatalf("DPI protocols = %#v, want [dns \"\" tls]", got)
	}
	if len(cfg.GetDeviceBindings()) != 1 {
		t.Fatalf("DeviceBindings = %d, want 1", len(cfg.GetDeviceBindings()))
	}

	binding := cfg.GetDeviceBindings()[0]
	if binding.GetIp() != testFingerprintIP {
		t.Fatalf("binding IP = %q, want %s", binding.GetIp(), testFingerprintIP)
	}
	if binding.GetProfileId() != "profile-1" {
		t.Fatalf("binding ProfileId = %q, want profile-1", binding.GetProfileId())
	}
	if binding.GetProfileName() != "Linux servers" {
		t.Fatalf("binding ProfileName = %q, want Linux servers", binding.GetProfileName())
	}
	if binding.GetSampleIntervalMs() != 500 {
		t.Fatalf("binding SampleIntervalMs = %d, want 500", binding.GetSampleIntervalMs())
	}
	if !binding.GetFingerprint().GetTcp() || !binding.GetFingerprint().GetTls() || binding.GetFingerprint().GetHttp() {
		t.Fatalf("binding Fingerprint = %#v, want tcp/tls true and http false", binding.GetFingerprint())
	}
	if !binding.GetDpi().GetEnabled() || len(binding.GetDpi().GetProtocols()) != 1 || binding.GetDpi().GetProtocols()[0] != "dns" {
		t.Fatalf("binding DPI = %#v, want enabled dns", binding.GetDpi())
	}
}

func TestApplyAddonConfigJSONMergesNetprobeOnlyFields(t *testing.T) {
	base := &netprobepb.VisibilityAgentConfig{
		Enabled:                      false,
		CaptureInterfaces:            []string{"eth0"},
		DefaultSampleIntervalMs:      250,
		FlowTableMaxEntries:          262_144,
		FlowAttributionIpcBatch:      true,
		EmitRawFlowAttributionEvents: true,
		ExternalFlowMatchWindowMs:    30_000,
	}

	merged, err := ApplyAddonConfigJSON(base, []byte(`{
		"enabled": true,
		"capture_interfaces": [" ens18 "],
		"default_sample_interval_ms": 0,
		"flow_table_max_entries": 131072,
		"process_snapshot_interval_s": 0,
		"external_flow_match_window_ms": 45000,
		"flow_attribution_ipc_batch": false,
		"emit_raw_flow_attribution_events": false
	}`))
	if err != nil {
		t.Fatalf("ApplyAddonConfigJSON() error = %v", err)
	}

	if merged == base {
		t.Fatal("ApplyAddonConfigJSON returned the input pointer, want clone")
	}
	if !merged.GetEnabled() {
		t.Fatal("Enabled = false, want true")
	}
	if got := merged.GetCaptureInterfaces(); len(got) != 1 || got[0] != "ens18" {
		t.Fatalf("CaptureInterfaces = %#v, want [ens18]", got)
	}
	if merged.GetDefaultSampleIntervalMs() != 0 {
		t.Fatalf("DefaultSampleIntervalMs = %d, want 0", merged.GetDefaultSampleIntervalMs())
	}
	if merged.GetFlowTableMaxEntries() != 131_072 {
		t.Fatalf("FlowTableMaxEntries = %d, want 131072", merged.GetFlowTableMaxEntries())
	}
	if merged.GetProcessSnapshotIntervalS() != 0 {
		t.Fatalf("ProcessSnapshotIntervalS = %d, want 0", merged.GetProcessSnapshotIntervalS())
	}
	if merged.GetExternalFlowMatchWindowMs() != 45_000 {
		t.Fatalf("ExternalFlowMatchWindowMs = %d, want 45000", merged.GetExternalFlowMatchWindowMs())
	}
	if merged.GetFlowAttributionIpcBatch() {
		t.Fatal("FlowAttributionIpcBatch = true, want false from add-on override")
	}
	if merged.GetEmitRawFlowAttributionEvents() {
		t.Fatal("EmitRawFlowAttributionEvents = true, want false from add-on override")
	}
	if base.GetEnabled() {
		t.Fatal("base config was mutated")
	}
	if !base.GetFlowAttributionIpcBatch() {
		t.Fatal("base FlowAttributionIpcBatch was mutated")
	}
	if !base.GetEmitRawFlowAttributionEvents() {
		t.Fatal("base EmitRawFlowAttributionEvents was mutated")
	}
}

func TestApplyAddonConfigJSONCoercesScalarCaptureInterfaces(t *testing.T) {
	// Compatibility form (fj#4381): a corrupt assignment row delivered
	// `capture_interfaces` as a scalar string and permanently wedged config
	// apply. The decoder now treats a non-empty string as a single-element
	// list, trimming whitespace like the array form does.
	for _, payload := range []string{
		`{"enabled": true, "capture_interfaces": "ens18"}`,
		`{"enabled": true, "capture_interfaces": " ens18 "}`,
	} {
		merged, err := ApplyAddonConfigJSON(&netprobepb.VisibilityAgentConfig{
			CaptureInterfaces: []string{"eth0"},
		}, []byte(payload))
		if err != nil {
			t.Fatalf("ApplyAddonConfigJSON(%s) error = %v", payload, err)
		}

		if got := merged.GetCaptureInterfaces(); len(got) != 1 || got[0] != "ens18" {
			t.Fatalf("CaptureInterfaces = %#v for %s, want [ens18]", got, payload)
		}
		if !merged.GetEnabled() {
			t.Fatalf("Enabled = false for %s, want true", payload)
		}
	}
}

func TestApplyAddonConfigJSONScalarEmptyCaptureInterfacesClears(t *testing.T) {
	// An empty (or whitespace-only) scalar string means "explicitly no capture
	// interfaces", matching the semantics of an explicit empty array.
	for _, payload := range []string{
		`{"capture_interfaces": ""}`,
		`{"capture_interfaces": "   "}`,
	} {
		merged, err := ApplyAddonConfigJSON(&netprobepb.VisibilityAgentConfig{
			CaptureInterfaces: []string{"eth0"},
		}, []byte(payload))
		if err != nil {
			t.Fatalf("ApplyAddonConfigJSON(%s) error = %v", payload, err)
		}

		if got := merged.GetCaptureInterfaces(); len(got) != 0 {
			t.Fatalf("CaptureInterfaces = %#v for %s, want empty", got, payload)
		}
	}
}

func TestApplyAddonConfigJSONNullCaptureInterfacesKeepsBase(t *testing.T) {
	merged, err := ApplyAddonConfigJSON(&netprobepb.VisibilityAgentConfig{
		CaptureInterfaces: []string{"eth0"},
	}, []byte(`{"capture_interfaces": null}`))
	if err != nil {
		t.Fatalf("ApplyAddonConfigJSON() error = %v", err)
	}

	if got := merged.GetCaptureInterfaces(); len(got) != 1 || got[0] != "eth0" {
		t.Fatalf("CaptureInterfaces = %#v, want base [eth0] preserved", got)
	}
}

func TestApplyAddonConfigJSONRejectsNonStringCaptureInterfaces(t *testing.T) {
	// Tolerance is bounded to the documented string form; other type drift is
	// still a decode error.
	for _, payload := range []string{
		`{"capture_interfaces": 42}`,
		`{"capture_interfaces": {"eth0": true}}`,
		`{"capture_interfaces": [1, 2]}`,
	} {
		if _, err := ApplyAddonConfigJSON(nil, []byte(payload)); err == nil {
			t.Fatalf("ApplyAddonConfigJSON(%s) error = nil, want unmarshal error", payload)
		}
	}
}

func TestApplyAddonConfigJSONDefaultsAttributionControlsWhenBaseMissing(t *testing.T) {
	merged, err := ApplyAddonConfigJSON(nil, []byte(`{"enabled":true}`))
	if err != nil {
		t.Fatalf("ApplyAddonConfigJSON() error = %v", err)
	}

	if !merged.GetEnabled() {
		t.Fatal("Enabled = false, want true")
	}
	if !merged.GetFlowAttributionIpcBatch() {
		t.Fatal("FlowAttributionIpcBatch = false, want true default")
	}
	if !merged.GetEmitRawFlowAttributionEvents() {
		t.Fatal("EmitRawFlowAttributionEvents = false, want true default")
	}
}

func TestParseVisibilityConfigNil(t *testing.T) {
	parsed := ParseVisibilityConfig(nil)
	if parsed.BinaryOverridePath != "" {
		t.Fatalf("BinaryOverridePath = %q, want empty", parsed.BinaryOverridePath)
	}
	if parsed.NetprobeConfig == nil {
		t.Fatal("NetprobeConfig = nil")
	}
	if parsed.NetprobeConfig.GetEnabled() {
		t.Fatal("Enabled = true, want false")
	}
	if !parsed.NetprobeConfig.GetFlowAttributionIpcBatch() {
		t.Fatal("FlowAttributionIpcBatch = false, want true default")
	}
	if !parsed.NetprobeConfig.GetEmitRawFlowAttributionEvents() {
		t.Fatal("EmitRawFlowAttributionEvents = false, want true default")
	}
}

func TestWriteBootstrapConfigOmitsEmptyCaptureInterfaces(t *testing.T) {
	path := filepath.Join(t.TempDir(), "netprobe.json")

	if err := WriteBootstrapConfig(path, &netprobepb.VisibilityAgentConfig{
		Enabled:                      true,
		FlowAttributionIpcBatch:      true,
		EmitRawFlowAttributionEvents: true,
	}); err != nil {
		t.Fatalf("WriteBootstrapConfig() error = %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile() error = %v", err)
	}

	payload := string(data)
	if strings.Contains(payload, "capture_interfaces") {
		t.Fatalf("bootstrap config contains capture_interfaces for empty list: %s", payload)
	}
	if !strings.Contains(payload, "\"enabled\": true") {
		t.Fatalf("bootstrap config missing enabled=true: %s", payload)
	}
	if !strings.Contains(payload, `"flow_attribution_ipc_batch": true`) {
		t.Fatalf("bootstrap config missing flow attribution batching: %s", payload)
	}
	if !strings.Contains(payload, `"emit_raw_flow_attribution_events": true`) {
		t.Fatalf("bootstrap config missing raw attribution event setting: %s", payload)
	}
}

func TestWriteBootstrapConfigIncludesStartupOnlyFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "netprobe.json")

	if err := WriteBootstrapConfig(path, &netprobepb.VisibilityAgentConfig{
		Enabled:                      true,
		ProcessSnapshotIntervalS:     0,
		ExternalFlowMatchWindowMs:    45_000,
		FlowAttributionIpcBatch:      true,
		EmitRawFlowAttributionEvents: true,
	}); err != nil {
		t.Fatalf("WriteBootstrapConfig() error = %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read bootstrap config: %v", err)
	}
	got := string(data)
	if strings.Contains(got, "process_snapshot_interval_s") {
		t.Fatalf("bootstrap config should omit zero process snapshot interval, got %s", got)
	}
	if !strings.Contains(got, `"external_flow_match_window_ms": 45000`) {
		t.Fatalf("bootstrap config = %s, want external flow match window", got)
	}
}

func TestApplyAddonConfigJSONIgnoresLegacyWorkloadIdentityFields(t *testing.T) {
	merged, err := ApplyAddonConfigJSON(&netprobepb.VisibilityAgentConfig{}, []byte(`{
		"enabled": true,
		"workload_identity_enabled": true,
		"cri_endpoint": " /run/k3s/containerd/containerd.sock ",
		"workload_identity_refresh_interval_s": 45
	}`))
	if err != nil {
		t.Fatalf("ApplyAddonConfigJSON() error = %v", err)
	}

	if !merged.GetEnabled() {
		t.Fatalf("netprobe config did not consume supported fields: %#v", merged)
	}

	path := filepath.Join(t.TempDir(), "netprobe.json")
	if err := WriteBootstrapConfig(path, merged); err != nil {
		t.Fatalf("WriteBootstrapConfig() error = %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read bootstrap config: %v", err)
	}

	got := string(data)
	for _, legacyField := range []string{
		"workload_identity_enabled",
		"cri_endpoint",
		"workload_identity_refresh_interval_s",
	} {
		if strings.Contains(got, legacyField) {
			t.Fatalf("bootstrap config leaked legacy workload identity field %q: %s", legacyField, got)
		}
	}
}

func TestWriteBootstrapConfigPreservesFalseAttributionBooleans(t *testing.T) {
	path := filepath.Join(t.TempDir(), "netprobe.json")

	if err := WriteBootstrapConfig(path, &netprobepb.VisibilityAgentConfig{
		Enabled:                      true,
		FlowAttributionIpcBatch:      false,
		EmitRawFlowAttributionEvents: false,
	}); err != nil {
		t.Fatalf("WriteBootstrapConfig() error = %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read bootstrap config: %v", err)
	}
	got := string(data)
	if !strings.Contains(got, `"flow_attribution_ipc_batch": false`) {
		t.Fatalf("bootstrap config = %s, want flow attribution batching false", got)
	}
	if !strings.Contains(got, `"emit_raw_flow_attribution_events": false`) {
		t.Fatalf("bootstrap config = %s, want raw attribution events false", got)
	}
}

func TestWriteBootstrapConfigReplacesReadOnlyExistingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "netprobe.json")
	if err := os.WriteFile(path, []byte(`{"enabled":false}`), 0o400); err != nil {
		t.Fatalf("seed read-only bootstrap config: %v", err)
	}

	if err := WriteBootstrapConfig(path, &netprobepb.VisibilityAgentConfig{
		Enabled:                      true,
		FlowAttributionIpcBatch:      true,
		EmitRawFlowAttributionEvents: true,
	}); err != nil {
		t.Fatalf("WriteBootstrapConfig() error = %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile() error = %v", err)
	}
	if !strings.Contains(string(data), "\"enabled\": true") {
		t.Fatalf("bootstrap config was not replaced: %s", string(data))
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat() error = %v", err)
	}
	if got := info.Mode().Perm(); got != 0o640 {
		t.Fatalf("bootstrap config mode = %o, want 640", got)
	}
}

// The two properties addons/netprobe/config.schema.json has declared since the
// manifest was written, and which the add-on config path silently ignored until
// they were added to addonConfig.
//
// Nothing errored, because the merge leaves an absent field at its base value --
// so an operator setting DPI or a per-device binding through the add-on surface
// simply had no effect, and the config that reached netprobe looked exactly like
// one where they had set nothing.
// goconst counts identical literals across the whole package, tests included.
// Naming the protocol here keeps test data from pushing a production literal in
// translator.go over the threshold and making an unrelated file look at fault.
const testProtocolTLS = "tls"

func TestApplyAddonConfigJSONCarriesDpiAndDeviceBindings(t *testing.T) {
	base := &netprobepb.VisibilityAgentConfig{
		Enabled: true,
		Dpi:     &netprobepb.DpiConfig{Enabled: false},
	}

	merged, err := ApplyAddonConfigJSON(base, []byte(`{
		"dpi": {"enabled": true, "protocols": ["`+testProtocolTLS+`", " http "]},
		"device_bindings": [
			{
				"ip": " 192.168.1.10 ",
				"profile_id": "profile-a",
				"profile_name": "Camera",
				"sample_interval_ms": 500,
				"fingerprint": {"tcp": true, "tls": true, "http": false},
				"dpi": {"enabled": true, "protocols": ["dns"]}
			}
		]
	}`))
	if err != nil {
		t.Fatalf("ApplyAddonConfigJSON() error = %v", err)
	}

	if !merged.GetDpi().GetEnabled() {
		t.Fatal("dpi.enabled was not carried from the add-on config")
	}
	if got := merged.GetDpi().GetProtocols(); len(got) != 2 || got[0] != testProtocolTLS || got[1] != "http" {
		t.Fatalf("dpi.protocols = %v, want [tls http] with whitespace trimmed", got)
	}

	bindings := merged.GetDeviceBindings()
	if len(bindings) != 1 {
		t.Fatalf("device_bindings length = %d, want 1", len(bindings))
	}

	binding := bindings[0]
	if binding.GetIp() != "192.168.1.10" {
		t.Fatalf("binding ip = %q, want the trimmed address", binding.GetIp())
	}
	if binding.GetProfileId() != "profile-a" || binding.GetProfileName() != "Camera" {
		t.Fatalf("binding profile = %q/%q", binding.GetProfileId(), binding.GetProfileName())
	}
	if binding.GetSampleIntervalMs() != 500 {
		t.Fatalf("binding sample interval = %d, want 500", binding.GetSampleIntervalMs())
	}
	if !binding.GetFingerprint().GetTcp() || !binding.GetFingerprint().GetTls() {
		t.Fatal("binding fingerprint toggles were not carried")
	}
	if binding.GetFingerprint().GetHttp() {
		t.Fatal("binding fingerprint http was set true, want the supplied false")
	}
	if !binding.GetDpi().GetEnabled() {
		t.Fatal("per-binding dpi was not carried")
	}
}

func TestApplyAddonConfigJSONAbsentDpiAndBindingsKeepTheBase(t *testing.T) {
	// The merge rule for every other field: absent means "not specified", not
	// "set to empty". Without this, an add-on config that omits them would wipe
	// bindings the base VisibilityConfig supplied.
	base := &netprobepb.VisibilityAgentConfig{
		Dpi:            &netprobepb.DpiConfig{Enabled: true, Protocols: []string{testProtocolTLS}},
		DeviceBindings: []*netprobepb.DeviceBinding{{Ip: "10.0.0.5", ProfileId: "keep-me"}},
	}

	merged, err := ApplyAddonConfigJSON(base, []byte(`{"enabled": true}`))
	if err != nil {
		t.Fatalf("ApplyAddonConfigJSON() error = %v", err)
	}

	if !merged.GetDpi().GetEnabled() {
		t.Fatal("absent dpi wiped the base value")
	}
	if len(merged.GetDeviceBindings()) != 1 || merged.GetDeviceBindings()[0].GetIp() != "10.0.0.5" {
		t.Fatalf("absent device_bindings wiped the base value: %v", merged.GetDeviceBindings())
	}
}

func TestApplyAddonConfigJSONEmptyDeviceBindingsClears(t *testing.T) {
	// Present-but-empty is how an operator removes every binding. If this were
	// treated the same as absent, a binding could be added through this surface
	// and never removed through it.
	base := &netprobepb.VisibilityAgentConfig{
		DeviceBindings: []*netprobepb.DeviceBinding{{Ip: "10.0.0.5"}},
	}

	merged, err := ApplyAddonConfigJSON(base, []byte(`{"device_bindings": []}`))
	if err != nil {
		t.Fatalf("ApplyAddonConfigJSON() error = %v", err)
	}

	if len(merged.GetDeviceBindings()) != 0 {
		t.Fatalf("device_bindings = %v, want cleared", merged.GetDeviceBindings())
	}
}

func TestApplyAddonConfigJSONDropsABindingWithNoIP(t *testing.T) {
	// The schema marks `ip` required; this is the runtime half. A binding with
	// no address can never match anything, so carrying it would just be a
	// permanently dead entry in the config netprobe applies.
	merged, err := ApplyAddonConfigJSON(nil, []byte(`{
		"device_bindings": [{"ip": "   ", "profile_id": "orphan"}, {"ip": "10.0.0.7"}]
	}`))
	if err != nil {
		t.Fatalf("ApplyAddonConfigJSON() error = %v", err)
	}

	bindings := merged.GetDeviceBindings()
	if len(bindings) != 1 || bindings[0].GetIp() != "10.0.0.7" {
		t.Fatalf("device_bindings = %v, want only the addressed binding", bindings)
	}
}

func TestBootstrapConfigCarriesCollectorIP(t *testing.T) {
	// netprobe needs the address from BOOT, not from the first config apply: the
	// payloads that need a subject start flowing before the agent connects.
	path := filepath.Join(t.TempDir(), "netprobe.json")

	if err := WriteBootstrapConfig(path, &netprobepb.VisibilityAgentConfig{
		Enabled:     true,
		CollectorIp: "  10.20.30.40  ",
	}); err != nil {
		t.Fatalf("WriteBootstrapConfig: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read bootstrap config: %v", err)
	}

	var decoded struct {
		CollectorIP string `json:"collector_ip"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal bootstrap config: %v", err)
	}
	if decoded.CollectorIP != "10.20.30.40" {
		t.Fatalf("collector_ip = %q, want %q (trimmed)", decoded.CollectorIP, "10.20.30.40")
	}
}

func TestBootstrapConfigOmitsAnUnsetCollectorIP(t *testing.T) {
	// Absent rather than empty: netprobe reads an absent value as "not supplied"
	// and keeps whatever it already had, so writing "" would be a wipe.
	path := filepath.Join(t.TempDir(), "netprobe.json")

	if err := WriteBootstrapConfig(path, &netprobepb.VisibilityAgentConfig{Enabled: true}); err != nil {
		t.Fatalf("WriteBootstrapConfig: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read bootstrap config: %v", err)
	}
	if strings.Contains(string(raw), "collector_ip") {
		t.Fatalf("unset collector_ip must be omitted, got: %s", raw)
	}
}

func TestAddonConfigJSONCannotOverrideCollectorIP(t *testing.T) {
	// The add-on config JSON is OPERATOR-controlled. The collector address is
	// agent runtime context, and an operator naming a different host's address
	// would send every fingerprint and DPI subject to the wrong device.
	base := &netprobepb.VisibilityAgentConfig{Enabled: true, CollectorIp: "10.20.30.40"}

	merged, err := ApplyAddonConfigJSON(base, []byte(`{"enabled":true,"collector_ip":"10.99.99.99"}`))
	if err != nil {
		t.Fatalf("ApplyAddonConfigJSON: %v", err)
	}
	if got := merged.GetCollectorIp(); got != "10.20.30.40" {
		t.Fatalf("collector_ip = %q, want the agent's %q; operator config must not relocate the collector", got, "10.20.30.40")
	}
}
