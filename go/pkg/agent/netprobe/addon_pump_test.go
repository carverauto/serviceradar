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
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"github.com/rs/zerolog"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
)

// fakeAddonService streams a fixed set of batches and then holds the stream open
// (or closes it, when closeAfterSend is set) so a test can observe both the
// steady state and the fallback transition.
type fakeAddonService struct {
	addonpb.UnimplementedAddonServiceServer

	batches        []*addonpb.TelemetryBatch
	closeAfterSend bool
	released       chan struct{}
}

func (f *fakeAddonService) StreamTelemetry(
	_ *addonpb.StreamTelemetryRequest,
	stream addonpb.AddonService_StreamTelemetryServer,
) error {
	for _, batch := range f.batches {
		if err := stream.Send(batch); err != nil {
			return err
		}
	}
	if f.closeAfterSend {
		return nil
	}
	<-stream.Context().Done()

	return stream.Context().Err()
}

func startFakeAddonService(t *testing.T, socketPath string, svc *fakeAddonService) {
	t.Helper()

	listener, err := net.Listen("unix", socketPath)
	require.NoError(t, err)

	server := grpc.NewServer()
	addonpb.RegisterAddonServiceServer(server, svc)

	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)
}

// shortSocketPath keeps the socket under the 104-byte sun_path limit. t.TempDir()
// on macOS returns a ~100-character path, which bind(2) rejects outright.
func shortSocketPath(t *testing.T) string {
	t.Helper()

	dir, err := os.MkdirTemp("/tmp", "np")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })

	return filepath.Join(dir, "addon.sock")
}

func pumpTestSidecar() *Sidecar {
	return &Sidecar{
		censusSnaps: make(chan *netprobepb.DeviceCensusSnapshot, defaultCensusSnapshotBuffer),
		mdnsSnaps:   make(chan *netprobepb.MdnsSnapshot, defaultCensusSnapshotBuffer),
	}
}

func newTestPump(t *testing.T, socketPath string, sc *Sidecar, sink func(*addonpb.TelemetryBatch)) *AddonPump {
	t.Helper()

	pump, err := NewAddonPump(AddonPumpConfig{
		SocketPath: socketPath,
		Sink:       sink,
		Sidecar:    sc,
		Logger:     zerolog.Nop(),
		MinBackoff: 10 * time.Millisecond,
		MaxBackoff: 20 * time.Millisecond,
	})
	require.NoError(t, err)

	return pump
}

// A batch the agent has no decoder for. If the pump ever grows an inspection
// step, this is what breaks: the whole point of the contract is that a new
// payload schema costs zero agent changes.
func opaqueBatch() *addonpb.TelemetryBatch {
	return &addonpb.TelemetryBatch{
		Records: []*addonpb.TelemetryRecord{{
			PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1,
			Payload:     []byte{0xDE, 0xAD, 0xBE, 0xEF},
		}},
	}
}

