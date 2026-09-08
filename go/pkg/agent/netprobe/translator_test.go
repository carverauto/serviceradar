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

func TestFingerprintEventToDiscoveredDeviceSweepActiveLicenseClean(t *testing.T) {
	device, err := FingerprintEventToDiscoveredDevice(&netprobepb.FingerprintEvent{
		Ip:                 "192.0.2.50",
		ProfileId:          "sweep_active",
		ObservedAtUnixNano: time.Date(2026, 5, 28, 12, 0, 0, 0, time.UTC).UnixNano(),
		Evidence: &netprobepb.FingerprintEvent_LicenseClean{
			LicenseClean: &netprobepb.LicenseCleanFingerprint{
				OsMatch: &netprobepb.OsMatch{
					Name:         "Ubuntu Linux",
					VersionRange: "22.04",
					OsFamily:     "linux",
					Confidence:   0.86,
				},
				RecogSsh: &netprobepb.RecogFingerprintMatch{
					Product:  "OpenSSH",
					Version:  "8.9",
					OsFamily: "linux",
				},
				RecogSmtp: &netprobepb.RecogFingerprintMatch{
					Product:  "Postfix",
					Version:  "3.8",
					OsFamily: "linux",
				},
				RecogNtp: &netprobepb.RecogFingerprintMatch{
					Product: "ntpsec",
					Version: "1.2",
				},
			},
		},
	}, TranslationOptions{})
	if err != nil {
		t.Fatalf("FingerprintEventToDiscoveredDevice() error = %v", err)
	}

	metadata := device.GetMetadata()
	assertMetadata(t, metadata, "discovery_source", string(models.DiscoverySourceSweepActive))
	assertMetadata(t, metadata, "source", string(models.DiscoverySourceSweepActive))
	assertMetadata(t, metadata, "active_fingerprint.source", string(models.DiscoverySourceSweepActive))
	assertMetadata(t, metadata, "active_fingerprint.protocol", "license_clean")
	assertMetadata(t, metadata, "active_fingerprint.os.name", "Ubuntu Linux")
	assertMetadata(t, metadata, "active_fingerprint.os.version_range", "22.04")
	assertMetadata(t, metadata, "active_fingerprint.os.family", "linux")
	assertMetadata(t, metadata, "active_fingerprint.os.confidence", "0.860")
	assertMetadata(t, metadata, "active_fingerprint.recog.ssh.product", "OpenSSH")
	assertMetadata(t, metadata, "active_fingerprint.recog.ssh.version", "8.9")
	assertMetadata(t, metadata, "active_fingerprint.recog.ssh.os_family", "linux")
	assertMetadata(t, metadata, "active_fingerprint.recog.smtp.product", "Postfix")
	assertMetadata(t, metadata, "active_fingerprint.recog.smtp.version", "3.8")
	assertMetadata(t, metadata, "active_fingerprint.recog.ntp.product", "ntpsec")
	assertMetadata(t, metadata, "active_fingerprint.recog.ntp.version", "1.2")
	assertMetadata(t, metadata, "active_fingerprint.observed_at", "2026-05-28T12:00:00Z")

	if _, ok := metadata["active_fingerprint.profile_id"]; ok {
		t.Fatal("active_fingerprint.profile_id should not expose sweep_active source sentinel")
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

func TestProcessSnapshotToDiscoveredDevice(t *testing.T) {
	observed := time.Date(2026, 5, 28, 16, 5, 4, 123, time.UTC)
	device, err := ProcessSnapshotToDiscoveredDevice(&netprobepb.ProcessSnapshot{
		Fingerprint:        "snapshot-1",
		ObservedAtUnixNano: observed.UnixNano(),
		Entries: []*netprobepb.ProcessSnapshotEntry{
			{
				LocalIp:           "127.0.0.1",
				LocalPort:         5432,
				TransportProtocol: "tcp",
				Pid:               4242,
				Tgid:              4242,
				Uid:               26,
				Gid:               26,
				Comm:              "postgres",
				RedactedCmdline:   []string{"postgres", "--config=redacted"},
				ContainerId:       "container-abc123",
			},
		},
	}, TranslationOptions{
		AgentID:     "agent-1",
		GatewayID:   "gateway-1",
		CollectorIP: testFingerprintIP,
	})
	if err != nil {
		t.Fatalf("ProcessSnapshotToDiscoveredDevice() error = %v", err)
	}

	if device.GetIp() != testFingerprintIP {
		t.Fatalf("device IP = %q, want %s", device.GetIp(), testFingerprintIP)
	}

	metadata := device.GetMetadata()
	assertMetadata(t, metadata, "local_processes.schema", "summary_v1")
	assertMetadata(t, metadata, "local_processes.fingerprint", "snapshot-1")
	assertMetadata(t, metadata, "local_processes.entry_count", "1")
	assertMetadata(t, metadata, "local_processes.process_count", "1")
	assertMetadata(t, metadata, "local_processes.port_count", "1")
	assertMetadata(t, metadata, "local_processes.container_count", "1")
	assertMetadata(t, metadata, "local_processes.protocols", "tcp")
	assertMetadata(t, metadata, "local_processes.tcp_port_count", "1")
	assertMetadata(t, metadata, "local_processes.observed_at", "2026-05-28T16:05:04.000000123Z")
	assertMetadata(t, metadata, "_alias_last_seen_ip", testFingerprintIP)
	assertMetadata(t, metadata, "_alias_last_seen_at", "2026-05-28T16:05:04.000000123Z")

	if _, ok := metadata["local_processes"]; ok {
		t.Fatal("metadata must not store the full local_processes payload")
	}
}

func TestProcessSnapshotToDiscoveredDeviceSummarizesLargeSnapshots(t *testing.T) {
	entries := make([]*netprobepb.ProcessSnapshotEntry, 0, 20)
	for idx := 0; idx < 20; idx++ {
		entries = append(entries, &netprobepb.ProcessSnapshotEntry{
			LocalIp:           "127.0.0.1",
			LocalPort:         uint32(10_000 + idx),
			TransportProtocol: "tcp",
			Pid:               uint32(1_000 + idx),
			Tgid:              uint32(1_000 + idx),
			Uid:               26,
			Gid:               26,
			Comm:              "postgres",
			RedactedCmdline:   []string{"postgres", strings.Repeat("x", 512)},
			ContainerId:       "container-abc123",
		})
	}

	device, err := ProcessSnapshotToDiscoveredDevice(&netprobepb.ProcessSnapshot{
		Fingerprint:        "snapshot-1",
		ObservedAtUnixNano: time.Date(2026, 5, 28, 16, 5, 4, 123, time.UTC).UnixNano(),
		Entries:            entries,
	}, TranslationOptions{
		CollectorIP: testFingerprintIP,
	})
	if err != nil {
		t.Fatalf("ProcessSnapshotToDiscoveredDevice() error = %v", err)
	}

	metadata := device.GetMetadata()
	assertMetadata(t, metadata, "local_processes.entry_count", "20")
	assertMetadata(t, metadata, "local_processes.process_count", "20")
	assertMetadata(t, metadata, "local_processes.port_count", "20")
	assertMetadata(t, metadata, "local_processes.container_count", "1")
	assertMetadata(t, metadata, "local_processes.protocols", "tcp")
	assertMetadata(t, metadata, "local_processes.tcp_port_count", "20")

	for _, value := range metadata {
		for _, unexpected := range []string{"redacted", "container-abc123", `"entries"`} {
			if strings.Contains(value, unexpected) {
				t.Fatalf("process snapshot metadata leaked detailed payload %q: %#v", unexpected, metadata)
			}
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

func TestProcessSnapshotToDiscoveredDeviceValidation(t *testing.T) {
	tests := []struct {
		name     string
		snapshot *netprobepb.ProcessSnapshot
		opts     TranslationOptions
		want     error
	}{
		{name: "nil", snapshot: nil, opts: TranslationOptions{CollectorIP: testFingerprintIP}, want: ErrNilProcessSnapshot},
		{name: "missing collector", snapshot: &netprobepb.ProcessSnapshot{}, opts: TranslationOptions{}, want: ErrProcessSnapshotMissing},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := ProcessSnapshotToDiscoveredDevice(tt.snapshot, tt.opts)
			if !errors.Is(err, tt.want) {
				t.Fatalf("ProcessSnapshotToDiscoveredDevice() error = %v, want %v", err, tt.want)
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
