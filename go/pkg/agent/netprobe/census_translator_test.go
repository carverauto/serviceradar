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

	"github.com/carverauto/serviceradar/go/pkg/models"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func censusObservation(mac, ip string) *netprobepb.DeviceCensusObservation {
	return &netprobepb.DeviceCensusObservation{
		Mac:               mac,
		Ip:                ip,
		InterfaceIndex:    2,
		Kind:              netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_ARP_REPLY,
		FirstSeenUnixNano: 1_700_000_000_000_000_000,
		LastSeenUnixNano:  1_700_000_060_000_000_000,
	}
}

func censusSnapshotOf(observations ...*netprobepb.DeviceCensusObservation) *netprobepb.DeviceCensusSnapshot {
	return &netprobepb.DeviceCensusSnapshot{
		Observations:  observations,
		SnapshotId:    "eth0-123-4",
		InterfaceName: "eth0",
		Complete:      true,
		ChunkCount:    1,
	}
}

func censusOpts() TranslationOptions {
	return TranslationOptions{AgentID: "agent-1", GatewayID: "gw-1", CollectorIP: "10.0.0.9"}
}

func TestCensusTranslatorEmitsTheSourceStringCoreMatchesOn(t *testing.T) {
	t.Parallel()

	// This exact string is what SourcePolicy.passive_census_source?/1 keys on.
	// If it drifts, the MAC guardrail silently stops applying and randomized
	// MACs start anchoring canonical devices -- a failure with no error.
	devices, stats := CensusSnapshotToDiscoveredDevices(
		censusSnapshotOf(censusObservation("aa:bb:cc:dd:ee:01", "192.168.1.10")),
		censusOpts(),
	)

	require.Len(t, devices, 1)
	assert.Equal(t, 1, stats.Devices)
	metadata := devices[0].GetMetadata()
	assert.Equal(t, "netprobe-census", metadata["source"])
	assert.Equal(t, "netprobe-census", string(models.DiscoverySourceNetprobeCensus))
	assert.Equal(t, "netprobe_census", metadata["identity_source"])
}

func TestCensusTranslatorPutsTheMACInsideMetadataNotOnlyOnTheDevice(t *testing.T) {
	t.Parallel()

	// SourcePolicy.census_anchorable_mac?/1 reads metadata["mac"]. A top-level
	// Mac field alone leaves that lookup nil, which fails CLOSED -- safe, but
	// it would silently stop every census device from anchoring anything.
	devices, _ := CensusSnapshotToDiscoveredDevices(
		censusSnapshotOf(censusObservation("aa:bb:cc:dd:ee:01", "192.168.1.10")),
		censusOpts(),
	)

	require.Len(t, devices, 1)
	assert.Equal(t, "aa:bb:cc:dd:ee:01", devices[0].GetMac(), "top-level MAC for the device record")
	assert.Equal(t, "aa:bb:cc:dd:ee:01", devices[0].GetMetadata()["mac"], "metadata MAC for the policy lookup")
}

func TestCensusTranslatorDropsOffSegmentSightings(t *testing.T) {
	t.Parallel()

	// An off-segment address arrives with the ROUTER's source MAC. Emitting it
	// binds a remote host to the gateway's hardware, collapsing every remote
	// address onto one device -- the over-merge failure.
	offSegment := censusObservation("aa:bb:cc:dd:ee:02", "10.9.9.9")
	offSegment.OffSegment = true

	devices, stats := CensusSnapshotToDiscoveredDevices(
		censusSnapshotOf(
			censusObservation("aa:bb:cc:dd:ee:01", "192.168.1.10"),
			offSegment,
		),
		censusOpts(),
	)

	require.Len(t, devices, 1)
	assert.Equal(t, "192.168.1.10", devices[0].GetIp())
	assert.Equal(t, 1, stats.SkippedOffSegment)
	assert.Equal(t, 2, stats.Observations, "the skip must still be counted, not invisible")
}

