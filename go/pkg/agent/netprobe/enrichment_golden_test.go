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
	"testing"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Golden fixtures pinning what the CURRENT Go fingerprint/DPI/process translators
// produce.
//
// Same reason as the census/mDNS fixtures before them: task 5.4 of
// refactor-netprobe-onto-generic-addon-contract moves device-update construction
// out of the agent and into core, and that move is only safe if the Elixir
// decoders produce the same maps these translators produce today. After the Go
// code is deleted there is nothing left to compare against, so the comparison is
// captured FIRST, from the real translators.
//
// The corpus covers the DECISION SPACE, not realistic traffic: every evidence
// arm, every skip rule, the sweep-active/passive split, the DPI endpoint
// selection, and the empty/zero edges. Ten ordinary fingerprints would pin almost
// nothing, because the branches are where a port goes wrong.
//
// Every value is SYNTHESIZED. This repository is public and a real capture
// carries real addresses and real software versions.
//
// Regenerating, after a DELIBERATE behavior change:
//
//	UPDATE_ENRICHMENT_GOLDEN=1 go test ./go/pkg/agent/netprobe/ -run TestEnrichmentGolden
const (
	enrichmentGoldenDir = "testdata/enrichment_golden"
	updateEnrichmentEnv = "UPDATE_ENRICHMENT_GOLDEN"
)

func enrichmentOpts() TranslationOptions {
	return TranslationOptions{
		AgentID:     "agent-synthetic-1",
		GatewayID:   "gateway-synthetic-1",
		CollectorIP: "10.20.30.40",
	}
}

func TestEnrichmentGoldenFingerprint(t *testing.T) {
	cases := []struct {
		name  string
		event *netprobepb.FingerprintEvent
	}{
		{
			name: "tcp_passive_full",
			event: &netprobepb.FingerprintEvent{
				Ip:                 "10.20.30.41",
				ProfileId:          "linux-hosts",
				InterfaceName:      "eth0",
				ObservedAtUnixNano: 1_787_500_000_000_000_000,
				Evidence: &netprobepb.FingerprintEvent_Tcp{Tcp: &netprobepb.TcpFingerprint{
					Signature:     "64240:64:1:60:M1460,S,T,N,W7",
					OsFamily:      "linux",
					OsName:        "Linux 5.x",
					Confidence:    0.86,
					Ttl:           64,
					Mss:           1460,
					WindowSize:    "64240",
					WindowScale:   7,
					IpVersion:     "4",
					PayloadClass:  "syn",
					OptionsLayout: []string{"mss", "sok", "ts"},
					Quirks:        []string{"df"},
				}},
			},
		},
		{
			// The sweep-active split: a different source AND a different metadata
			// prefix, and profile_id is suppressed because it IS the sentinel.
			name: "tcp_sweep_active",
			event: &netprobepb.FingerprintEvent{
				Ip:                 "10.20.30.42",
				ProfileId:          "sweep_active",
				ObservedAtUnixNano: 1_787_500_000_000_000_000,
				Evidence: &netprobepb.FingerprintEvent_Tcp{Tcp: &netprobepb.TcpFingerprint{
					Signature: "s", OsFamily: "linux", Confidence: 0.5,
				}},
			},
		},
		{
			// Zero observed_at: the timestamp keys drop out and ip_alias goes empty.
			name: "tcp_no_observed_at",
			event: &netprobepb.FingerprintEvent{
				Ip: "10.20.30.43",
				Evidence: &netprobepb.FingerprintEvent_Tcp{Tcp: &netprobepb.TcpFingerprint{
					Signature: "s",
				}},
			},
		},
		{
			name: "tls_sni_redaction",
			event: &netprobepb.FingerprintEvent{
				Ip:                 "10.20.30.44",
				ObservedAtUnixNano: 1_787_500_000_000_000_000,
				Evidence: &netprobepb.FingerprintEvent_Tls{Tls: &netprobepb.TlsFingerprint{
					Ja4: "t13d1516h2_synthetic", Ja4S: "t130200_synthetic", SniRedacted: "not-a-real-host",
				}},
			},
		},
		{
			name: "http_headers",
			event: &netprobepb.FingerprintEvent{
				Ip:                 "10.20.30.45",
				ObservedAtUnixNano: 1_787_500_000_000_000_000,
				Evidence: &netprobepb.FingerprintEvent_Http{Http: &netprobepb.HttpFingerprint{
					UserAgent: "synthetic-agent/1.0", Server: "synthetic-server/2.0", AcceptLanguage: "en",
				}},
			},
		},
		{
			name: "license_clean_with_os_and_recog",
			event: &netprobepb.FingerprintEvent{
				Ip:                 "10.20.30.46",
				ObservedAtUnixNano: 1_787_500_000_000_000_000,
				Evidence: &netprobepb.FingerprintEvent_LicenseClean{
					LicenseClean: &netprobepb.LicenseCleanFingerprint{
						OsMatch: &netprobepb.OsMatch{
							Name: "Synthetic OS", VersionRange: "1.x", OsFamily: "synthetic", Confidence: 0.75,
						},
						RecogHttp: &netprobepb.RecogFingerprintMatch{
							Product: "synthetic-httpd", Version: "1.2", OsFamily: "synthetic",
						},
						RecogSsh: &netprobepb.RecogFingerprintMatch{
							Product: "synthetic-sshd", Version: "9.9",
						},
					},
				},
			},
		},
		{
			// The arm is set but carries nothing. This is what an evidence-free
			// license_clean looks like ON THE WIRE -- a nil inner pointer cannot
			// be encoded, it decodes back as an empty message -- so this is the
			// shape a decoder will actually meet. It still emits a device, with
			// the protocol key and no detail keys at all.
			name: "license_clean_empty_inner",
			event: &netprobepb.FingerprintEvent{
				Ip:                 "10.20.30.47",
				ObservedAtUnixNano: 1_787_500_000_000_000_000,
				Evidence: &netprobepb.FingerprintEvent_LicenseClean{
					LicenseClean: &netprobepb.LicenseCleanFingerprint{},
				},
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			device, err := FingerprintEventToDiscoveredDevice(tc.event, enrichmentOpts())
			require.NoError(t, err)
			assertEnrichmentGolden(t, "fingerprint_"+tc.name, device.GetIp(), device.GetMetadata())
		})
	}
}

