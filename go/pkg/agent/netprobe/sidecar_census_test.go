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

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func censusSnapshotFor(iface string, generatedAt int64, macs ...string) *netprobepb.DeviceCensusSnapshot {
	observations := make([]*netprobepb.DeviceCensusObservation, 0, len(macs))
	for _, mac := range macs {
		observations = append(observations, &netprobepb.DeviceCensusObservation{Mac: mac, Ip: "192.168.1.1"})
	}

	return &netprobepb.DeviceCensusSnapshot{
		Observations:        observations,
		SnapshotId:          iface + "-x",
		InterfaceName:       iface,
		GeneratedAtUnixNano: generatedAt,
		Complete:            true,
		ChunkCount:          1,
	}
}

func censusTestSidecar(t *testing.T) *Sidecar {
	t.Helper()

	return &Sidecar{
		censusSnaps: make(chan *netprobepb.DeviceCensusSnapshot, defaultCensusSnapshotBuffer),
	}
}

func TestDrainCensusSnapshotsKeepsOnlyTheNewestPerInterface(t *testing.T) {
	t.Parallel()

	// Each snapshot is a COMPLETE replacement for the last. Pushing an older
	// view after a newer one resurrects devices that have since aged out, so
	// the drain collapses a backlog instead of replaying it.
	s := censusTestSidecar(t)
	s.censusSnaps <- censusSnapshotFor("eth0", 100, "mac-old")
	s.censusSnaps <- censusSnapshotFor("eth0", 200, "mac-new")

	drained := s.DrainCensusSnapshots(0)

	require.Len(t, drained, 1, "a backlog for one interface collapses to one snapshot")
	assert.Equal(t, int64(200), drained[0].GetGeneratedAtUnixNano())
	assert.Equal(t, "mac-new", drained[0].GetObservations()[0].GetMac())
}

func TestDrainCensusSnapshotsIgnoresAnOutOfOrderOlderSnapshot(t *testing.T) {
	t.Parallel()

	// Ordering is not guaranteed by anything downstream of the channel, and
	// "last one wins" would let a late-delivered stale view overwrite a fresh
	// one. The comparison is on generated_at, not arrival.
	s := censusTestSidecar(t)
	s.censusSnaps <- censusSnapshotFor("eth0", 500, "mac-new")
	s.censusSnaps <- censusSnapshotFor("eth0", 100, "mac-old")

	drained := s.DrainCensusSnapshots(0)

	require.Len(t, drained, 1)
	assert.Equal(t, int64(500), drained[0].GetGeneratedAtUnixNano(),
		"an older snapshot arriving later must not win")
}

func TestDrainCensusSnapshotsKeepsEveryInterfaceSeparate(t *testing.T) {
	t.Parallel()

	// Collapsing is per-interface: two interfaces are two different segments,
	// and one must never supersede the other.
	s := censusTestSidecar(t)
	s.censusSnaps <- censusSnapshotFor("eth0", 100, "mac-a")
	s.censusSnaps <- censusSnapshotFor("eth1", 100, "mac-b")

	drained := s.DrainCensusSnapshots(0)

	require.Len(t, drained, 2)
	interfaces := []string{drained[0].GetInterfaceName(), drained[1].GetInterfaceName()}
	assert.ElementsMatch(t, []string{"eth0", "eth1"}, interfaces)
}

func TestDrainCensusSnapshotsReturnsEmptyWhenIdle(t *testing.T) {
	t.Parallel()

	s := censusTestSidecar(t)
	assert.Empty(t, s.DrainCensusSnapshots(0), "an idle drain must not block")
}
