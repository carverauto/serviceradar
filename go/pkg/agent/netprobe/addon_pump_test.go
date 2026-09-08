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

	var lc net.ListenConfig
	listener, err := lc.Listen(context.Background(), "unix", socketPath)
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

func newTestPump(t *testing.T, socketPath string, sink func(*addonpb.TelemetryBatch)) *AddonPump {
	t.Helper()

	pump, err := NewAddonPump(AddonPumpConfig{
		SocketPath: socketPath,
		Sink:       sink,
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

	pump := newTestPump(t, socketPath, func(batch *addonpb.TelemetryBatch) {
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

func TestAddonPumpForwardsNothingWhenSocketAbsent(t *testing.T) {
	// A netprobe too old to serve the contract: nothing is listening. The pump
	// must keep retrying quietly rather than spin or forward a partial batch --
	// there is no legacy channel behind it any more, so the host simply reports
	// no devices until netprobe is updated.
	socketPath := shortSocketPath(t)

	pump := newTestPump(t, socketPath, func(*addonpb.TelemetryBatch) {
		t.Error("pump must not forward anything when the socket is absent")
	})

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	pump.Run(ctx)
}

func TestAddonPumpReconnectsAfterTheStreamEnds(t *testing.T) {
	// netprobe restarting under the agent is routine (add-on upgrades, config
	// changes that need a restart). Discovery has no second channel to fall back
	// to, so a pump that gave up after one stream would silently end device
	// collection for that host until the agent itself restarted.
	socketPath := shortSocketPath(t)
	startFakeAddonService(t, socketPath, &fakeAddonService{
		batches:        []*addonpb.TelemetryBatch{opaqueBatch()},
		closeAfterSend: true,
	})

	var mu sync.Mutex
	forwards := 0
	twice := make(chan struct{})
	pump := newTestPump(t, socketPath, func(*addonpb.TelemetryBatch) {
		mu.Lock()
		defer mu.Unlock()
		forwards++
		if forwards == 2 {
			close(twice)
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	go pump.Run(ctx)

	select {
	case <-twice:
	case <-ctx.Done():
		mu.Lock()
		defer mu.Unlock()
		t.Fatalf("pump did not reconnect after the stream ended (forwards=%d)", forwards)
	}
}
