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

package agent

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"
)

var errRelayGatewayDown = errors.New("relay gateway down")

// fakeRelayGateway records StreamStatus calls and fails the first failFirst
// attempts with errRelayGatewayDown.
type fakeRelayGateway struct {
	mu        sync.Mutex
	failFirst int
	attempts  int
	calls     [][]*proto.GatewayStatusChunk
}

func (g *fakeRelayGateway) GetGatewayID() string { return "gateway-test" }

func (g *fakeRelayGateway) StreamStatus(
	_ context.Context, chunks []*proto.GatewayStatusChunk,
) (*proto.GatewayStatusResponse, error) {
	g.mu.Lock()
	defer g.mu.Unlock()

	g.attempts++
	if g.attempts <= g.failFirst {
		return nil, errRelayGatewayDown
	}

	g.calls = append(g.calls, chunks)
	return &proto.GatewayStatusResponse{Received: true}, nil
}

func (g *fakeRelayGateway) attemptCount() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.attempts
}

// allStatuses flattens every accepted chunk's services in delivery order.
func (g *fakeRelayGateway) allStatuses() []*proto.GatewayServiceStatus {
	g.mu.Lock()
	defer g.mu.Unlock()

	var statuses []*proto.GatewayServiceStatus
	for _, chunks := range g.calls {
		for _, chunk := range chunks {
			statuses = append(statuses, chunk.GetServices()...)
		}
	}
	return statuses
}

func newTestOtlpRelayPump(gw otlpRelayGateway) *otlpRelayPump {
	return &otlpRelayPump{
		addonID:             "otel-collector",
		gateway:             gw,
		agentID:             "agent-test",
		partition:           "partition-test",
		kvStoreID:           "kv-test",
		sourceIP:            func() string { return "10.0.0.9" },
		logger:              logger.NewTestLogger(),
		flushInterval:       10 * time.Millisecond,
		pushTimeout:         time.Second,
		retryBackoffInitial: 5 * time.Millisecond,
		retryBackoffMax:     20 * time.Millisecond,
		ackSendTimeout:      time.Second,
	}
}

func testRelayFrame(id uint64, payloadSize int) *addonpb.OtlpRelayFrame {
	return &addonpb.OtlpRelayFrame{
		RelayId: id,
		Batch: &addonpb.TelemetryBatch{
			Source: &addonpb.TelemetrySource{
				SourceType:     "otel-collector",
				SourceInstance: "edge",
			},
			Records: []*addonpb.TelemetryRecord{
				{
					EventId:     fmt.Sprintf("frame-%d", id),
					PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
					Payload:     bytes.Repeat([]byte{0xAB}, payloadSize),
				},
			},
		},
	}
}

func startRelayPump(
	t *testing.T,
	pump *otlpRelayPump,
	frames <-chan *addonpb.OtlpRelayFrame,
	acks chan<- uint64,
) (cancel context.CancelFunc, done chan struct{}) {
	t.Helper()

	ctx, cancelFn := context.WithCancel(context.Background())
	doneCh := make(chan struct{})
	go func() {
		defer close(doneCh)
		pump.run(ctx, frames, acks)
	}()

	t.Cleanup(func() {
		cancelFn()
		select {
		case <-doneCh:
		case <-time.After(5 * time.Second):
			t.Fatal("relay pump did not stop on context cancel")
		}
	})

	return cancelFn, doneCh
}

// waitForWatermark drains acks until the expected cumulative watermark
// arrives, returning every watermark observed.
func waitForWatermark(t *testing.T, acks <-chan uint64, expected uint64) []uint64 {
	t.Helper()

	deadline := time.After(5 * time.Second)
	var seen []uint64
	for {
		select {
		case watermark := <-acks:
			seen = append(seen, watermark)
			if watermark >= expected {
				return seen
			}
		case <-deadline:
			t.Fatalf("timed out waiting for ack watermark %d (saw %v)", expected, seen)
		}
	}
}

func requireAckedFramesEventually(t *testing.T, expected uint64) {
	t.Helper()

	require.Eventually(t, func() bool {
		return AgentOtlpRelayFramesAckedTotal() == expected
	}, time.Second, time.Millisecond, "acked frame counter should reach expected watermark")
}

