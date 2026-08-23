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
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Golden fixtures pinning what the CURRENT Go translators produce.
//
// These exist for one reason: refactor-netprobe-onto-generic-addon-contract
// moves device-update construction out of the agent and into core, next to
// SourcePolicy and DIRE. That move is only safe if the Elixir decoders produce
// the same maps the Go translators produce today, and after the Go code is
// deleted there is nothing left to compare against. So the comparison is
// captured first, from the real translators, before anything is removed.
//
// The corpus is chosen to cover the DECISION SPACE, not to look realistic: every
// skip rule, every flag, every tri-state. A fixture set of ten ordinary devices
// would pin almost nothing, because the branches are where a port goes wrong.
// The shapes are drawn from what a live collector actually emits (alma-test01,
// 2026-08-23) -- addressless ARP probes, IPv6 link-local and global on one MAC,
// mDNS devices announcing no services, truncated payloads -- but every value is
// SYNTHESIZED. This repository is public and a real capture carries real MACs.
//
// Regenerating, after a DELIBERATE behavior change:
//
//	UPDATE_DISCOVERY_GOLDEN=1 go test ./go/pkg/agent/netprobe/ -run TestDiscoveryGolden
//
// and commit the result. An accidental change fails the test instead.
//
// An environment variable rather than a `-update` flag: a package-level
// flag.Bool is a global (gochecknoglobals), and under `bazel test` an env var
// is reachable with --test_env while a custom test flag is not.
const (
	goldenDir       = "testdata/discovery_golden"
	updateGoldenEnv = "UPDATE_DISCOVERY_GOLDEN"
)

func updatingGolden() bool {
	return os.Getenv(updateGoldenEnv) != ""
}

// goldenDevice is the translator's output as a stable contract, rather than
// whatever protojson happens to emit for DiscoveredDevice this release.
//
// The metadata map is reproduced verbatim, INCLUDING the agent_id, gateway_id
// and source keys the translator writes into it from TranslationOptions. That
// is what the translator does today, so that is what the fixture pins.
//
// When this construction moves to core, those three come from a different
// place: agent_id and gateway_id from the gateway-attested status metadata, and
// source from the schema registry -- never from the payload. So the Elixir
// comparison substitutes them rather than expecting the decoder to invent
// "agent-1". Every other key must match byte for byte.
type goldenDevice struct {
	IP       string            `json:"ip"`
	MAC      string            `json:"mac"`
	Metadata map[string]string `json:"metadata"`
}

type goldenCase struct {
	Devices []goldenDevice `json:"devices"`
	Stats   map[string]int `json:"stats"`
}

func goldenOpts() TranslationOptions {
	return TranslationOptions{AgentID: "agent-1", GatewayID: "gw-1", CollectorIP: "10.0.0.9"}
}

func toGolden(devices []*discoverypb.DiscoveredDevice) []goldenDevice {
	out := make([]goldenDevice, 0, len(devices))
	for _, d := range devices {
		out = append(out, goldenDevice{IP: d.GetIp(), MAC: d.GetMac(), Metadata: d.GetMetadata()})
	}

	return out
}

func assertGolden(t *testing.T, name string, got goldenCase) {
	t.Helper()

	path := filepath.Join(goldenDir, name+".json")

	// Indented and newline-terminated so the committed fixture is reviewable in
	// a diff -- these are read by humans deciding whether a behavior change was
	// intended, not only by the test.
	encoded, err := json.MarshalIndent(got, "", "  ")
	require.NoError(t, err)
	encoded = append(encoded, '\n')

	if updatingGolden() {
		require.NoError(t, os.MkdirAll(goldenDir, 0o755))
		require.NoError(t, os.WriteFile(path, encoded, 0o644))

		return
	}

	want, err := os.ReadFile(path)
	require.NoError(t, err,
		"missing golden fixture %s; set %s=1 to create it", path, updateGoldenEnv)

	assert.JSONEq(t, string(want), string(encoded),
		"translator output changed for %q. If deliberate, rerun with %s=1 and explain the change "+
			"in the commit -- this fixture is the contract the Elixir decoder must reproduce.",
		name, updateGoldenEnv)
}

