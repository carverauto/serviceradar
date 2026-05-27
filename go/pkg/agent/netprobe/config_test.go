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
	"testing"

	monitoringpb "github.com/carverauto/serviceradar/proto"
)

func TestParseVisibilityConfig(t *testing.T) {
	parsed := ParseVisibilityConfig(&monitoringpb.VisibilityConfig{
		Enabled:                 true,
		CaptureInterfaces:       []string{" en0 ", "", "eth1"},
		BinaryOverrides:         &monitoringpb.VisibilityBinaryOverrides{Path: " /tmp/netprobe "},
		DefaultSampleIntervalMs: 250,
		DeviceBindings: []*monitoringpb.VisibilityDeviceBinding{
			nil,
			{
				Ip:               " 192.0.2.10 ",
				ProfileId:        " profile-1 ",
				ProfileName:      " Linux servers ",
				SampleIntervalMs: 500,
				Fingerprint: &monitoringpb.VisibilityFingerprintConfig{
					Tcp:  true,
					Tls:  true,
					Http: false,
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
	if got := cfg.GetCaptureInterfaces(); len(got) != 2 || got[0] != "en0" || got[1] != "eth1" {
		t.Fatalf("CaptureInterfaces = %#v, want [en0 eth1]", got)
	}
	if cfg.GetDefaultSampleIntervalMs() != 250 {
		t.Fatalf("DefaultSampleIntervalMs = %d, want 250", cfg.GetDefaultSampleIntervalMs())
	}
	if len(cfg.GetDeviceBindings()) != 1 {
		t.Fatalf("DeviceBindings = %d, want 1", len(cfg.GetDeviceBindings()))
	}

	binding := cfg.GetDeviceBindings()[0]
	if binding.GetIp() != "192.0.2.10" {
		t.Fatalf("binding IP = %q, want 192.0.2.10", binding.GetIp())
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
