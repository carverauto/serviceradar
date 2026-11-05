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

// addon_otlp_relay.go runs the agent-side pump for add-ons advertising the
// otlp-relay:v1 capability: it drains OtlpRelayFrame messages from the
// add-on's durable spool and appends them to the agent's edge spool as
// serviceradar.otlp.relay records. The pump flushes on a dedicated <=100ms
// cadence (not the 30s push tick) and sends the cumulative ack watermark back
// to the add-on only after those appends have succeeded. Without the relay
// grant or the spool the pump stops pulling frames, so they stay in the
// add-on's durable spool until the grant is held. Unlike the lossy
// native-telemetry:v1 path (addon_telemetry.go), a frame that can still be
// delivered stays unacked, and the add-on's spool retains and re-sends it on
// reconnect.

package agent

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const (
	// otlpRelayWindowMaxFrames/Bytes bound the in-flight window: frames pulled
	// from the add-on but not yet resolved. When either bound is reached the
	// pump stops pulling and flushes; pulling resumes only after the window
	// is appended to the edge spool and the cumulative ack was sent.
	otlpRelayWindowMaxFrames = 64
	otlpRelayWindowMaxBytes  = 8 * 1024 * 1024

	// otlpRelayMaxFrameMessageBytes enforces the edge pre-chunking invariant:
	// the add-on chunks OTLP payloads to <=900 KiB per frame before spooling,
	// so a compliant marshaled TelemetryBatch stays within 900 KiB plus a
	// small envelope allowance. It caps one relay record's payload.
	otlpRelayMaxFrameMessageBytes = 900*1024 + 64*1024

	// otlpRelayFlushInterval is the maximum latency between pulling the first
	// pending frame and flushing it; the pump flushes earlier when the window
	// fills.
	otlpRelayFlushInterval = 100 * time.Millisecond

	// otlpRelayRetryBackoff* drive the exponential backoff between failed
	// flushes, and between checks for a relay grant while none is held.
	// Frames stay pending (and unacked) across retries.
	otlpRelayRetryBackoffInitial = time.Second
	otlpRelayRetryBackoffMax     = 30 * time.Second

	// otlpRelayAckSendTimeout bounds the watermark send to the add-on. If the
	// relay stream broke underneath us the adapter stops draining acks; the
	// pump then abandons the stream and reconnects (the add-on simply
	// re-sends the frames whose ack was lost — at-least-once).
	otlpRelayAckSendTimeout = 5 * time.Second

	// otlpRelayReconnectBackoff* drive stream re-open attempts after the
	// relay stream ends or fails to open. The backoff resets once a stream
	// stayed up for otlpRelayReconnectResetAfter.
	otlpRelayReconnectBackoffInitial = time.Second
	otlpRelayReconnectBackoffMax     = time.Minute
	otlpRelayReconnectResetAfter     = time.Minute
)

// addonOtlpRelayDeps carries the late-bound edge dependencies for relay pumps:
// the add-on manager (and therefore the relay runner hook) is created in
// NewServer before the push loop exists, so NewPushLoop binds the edge target
// once it is available and pumps wait on ready.
type addonOtlpRelayDeps struct {
	mu         sync.Mutex
	edgeTarget func(now time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1)
	recordDrop func(reason edgeDropReason, count int, err error)
	recordHold func()
	ready      chan struct{}
}

func newAddonOtlpRelayDeps() *addonOtlpRelayDeps {
	return &addonOtlpRelayDeps{ready: make(chan struct{})}
}

func (d *addonOtlpRelayDeps) bindEdge(
	edgeTarget func(now time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1),
	recordDrop func(reason edgeDropReason, count int, err error),
	recordHold func(),
) {
	if d == nil || edgeTarget == nil {
		return
	}

	d.mu.Lock()
	defer d.mu.Unlock()

	alreadyBound := d.edgeTarget != nil
	d.edgeTarget = edgeTarget
	d.recordDrop = recordDrop
	d.recordHold = recordHold
	if !alreadyBound {
		close(d.ready)
	}
}

func (d *addonOtlpRelayDeps) snapshot() (
	func(now time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1),
	func(reason edgeDropReason, count int, err error),
	func(),
) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.edgeTarget, d.recordDrop, d.recordHold
}