func TestOtlpRelayPumpForwardsFramesThenAcks(t *testing.T) {
	resetAgentOtlpRelayFrameCounters()

	gw := &fakeRelayGateway{}
	pump := newTestOtlpRelayPump(gw)

	frames := make(chan *addonpb.OtlpRelayFrame, 3)
	acks := make(chan uint64, 16)
	frames <- testRelayFrame(1, 64)
	frames <- testRelayFrame(2, 64)
	frames <- testRelayFrame(3, 64)

	startRelayPump(t, pump, frames, acks)

	watermarks := waitForWatermark(t, acks, 3)
	for i := 1; i < len(watermarks); i++ {
		require.Greater(t, watermarks[i], watermarks[i-1], "ack watermarks must be cumulative and increasing")
	}

	statuses := gw.allStatuses()
	require.Len(t, statuses, 3, "one GatewayServiceStatus per relay frame")

	for i, status := range statuses {
		require.Equal(t, otlpRelayServiceName, status.GetServiceName())
		require.Equal(t, otlpRelayServiceType, status.GetServiceType())
		require.Equal(t, otlpRelaySource, status.GetSource())
		require.True(t, status.GetAvailable())
		require.Equal(t, "agent-test", status.GetAgentId())
		require.Equal(t, "gateway-test", status.GetGatewayId())
		require.Equal(t, "partition-test", status.GetPartition())
		require.Equal(t, "kv-test", status.GetKvStoreId())

		var decoded addonpb.TelemetryBatch
		require.NoError(t, gproto.Unmarshal(status.GetMessage(), &decoded))
		require.Equal(t, fmt.Sprintf("frame-%d", i+1), decoded.GetRecords()[0].GetEventId(),
			"statuses must be delivered in relay_id order")
	}

	require.Equal(t, uint64(3), AgentOtlpRelayFramesForwardedTotal())
	requireAckedFramesEventually(t, 3)
	require.Zero(t, AgentOtlpRelayFramesRetriedTotal())
	require.Zero(t, AgentOtlpRelayFramesSkippedOversizeTotal())
}

func TestOtlpRelayPumpRetriesWithoutAckOnGatewayFailure(t *testing.T) {
	resetAgentOtlpRelayFrameCounters()

	gw := &fakeRelayGateway{failFirst: 2}
	pump := newTestOtlpRelayPump(gw)
	// Deterministic single flush: window-full at exactly two frames, timer
	// effectively disabled.
	pump.windowMaxFrames = 2
	pump.flushInterval = time.Hour

	frames := make(chan *addonpb.OtlpRelayFrame, 2)
	acks := make(chan uint64, 16)
	frames <- testRelayFrame(1, 64)
	frames <- testRelayFrame(2, 64)

	startRelayPump(t, pump, frames, acks)

	watermarks := waitForWatermark(t, acks, 2)
	require.Equal(t, []uint64{2}, watermarks,
		"no ack may be sent before the gateway accepts the frames")

	require.Equal(t, 3, gw.attemptCount(), "two failed attempts plus the successful one")
	require.Equal(t, uint64(4), AgentOtlpRelayFramesRetriedTotal(), "2 frames x 2 failed attempts")
	require.Equal(t, uint64(2), AgentOtlpRelayFramesForwardedTotal())
	requireAckedFramesEventually(t, 2)
}

func TestOtlpRelayPumpSkipsOversizedFrameAndStillAcksIt(t *testing.T) {
	resetAgentOtlpRelayFrameCounters()

	gw := &fakeRelayGateway{}
	pump := newTestOtlpRelayPump(gw)
	pump.maxFrameBytes = 1024
	pump.windowMaxFrames = 2
	pump.flushInterval = time.Hour

	frames := make(chan *addonpb.OtlpRelayFrame, 3)
	acks := make(chan uint64, 16)
	frames <- testRelayFrame(1, 64)
	frames <- testRelayFrame(2, 4096) // violates the pre-chunking invariant
	frames <- testRelayFrame(3, 64)

	startRelayPump(t, pump, frames, acks)

	watermarks := waitForWatermark(t, acks, 3)
	require.Equal(t, uint64(3), watermarks[len(watermarks)-1],
		"the skipped frame is covered by the cumulative watermark")

	statuses := gw.allStatuses()
	require.Len(t, statuses, 2, "the oversized frame must not reach the gateway")
	for i, wantEvent := range []string{"frame-1", "frame-3"} {
		var decoded addonpb.TelemetryBatch
		require.NoError(t, gproto.Unmarshal(statuses[i].GetMessage(), &decoded))
		require.Equal(t, wantEvent, decoded.GetRecords()[0].GetEventId())
	}

	require.Equal(t, uint64(1), AgentOtlpRelayFramesSkippedOversizeTotal())
	require.Equal(t, uint64(2), AgentOtlpRelayFramesForwardedTotal())
	requireAckedFramesEventually(t, 3)
}

