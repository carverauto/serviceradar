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
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/devicealias"
	"github.com/carverauto/serviceradar/go/pkg/models"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
)

const testFingerprintIP = "192.0.2.10"

func TestFingerprintEventToDiscoveredDeviceTCP(t *testing.T) {
	observed := time.Date(2026, 5, 27, 14, 30, 1, 123, time.UTC)
	device, err := FingerprintEventToDiscoveredDevice(&netprobepb.FingerprintEvent{
		Ip:                 " " + testFingerprintIP + " ",
		ProfileId:          "profile-1",
		InterfaceName:      "en0",
		ObservedAtUnixNano: observed.UnixNano(),
		Evidence: &netprobepb.FingerprintEvent_Tcp{
			Tcp: &netprobepb.TcpFingerprint{
				Signature:  "64240:64:1:60:M1460,S,T,N,W7",
				OsFamily:   "linux",
				OsName:     "Linux 5.x",
				Confidence: 0.92,
			},
		},
	}, TranslationOptions{
		AgentID:     "agent-a",
		GatewayID:   "gateway-a",
		CollectorIP: "198.51.100.4",
		ProfileNames: map[string]string{
			"profile-1": "Linux servers",
		},
	})
	if err != nil {
		t.Fatalf("FingerprintEventToDiscoveredDevice() error = %v", err)
	}
	if device.GetIp() != testFingerprintIP {
		t.Fatalf("device IP = %q, want %s", device.GetIp(), testFingerprintIP)
	}

	metadata := device.GetMetadata()
	assertMetadata(t, metadata, "discovery_source", string(models.DiscoverySourcePassiveNetprobe))
	assertMetadata(t, metadata, "source", string(models.DiscoverySourcePassiveNetprobe))
	assertMetadata(t, metadata, "passive_fingerprint.protocol", "tcp")
	assertMetadata(t, metadata, "passive_fingerprint.profile_name", "Linux servers")
	assertMetadata(t, metadata, "passive_fingerprint.tcp.signature", "64240:64:1:60:M1460,S,T,N,W7")
	assertMetadata(t, metadata, "passive_fingerprint.tcp.os_family", "linux")
	assertMetadata(t, metadata, "passive_fingerprint.tcp.os_name", "Linux 5.x")
	assertMetadata(t, metadata, "passive_fingerprint.tcp.confidence", "0.920")
	assertMetadata(t, metadata, "agent_id", "agent-a")
	assertMetadata(t, metadata, "gateway_id", "gateway-a")
	assertMetadata(t, metadata, "_alias_last_seen_at", "2026-05-27T14:30:01.000000123Z")
	assertMetadata(t, metadata, "_alias_last_seen_ip", testFingerprintIP)
	assertMetadata(t, metadata, "_alias_collector_ip", "198.51.100.4")
	assertMetadata(t, metadata, "ip_alias:"+testFingerprintIP, "2026-05-27T14:30:01.000000123Z")

	alias := devicealias.FromMetadata(metadata)
	if alias == nil {
		t.Fatal("devicealias.FromMetadata() = nil, want alias record")
	}
	if alias.CurrentIP != testFingerprintIP {
		t.Fatalf("alias CurrentIP = %q, want %s", alias.CurrentIP, testFingerprintIP)
	}
	if alias.CollectorIP != "198.51.100.4" {
		t.Fatalf("alias CollectorIP = %q, want 198.51.100.4", alias.CollectorIP)
	}
	if got := alias.IPs[testFingerprintIP]; got != "2026-05-27T14:30:01.000000123Z" {
		t.Fatalf("alias IP timestamp = %q, want observed timestamp", got)
	}
}

func TestFingerprintEventToDiscoveredDeviceTLSAndHTTP(t *testing.T) {
	tests := []struct {
		name     string
		event    *netprobepb.FingerprintEvent
		expected map[string]string
	}{
		{
			name: "tls",
			event: &netprobepb.FingerprintEvent{
				Ip: "192.0.2.20",
				Evidence: &netprobepb.FingerprintEvent_Tls{
					Tls: &netprobepb.TlsFingerprint{
						Ja4:         "t13d1516h2_8daaf6152771_b0da82dd1658",
						Ja4S:        "t130200_1301_a56c5b993250",
						SniRedacted: "example.invalid",
					},
				},
			},
			expected: map[string]string{
				"passive_fingerprint.protocol":         "tls",
				"passive_fingerprint.tls.ja4":          "t13d1516h2_8daaf6152771_b0da82dd1658",
				"passive_fingerprint.tls.ja4s":         "t130200_1301_a56c5b993250",
				"passive_fingerprint.tls.sni_redacted": "<present>",
			},
		},
		{
			name: "http",
			event: &netprobepb.FingerprintEvent{
				Ip: "192.0.2.30",
				Evidence: &netprobepb.FingerprintEvent_Http{
					Http: &netprobepb.HttpFingerprint{
						UserAgent:      "curl/8.7.1",
						Server:         "nginx",
						AcceptLanguage: "en-US",
					},
				},
			},
			expected: map[string]string{
				"passive_fingerprint.protocol":             "http",
				"passive_fingerprint.http.user_agent":      "curl/8.7.1",
				"passive_fingerprint.http.server":          "nginx",
				"passive_fingerprint.http.accept_language": "en-US",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			device, err := FingerprintEventToDiscoveredDevice(tt.event, TranslationOptions{})
			if err != nil {
				t.Fatalf("FingerprintEventToDiscoveredDevice() error = %v", err)
			}
			for key, expected := range tt.expected {
				assertMetadata(t, device.GetMetadata(), key, expected)
			}
		})
	}
}