// runAddonOtlpRelay is the add-on manager's OtlpRelayRunner hook. It owns the
// relay pump for one add-on instance for as long as ctx lives: the manager
// cancels ctx when the add-on stops, restarts, turns unhealthy, or the agent
// shuts down. The relay stream is re-opened with exponential backoff after
// transient failures; the add-on resumes from its durable ack watermark on
// every reconnect, so the pump never tracks cross-stream state.
func (s *Server) runAddonOtlpRelay(ctx context.Context, addonID string, client coreaddon.OtlpRelayClient) {
	if s == nil || client == nil {
		return
	}

	s.mu.RLock()
	deps := s.addonOtlpRelay
	log := s.logger
	s.mu.RUnlock()

	if deps == nil {
		return
	}

	select {
	case <-deps.ready:
	case <-ctx.Done():
		return
	}

	backoff := otlpRelayReconnectBackoffInitial
	for ctx.Err() == nil {
		edgeTarget, recordDrop, recordHold := deps.snapshot()

		frames, acks, err := client.RelayOtlp(ctx)
		if err != nil {
			log.Warn().Err(err).Str("addon", addonID).Msg("Failed to open OTLP relay stream")
		} else {
			pump := &otlpRelayPump{
				addonID:    addonID,
				edgeTarget: edgeTarget,
				recordDrop: recordDrop,
				recordHold: recordHold,
				logger:     log,
			}

			streamStart := time.Now()
			pump.run(ctx, frames, acks)
			close(acks)

			if time.Since(streamStart) >= otlpRelayReconnectResetAfter {
				backoff = otlpRelayReconnectBackoffInitial
			}
		}

		if !otlpRelaySleep(ctx, backoff) {
			return
		}

		backoff *= 2
		if backoff > otlpRelayReconnectBackoffMax {
			backoff = otlpRelayReconnectBackoffMax
		}
	}
}

// otlpRelayPending is one frame pulled from the add-on and built into durable
// edge records, awaiting their append.
type otlpRelayPending struct {
	relayID   uint64
	edgeSpool edgeMetricsAppender
	edgeParts []edgeMetricsBuilt
	bytes     int
}

// otlpRelayPump drains one open relay stream into the edge spool.
// Zero-valued tuning fields fall back to the package defaults (test seams).
type otlpRelayPump struct {
	addonID    string
	edgeTarget func(now time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1)
	recordDrop func(reason edgeDropReason, count int, err error)
	recordHold func()
	logger     logger.Logger

	windowMaxFrames     int
	windowMaxBytes      int
	maxFrameBytes       int
	flushInterval       time.Duration
	retryBackoffInitial time.Duration
	retryBackoffMax     time.Duration
	ackSendTimeout      time.Duration

	stats otlpRelayPumpStats
}

// otlpRelayPumpStats counts frames through one relay pump.
type otlpRelayPumpStats struct {
	// forwarded counts frames whose records were appended to the edge spool.
	forwarded atomic.Uint64
	// acked counts frames resolved by a cumulative ack watermark sent to the
	// add-on: delivered frames plus skipped undeliverable frames.
	acked atomic.Uint64
	// retried counts frame deliveries retried after a failed flush.
	retried atomic.Uint64
	// skippedOversize counts relay records skipped (and acked) because no edge
	// record can hold them.
	skippedOversize atomic.Uint64
}

func (p *otlpRelayPump) normalize() {
	if p.windowMaxFrames <= 0 {
		p.windowMaxFrames = otlpRelayWindowMaxFrames
	}
	if p.windowMaxBytes <= 0 {
		p.windowMaxBytes = otlpRelayWindowMaxBytes
	}
	if p.maxFrameBytes <= 0 {
		p.maxFrameBytes = otlpRelayMaxFrameMessageBytes
	}
	if p.flushInterval <= 0 {
		p.flushInterval = otlpRelayFlushInterval
	}
	if p.retryBackoffInitial <= 0 {
		p.retryBackoffInitial = otlpRelayRetryBackoffInitial
	}
	if p.retryBackoffMax <= 0 {
		p.retryBackoffMax = otlpRelayRetryBackoffMax
	}
	if p.ackSendTimeout <= 0 {
		p.ackSendTimeout = otlpRelayAckSendTimeout
	}
	if p.logger == nil {
		p.logger = logger.NewTestLogger()
	}
}

