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
// otlp-relay:v1 capability: it drains acked OtlpRelayFrame messages from the
// add-on's durable spool, wraps each frame as a GatewayServiceStatus
// (ServiceName/Source "otlp-relay"), flushes them to the gateway on a
// dedicated <=100ms cadence (not the 30s push tick), and sends the cumulative
// ack watermark back to the add-on only after the gateway accepted the
// frames. Unlike the lossy native-telemetry:v1 path (addon_telemetry.go),
// nothing is dropped here: undelivered frames stay unacked, and the add-on's
// spool retains and re-sends them on reconnect.

package agent

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	gproto "google.golang.org/protobuf/proto"
)

const (
	// otlpRelayServiceName/Type/Source are the fixed GatewayServiceStatus
	// identity for relayed OTLP frames — the shared contract with the gateway
	// status processor (synchronous forward, no false acks) and the core
	// StatusHandler (TelemetryBatch decode + NATS republish).
	otlpRelayServiceName = "otlp-relay"
	otlpRelayServiceType = "otel-collector"
	otlpRelaySource      = "otlp-relay"

	// otlpRelayWindowMaxFrames/Bytes bound the in-flight window: frames pulled
	// from the add-on but not yet accepted by the gateway. When either bound
	// is reached the pump stops pulling and flushes; pulling resumes only
	// after the gateway accepted the window and the cumulative ack was sent.
	otlpRelayWindowMaxFrames = 64
	otlpRelayWindowMaxBytes  = 8 * 1024 * 1024

	// otlpRelayMaxFrameMessageBytes enforces the edge pre-chunking invariant:
	// the add-on chunks OTLP payloads to <=900 KiB per frame before spooling,
	// so a compliant marshaled TelemetryBatch stays within 900 KiB plus a
	// small envelope allowance. An oversized frame can never become
	// deliverable (the spool-side rejection accounting already counted it),
	// so the pump skips it, counts it, logs it, and ACKS it — it must never
	// crash or wedge the stream.
	otlpRelayMaxFrameMessageBytes = 900*1024 + 64*1024

	// otlpRelayMaxChunkMessageBytes mirrors addonTelemetryMaxBatchMessageBytes:
	// the per-GatewayStatusChunk message budget kept below the gateway's
	// 16 MiB stream chunk cap.
	otlpRelayMaxChunkMessageBytes = 6 * 1024 * 1024

	// otlpRelayFlushInterval is the maximum latency between pulling the first
	// pending frame and flushing it to the gateway; the pump flushes earlier
	// when the window fills.
	otlpRelayFlushInterval = 100 * time.Millisecond

	// otlpRelayPushTimeout bounds a single StreamStatus call.
	otlpRelayPushTimeout = 30 * time.Second

	// otlpRelayRetryBackoff* drive the exponential backoff between failed
	// gateway flushes. Frames stay pending (and unacked) across retries.
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

var errOtlpRelayGatewayRejected = errors.New("gateway did not acknowledge otlp relay status")

// agentOtlpRelayFrames* count relay frames through the agent-side pump,
// surfaced as `agent_otlp_relay_frames_forwarded_total`,
// `agent_otlp_relay_frames_acked_total`,
// `agent_otlp_relay_frames_retried_total`, and
// `agent_otlp_relay_frames_skipped_oversize_total` by the Prometheus
// exporter (same style as agentFlowAttributionEventsForwardedTotal).
//
//nolint:gochecknoglobals // process-global Prometheus counters
var (
	agentOtlpRelayFramesForwardedTotal       atomic.Uint64
	agentOtlpRelayFramesAckedTotal           atomic.Uint64
	agentOtlpRelayFramesRetriedTotal         atomic.Uint64
	agentOtlpRelayFramesSkippedOversizeTotal atomic.Uint64
)

// AgentOtlpRelayFramesForwardedTotal returns the number of relay frames the
// gateway accepted. Exposed for the Prometheus exporter and tests.
func AgentOtlpRelayFramesForwardedTotal() uint64 {
	return agentOtlpRelayFramesForwardedTotal.Load()
}

// AgentOtlpRelayFramesAckedTotal returns the number of relay frames resolved
// by a cumulative ack watermark sent to the add-on (delivered frames plus
// skipped oversized frames). Exposed for the Prometheus exporter and tests.
func AgentOtlpRelayFramesAckedTotal() uint64 {
	return agentOtlpRelayFramesAckedTotal.Load()
}

// AgentOtlpRelayFramesRetriedTotal returns the number of frame deliveries
// re-attempted after a gateway flush failure. Exposed for the Prometheus
// exporter and tests.
func AgentOtlpRelayFramesRetriedTotal() uint64 {
	return agentOtlpRelayFramesRetriedTotal.Load()
}

// AgentOtlpRelayFramesSkippedOversizeTotal returns the number of relay frames
// skipped (and acked) because they violated the <=900 KiB edge pre-chunking
// invariant. Exposed for the Prometheus exporter and tests.
func AgentOtlpRelayFramesSkippedOversizeTotal() uint64 {
	return agentOtlpRelayFramesSkippedOversizeTotal.Load()
}

// resetAgentOtlpRelayFrameCounters is exposed for tests.
func resetAgentOtlpRelayFrameCounters() {
	agentOtlpRelayFramesForwardedTotal.Store(0)
	agentOtlpRelayFramesAckedTotal.Store(0)
	agentOtlpRelayFramesRetriedTotal.Store(0)
	agentOtlpRelayFramesSkippedOversizeTotal.Store(0)
}

// otlpRelayGateway is the narrow gateway surface the relay pump needs.
// Satisfied by *agentgateway.GatewayClient.
type otlpRelayGateway interface {
	GetGatewayID() string
	StreamStatus(ctx context.Context, chunks []*proto.GatewayStatusChunk) (*proto.GatewayStatusResponse, error)
}

// addonOtlpRelayDeps carries the late-bound gateway dependencies for relay
// pumps: the add-on manager (and therefore the relay runner hook) is created
// in NewServer before the gateway client exists, so NewPushLoop binds the
// gateway once it is available and pumps wait on ready.
type addonOtlpRelayDeps struct {
	mu       sync.Mutex
	gateway  otlpRelayGateway
	sourceIP func() string
	ready    chan struct{}
}

func newAddonOtlpRelayDeps() *addonOtlpRelayDeps {
	return &addonOtlpRelayDeps{ready: make(chan struct{})}
}

func (d *addonOtlpRelayDeps) bind(gateway otlpRelayGateway, sourceIP func() string) {
	if d == nil || gateway == nil {
		return
	}

	d.mu.Lock()
	defer d.mu.Unlock()

	alreadyBound := d.gateway != nil
	d.gateway = gateway
	d.sourceIP = sourceIP
	if !alreadyBound {
		close(d.ready)
	}
}

func (d *addonOtlpRelayDeps) snapshot() (otlpRelayGateway, func() string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.gateway, d.sourceIP
}

// bindAddonOtlpRelayGateway hands the gateway client to the add-on OTLP relay
// pumps once it exists (mirrors configurePluginCredentialBroker: the add-on
// manager is created before the gateway client).
func bindAddonOtlpRelayGateway(server *Server, gateway otlpRelayGateway, sourceIP func() string) {
	if server == nil || gateway == nil {
		return
	}

	server.mu.RLock()
	deps := server.addonOtlpRelay
	server.mu.RUnlock()

	deps.bind(gateway, sourceIP)
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
	var agentID, partition, kvStoreID string
	if s.config != nil {
		agentID = s.config.AgentID
		partition = s.config.Partition
		kvStoreID = s.config.KVAddress
	}
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
		gateway, sourceIP := deps.snapshot()

		frames, acks, err := client.RelayOtlp(ctx)
		if err != nil {
			log.Warn().Err(err).Str("addon", addonID).Msg("Failed to open OTLP relay stream")
		} else {
			pump := &otlpRelayPump{
				addonID:   addonID,
				gateway:   gateway,
				agentID:   agentID,
				partition: partition,
				kvStoreID: kvStoreID,
				sourceIP:  sourceIP,
				logger:    log,
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

// otlpRelayPending is one frame pulled from the add-on, built into a
// GatewayServiceStatus, awaiting gateway acceptance.
type otlpRelayPending struct {
	relayID uint64
	status  *proto.GatewayServiceStatus
	bytes   int
}

// otlpRelayPump drains one open relay stream into the gateway. Zero-valued
// tuning fields fall back to the package defaults (test seams).
type otlpRelayPump struct {
	addonID   string
	gateway   otlpRelayGateway
	agentID   string
	partition string
	kvStoreID string
	sourceIP  func() string
	logger    logger.Logger

	windowMaxFrames     int
	windowMaxBytes      int
	maxFrameBytes       int
	flushInterval       time.Duration
	pushTimeout         time.Duration
	retryBackoffInitial time.Duration
	retryBackoffMax     time.Duration
	ackSendTimeout      time.Duration
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
	if p.pushTimeout <= 0 {
		p.pushTimeout = otlpRelayPushTimeout
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

// run pumps relay frames to the gateway until ctx is cancelled or the frames
// channel closes (stream end). On return any still-pending frames are simply
// abandoned unacked — the add-on's durable spool re-sends them with the same
// relay_ids on the next stream.
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

	// flush delivers pending statuses (retrying until the gateway accepts
	// them), then advances the cumulative ack watermark: at this point every
	// frame pulled so far is resolved (delivered or skipped), so the
	// watermark is the highest pulled relay_id. Returns false when the pump
	// must stop (ctx done or broken ack channel).
	flush := func() bool {
		stopTimer()

		if len(pending) > 0 {
			if !p.flushWithRetry(ctx, pending) {
				return false
			}

			agentOtlpRelayFramesForwardedTotal.Add(uint64(len(pending)))
			resolvedSinceAck += uint64(len(pending))
			pending = nil
			pendingBytes = 0
		}

		if resolvedSinceAck > 0 && havePulled {
			if !p.sendAck(ctx, acks, lastPulled) {
				return false
			}
			agentOtlpRelayFramesAckedTotal.Add(resolvedSinceAck)
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

			lastPulled = frame.GetRelayId()
			havePulled = true

			status, messageByteCount, err := buildOtlpRelayGatewayStatus(
				frame, p.agentID, p.gateway.GetGatewayID(), p.partition, p.kvStoreID)
			switch {
			case err != nil:
				// A frame that cannot be marshaled can never become
				// deliverable: skip and ack it so it cannot wedge the stream.
				p.logger.Warn().Err(err).
					Str("addon", p.addonID).
					Uint64("relay_id", frame.GetRelayId()).
					Msg("Skipping unmarshalable OTLP relay frame")
				resolvedSinceAck++
			case messageByteCount > p.maxFrameBytes:
				// Edge pre-chunking invariant violated. The frame is skipped,
				// counted, and acked: it can never become deliverable, and
				// spool-side rejection accounting already counted it.
				agentOtlpRelayFramesSkippedOversizeTotal.Add(1)
				p.logger.Warn().
					Str("addon", p.addonID).
					Uint64("relay_id", frame.GetRelayId()).
					Int("message_bytes", messageByteCount).
					Int("max_bytes", p.maxFrameBytes).
					Msg("Skipping oversized OTLP relay frame")
				resolvedSinceAck++
			default:
				pending = append(pending, otlpRelayPending{
					relayID: frame.GetRelayId(),
					status:  status,
					bytes:   messageByteCount,
				})
				pendingBytes += messageByteCount
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

// flushWithRetry delivers pending statuses to the gateway, retrying with
// exponential backoff until the gateway accepts them or ctx ends. Frames are
// never dropped here: on persistent failure they stay pending and unacked, so
// the add-on's durable spool retains them.
func (p *otlpRelayPump) flushWithRetry(ctx context.Context, pending []otlpRelayPending) bool {
	backoff := p.retryBackoffInitial
	for {
		err := p.flushOnce(ctx, pending)
		if err == nil {
			return true
		}
		if ctx.Err() != nil {
			return false
		}

		agentOtlpRelayFramesRetriedTotal.Add(uint64(len(pending)))
		p.logger.Warn().Err(err).
			Str("addon", p.addonID).
			Int("frame_count", len(pending)).
			Dur("backoff", backoff).
			Msg("Failed to stream OTLP relay frames to gateway; retrying")

		if !otlpRelaySleep(ctx, backoff) {
			return false
		}

		backoff *= 2
		if backoff > p.retryBackoffMax {
			backoff = p.retryBackoffMax
		}
	}
}

func (p *otlpRelayPump) flushOnce(ctx context.Context, pending []otlpRelayPending) error {
	chunks := p.buildChunks(pending)

	pushCtx, cancel := context.WithTimeout(ctx, p.pushTimeout)
	defer cancel()

	resp, err := p.gateway.StreamStatus(pushCtx, chunks)
	if err != nil {
		return err
	}
	if resp == nil || !resp.GetReceived() {
		return errOtlpRelayGatewayRejected
	}
	return nil
}

// buildChunks packs the pending statuses into GatewayStatusChunk envelopes,
// allowing multiple statuses per chunk while keeping each chunk's summed
// message bytes within the 6 MiB budget.
func (p *otlpRelayPump) buildChunks(pending []otlpRelayPending) []*proto.GatewayStatusChunk {
	gatewayID := p.gateway.GetGatewayID()
	runtimeMetadata := currentRuntimeMetadata()
	sourceIP := ""
	if p.sourceIP != nil {
		sourceIP = p.sourceIP()
	}

	var chunks []*proto.GatewayStatusChunk
	statuses := make([]*proto.GatewayServiceStatus, 0, len(pending))
	chunkBytes := 0

	appendChunk := func() {
		if len(statuses) == 0 {
			return
		}
		chunks = append(chunks, &proto.GatewayStatusChunk{
			Services:  statuses,
			GatewayId: gatewayID,
			AgentId:   p.agentID,
			Timestamp: time.Now().UnixNano(),
			Partition: p.partition,
			SourceIp:  sourceIP,
			Version:   runtimeMetadata.Version,
			Hostname:  runtimeMetadata.Hostname,
			Os:        runtimeMetadata.Os,
			Arch:      runtimeMetadata.Arch,
		})
		statuses = nil
		chunkBytes = 0
	}

	for _, entry := range pending {
		if len(statuses) > 0 && chunkBytes+entry.bytes > otlpRelayMaxChunkMessageBytes {
			appendChunk()
		}
		statuses = append(statuses, entry.status)
		chunkBytes += entry.bytes
	}
	appendChunk()

	totalChunks := int32(len(chunks))
	for i, chunk := range chunks {
		chunk.ChunkIndex = int32(i)
		chunk.TotalChunks = totalChunks
		chunk.IsFinal = int32(i) == totalChunks-1
	}

	return chunks
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

// buildOtlpRelayGatewayStatus wraps one relay frame's TelemetryBatch as a
// GatewayServiceStatus (same shape as buildAddonTelemetryGatewayStatus, with
// the fixed otlp-relay identity contract).
func buildOtlpRelayGatewayStatus(
	frame *addonpb.OtlpRelayFrame,
	agentID, gatewayID, partition, kvStoreID string,
) (*proto.GatewayServiceStatus, int, error) {
	messageBytes, err := gproto.Marshal(frame.GetBatch())
	if err != nil {
		return nil, 0, err
	}

	return &proto.GatewayServiceStatus{
		ServiceName:  otlpRelayServiceName,
		Available:    true,
		Message:      messageBytes,
		ServiceType:  otlpRelayServiceType,
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       otlpRelaySource,
		KvStoreId:    kvStoreID,
	}, len(messageBytes), nil
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
