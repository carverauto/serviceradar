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
	"context"
	"fmt"
	"net"
	"testing"
	"time"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func censusChunk(id string, index, count uint32, complete bool, macs ...string) *netprobepb.DeviceCensusSnapshot {
	observations := make([]*netprobepb.DeviceCensusObservation, 0, len(macs))
	for _, mac := range macs {
		observations = append(observations, &netprobepb.DeviceCensusObservation{Mac: mac})
	}

	return &netprobepb.DeviceCensusSnapshot{
		Observations:        observations,
		SnapshotId:          id,
		InterfaceName:       "eth0",
		GeneratedAtUnixNano: 42,
		Complete:            complete,
		ChunkIndex:          index,
		ChunkCount:          count,
		DroppedSinceLast:    7,
	}
}

func TestCensusAssemblerPassesAnUnchunkedSnapshotStraightThrough(t *testing.T) {
	t.Parallel()

	// The common case by far. Buffering it would add latency and a map entry
	// for nothing.
	a := newCensusAssembler()
	out, reason := a.Offer(censusChunk("eth0-1-1", 0, 1, true, "aa:bb:cc:dd:ee:01"))

	require.NotNil(t, out)
	assert.Empty(t, reason)
	assert.Len(t, out.GetObservations(), 1)
	assert.Zero(t, a.pendingSets(), "a single-chunk snapshot must not be buffered")
}

func TestCensusAssemblerReassemblesInChunkOrderNotArrivalOrder(t *testing.T) {
	t.Parallel()

	// Chunks are written to a socket in order today, but nothing in the
	// contract guarantees the assembler sees them that way, and observation
	// order is what the receiver reads as the segment view.
	a := newCensusAssembler()

	out, _ := a.Offer(censusChunk("eth0-9-3", 2, 3, true, "mac-c"))
	require.Nil(t, out, "must not complete before every chunk arrives")

	out, _ = a.Offer(censusChunk("eth0-9-3", 0, 3, false, "mac-a"))
	require.Nil(t, out)

	out, reason := a.Offer(censusChunk("eth0-9-3", 1, 3, false, "mac-b"))
	require.NotNil(t, out, "the set is complete once all three chunks arrive")
	assert.Empty(t, reason)

	got := make([]string, 0, 3)
	for _, observation := range out.GetObservations() {
		got = append(got, observation.GetMac())
	}
	assert.Equal(t, []string{"mac-a", "mac-b", "mac-c"}, got)

	// The assembled snapshot must look unchunked to everything downstream.
	assert.True(t, out.GetComplete())
	assert.Equal(t, uint32(1), out.GetChunkCount())
	assert.Equal(t, uint32(0), out.GetChunkIndex())
	// dropped_since_last is per-snapshot and replicated onto each chunk;
	// summing would report 21 for three chunks that each said 7.
	assert.Equal(t, uint32(7), out.GetDroppedSinceLast())
	assert.Zero(t, a.pendingSets(), "a completed set must be released")
}

func TestCensusAssemblerNeedsBothTheCountAndTheCompleteFlag(t *testing.T) {
	t.Parallel()

	// Counting chunks alone would accept a set whose last chunk never arrived
	// but which received a duplicate of an earlier one instead.
	a := newCensusAssembler()

	require.Nil(t, firstOf(a.Offer(censusChunk("s", 0, 2, false, "mac-a"))))
	out, _ := a.Offer(censusChunk("s", 0, 2, false, "mac-a"))
	require.Nil(t, out, "a duplicate index must not stand in for the missing chunk")
	assert.Equal(t, 1, a.pendingSets())

	out, _ = a.Offer(censusChunk("s", 1, 2, true, "mac-b"))
	require.NotNil(t, out)
	assert.Len(t, out.GetObservations(), 2)
}

func TestCensusAssemblerTreatsARepeatedChunkAsIdempotent(t *testing.T) {
	t.Parallel()

	a := newCensusAssembler()
	require.Nil(t, firstOf(a.Offer(censusChunk("s", 0, 2, false, "mac-a"))))
	require.Nil(t, firstOf(a.Offer(censusChunk("s", 0, 2, false, "mac-a"))))

	out, _ := a.Offer(censusChunk("s", 1, 2, true, "mac-b"))
	require.NotNil(t, out)
	assert.Len(t, out.GetObservations(), 2, "redelivery must not duplicate observations")
}

func TestCensusAssemblerDiscardsASetWhoseChunkCountChanges(t *testing.T) {
	t.Parallel()

	// Two different snapshots claiming one id, or a corrupted header. Merging
	// them would report devices present or absent from fragments of two
	// different observations, which is worse than reporting nothing.
	a := newCensusAssembler()
	require.Nil(t, firstOf(a.Offer(censusChunk("s", 0, 3, false, "mac-a"))))

	out, reason := a.Offer(censusChunk("s", 1, 2, true, "mac-b"))
	assert.Nil(t, out)
	assert.Equal(t, CensusDropChunkCountChanged, reason)
	assert.Zero(t, a.pendingSets(), "the poisoned set must be dropped, not left to grow")
	assert.Equal(t, uint64(1), a.DroppedCensusChunks()[CensusDropChunkCountChanged])
}

