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
	"fmt"
	"math"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"github.com/stretchr/testify/require"
)

// refusingRelayAppender delegates to a real spool after refusing the first
// refuseFirst appends as retryable backpressure, recording each event id tried.
type refusingRelayAppender struct {
	mu          sync.Mutex
	delegate    *spool.Spool
	refuseFirst int
	attempts    int
	eventIDs    [][]byte
}

func (f *refusingRelayAppender) AppendFlow(_ string, eventID, body []byte) (uint64, error) {
	f.mu.Lock()
	f.attempts++
	attempt := f.attempts
	f.eventIDs = append(f.eventIDs, append([]byte(nil), eventID...))
	f.mu.Unlock()
	if attempt <= f.refuseFirst {
		return 0, spool.ErrAdmissionPaused
	}
	return f.delegate.Append(eventID, body)
}

func (f *refusingRelayAppender) attemptCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.attempts
}

// newTestOtlpRelayPump is a relay pump whose edge target is app under a current
// OTLP relay grant.
func newTestOtlpRelayPump(t *testing.T, app edgeMetricsAppender) *otlpRelayPump {
	t.Helper()
	now := time.Now()
	capability := otlpRelayCapability(t, now.Add(-time.Hour), now.Add(8*24*time.Hour), 1024)
	return &otlpRelayPump{
		addonID: "otel-collector",
		edgeTarget: func(time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1) {
			return app, capability
		},
		logger:              logger.NewTestLogger(),
		flushInterval:       10 * time.Millisecond,
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

func requireAckedFramesEventually(t *testing.T, pump *otlpRelayPump, expected uint64) {
	t.Helper()

	require.Eventually(t, func() bool {
		return pump.stats.acked.Load() == expected
	}, time.Second, time.Millisecond, "acked frame counter should reach expected watermark")
}

func spooledRelayEventIDs(t *testing.T, sp *spool.Spool) []string {
	t.Helper()
	_, frames := spooledOtlpRelayRecords(t, sp)
	ids := make([]string, 0, len(frames))
	for _, frame := range frames {
		for _, record := range frame.GetBatch().GetRecords() {
			ids = append(ids, record.GetEventId())
		}
	}
	return ids
}

func TestOtlpRelayPumpSpoolsFramesThenAcks(t *testing.T) {
	sp := openTestEdgeSpool(t)
	pump := newTestOtlpRelayPump(t, sp)

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

	require.Equal(t, []string{"frame-1", "frame-2", "frame-3"}, spooledRelayEventIDs(t, sp),
		"records must be spooled in relay_id order")
	require.Equal(t, uint64(3), pump.stats.forwarded.Load())
	requireAckedFramesEventually(t, pump, 3)
	require.Zero(t, pump.stats.retried.Load())
	require.Zero(t, pump.stats.skippedOversize.Load())
}

func TestOtlpRelayPumpSkipsOversizedFrameAndStillAcksIt(t *testing.T) {
	sp := openTestEdgeSpool(t)
	pump := newTestOtlpRelayPump(t, sp)
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
	require.Equal(t, []string{"frame-1", "frame-3"}, spooledRelayEventIDs(t, sp),
		"the oversized frame must not be spooled")
	require.Equal(t, uint64(1), pump.stats.skippedOversize.Load())
	require.Equal(t, uint64(2), pump.stats.forwarded.Load())
	requireAckedFramesEventually(t, pump, 3)
}

func TestOtlpRelayPumpStopsPullingWhileTheSpoolRefuses(t *testing.T) {
	app := &refusingRelayAppender{delegate: openTestEdgeSpool(t), refuseFirst: math.MaxInt}
	pump := newTestOtlpRelayPump(t, app)
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
	// spool retry loop without pulling further.
	require.Eventually(t, func() bool {
		return len(frames) == fed-window && app.attemptCount() >= 1
	}, 5*time.Second, 5*time.Millisecond, "pump should pull exactly one window then stall")

	// Hold for several retry cycles: still no further pulls, still no acks.
	time.Sleep(100 * time.Millisecond)
	require.Len(t, frames, fed-window, "pulling must stop while the spool refuses")
	require.Empty(t, acks, "frames stay unacked while the spool refuses them")
	require.NotZero(t, pump.stats.retried.Load())
	require.Zero(t, pump.stats.forwarded.Load())
}

// Without the relay grant (or spool) the pump stops pulling and acks nothing,
// so frames stay in the add-on's durable spool; once a grant is held the held
// frame is spooled and acked, and pulling resumes.
func TestOtlpRelayPumpHoldsFramesUntilAGrantIsHeld(t *testing.T) {
	sp := openTestEdgeSpool(t)
	pump := newTestOtlpRelayPump(t, sp)
	granted := pump.edgeTarget
	var haveGrant atomic.Bool
	pump.edgeTarget = func(now time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1) {
		if !haveGrant.Load() {
			return nil, nil
		}
		return granted(now)
	}
	var holds atomic.Int64
	pump.recordHold = func() { holds.Add(1) }

	frames := make(chan *addonpb.OtlpRelayFrame, 3)
	acks := make(chan uint64, 16)
	frames <- testRelayFrame(1, 64)
	frames <- testRelayFrame(2, 64)
	frames <- testRelayFrame(3, 64)

	startRelayPump(t, pump, frames, acks)

	require.Eventually(t, func() bool { return holds.Load() >= 2 }, 5*time.Second, time.Millisecond,
		"the pump must count its waits for a grant")
	require.Len(t, frames, 2, "only the frame being held is pulled")
	require.Empty(t, acks, "nothing is acked without a grant")
	require.Empty(t, spooledRelayEventIDs(t, sp))

	haveGrant.Store(true)
	watermarks := waitForWatermark(t, acks, 3)
	require.Equal(t, uint64(3), watermarks[len(watermarks)-1])
	require.Equal(t, []string{"frame-1", "frame-2", "frame-3"}, spooledRelayEventIDs(t, sp))
}

func TestOtlpRelayPumpStopsOnContextCancel(t *testing.T) {
	pump := newTestOtlpRelayPump(t, openTestEdgeSpool(t))

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
	sp := openTestEdgeSpool(t)
	pump := newTestOtlpRelayPump(t, sp)

	frames := make(chan *addonpb.OtlpRelayFrame)
	acks := make(chan uint64, 16)

	_, done := startRelayPump(t, pump, frames, acks)

	close(frames)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("pump did not stop when the relay stream closed")
	}
	require.Empty(t, spooledRelayEventIDs(t, sp))
}
