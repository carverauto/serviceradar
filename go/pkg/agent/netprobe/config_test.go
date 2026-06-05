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
}

func TestWriteBootstrapConfigOmitsEmptyCaptureInterfaces(t *testing.T) {
	path := filepath.Join(t.TempDir(), "netprobe.json")

	if err := WriteBootstrapConfig(path, &netprobepb.VisibilityAgentConfig{Enabled: true}); err != nil {
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
}