func TestCensusAssemblerRejectsAnOutOfRangeChunkIndex(t *testing.T) {
	t.Parallel()

	a := newCensusAssembler()

	out, reason := a.Offer(censusChunk("s", 5, 3, false, "mac-a"))
	assert.Nil(t, out)
	assert.Equal(t, CensusDropInvalidChunkIndex, reason)

	// chunk_count == 0 on a non-complete chunk names no set it could join.
	out, reason = a.Offer(censusChunk("s", 0, 0, false, "mac-a"))
	assert.Nil(t, out)
	assert.Equal(t, CensusDropInvalidChunkIndex, reason)

	assert.Zero(t, a.pendingSets())
}

func TestCensusAssemblerRefusesAnAbsurdChunkCount(t *testing.T) {
	t.Parallel()

	// One corrupt header must not be able to reserve an enormous map.
	a := newCensusAssembler()

	out, reason := a.Offer(censusChunk("s", 0, censusMaxChunks+1, false, "mac-a"))
	assert.Nil(t, out)
	assert.Equal(t, CensusDropTooManyChunks, reason)
	assert.Zero(t, a.pendingSets())
}

func TestCensusAssemblerExpiresAPartialSetFromADeadNetprobe(t *testing.T) {
	t.Parallel()

	// netprobe dying mid-snapshot leaves chunks nothing will ever complete.
	// Without expiry they sit in the map for the life of the agent.
	now := time.Unix(1_700_000_000, 0)
	a := newCensusAssembler()
	a.now = func() time.Time { return now }

	require.Nil(t, firstOf(a.Offer(censusChunk("dead", 0, 2, false, "mac-a"))))
	require.Equal(t, 1, a.pendingSets())

	now = now.Add(censusPartialTTL + time.Second)
	// Any subsequent offer sweeps expired sets.
	require.Nil(t, firstOf(a.Offer(censusChunk("live", 0, 2, false, "mac-b"))))

	assert.Equal(t, 1, a.pendingSets(), "only the live set should remain")
	assert.Equal(t, uint64(1), a.DroppedCensusChunks()[CensusDropPartialExpired])
}

func TestCensusAssemblerBoundsConcurrentPartialSets(t *testing.T) {
	t.Parallel()

	// A malformed or hostile stream of distinct snapshot ids must not grow the
	// map without limit.
	now := time.Unix(1_700_000_000, 0)
	a := newCensusAssembler()
	a.now = func() time.Time {
		now = now.Add(time.Second)
		return now
	}

	for i := range censusMaxPartialSets + 4 {
		id := fmt.Sprintf("set-%d", i)
		require.Nil(t, firstOf(a.Offer(censusChunk(id, 0, 2, false, "mac"))))
	}

	assert.LessOrEqual(t, a.pendingSets(), censusMaxPartialSets)
	assert.Positive(t, a.DroppedCensusChunks()[CensusDropPartialEvicted])
}

func TestCensusAssemblerIgnoresNil(t *testing.T) {
	t.Parallel()

	a := newCensusAssembler()
	out, reason := a.Offer(nil)
	assert.Nil(t, out)
	assert.Empty(t, reason)
}

func firstOf(snapshot *netprobepb.DeviceCensusSnapshot, _ string) *netprobepb.DeviceCensusSnapshot {
	return snapshot
}

// TestClientReassemblesChunkedCensusSnapshotFromFrames drives the whole client
// path: three frames on the wire become ONE snapshot on the channel.
//
// The assembler unit tests would all pass even if readLoop never dispatched the
// new payload variant, or dispatched it to the wrong stream. This is what
// proves the wiring.
func TestClientReassemblesChunkedCensusSnapshotFromFrames(t *testing.T) {
	t.Parallel()

	serverConn, clientConn := net.Pipe()
	serverDone := make(chan struct{})

	go func() {
		defer close(serverDone)
		defer func() { _ = serverConn.Close() }()

		for _, chunk := range []*netprobepb.DeviceCensusSnapshot{
			censusChunk("eth0-77-3", 0, 3, false, "aa:bb:cc:00:00:01"),
			censusChunk("eth0-77-3", 1, 3, false, "aa:bb:cc:00:00:02"),
			censusChunk("eth0-77-3", 2, 3, true, "aa:bb:cc:00:00:03"),
		} {
			frame := &netprobepb.NetprobeFrame{
				Payload: &netprobepb.NetprobeFrame_DeviceCensusSnapshot{DeviceCensusSnapshot: chunk},
			}
			if err := writeFrame(serverConn, frame); err != nil {
				t.Errorf("write census chunk frame: %v", err)
				return
			}
		}
	}()

	client := NewClient(clientConn, 4)
	defer func() { _ = client.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	select {
	case snapshot := <-client.CensusSnapshots():
		require.NotNil(t, snapshot)
		assert.Equal(t, "eth0-77-3", snapshot.GetSnapshotId())
		assert.True(t, snapshot.GetComplete(), "consumers must never see a fragment")
		assert.Equal(t, uint32(1), snapshot.GetChunkCount())
		require.Len(t, snapshot.GetObservations(), 3)
		assert.Equal(t, "aa:bb:cc:00:00:01", snapshot.GetObservations()[0].GetMac())
		assert.Equal(t, "aa:bb:cc:00:00:03", snapshot.GetObservations()[2].GetMac())
	case <-ctx.Done():
		t.Fatal("timed out waiting for the reassembled census snapshot")
	}

	_ = client.Close()
	<-serverDone
}