func TestFingerprintEventsToResults(t *testing.T) {
	result, err := FingerprintEventsToResults([]*netprobepb.FingerprintEvent{
		{
			Ip: "192.0.2.40",
			Evidence: &netprobepb.FingerprintEvent_Http{
				Http: &netprobepb.HttpFingerprint{Server: "apache"},
			},
		},
	}, TranslationOptions{AgentID: "agent-a", GatewayID: "gateway-a"})
	if err != nil {
		t.Fatalf("FingerprintEventsToResults() error = %v", err)
	}
	if result.GetStatus() != discoverypb.DiscoveryStatus_COMPLETED {
		t.Fatalf("result status = %s, want COMPLETED", result.GetStatus())
	}
	if len(result.GetDevices()) != 1 {
		t.Fatalf("result devices = %d, want 1", len(result.GetDevices()))
	}
	assertMetadata(t, result.GetMetadata(), "discovery_source", string(models.DiscoverySourcePassiveNetprobe))
	assertMetadata(t, result.GetMetadata(), "agent_id", "agent-a")
	assertMetadata(t, result.GetDevices()[0].GetMetadata(), "passive_fingerprint.http.server", "apache")
}

func TestDpiEventToDiscoveredDevice(t *testing.T) {
	device, err := DpiEventToDiscoveredDevice(&netprobepb.DpiEvent{
		SourceIp:           testFingerprintIP,
		DestinationIp:      "198.51.100.20",
		SourcePort:         49152,
		DestinationPort:    53,
		TransportProtocol:  "udp",
		Protocol:           "dns",
		Confidence:         0.92,
		ObservedAtUnixNano: time.Date(2026, 5, 27, 14, 30, 1, 0, time.UTC).UnixNano(),
		InterfaceName:      "eth0",
		ProfileId:          "profile-1",
		DissectorId:        "dns_header",
	}, TranslationOptions{
		AgentID:      "agent-1",
		GatewayID:    "gateway-1",
		CollectorIP:  testFingerprintIP,
		ProfileNames: map[string]string{"profile-1": "DNS Sensors"},
	})
	if err != nil {
		t.Fatalf("DpiEventToDiscoveredDevice() error = %v", err)
	}

	if device.GetIp() != testFingerprintIP {
		t.Fatalf("device IP = %q, want %s", device.GetIp(), testFingerprintIP)
	}
	metadata := device.GetMetadata()
	assertMetadata(t, metadata, "dpi.source", "passive-netprobe")
	assertMetadata(t, metadata, "dpi.profile_id", "profile-1")
	assertMetadata(t, metadata, "dpi.profile_name", "DNS Sensors")
	assertMetadata(t, metadata, "dpi.interface", "eth0")
	assertMetadata(t, metadata, "dpi.protocol", "dns")
	assertMetadata(t, metadata, "dpi.dns.count", "1")
	assertMetadata(t, metadata, "dpi.dns.confidence", "0.920")
	assertMetadata(t, metadata, "dpi.dns.last_observed_at", "2026-05-27T14:30:01Z")

	for key := range metadata {
		if strings.Contains(key, "source_port") || strings.Contains(key, "destination_port") {
			t.Fatalf("metadata stored flow tuple field %q", key)
		}
	}
}

func TestDpiEventToDiscoveredDeviceValidation(t *testing.T) {
	tests := []struct {
		name  string
		event *netprobepb.DpiEvent
		want  error
	}{
		{name: "nil", event: nil, want: ErrNilDPIEvent},
		{name: "missing protocol", event: &netprobepb.DpiEvent{SourceIp: testFingerprintIP}, want: ErrDPIEventMissing},
		{name: "missing ip", event: &netprobepb.DpiEvent{Protocol: "dns"}, want: ErrDPIEventMissing},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := DpiEventToDiscoveredDevice(tt.event, TranslationOptions{})
			if !errors.Is(err, tt.want) {
				t.Fatalf("DpiEventToDiscoveredDevice() error = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestFingerprintEventToDiscoveredDeviceValidation(t *testing.T) {
	tests := []struct {
		name  string
		event *netprobepb.FingerprintEvent
		want  error
	}{
		{name: "nil", event: nil, want: ErrNilFingerprintEvent},
		{name: "missing ip", event: &netprobepb.FingerprintEvent{}, want: ErrFingerprintEventMissing},
		{
			name: "missing evidence",
			event: &netprobepb.FingerprintEvent{
				Ip: "192.0.2.50",
			},
			want: ErrFingerprintEventMissing,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := FingerprintEventToDiscoveredDevice(tt.event, TranslationOptions{})
			if !errors.Is(err, tt.want) {
				t.Fatalf("FingerprintEventToDiscoveredDevice() error = %v, want %v", err, tt.want)
			}
		})
	}
}

func assertMetadata(t *testing.T, metadata map[string]string, key, want string) {
	t.Helper()

	if got := metadata[key]; got != want {
		t.Fatalf("metadata[%q] = %q, want %q", key, got, want)
	}
}
