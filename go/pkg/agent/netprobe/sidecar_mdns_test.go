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

func mdnsSnapshotFor(iface string, generatedAt int64, macs ...string) *netprobepb.MdnsSnapshot {
	devices := make([]*netprobepb.MdnsDevice, 0, len(macs))
	for _, mac := range macs {
		devices = append(devices, &netprobepb.MdnsDevice{
			Mac:          mac,
			ServiceTypes: []string{"_airplay._tcp"},
		})
	}

	return &netprobepb.MdnsSnapshot{
		Devices:             devices,
		SnapshotId:          iface + "-m",
		InterfaceName:       iface,
		GeneratedAtUnixNano: generatedAt,
		Complete:            true,
		ChunkCount:          1,
	}
}

func mdnsTestSidecar(t *testing.T) *Sidecar {
	t.Helper()

	return &Sidecar{
		mdnsSnaps: make(chan *netprobepb.MdnsSnapshot, defaultCensusSnapshotBuffer),
	}
}

func TestDrainMdnsSnapshotsKeepsOnlyTheNewestPerInterface(t *testing.T) {
	t.Parallel()

	s := mdnsTestSidecar(t)
	s.mdnsSnaps <- mdnsSnapshotFor("eth0", 100, "aa:bb:cc:dd:ee:01")
	s.mdnsSnaps <- mdnsSnapshotFor("eth0", 200, "aa:bb:cc:dd:ee:02")

	drained := s.DrainMdnsSnapshots(0)

	require.Len(t, drained, 1)
	assert.Equal(t, int64(200), drained[0].GetGeneratedAtUnixNano())
	require.Len(t, drained[0].GetDevices(), 1)
	assert.Equal(t, "aa:bb:cc:dd:ee:02", drained[0].GetDevices()[0].GetMac())
}

func TestDrainMdnsSnapshotsIgnoresAnOutOfOrderOlderSnapshot(t *testing.T) {
	t.Parallel()

	// Nothing between the netprobe ring buffer and this channel guarantees
	// order. Comparing on arrival would let a late-delivered older view
	// overwrite a newer one and resurrect devices that had already aged out.
	s := mdnsTestSidecar(t)
	s.mdnsSnaps <- mdnsSnapshotFor("eth0", 200, "aa:bb:cc:dd:ee:02")
	s.mdnsSnaps <- mdnsSnapshotFor("eth0", 100, "aa:bb:cc:dd:ee:01")

	drained := s.DrainMdnsSnapshots(0)

	require.Len(t, drained, 1)
	assert.Equal(t, int64(200), drained[0].GetGeneratedAtUnixNano())
}

func TestDrainMdnsSnapshotsKeepsEveryInterfaceSeparate(t *testing.T) {
	t.Parallel()

	s := mdnsTestSidecar(t)
	s.mdnsSnaps <- mdnsSnapshotFor("eth0", 100, "aa:bb:cc:dd:ee:01")
	s.mdnsSnaps <- mdnsSnapshotFor("eth1", 100, "aa:bb:cc:dd:ee:02")

	drained := s.DrainMdnsSnapshots(0)

	assert.Len(t, drained, 2, "collapsing across interfaces would hide a whole segment")
}

func TestDrainMdnsSnapshotsReturnsEmptyWhenIdle(t *testing.T) {
	t.Parallel()

	s := mdnsTestSidecar(t)

	assert.Empty(t, s.DrainMdnsSnapshots(0), "an idle drain must not block")
}