func TestDiscoveryGoldenCensus(t *testing.T) {
	obs := func(mac, ip string, kind netprobepb.DeviceCensusKind, mutate func(*netprobepb.DeviceCensusObservation)) *netprobepb.DeviceCensusObservation {
		o := &netprobepb.DeviceCensusObservation{
			Mac:               mac,
			Ip:                ip,
			InterfaceIndex:    2,
			Kind:              kind,
			FirstSeenUnixNano: 1_700_000_000_000_000_000,
			LastSeenUnixNano:  1_700_000_060_000_000_000,
		}
		if mutate != nil {
			mutate(o)
		}

		return o
	}

	cases := map[string][]*netprobepb.DeviceCensusObservation{
		// An ordinary IPv4 ARP reply: the baseline every other case deviates from.
		"arp_reply_ipv4": {
			obs("a8:bb:cc:00:00:01", "192.168.1.10", netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_ARP_REPLY, nil),
		},
		// One MAC with link-local AND global IPv6, which is the common real shape
		// and the one most likely to be collapsed wrongly by a reimplementation.
		"ipv6_ndp_link_local_and_global": {
			obs("a8:bb:cc:00:00:02", "fe80::aabb:ccff:fe00:0002", netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_IPV6_NDP, nil),
			obs("a8:bb:cc:00:00:02", "2001:db8:85a3::8a2e:370:7334", netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_IPV6_NDP, nil),
		},
		// An ARP probe carries no sender IP. The device is real; the address is
		// not yet claimed, so nothing may be bound to it.
		"arp_probe_addressless": {
			obs("a8:bb:cc:00:00:03", "", netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_ARP_REQUEST, nil),
		},
		// A locally administered MAC: iOS/Android rotate these per SSID, so one
		// must never anchor a canonical device.
		"randomized_mac": {
			obs("aa:bb:cc:00:00:04", "192.168.1.11", netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_ARP_REPLY,
				func(o *netprobepb.DeviceCensusObservation) { o.RandomizedMac = true }),
		},
		// A router's MAC answering for an address beyond the segment. Binding it
		// would merge every off-segment host onto the router.
		"off_segment": {
			obs("a8:bb:cc:00:00:05", "203.0.113.7", netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_ARP_REPLY,
				func(o *netprobepb.DeviceCensusObservation) { o.OffSegment = true }),
		},
		"no_mac": {
			obs("   ", "192.168.1.12", netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_ARP_REPLY, nil),
		},
		// A MAC that LOOKS locally administered but carries no flag. The
		// translator trusts netprobe's determination and does not re-derive it
		// from the address -- pinned here because a reimplementation elsewhere
		// would be tempted to check the U/L bit itself and would then disagree
		// with the producer about which devices may anchor.
		"randomized_flag_not_derived_from_mac": {
			obs("aa:bb:cc:00:00:06", "192.168.1.13", netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_ARP_REPLY, nil),
		},
	}

	for name, observations := range cases {
		t.Run(name, func(t *testing.T) {
			snapshot := &netprobepb.DeviceCensusSnapshot{
				Observations:        observations,
				SnapshotId:          "ens18-1700000000-1",
				InterfaceName:       "ens18",
				GeneratedAtUnixNano: 1_700_000_060_000_000_000,
				Complete:            true,
				ChunkCount:          1,
			}

			devices, stats := CensusSnapshotToDiscoveredDevices(snapshot, goldenOpts())

			assertGolden(t, "census_"+name, goldenCase{
				Devices: toGolden(devices),
				Stats: map[string]int{
					"observations":        stats.Observations,
					"devices":             stats.Devices,
					"skipped_no_mac":      stats.SkippedNoMAC,
					"skipped_off_segment": stats.SkippedOffSegment,
					"randomized_mac":      stats.RandomizedMAC,
					"addressless":         stats.Addressless,
				},
			})
		})
	}
}