func TestOtlpRelayPumpAcksOversizedFrameImmediatelyWhenIdle(t *testing.T) {
	resetAgentOtlpRelayFrameCounters()

	gw := &fakeRelayGateway{}
	pump := newTestOtlpRelayPump(gw)
	pump.maxFrameBytes = 1024
	pump.flushInterval = time.Hour

	frames := make(chan *addonpb.OtlpRelayFrame, 1)
	acks := make(chan uint64, 16)
	frames <- testRelayFrame(7, 4096)

	startRelayPump(t, pump, frames, acks)

	watermarks := waitForWatermark(t, acks, 7)
	require.Equal(t, []uint64{7}, watermarks)
	require.Zero(t, gw.attemptCount(), "nothing deliverable: the gateway must not be called")
	require.Equal(t, uint64(1), AgentOtlpRelayFramesSkippedOversizeTotal())
	requireAckedFramesEventually(t, 1)
	require.Zero(t, AgentOtlpRelayFramesForwardedTotal())
}

func TestOtlpRelayPumpStopsPullingWhenAcksStall(t *testing.T) {
	resetAgentOtlpRelayFrameCounters()

	gw := &fakeRelayGateway{failFirst: math.MaxInt}
	pump := newTestOtlpRelayPump(gw)
	const window = 4
	pump.windowMaxFrames = window
	pump.flushInterval = time.Hour

	const fed = 10
	frames := make(chan *addonpb.OtlpRelayFrame, fed)
	acks := make(chan uint64, 16)
	for i := 1; i <= fed; i++ {
		frames <- testRelayFrame(uint64(i), 64)
	}

	startRelayPump(t, pump, frames, acks)

	// The pump pulls until the window fills (4 frames), then blocks in the
	// gateway retry loop without pulling further.
	require.Eventually(t, func() bool {
		return len(frames) == fed-window && gw.attemptCount() >= 1
	}, 5*time.Second, 5*time.Millisecond, "pump should pull exactly one window then stall")

	// Hold for several retry cycles: still no further pulls, still no acks.
	time.Sleep(100 * time.Millisecond)
	require.Len(t, frames, fed-window, "pulling must stop while acks are stalled")
	require.Empty(t, acks, "frames stay unacked while the gateway rejects them")
	require.NotZero(t, AgentOtlpRelayFramesRetriedTotal())
	require.Zero(t, AgentOtlpRelayFramesForwardedTotal())
}

func TestOtlpRelayPumpStopsOnContextCancel(t *testing.T) {
	gw := &fakeRelayGateway{}
	pump := newTestOtlpRelayPump(gw)

	frames := make(chan *addonpb.OtlpRelayFrame)
	acks := make(chan uint64, 16)

	cancel, done := startRelayPump(t, pump, frames, acks)

	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("pump did not stop on context cancel")
	}
}

func TestOtlpRelayPumpStopsWhenStreamCloses(t *testing.T) {
	gw := &fakeRelayGateway{}
	pump := newTestOtlpRelayPump(gw)

	frames := make(chan *addonpb.OtlpRelayFrame)
	acks := make(chan uint64, 16)

	_, done := startRelayPump(t, pump, frames, acks)

	close(frames)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("pump did not stop when the relay stream closed")
	}
	require.Zero(t, gw.attemptCount())
}

func TestBuildOtlpRelayGatewayStatusWrapsFrameBatch(t *testing.T) {
	frame := testRelayFrame(42, 128)

	status, messageByteCount, err := buildOtlpRelayGatewayStatus(
		frame, "agent-a", "gateway-a", "prod-east", "kv-a")
	require.NoError(t, err)

	require.Equal(t, otlpRelayServiceName, status.GetServiceName())
	require.Equal(t, otlpRelayServiceType, status.GetServiceType())
	require.Equal(t, otlpRelaySource, status.GetSource())
	require.True(t, status.GetAvailable())
	require.Equal(t, "agent-a", status.GetAgentId())
	require.Equal(t, "gateway-a", status.GetGatewayId())
	require.Equal(t, "prod-east", status.GetPartition())
	require.Equal(t, "kv-a", status.GetKvStoreId())
	require.Equal(t, len(status.GetMessage()), messageByteCount)

	var decoded addonpb.TelemetryBatch
	require.NoError(t, gproto.Unmarshal(status.GetMessage(), &decoded))
	require.Equal(t, "frame-42", decoded.GetRecords()[0].GetEventId())
	require.Equal(t,
		addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
		decoded.GetRecords()[0].GetPayloadKind())
}