func TestEnrichmentGoldenFingerprintSkips(t *testing.T) {
	// The skip rules are behaviour too: a port that emits a device here is wrong
	// in a way no golden of a successful case would catch.
	_, err := FingerprintEventToDiscoveredDevice(nil, enrichmentOpts())
	require.ErrorIs(t, err, ErrNilFingerprintEvent)

	_, err = FingerprintEventToDiscoveredDevice(&netprobepb.FingerprintEvent{Ip: "   "}, enrichmentOpts())
	require.ErrorIs(t, err, ErrFingerprintEventMissing, "a fingerprint with no IP must be dropped")

	require.ErrorIs(t, err, ErrFingerprintEventMissing, "a fingerprint with no evidence must be dropped")

	// An in-memory nil inside a set arm still emits, with NO protocol key. This
	// shape cannot survive a protobuf round trip -- it decodes back as an empty
	// message -- so it is asserted here rather than pinned as a wire fixture.
	nilInner, err := FingerprintEventToDiscoveredDevice(&netprobepb.FingerprintEvent{
		Ip:       "10.20.30.49",
		Evidence: &netprobepb.FingerprintEvent_LicenseClean{LicenseClean: nil},
	}, enrichmentOpts())
	require.NoError(t, err)
	assert.NotContains(t, nilInner.GetMetadata(), "passive_fingerprint.protocol")
}