func TestDiscoveryGoldenMdns(t *testing.T) {
	cases := map[string]*netprobepb.MdnsDevice{
		"single_model": {
			Mac:               "a8:bb:cc:00:01:01",
			InterfaceIndex:    2,
			ServiceTypes:      []string{"_airplay._tcp", "_raop._tcp"},
			Models:            []string{"SyntheticTV1,1"},
			FirstSeenUnixNano: 1_700_000_000_000_000_000,
			LastSeenUnixNano:  1_700_000_060_000_000_000,
		},
		// The case the whole mDNS design turns on: one MAC advertising two
		// products has not said which it is, so no model may be asserted.
		"ambiguous_model": {
			Mac:               "a8:bb:cc:00:01:02",
			InterfaceIndex:    2,
			ServiceTypes:      []string{"_airplay._tcp"},
			Models:            []string{"SyntheticSpeaker5,1", "SyntheticTV6,2"},
			AmbiguousModel:    true,
			FirstSeenUnixNano: 1_700_000_000_000_000_000,
			LastSeenUnixNano:  1_700_000_060_000_000_000,
		},
		// RFC 6763 6.4: "key", "key=" and "key=value" are three states, and
		// collapsing the first two reports something the device never sent.
		"txt_tristate": {
			Mac:            "a8:bb:cc:00:01:03",
			InterfaceIndex: 2,
			ServiceTypes:   []string{"_ipp._tcp"},
			Txt: []*netprobepb.MdnsTxtPair{
				{Key: "md", Value: "", HasValue: false},
				{Key: "am", Value: "", HasValue: true},
				{Key: "ty", Value: "synthetic printer", HasValue: true},
			},
			FirstSeenUnixNano: 1_700_000_000_000_000_000,
			LastSeenUnixNano:  1_700_000_060_000_000_000,
		},
		// Observed live: a device that announced nothing identifying. The census
		// already knows it exists; mDNS has nothing to add.
		"no_evidence": {
			Mac:               "a8:bb:cc:00:01:04",
			InterfaceIndex:    2,
			FirstSeenUnixNano: 1_700_000_000_000_000_000,
			LastSeenUnixNano:  1_700_000_060_000_000_000,
		},
		// Observed live: the payload exceeded the capture cap. Whatever parsed
		// still counts, flagged so core can decline to conclude from a partial
		// TXT record.
		"truncated": {
			Mac:               "a8:bb:cc:00:01:05",
			InterfaceIndex:    2,
			ServiceTypes:      []string{"_ipp._tcp", "_matter._tcp"},
			Truncated:         true,
			FirstSeenUnixNano: 1_700_000_000_000_000_000,
			LastSeenUnixNano:  1_700_000_060_000_000_000,
		},
		"no_mac": {
			Mac:          "  ",
			ServiceTypes: []string{"_airplay._tcp"},
		},
		// An announcement carries an address; mDNS still must not locate the
		// device from it. The fixture proves the IP is dropped.
		"announced_ip_is_not_carried": {
			Mac:               "a8:bb:cc:00:01:06",
			Ip:                "192.168.1.55",
			InterfaceIndex:    2,
			ServiceTypes:      []string{"_googlecast._tcp"},
			FirstSeenUnixNano: 1_700_000_000_000_000_000,
			LastSeenUnixNano:  1_700_000_060_000_000_000,
		},
	}

	for name, device := range cases {
		t.Run(name, func(t *testing.T) {
			snapshot := &netprobepb.MdnsSnapshot{
				Devices:             []*netprobepb.MdnsDevice{device},
				SnapshotId:          "ens18-1700000000-7",
				InterfaceName:       "ens18",
				GeneratedAtUnixNano: 1_700_000_060_000_000_000,
				Complete:            true,
				ChunkCount:          1,
			}

			devices, stats := MdnsSnapshotToDiscoveredDevices(snapshot, goldenOpts())

			assertGolden(t, "mdns_"+name, goldenCase{
				Devices: toGolden(devices),
				Stats: map[string]int{
					"devices":             stats.Devices,
					"emitted":             stats.Emitted,
					"skipped_no_mac":      stats.SkippedNoMAC,
					"skipped_no_evidence": stats.SkippedNoEvidence,
					"ambiguous":           stats.Ambiguous,
					"truncated":           stats.Truncated,
				},
			})
		})
	}
}