// run pumps relay frames to the edge spool until ctx is cancelled or the
// frames channel closes (stream end). On return any still-pending frames are
// simply abandoned unacked — the add-on's durable spool re-sends them with the
// same relay_ids on the next stream.
func (p *otlpRelayPump) run(ctx context.Context, frames <-chan *addonpb.OtlpRelayFrame, acks chan<- uint64) {
	p.normalize()

	var (
		pending          []otlpRelayPending
		pendingBytes     int
		lastPulled       uint64
		havePulled       bool
		resolvedSinceAck uint64
		flushTimer       *time.Timer
		flushC           <-chan time.Time
	)

	stopTimer := func() {
		if flushTimer != nil {
			flushTimer.Stop()
			flushTimer = nil
			flushC = nil
		}
	}
	defer stopTimer()

	// flush appends pending edge records (retrying until they are admitted),
	// then advances the cumulative ack watermark: at this point every frame
	// pulled so far is resolved (spooled or skipped), so the watermark is the
	// highest pulled relay_id. Returns false when the pump must stop (ctx done
	// or broken ack channel).
	flush := func() bool {
		stopTimer()

		if len(pending) > 0 {
			if !p.flushWithRetry(ctx, pending) {
				return false
			}

			p.stats.forwarded.Add(uint64(len(pending)))
			resolvedSinceAck += uint64(len(pending))
			pending = nil
			pendingBytes = 0
		}

		if resolvedSinceAck > 0 && havePulled {
			if !p.sendAck(ctx, acks, lastPulled) {
				return false
			}
			p.stats.acked.Add(resolvedSinceAck)
			resolvedSinceAck = 0
		}

		return true
	}

	for {
		select {
		case <-ctx.Done():
			return

		case <-flushC:
			flushTimer = nil
			flushC = nil
			if !flush() {
				return
			}

		case frame, ok := <-frames:
			if !ok {
				// Stream ended; reconnect from the caller. Pending frames
				// stay unacked and are re-sent by the add-on.
				return
			}
			if frame == nil {
				continue
			}

			spoolApp, capability := p.currentEdgeTarget(time.Now())
			if spoolApp == nil || capability == nil {
				// No relay grant or spool: resolve what is already pending,
				// then hold this frame (and pull nothing further) until a grant
				// is held. The add-on's durable spool keeps the rest.
				if !flush() {
					return
				}
				if spoolApp, capability = p.awaitEdgeTarget(ctx); spoolApp == nil {
					return
				}
			}

			lastPulled = frame.GetRelayId()
			havePulled = true

			parts, edgeBytes, ok := p.prepareEdgeRelayFrame(frame, capability)
			if !ok || len(parts) == 0 {
				resolvedSinceAck++
			} else {
				pending = append(pending, otlpRelayPending{
					relayID:   frame.GetRelayId(),
					edgeSpool: spoolApp,
					edgeParts: parts,
					bytes:     edgeBytes,
				})
				pendingBytes += edgeBytes
			}

			if len(pending) >= p.windowMaxFrames || pendingBytes >= p.windowMaxBytes {
				// Window full: stop pulling and flush now.
				if !flush() {
					return
				}
				continue
			}

			if len(pending) == 0 && resolvedSinceAck > 0 {
				// Only skipped frames outstanding — nothing to deliver, so
				// the watermark can advance immediately.
				if !flush() {
					return
				}
				continue
			}

			if len(pending) > 0 && flushC == nil {
				flushTimer = time.NewTimer(p.flushInterval)
				flushC = flushTimer.C
			}
		}
	}
}

// awaitEdgeTarget waits, with exponential backoff, until the agent holds the
// relay grant and the spool is open, counting each wait. It returns nils when
// ctx ends first.
func (p *otlpRelayPump) awaitEdgeTarget(ctx context.Context) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1) {
	backoff := p.retryBackoffInitial
	for {
		if p.recordHold != nil {
			p.recordHold()
		}
		if !otlpRelaySleep(ctx, backoff) {
			return nil, nil
		}
		if spoolApp, capability := p.currentEdgeTarget(time.Now()); spoolApp != nil && capability != nil {
			return spoolApp, capability
		}
		backoff *= 2
		if backoff > p.retryBackoffMax {
			backoff = p.retryBackoffMax
		}
	}
}

// flushWithRetry appends pending edge records, retrying with exponential
// backoff until they are admitted or ctx ends. Frames are never dropped here:
// on persistent refusal they stay pending and unacked, so the add-on's durable
// spool retains them.
func (p *otlpRelayPump) flushWithRetry(ctx context.Context, pending []otlpRelayPending) bool {
	backoff := p.retryBackoffInitial
	for {
		err := p.flushOnce(pending)
		if err == nil {
			return true
		}
		if ctx.Err() != nil {
			return false
		}

		p.stats.retried.Add(uint64(len(pending)))
		p.logger.Warn().Err(err).
			Str("addon", p.addonID).
			Int("frame_count", len(pending)).
			Dur("backoff", backoff).
			Msg("Edge spool refused OTLP relay records; retrying")

		if !otlpRelaySleep(ctx, backoff) {
			return false
		}

		backoff *= 2
		if backoff > p.retryBackoffMax {
			backoff = p.retryBackoffMax
		}
	}
}

func (p *otlpRelayPump) flushOnce(pending []otlpRelayPending) error {
	for i := range pending {
		if len(pending[i].edgeParts) == 0 {
			continue
		}
		rest, err := p.appendEdgeRelayParts(pending[i].edgeSpool, pending[i].edgeParts)
		pending[i].edgeParts = rest
		if err != nil {
			return err
		}
	}
	return nil
}

// sendAck sends the cumulative watermark to the add-on. A stalled ack channel
// (broken stream adapter) is bounded by ackSendTimeout: the pump abandons the
// stream and the caller reconnects — the frames whose ack was lost are simply
// re-sent by the add-on (at-least-once).
func (p *otlpRelayPump) sendAck(ctx context.Context, acks chan<- uint64, watermark uint64) bool {
	timer := time.NewTimer(p.ackSendTimeout)
	defer timer.Stop()

	select {
	case acks <- watermark:
		return true
	case <-ctx.Done():
		return false
	case <-timer.C:
		p.logger.Warn().
			Str("addon", p.addonID).
			Uint64("watermark", watermark).
			Msg("Timed out sending OTLP relay ack watermark; reconnecting stream")
		return false
	}
}

// otlpRelaySleep waits d, returning false if ctx ended first.
func otlpRelaySleep(ctx context.Context, d time.Duration) bool {
	timer := time.NewTimer(d)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