func TestEnrichmentGoldenDpi(t *testing.T) {
	cases := []struct {
		name  string
		event *netprobepb.DpiEvent
	}{
		{
			// Collector is one endpoint -> the collector's own address wins.
			name: "collector_is_endpoint",
			event: &netprobepb.DpiEvent{
				Protocol: "dns", SourceIp: "10.20.30.40", DestinationIp: "10.20.30.60",
				ObservedAtUnixNano: 1_787_500_000_000_000_000, InterfaceName: "eth0",
			},
		},
		{
			// Collector is neither endpoint -> source wins. This is the arm that
			// used to mint devices for arbitrary peers.
			name: "collector_is_neither_source_wins",
			event: &netprobepb.DpiEvent{
				Protocol: "tls", SourceIp: "10.20.30.61", DestinationIp: "10.20.30.62",
				ObservedAtUnixNano: 1_787_500_000_000_000_000,
			},
		},
		{
			// Collector is the DESTINATION. Go prefers the collector over the
			// source here, which is the one arm core cannot reproduce: the
			// collector's own address is not in the attested metadata, so the
			// producer has to make this choice before it sends the payload.
			name: "collector_is_destination",
			event: &netprobepb.DpiEvent{
				Protocol: "tls", SourceIp: "10.20.30.65", DestinationIp: "10.20.30.40",
				ObservedAtUnixNano: 1_787_500_000_000_000_000,
			},
		},
		{
			name: "no_source_destination_wins",
			event: &netprobepb.DpiEvent{
				Protocol: "http", DestinationIp: "10.20.30.63",
				ObservedAtUnixNano: 1_787_500_000_000_000_000,
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			device, err := DpiEventToDiscoveredDevice(tc.event, enrichmentOpts())
			require.NoError(t, err)
			assertEnrichmentGolden(t, "dpi_"+tc.name, device.GetIp(), device.GetMetadata())
		})
	}

	_, err := DpiEventToDiscoveredDevice(&netprobepb.DpiEvent{SourceIp: "10.20.30.64"}, enrichmentOpts())
	require.ErrorIs(t, err, ErrDPIEventMissing, "DPI with no protocol must be dropped")

	_, err = DpiEventToDiscoveredDevice(&netprobepb.DpiEvent{Protocol: "dns"}, TranslationOptions{})
	require.ErrorIs(t, err, ErrDPIEventMissing, "DPI with no resolvable IP must be dropped")
}

func TestEnrichmentGoldenProcessSnapshot(t *testing.T) {
	snapshot := &netprobepb.ProcessSnapshot{
		Fingerprint:        "synthetic-fingerprint-1",
		ObservedAtUnixNano: 1_787_500_000_000_000_000,
		Entries: []*netprobepb.ProcessSnapshotEntry{
			{LocalIp: "0.0.0.0", LocalPort: 8080, TransportProtocol: "tcp", Pid: 101, Comm: "synthetic-a"},
			{LocalIp: "::", LocalPort: 9090, TransportProtocol: "tcp", Pid: 102, Comm: "synthetic-b", ContainerId: "ctr-synthetic-1"},
			{LocalIp: "0.0.0.0", LocalPort: 53, TransportProtocol: "udp", Pid: 103, Comm: "synthetic-c"},
			nil,
		},
	}

	device, err := ProcessSnapshotToDiscoveredDevice(snapshot, enrichmentOpts())
	require.NoError(t, err)
	assertEnrichmentGolden(t, "process_snapshot", device.GetIp(), device.GetMetadata())

	// The per-entry detail the UI's process-listener table wants is NOT emitted --
	// only these summary scalars are. Pinned so the Elixir decoder's addition of
	// real entries is a visible, deliberate change rather than a silent drift.
	assert.NotContains(t, device.GetMetadata(), "local_processes.entries")

	_, err = ProcessSnapshotToDiscoveredDevice(snapshot, TranslationOptions{})
	require.ErrorIs(t, err, ErrProcessSnapshotMissing, "no collector IP means no subject device")
}

type enrichmentGolden struct {
	IP       string            `json:"ip"`
	Metadata map[string]string `json:"metadata"`
}

func assertEnrichmentGolden(t *testing.T, name, ip string, metadata map[string]string) {
	t.Helper()

	path := filepath.Join(enrichmentGoldenDir, name+".json")
	actual := enrichmentGolden{IP: ip, Metadata: metadata}

	encoded, err := json.MarshalIndent(actual, "", "  ")
	require.NoError(t, err)
	encoded = append(encoded, '\n')

	if os.Getenv(updateEnrichmentEnv) != "" {
		require.NoError(t, os.MkdirAll(enrichmentGoldenDir, 0o755))
		require.NoError(t, os.WriteFile(path, encoded, 0o600))

		return
	}

	want, err := os.ReadFile(path)
	require.NoError(t, err, "missing golden %s; regenerate with %s=1", path, updateEnrichmentEnv)
	assert.JSONEq(t, string(want), string(actual2JSON(t, actual)))
}

func actual2JSON(t *testing.T, value enrichmentGolden) []byte {
	t.Helper()
	encoded, err := json.Marshal(value)
	require.NoError(t, err)

	return encoded
}
