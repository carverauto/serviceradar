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

// Synthesized, not captured. This repository is public and a real mDNS capture
// carries instance names people chose for their own devices.
func mdnsDevice(mac string, serviceTypes []string, models []string) *netprobepb.MdnsDevice {
	return &netprobepb.MdnsDevice{
		Mac:               mac,
		InterfaceIndex:    2,
		ServiceTypes:      serviceTypes,
		Models:            models,
		AmbiguousModel:    len(models) > 1,
		FirstSeenUnixNano: 1_700_000_000_000_000_000,
		LastSeenUnixNano:  1_700_000_060_000_000_000,
	}
}

func mdnsSnapshotOf(devices ...*netprobepb.MdnsDevice) *netprobepb.MdnsSnapshot {
	return &netprobepb.MdnsSnapshot{
		Devices:       devices,
		SnapshotId:    "eth0-123-7",
		InterfaceName: "eth0",
		Complete:      true,
		ChunkCount:    1,
	}
}

func mdnsOpts() TranslationOptions {
	return TranslationOptions{AgentID: "agent-1", GatewayID: "gw-1", CollectorIP: "10.0.0.9"}
}

func TestMdnsTranslatorEmitsTheSourceStringCoreMatchesOn(t *testing.T) {
	t.Parallel()

	devices, stats := MdnsSnapshotToDiscoveredDevices(
		mdnsSnapshotOf(mdnsDevice("aa:bb:cc:dd:ee:01", []string{"_airplay._tcp"}, nil)),
		mdnsOpts(),
	)

	require.Len(t, devices, 1)
	assert.Equal(t, 1, stats.Emitted)

	metadata := devices[0].GetMetadata()
	assert.Equal(t, "netprobe-mdns", metadata["source"])
	assert.Equal(t, "netprobe-mdns", string(models.DiscoverySourceNetprobeMdns))
	assert.Equal(t, "netprobe_mdns", metadata["identity_source"])
	assert.Equal(t, "aa:bb:cc:dd:ee:01", metadata["mac"])
}

func TestMdnsTranslatorNeverCarriesAnIP(t *testing.T) {
	t.Parallel()

	// mDNS identifies, it does not locate. The A/AAAA record in an announcement
	// is the responder's claim about itself, and this collector does not verify
	// it. An IP here would let core bind an address to a device on the strength
	// of a claim it never checked -- which is how IP squatting starts.
	device := mdnsDevice("aa:bb:cc:dd:ee:01", []string{"_airplay._tcp"}, nil)
	device.Ip = "192.168.1.55"

	devices, _ := MdnsSnapshotToDiscoveredDevices(mdnsSnapshotOf(device), mdnsOpts())

	require.Len(t, devices, 1)
	assert.Empty(t, devices[0].GetIp(), "mDNS records must not carry an IP even when one was announced")
	assert.NotContains(t, devices[0].GetMetadata(), "ip")
}

func TestMdnsTranslatorAssertsAModelOnlyWhenThereIsExactlyOne(t *testing.T) {
	t.Parallel()

	single, _ := MdnsSnapshotToDiscoveredDevices(
		mdnsSnapshotOf(mdnsDevice("aa:bb:cc:dd:ee:01", []string{"_airplay._tcp"}, []string{"B620AP"})),
		mdnsOpts(),
	)
	require.Len(t, single, 1)
	assert.Equal(t, "B620AP", single[0].GetMetadata()["mdns.model"])
	assert.Equal(t, "false", single[0].GetMetadata()["mdns.ambiguous_model"])
}

func TestMdnsTranslatorWithholdsTheModelWhenTheMACSpokeForTwoProducts(t *testing.T) {
	t.Parallel()

	// One MAC advertising both a HomePod and an Apple TV has not told us which
	// it is. Writing either would let core type the device from whichever
	// happened to sort first -- a wrong answer that looks exactly like a right
	// one. Absent is the honest answer, and `mdns.models` keeps the evidence.
	devices, stats := MdnsSnapshotToDiscoveredDevices(
		mdnsSnapshotOf(mdnsDevice(
			"aa:bb:cc:dd:ee:01",
			[]string{"_airplay._tcp"},
			[]string{"AppleTV6,2", "B620AP"},
		)),
		mdnsOpts(),
	)

	require.Len(t, devices, 1)
	assert.Equal(t, 1, stats.Ambiguous)

	metadata := devices[0].GetMetadata()
	assert.NotContains(t, metadata, "mdns.model", "an ambiguous MAC must not assert a single model")
	assert.Equal(t, "AppleTV6,2,B620AP", metadata["mdns.models"])
	assert.Equal(t, "true", metadata["mdns.ambiguous_model"])
}