func TestAddonPumpForwardsBatchesWithoutInspectingThem(t *testing.T) {
	socketPath := shortSocketPath(t)
	startFakeAddonService(t, socketPath, &fakeAddonService{batches: []*addonpb.TelemetryBatch{opaqueBatch()}})

	var mu sync.Mutex
	received := make([]*addonpb.TelemetryBatch, 0, 1)
	done := make(chan struct{})

	sc := pumpTestSidecar()
	pump := newTestPump(t, socketPath, sc, func(batch *addonpb.TelemetryBatch) {
		mu.Lock()
		defer mu.Unlock()
		received = append(received, batch)
		if len(received) == 1 {
			close(done)
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	go pump.Run(ctx)

	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("pump never forwarded a batch")
	}

	mu.Lock()
	defer mu.Unlock()
	require.Len(t, received, 1)
	require.Len(t, received[0].GetRecords(), 1)
	assert.Equal(t, []byte{0xDE, 0xAD, 0xBE, 0xEF}, received[0].GetRecords()[0].GetPayload(),
		"payload must reach the buffer byte-identical")
}

func TestAddonPumpTakesDiscoveryOwnershipOnFirstBatch(t *testing.T) {
	socketPath := shortSocketPath(t)
	startFakeAddonService(t, socketPath, &fakeAddonService{batches: []*addonpb.TelemetryBatch{opaqueBatch()}})

	sc := pumpTestSidecar()
	require.False(t, sc.AddonStreamOwnsDiscovery(), "legacy channel owns discovery until a batch arrives")

	forwarded := make(chan struct{}, 1)
	pump := newTestPump(t, socketPath, sc, func(*addonpb.TelemetryBatch) {
		// Ownership must already be held HERE: if it were taken after the
		// forward, the legacy loop could push the same snapshot core just got.
		assert.True(t, sc.AddonStreamOwnsDiscovery(), "ownership must be taken before the first forward")
		select {
		case forwarded <- struct{}{}:
		default:
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	go pump.Run(ctx)

	select {
	case <-forwarded:
	case <-ctx.Done():
		t.Fatal("pump never forwarded a batch")
	}

	require.Eventually(t, sc.AddonStreamOwnsDiscovery, 5*time.Second, 10*time.Millisecond)

	// The single-consumer rule: with the stream authoritative, the legacy drain
	// yields nothing even though snapshots are sitting in the buffer.
	sc.censusSnaps <- censusSnapshotFor("eth0", 100, "aa:bb:cc:dd:ee:ff")
	assert.Empty(t, sc.DrainCensusSnapshots(0), "legacy census drain must be inert while the stream owns discovery")
	assert.Empty(t, sc.DrainMdnsSnapshots(0), "legacy mDNS drain must be inert while the stream owns discovery")
}

func TestAddonPumpLeavesLegacyChannelAuthoritativeWhenSocketAbsent(t *testing.T) {
	// A netprobe too old to serve the contract: nothing is listening.
	socketPath := shortSocketPath(t)

	sc := pumpTestSidecar()
	pump := newTestPump(t, socketPath, sc, func(*addonpb.TelemetryBatch) {
		t.Error("pump must not forward anything when the socket is absent")
	})

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	pump.Run(ctx)

	assert.False(t, sc.AddonStreamOwnsDiscovery(), "ownership must stay with the legacy channel")

	sc.censusSnaps <- censusSnapshotFor("eth0", 100, "aa:bb:cc:dd:ee:ff")
	assert.Len(t, sc.DrainCensusSnapshots(0), 1, "legacy census drain must keep working")
}

func TestAddonPumpReleasesOwnershipAndDiscardsStaleBacklogOnStreamEnd(t *testing.T) {
	socketPath := shortSocketPath(t)
	startFakeAddonService(t, socketPath, &fakeAddonService{
		batches:        []*addonpb.TelemetryBatch{opaqueBatch()},
		closeAfterSend: true,
	})

	sc := pumpTestSidecar()
	forwarded := make(chan struct{}, 1)
	pump := newTestPump(t, socketPath, sc, func(*addonpb.TelemetryBatch) {
		// Queued while the stream is authoritative, so it is older than what the
		// stream already delivered. It must not survive the handover back.
		sc.censusSnaps <- censusSnapshotFor("eth0", 100, "aa:bb:cc:dd:ee:ff")
		select {
		case forwarded <- struct{}{}:
		default:
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	go pump.Run(ctx)

	select {
	case <-forwarded:
	case <-ctx.Done():
		t.Fatal("pump never forwarded a batch")
	}

	// The stream closed, so ownership returns to the legacy channel -- with the
	// backlog dropped rather than replayed. Replaying it would resurrect devices
	// that aged out of the newer view the stream already delivered.
	require.Eventually(t, func() bool { return !sc.AddonStreamOwnsDiscovery() }, 5*time.Second, 10*time.Millisecond)
	assert.Empty(t, sc.DrainCensusSnapshots(0), "snapshots buffered under stream ownership must be discarded")

	// And the legacy path is live again for whatever netprobe sends next.
	sc.censusSnaps <- censusSnapshotFor("eth0", 200, "aa:bb:cc:dd:ee:ff")
	assert.Len(t, sc.DrainCensusSnapshots(0), 1, "legacy census drain must resume after fallback")
}