func TestCensusTranslatorEmitsRandomizedMACsAndFlagsThem(t *testing.T) {
	t.Parallel()

	// A randomized MAC is real presence evidence -- it is exactly the
	// short-lived phone the census exists to see. It is emitted; core refuses
	// to let it ANCHOR a canonical device. Dropping it here would defeat the
	// feature; anchoring it would mint a device per rotation.
	randomized := censusObservation("02:11:22:33:44:55", "192.168.1.50")
	randomized.RandomizedMac = true

	devices, stats := CensusSnapshotToDiscoveredDevices(censusSnapshotOf(randomized), censusOpts())

	require.Len(t, devices, 1)
	assert.Equal(t, 1, stats.RandomizedMAC)
	assert.Equal(t, "true", devices[0].GetMetadata()["device_census.randomized_mac"])
	assert.Equal(t, "02:11:22:33:44:55", devices[0].GetMetadata()["mac"],
		"core must still receive the MAC so it can make the anchoring decision itself")
}

func TestCensusTranslatorKeepsAnAddresslessProbeWithoutInventingAnAlias(t *testing.T) {
	t.Parallel()

	// An RFC 5227 probe is the EARLIEST possible sighting of a joining device,
	// which is the whole point of a passive census. It has a MAC and no address
	// yet, so it must not carry an ip alias claiming a binding it never made.
	devices, stats := CensusSnapshotToDiscoveredDevices(
		censusSnapshotOf(censusObservation("aa:bb:cc:dd:ee:03", "")),
		censusOpts(),
	)

	require.Len(t, devices, 1)
	assert.Equal(t, 1, stats.Addressless)
	assert.Empty(t, devices[0].GetIp())
	assert.Equal(t, "aa:bb:cc:dd:ee:03", devices[0].GetMac())

	metadata := devices[0].GetMetadata()
	assert.NotContains(t, metadata, "_alias_last_seen_ip")
	assert.NotContains(t, metadata, "ip_alias:")
}

func TestCensusTranslatorSkipsAnObservationWithNoMAC(t *testing.T) {
	t.Parallel()

	devices, stats := CensusSnapshotToDiscoveredDevices(
		censusSnapshotOf(censusObservation("  ", "192.168.1.10")),
		censusOpts(),
	)

	assert.Empty(t, devices)
	assert.Equal(t, 1, stats.SkippedNoMAC)
}

func TestCensusTranslatorRefusesAnIncompleteSnapshot(t *testing.T) {
	t.Parallel()

	// Applying a fragment reads as "every device in the missing chunks has left
	// the segment". Reassembly happens before this point; anything arriving
	// here still marked incomplete is a bug, and must produce nothing.
	snapshot := censusSnapshotOf(censusObservation("aa:bb:cc:dd:ee:01", "192.168.1.10"))
	snapshot.Complete = false
	snapshot.ChunkCount = 3

	devices, stats := CensusSnapshotToDiscoveredDevices(snapshot, censusOpts())

	assert.Nil(t, devices)
	assert.Zero(t, stats.Devices)
	assert.Zero(t, stats.Observations)
}

func TestCensusTranslatorDoesNotAttributeDevicesToTheCollector(t *testing.T) {
	t.Parallel()

	// The regression this translator exists to avoid: the process-snapshot
	// translator hardcodes opts.CollectorIP, so reusing it would give every
	// device on the segment the observing host's address.
	devices, _ := CensusSnapshotToDiscoveredDevices(
		censusSnapshotOf(
			censusObservation("aa:bb:cc:dd:ee:01", "192.168.1.10"),
			censusObservation("aa:bb:cc:dd:ee:02", "192.168.1.11"),
		),
		censusOpts(),
	)

	require.Len(t, devices, 2)
	for _, device := range devices {
		assert.NotEqual(t, "10.0.0.9", device.GetIp(), "collector IP must never be the device IP")
	}
	assert.Equal(t, "192.168.1.10", devices[0].GetIp())
	assert.Equal(t, "192.168.1.11", devices[1].GetIp())
}

func TestCensusTranslatorHandlesNil(t *testing.T) {
	t.Parallel()

	devices, stats := CensusSnapshotToDiscoveredDevices(nil, censusOpts())
	assert.Nil(t, devices)
	assert.Zero(t, stats.Observations)
}
