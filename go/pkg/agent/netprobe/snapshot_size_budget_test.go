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
	"fmt"
	"testing"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/proto"
)

// How large a snapshot has to get before it must be split across telemetry
// batches, and how far today's fleet is from that.
//
// This exists because the answer decides whether snapshot reassembly is a
// routine path or a rare one, and because the failure mode when a snapshot
// exceeds the cap is TOTAL SILENCE rather than degradation: the agent's
// telemetry push skips an over-cap batch entirely, with a warning and no
// re-queue. The segments that would hit it first are the largest ones, which
// are exactly the segments a device census matters most for.
//
// The numbers below are measured, not estimated -- the test marshals real proto
// messages and reports bytes. Field widths are the worst realistic case: a
// 17-character MAC and a 39-character IPv6 address, the widest form observed on
// a live collector. Values are synthesized; this repository is public.
const (
	// addon_telemetry's per-batch cap (push_loop_addon_telemetry.go). Repeated
	// rather than imported because that constant is unexported and in another
	// package -- if it changes, this test's premise changes with it, and a
	// mismatch is exactly what should be noticed.
	telemetryBatchCapBytes = 6 * 1024 * 1024

	// The largest census snapshot observed on a live collector over 24h
	// (alma-test01, 2026-08-23: max devices=127 on ens18, typical 101).
	observedFleetMaxCensusDevices = 127
)

func syntheticCensusObservation(i int) *netprobepb.DeviceCensusObservation {
	return &netprobepb.DeviceCensusObservation{
		// Worst realistic widths: full-length MAC and a global IPv6 address.
		Mac:               fmt.Sprintf("aa:bb:cc:%02x:%02x:%02x", i>>16&0xFF, i>>8&0xFF, i&0xFF),
		Ip:                fmt.Sprintf("2001:0db8:85a3:%04x:%04x:8a2e:0370:7334", i>>16&0xFFFF, i&0xFFFF),
		InterfaceIndex:    2,
		Kind:              netprobepb.DeviceCensusKind_DEVICE_CENSUS_KIND_IPV6_NDP,
		FirstSeenUnixNano: 1_700_000_000_000_000_000,
		LastSeenUnixNano:  1_700_000_060_000_000_000,
	}
}

func censusSnapshotOfSize(n int) *netprobepb.DeviceCensusSnapshot {
	observations := make([]*netprobepb.DeviceCensusObservation, 0, n)
	for i := range n {
		observations = append(observations, syntheticCensusObservation(i))
	}

	return &netprobepb.DeviceCensusSnapshot{
		Observations:        observations,
		SnapshotId:          "ens18-1787458539983415066-408",
		InterfaceName:       "ens18",
		GeneratedAtUnixNano: 1_700_000_060_000_000_000,
		Complete:            true,
		ChunkCount:          1,
	}
}

func TestCensusSnapshotSizeAgainstTheTelemetryBatchCap(t *testing.T) {
	t.Parallel()

	// Measure the marginal cost of one observation rather than dividing a
	// single total, so the fixed snapshot header does not skew the per-device
	// figure at small N.
	base := proto.Size(censusSnapshotOfSize(1000))
	wider := proto.Size(censusSnapshotOfSize(2000))
	perObservation := (wider - base) / 1000

	require.Positive(t, perObservation)

	devicesAtCap := telemetryBatchCapBytes / perObservation

	t.Logf("census: %d bytes per observation; ~%d observations fill the %d-byte batch cap",
		perObservation, devicesAtCap, telemetryBatchCapBytes)
	t.Logf("census: largest snapshot observed on a live collector was %d devices (%.4f%% of the cap)",
		observedFleetMaxCensusDevices,
		float64(observedFleetMaxCensusDevices)/float64(devicesAtCap)*100)

	// The load-bearing assertion: a snapshot the size of the largest one really
	// seen is nowhere near the cap. If this ever fails, splitting has stopped
	// being a rare path and the reassembly logic is on the hot path.
	observed := proto.Size(censusSnapshotOfSize(observedFleetMaxCensusDevices))
	assert.Less(t, observed, telemetryBatchCapBytes/100,
		"a fleet-maximum census snapshot now exceeds 1%% of the telemetry batch cap")

	// A segment would need roughly this many L2 bindings on ONE interface before
	// a census snapshot had to be split. Recorded so the order of magnitude is
	// visible rather than folded into a passing test.
	assert.Greater(t, devicesAtCap, 40_000,
		"per-observation size grew enough to change the splitting story")
}

func TestMdnsSnapshotSizeAgainstTheTelemetryBatchCap(t *testing.T) {
	t.Parallel()

	// mDNS devices carry service types and TXT pairs, so they are individually
	// larger than a census observation and the device count that fills a batch
	// is correspondingly lower.
	build := func(n int) *netprobepb.MdnsSnapshot {
		devices := make([]*netprobepb.MdnsDevice, 0, n)
		for i := range n {
			devices = append(devices, &netprobepb.MdnsDevice{
				Mac:            fmt.Sprintf("aa:bb:cc:%02x:%02x:%02x", i>>16&0xFF, i>>8&0xFF, i&0xFF),
				InterfaceIndex: 2,
				// Shapes seen on a live collector: several service types, a
				// model, and a handful of TXT pairs.
				ServiceTypes: []string{"_airplay._tcp", "_raop._tcp", "_companion-link._tcp", "_ipp._tcp"},
				Models:       []string{"SyntheticModel1,1"},
				Txt: []*netprobepb.MdnsTxtPair{
					{Key: "md", Value: "SyntheticModel", HasValue: true},
					{Key: "am", Value: "SyntheticModel1,1", HasValue: true},
					{Key: "ty", Value: "synthetic device", HasValue: true},
				},
				FirstSeenUnixNano: 1_700_000_000_000_000_000,
				LastSeenUnixNano:  1_700_000_060_000_000_000,
			})
		}

		return &netprobepb.MdnsSnapshot{
			Devices:             devices,
			SnapshotId:          "ens18-1787458539983415066-77",
			InterfaceName:       "ens18",
			GeneratedAtUnixNano: 1_700_000_060_000_000_000,
			Complete:            true,
			ChunkCount:          1,
		}
	}

	perDevice := (proto.Size(build(2000)) - proto.Size(build(1000))) / 1000
	require.Positive(t, perDevice)

	devicesAtCap := telemetryBatchCapBytes / perDevice

	t.Logf("mdns: %d bytes per device; ~%d devices fill the %d-byte batch cap",
		perDevice, devicesAtCap, telemetryBatchCapBytes)

	// mDNS only ever describes a subset of a segment -- a device has to announce
	// something to appear at all -- so it is bounded below the census on the
	// same wire. Still far from the cap.
	assert.Greater(t, devicesAtCap, 10_000,
		"per-device size grew enough to change the splitting story")
}