func TestMdnsTranslatorDistinguishesAValuelessTXTKeyFromAnEmptyValue(t *testing.T) {
	t.Parallel()

	// RFC 6763 6.4: "key" alone, "key=" and "key=value" are three different
	// states. Collapsing the first two would report that a device sent an empty
	// string when it sent no "=" at all.
	device := mdnsDevice("aa:bb:cc:dd:ee:01", []string{"_airplay._tcp"}, nil)
	device.Txt = []*netprobepb.MdnsTxtPair{
		{Key: "md", Value: "", HasValue: false},
		{Key: "am", Value: "", HasValue: true},
		{Key: "ty", Value: "printer", HasValue: true},
	}

	devices, _ := MdnsSnapshotToDiscoveredDevices(mdnsSnapshotOf(device), mdnsOpts())

	require.Len(t, devices, 1)
	metadata := devices[0].GetMetadata()
	assert.Equal(t, "true", metadata["mdns.txt.md"])
	assert.Equal(t, "printer", metadata["mdns.txt.ty"])

	// Checked for PRESENCE first. An empty-value assertion alone would pass
	// just as well if the key had been dropped, which is the opposite of what
	// this test is about.
	emptyValued, present := metadata["mdns.txt.am"]
	assert.True(t, present, `"am=" must be recorded, not dropped`)
	assert.Empty(t, emptyValued)
}

func TestMdnsTranslatorSkipsADeviceThatAnnouncedNothingIdentifying(t *testing.T) {
	t.Parallel()

	// A MAC with no service types and no TXT tells core nothing it does not
	// already have from the census. Sending it costs a write and risks
	// re-stamping provenance on a device no mDNS evidence supports.
	devices, stats := MdnsSnapshotToDiscoveredDevices(
		mdnsSnapshotOf(mdnsDevice("aa:bb:cc:dd:ee:01", nil, nil)),
		mdnsOpts(),
	)

	assert.Empty(t, devices)
	assert.Equal(t, 1, stats.SkippedNoEvidence)
	assert.Equal(t, 0, stats.Emitted)
}

func TestMdnsTranslatorSkipsADeviceWithNoMAC(t *testing.T) {
	t.Parallel()

	devices, stats := MdnsSnapshotToDiscoveredDevices(
		mdnsSnapshotOf(mdnsDevice("  ", []string{"_airplay._tcp"}, nil)),
		mdnsOpts(),
	)

	assert.Empty(t, devices)
	assert.Equal(t, 1, stats.SkippedNoMAC)
}

func TestMdnsTranslatorRefusesAnIncompleteSnapshot(t *testing.T) {
	t.Parallel()

	// Half a snapshot is not a smaller snapshot: the devices it omits are
	// indistinguishable from devices that went quiet.
	snapshot := mdnsSnapshotOf(mdnsDevice("aa:bb:cc:dd:ee:01", []string{"_airplay._tcp"}, nil))
	snapshot.Complete = false
	snapshot.ChunkCount = 2

	devices, stats := MdnsSnapshotToDiscoveredDevices(snapshot, mdnsOpts())

	assert.Empty(t, devices)
	assert.Equal(t, 0, stats.Devices)
}

func TestMdnsTranslatorCountsTruncationWithoutDiscardingTheDevice(t *testing.T) {
	t.Parallel()

	// A truncated payload still yielded whatever parsed before the cap. The
	// flag rides along so core can decline to draw conclusions from a partial
	// TXT record without losing the service types that did arrive.
	device := mdnsDevice("aa:bb:cc:dd:ee:01", []string{"_airplay._tcp"}, nil)
	device.Truncated = true

	devices, stats := MdnsSnapshotToDiscoveredDevices(mdnsSnapshotOf(device), mdnsOpts())

	require.Len(t, devices, 1)
	assert.Equal(t, 1, stats.Truncated)
	assert.Equal(t, "true", devices[0].GetMetadata()["mdns.truncated"])
}

func TestMdnsTranslatorDoesNotAttributeDevicesToTheCollector(t *testing.T) {
	t.Parallel()

	// agent_id names the machine that overheard the announcement. Core's
	// observer_agent_source?/1 is what stops it becoming a device identifier;
	// this asserts the translator does not additionally smuggle the
	// collector's own address in as if it belonged to the device.
	devices, _ := MdnsSnapshotToDiscoveredDevices(
		mdnsSnapshotOf(mdnsDevice("aa:bb:cc:dd:ee:01", []string{"_airplay._tcp"}, nil)),
		mdnsOpts(),
	)

	require.Len(t, devices, 1)
	metadata := devices[0].GetMetadata()
	assert.Equal(t, "agent-1", metadata["agent_id"])
	assert.Equal(t, "gw-1", metadata["gateway_id"])

	for key, value := range metadata {
		assert.NotEqual(t, "10.0.0.9", value, "collector IP leaked into %s", key)
	}
}

func TestMdnsTranslatorHandlesNil(t *testing.T) {
	t.Parallel()

	devices, stats := MdnsSnapshotToDiscoveredDevices(nil, mdnsOpts())

	assert.Empty(t, devices)
	assert.Equal(t, MdnsTranslationStats{}, stats)
}
