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
	"net"
	"testing"
	"time"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func mdnsChunk(id string, index, count uint32, complete bool, macs ...string) *netprobepb.MdnsSnapshot {
	devices := make([]*netprobepb.MdnsDevice, 0, len(macs))
	for _, mac := range macs {
		devices = append(devices, &netprobepb.MdnsDevice{
			Mac:          mac,
			ServiceTypes: []string{"_airplay._tcp"},
			Models:       []string{"B620AP"},
			Txt: []*netprobepb.MdnsTxtPair{
				{Key: "model", Value: "B620AP", HasValue: true},
			},
		})
	}

	return &netprobepb.MdnsSnapshot{
		Devices:             devices,
		SnapshotId:          id,
		InterfaceName:       "eth0",
		GeneratedAtUnixNano: 42,
		Complete:            complete,
		ChunkIndex:          index,
		ChunkCount:          count,
		DroppedSinceLast:    7,
	}
}

func TestMdnsAssemblerPassesAnUnchunkedSnapshotStraightThrough(t *testing.T) {
	t.Parallel()

	a := newMdnsAssembler()
	out, reason := a.Offer(mdnsChunk("eth0-1-1", 0, 1, true, "aa:bb:cc:dd:ee:01"))

	require.NotNil(t, out)
	assert.Empty(t, reason)
	assert.Len(t, out.GetDevices(), 1)
	assert.Zero(t, a.pendingSets(), "a single-chunk snapshot must not be buffered")
}

func TestMdnsAssemblerReassemblesInChunkOrder(t *testing.T) {
	t.Parallel()

	a := newMdnsAssembler()
	require.Nil(t, mdnsFirst(a.Offer(mdnsChunk("s", 2, 3, true, "mac-c"))))
	require.Nil(t, mdnsFirst(a.Offer(mdnsChunk("s", 0, 3, false, "mac-a"))))

	out, reason := a.Offer(mdnsChunk("s", 1, 3, false, "mac-b"))
	require.NotNil(t, out)
	assert.Empty(t, reason)

	got := make([]string, 0, 3)
	for _, device := range out.GetDevices() {
		got = append(got, device.GetMac())
	}
	assert.Equal(t, []string{"mac-a", "mac-b", "mac-c"}, got, "arrival order must not leak through")

	assert.True(t, out.GetComplete())
	assert.Equal(t, uint32(1), out.GetChunkCount())
	// Per-snapshot and replicated onto each chunk; summing would report 21.
	assert.Equal(t, uint32(7), out.GetDroppedSinceLast())
}

func TestMdnsAssemblerDiscardsASetWhoseChunkCountChanges(t *testing.T) {
	t.Parallel()

	a := newMdnsAssembler()
	require.Nil(t, mdnsFirst(a.Offer(mdnsChunk("s", 0, 3, false, "mac-a"))))

	out, reason := a.Offer(mdnsChunk("s", 1, 2, true, "mac-b"))
	assert.Nil(t, out)
	assert.Equal(t, ChunkDropChunkCountChanged, reason)
	assert.Zero(t, a.pendingSets())
}

func TestMdnsAssemblerPreservesTheTxtTristate(t *testing.T) {
	t.Parallel()

	// The whole reason the wire uses pairs instead of a map. If reassembly
	// flattened these, the distinction the parser and proto both preserve would
	// die at the last hop before core.
	a := newMdnsAssembler()
	chunk := mdnsChunk("s", 0, 1, true, "mac-a")
	chunk.Devices[0].Txt = []*netprobepb.MdnsTxtPair{
		{Key: "model", Value: "B620AP", HasValue: true},
		{Key: "ty", Value: "", HasValue: false},
		{Key: "md", Value: "", HasValue: true},
	}

	out, _ := a.Offer(chunk)
	require.NotNil(t, out)
	pairs := out.GetDevices()[0].GetTxt()
	require.Len(t, pairs, 3)
	assert.True(t, pairs[0].GetHasValue())
	assert.False(t, pairs[1].GetHasValue(), "present-with-no-value must survive")
	assert.True(t, pairs[2].GetHasValue(), "present-with-empty-value is a different claim")
}

func TestMdnsAssemblerCarriesAmbiguityThrough(t *testing.T) {
	t.Parallel()

	// Core refuses to assign a type when this is set. If reassembly dropped it,
	// core would type an ambiguous device from whichever model sorts first.
	a := newMdnsAssembler()
	chunk := mdnsChunk("s", 0, 1, true, "mac-a")
	chunk.Devices[0].Models = []string{"B620AP", "J255AP"}
	chunk.Devices[0].AmbiguousModel = true

	out, _ := a.Offer(chunk)
	require.NotNil(t, out)
	assert.True(t, out.GetDevices()[0].GetAmbiguousModel())
	assert.Len(t, out.GetDevices()[0].GetModels(), 2)
}

func TestClientReassemblesChunkedMdnsSnapshotFromFrames(t *testing.T) {
	t.Parallel()

	serverConn, clientConn := net.Pipe()
	serverDone := make(chan struct{})

	go func() {
		defer close(serverDone)
		defer func() { _ = serverConn.Close() }()

		for _, chunk := range []*netprobepb.MdnsSnapshot{
			mdnsChunk("eth0-77-3", 0, 3, false, "aa:bb:cc:00:00:01"),
			mdnsChunk("eth0-77-3", 1, 3, false, "aa:bb:cc:00:00:02"),
			mdnsChunk("eth0-77-3", 2, 3, true, "aa:bb:cc:00:00:03"),
		} {
			frame := &netprobepb.NetprobeFrame{
				Payload: &netprobepb.NetprobeFrame_MdnsSnapshot{MdnsSnapshot: chunk},
			}
			if err := writeFrame(serverConn, frame); err != nil {
				t.Errorf("write mdns chunk frame: %v", err)
				return
			}
		}
	}()

	client := NewClient(clientConn, 4)
	defer func() { _ = client.Close() }()

	// Bounded: without this, a missing readLoop branch blocks forever instead
	// of failing, and a hanging test reports nothing.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	select {
	case snapshot := <-client.MdnsSnapshots():
		require.NotNil(t, snapshot)
		assert.Equal(t, "eth0-77-3", snapshot.GetSnapshotId())
		assert.True(t, snapshot.GetComplete(), "consumers must never see a fragment")
		require.Len(t, snapshot.GetDevices(), 3)
		assert.Equal(t, "aa:bb:cc:00:00:01", snapshot.GetDevices()[0].GetMac())
	case <-ctx.Done():
		t.Fatal("timed out waiting for the reassembled mdns snapshot; is readLoop wired?")
	}

	_ = client.Close()
	<-serverDone
}

func mdnsFirst(snapshot *netprobepb.MdnsSnapshot, _ string) *netprobepb.MdnsSnapshot {
	return snapshot
}
