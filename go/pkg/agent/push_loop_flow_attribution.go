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

// Package agent - flow attribution forwarding (Option A).
//
// The netprobe sidecar emits FlowAttributionEvent records on its
// flowEvents channel. This file drains those events on each push
// loop tick and forwards them to the agent-gateway inside the existing
// GatewayServiceStatus envelope, keyed by Source="flow-attribution".
//
// The core-side 5-tuple join consumer reads these batches and pairs
// them with AttributedFlowMessage records published by the host-slice
// flow collector on `flow.host-slice.<agent_id>`.
//
// Partition guard (B-4 defeater): the agent does NOT populate any
// partition field inside the batch payload. The cert-derived
// partition_id attached at the agent-gateway is the only value used
// by core; the envelope's Partition field is informational only.
package agent

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	gproto "google.golang.org/protobuf/proto"
)

const (
	// FlowAttributionServiceName is the service_name used on
	// GatewayServiceStatus envelopes carrying flow-attribution batches.
	FlowAttributionServiceName = "flow-attribution"

	// FlowAttributionServiceType identifies the envelope as originating
	// from the passive netprobe sidecar's flow-attribution stream.
	FlowAttributionServiceType = "passive-netprobe"

	// FlowAttributionSource is the GatewayServiceStatus.Source
	// discriminator used to route batches to the core-elx
	// FlowAttributionRouter / FlowJoinCache.
	FlowAttributionSource = "flow-attribution"

	// flowAttributionMaxEventsPerChunk bounds each protobuf payload. This
	// preserves the existing per-message behavior while allowing a push tick to
	// forward multiple independently acknowledged windows when a busy host has
	// accumulated more than one chunk.
	flowAttributionMaxEventsPerChunk = 4096

	// flowAttributionMaxDrainPerPush bounds the total number of
	// FlowAttributionEvents drained per push loop tick. This keeps the agent
	// from spending an unbounded amount of time in one status pass, but no
	// longer caps a busy worker to a single 4096-event chunk every 30s.
	flowAttributionMaxDrainPerPush = 32 * 1024

	// flowAttributionMaxBatchMessageBytes is the target maximum size for a
	// single marshaled FlowAttributionEventBatch.
	flowAttributionMaxBatchMessageBytes = 6 * 1024 * 1024

	// flowAttributionMaxStreamWindowBytes bounds the complete protobuf sent in
	// one StreamStatus RPC. Each RPC contains exactly one chunk, keeping it well
	// below the GatewayClient's 16MiB chunk and 64MiB stream limits.
	flowAttributionMaxStreamWindowBytes = 8 * 1024 * 1024

	// flowAttributionMaxDeliveryStepsPerPush bounds synchronous core writes in
	// one push-loop pass. A step either acknowledges one delivery window or
	// quarantines one permanently oversized event.
	flowAttributionMaxDeliveryStepsPerPush = 8

	// Optional runtime fields are diagnostic only. Omitting a pathological value
	// prevents host metadata from making every otherwise valid event impossible
	// to deliver.
	flowAttributionMaxRuntimeMetadataBytes = 256
	flowAttributionMaxKVStoreIDBytes       = 1024
)

var (
	errFlowAttributionEmptyWindow             = errors.New("cannot build flow attribution delivery window without events")
	errFlowAttributionEventExceedsBatchBudget = errors.New("flow attribution event exceeds batch message byte budget")
	errFlowAttributionWindowExceedsBudget     = errors.New("flow attribution stream window exceeds byte budget")
)

// flowAttributionPendingBatch owns events removed from the sidecar channel
// until core has durably accepted them through the gateway. The batch is
// bounded by flowAttributionMaxDrainPerPush.
type flowAttributionPendingBatch struct {
	events              []*netprobepb.FlowAttributionEvent
	hitDrainLimit       bool
	batchStart          time.Time
	batchEnd            time.Time
	cumulativeDropped   uint64
	dropped             uint32
	dropBaselinePending bool
}

type flowAttributionDeliveryWindow struct {
	chunk        *proto.GatewayStatusChunk
	eventCount   int
	messageBytes int
	streamBytes  int
}

// flowAttributionDeliveryQueue keeps at most one drained batch in memory. A
// failed StreamStatus call leaves the prefix pending for the next push tick.
// Delivered prefixes require a positive acknowledgement; a permanently
// oversized single event is explicitly quarantined. This is intentionally
// bounded, but it is not a disk spool and does not survive an agent restart.
type flowAttributionDeliveryQueue struct {
	mu      sync.Mutex
	pending *flowAttributionPendingBatch
}

func (q *flowAttributionDeliveryQueue) getOrLoad(load func() *flowAttributionPendingBatch) *flowAttributionPendingBatch {
	q.mu.Lock()
	defer q.mu.Unlock()

	if q.pending == nil {
		q.pending = load()
	}

	return q.pending
}

func (q *flowAttributionDeliveryQueue) acknowledgePrefix(
	batch *flowAttributionPendingBatch,
	eventCount int,
) (uint64, bool, int, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()

	if batch == nil || q.pending != batch || eventCount <= 0 || eventCount > len(batch.events) {
		return 0, false, 0, false
	}

	for i := range eventCount {
		batch.events[i] = nil
	}
	batch.events = batch.events[eventCount:len(batch.events):len(batch.events)]

	cumulativeDropped := uint64(0)
	commitDropBaseline := false
	if batch.dropBaselinePending {
		cumulativeDropped = batch.cumulativeDropped
		commitDropBaseline = true
		batch.dropBaselinePending = false
		batch.dropped = 0
	}

	remaining := len(batch.events)
	if remaining == 0 {
		q.pending = nil
	}

	return cumulativeDropped, commitDropBaseline, remaining, true
}

func (q *flowAttributionDeliveryQueue) quarantineFirst(
	batch *flowAttributionPendingBatch,
) (*netprobepb.FlowAttributionEvent, int, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()

	if batch == nil || q.pending != batch || len(batch.events) == 0 {
		return nil, 0, false
	}

	quarantined := batch.events[0]
	batch.events[0] = nil
	batch.events = batch.events[1:len(batch.events):len(batch.events)]

	remaining := len(batch.events)
	if remaining == 0 {
		q.pending = nil
	}
	agentFlowAttributionEventsQuarantinedTotal.Add(1)

	return quarantined, remaining, true
}

func (q *flowAttributionDeliveryQueue) dropPrefix(
	batch *flowAttributionPendingBatch,
	eventCount int,
) (int, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()

	if batch == nil || q.pending != batch || eventCount <= 0 || eventCount > len(batch.events) {
		return 0, false
	}

	for i := range eventCount {
		batch.events[i] = nil
	}
	batch.events = batch.events[eventCount:len(batch.events):len(batch.events)]
	remaining := len(batch.events)
	if remaining == 0 {
		q.pending = nil
	}

	return remaining, true
}

// agentFlowAttributionEventsForwardedTotal counts the number of
// FlowAttributionEvent records the agent has successfully forwarded
// to the gateway, surfaced as
// `agent_flow_attribution_events_forwarded_total` by the Prometheus
// exporter.
//
//nolint:gochecknoglobals // process-global Prometheus counter
var agentFlowAttributionEventsForwardedTotal atomic.Uint64

// agentFlowAttributionEventsQuarantinedTotal counts individual events that
// cannot fit in an otherwise empty delivery window. Quarantining the poison
// event allows later attribution records to continue in order.
//
//nolint:gochecknoglobals // process-global Prometheus counter
var agentFlowAttributionEventsQuarantinedTotal atomic.Uint64

// AgentFlowAttributionEventsForwardedTotal returns the current value
// of the agent-side forwarded-events counter. Exposed for the
// Prometheus exporter and tests.
func AgentFlowAttributionEventsForwardedTotal() uint64 {
	return agentFlowAttributionEventsForwardedTotal.Load()
}

// AgentFlowAttributionEventsQuarantinedTotal returns the current value of the
// agent-side permanently-oversized-events counter.
func AgentFlowAttributionEventsQuarantinedTotal() uint64 {
	return agentFlowAttributionEventsQuarantinedTotal.Load()
}

// resetAgentFlowAttributionEventCounters is exposed for tests.
func resetAgentFlowAttributionEventCounters() {
	agentFlowAttributionEventsForwardedTotal.Store(0)
	agentFlowAttributionEventsQuarantinedTotal.Store(0)
}

// pushFlowAttribution drains buffered FlowAttributionEvents from the netprobe
// sidecar into a bounded pending batch and streams it to the agent-gateway.
// Delivered prefixes are removed only after a positive gateway acknowledgement;
// transport or persistence failures retry the same prefix on the next tick. A
// permanently oversized single event is quarantined so later events progress.
//
// Returns false when:
//   - the netprobe sidecar is not attached (e.g. host-network
//     visibility disabled);
//   - no events were available to drain;
//   - marshaling or transport failed (errors are logged).
func (p *PushLoop) pushFlowAttribution(ctx context.Context) bool {
	p.server.mu.RLock()
	netprobeSidecar := p.server.netprobeSidecar
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()

	pending := p.flowAttributionDelivery.getOrLoad(func() *flowAttributionPendingBatch {
		if netprobeSidecar == nil {
			return nil
		}

		batchStart := time.Now().UTC()
		eventBatches, totalEvents, hitDrainLimit := drainFlowAttributionBatches(netprobeSidecar)
		if totalEvents == 0 {
			return nil
		}

		cumulativeDropped, dropped := observeFlowAttributionDropped(netprobeSidecar)

		return &flowAttributionPendingBatch{
			events:              flattenFlowAttributionEventBatches(eventBatches, totalEvents),
			hitDrainLimit:       hitDrainLimit,
			batchStart:          batchStart,
			batchEnd:            time.Now().UTC(),
			cumulativeDropped:   cumulativeDropped,
			dropped:             dropped,
			dropBaselinePending: true,
		}
	})
	if pending == nil {
		return false
	}

	gatewayID := gatewayIDFromClient(p.gateway)
	runtimeMetadata := currentRuntimeMetadata()
	sourceIP := p.getSourceIP()
	sentAny := false

	for range flowAttributionMaxDeliveryStepsPerPush {
		if len(pending.events) == 0 {
			break
		}

		droppedSinceLast := uint32(0)
		if pending.dropBaselinePending {
			droppedSinceLast = pending.dropped
		}

		window, err := buildNextFlowAttributionDeliveryWindow(
			pending.events,
			pending.batchStart,
			pending.batchEnd,
			droppedSinceLast,
			agentID,
			gatewayID,
			partition,
			kvStoreID,
			sourceIP,
			runtimeMetadata,
		)
		if errors.Is(err, errFlowAttributionEventExceedsBatchBudget) {
			poisonBytes := gproto.Size(&netprobepb.FlowAttributionEventBatch{
				Events:             pending.events[:1],
				BatchStartUnixNano: pending.batchStart.UnixNano(),
				BatchEndUnixNano:   pending.batchEnd.UnixNano(),
				DroppedSinceLast:   droppedSinceLast,
			})
			quarantined, remaining, ok := p.flowAttributionDelivery.quarantineFirst(pending)
			if !ok {
				p.logger.Warn().Msg("Flow attribution quarantine did not match the pending batch")
				break
			}

			recordAgentRetainedPoisonDrop(
				"flow-attribution",
				retainedPoisonReasonNames[poisonReasonPayloadTooLarge],
				1,
				poisonBytes,
			)
			p.logger.Error().Err(err).
				Uint32("pid", quarantined.GetPid()).
				Str("comm", quarantined.GetComm()).
				Int("remaining_events", remaining).
				Msg("Quarantined permanently oversized flow attribution event")
			continue
		}
		if err != nil {
			p.logger.Error().Err(err).
				Int("remaining_events", len(pending.events)).
				Msg("Failed to build flow attribution delivery window")
			break
		}

		pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		resp, streamErr := p.streamFlowAttributionStatus(pushCtx, []*proto.GatewayStatusChunk{window.chunk})
		cancel()

		if streamErr != nil {
			if reason, terminal := retainedPoisonDropReason(streamErr); terminal {
				remaining, ok := p.flowAttributionDelivery.dropPrefix(pending, window.eventCount)
				if !ok {
					p.logger.Warn().Msg("Flow attribution poison drop did not match the pending batch")
					break
				}

				recordAgentRetainedPoisonDrop("flow-attribution", reason, window.eventCount, window.streamBytes)
				p.logger.Error().Err(streamErr).
					Str("reason", reason).
					Int("event_count", window.eventCount).
					Int("remaining_events", remaining).
					Msg("Poison-dropped terminally invalid flow attribution window")
				continue
			}

			p.logger.Error().Err(streamErr).
				Int("event_count", window.eventCount).
				Int("remaining_events", len(pending.events)).
				Msg("Failed to stream flow attribution delivery window to gateway")
			break
		}
		if resp == nil || !resp.Received {
			p.logger.Warn().
				Int("event_count", window.eventCount).
				Int("remaining_events", len(pending.events)).
				Msg("Gateway did not acknowledge flow attribution delivery window")
			break
		}

		cumulativeDropped, commitDropBaseline, remaining, ok :=
			p.flowAttributionDelivery.acknowledgePrefix(pending, window.eventCount)
		if !ok {
			p.logger.Warn().
				Int("event_count", window.eventCount).
				Msg("Flow attribution prefix acknowledgement did not match the pending batch")
			break
		}

		agentFlowAttributionEventsForwardedTotal.Add(uint64(window.eventCount))
		if commitDropBaseline {
			commitFlowAttributionDropped(cumulativeDropped)
		}
		sentAny = true

		logEvent := p.logger.Info()
		if pending.hitDrainLimit {
			logEvent = p.logger.Warn()
		}
		logEvent.
			Int("event_count", window.eventCount).
			Int("remaining_events", remaining).
			Int("message_bytes", window.messageBytes).
			Int("stream_bytes", window.streamBytes).
			Uint32("dropped_since_last", droppedSinceLast).
			Msg("Streamed flow attribution delivery window to gateway")
	}

	return sentAny
}

func (p *PushLoop) streamFlowAttributionStatus(
	ctx context.Context,
	chunks []*proto.GatewayStatusChunk,
) (*proto.GatewayStatusResponse, error) {
	if p.flowAttributionStreamStatus != nil {
		return p.flowAttributionStreamStatus(ctx, chunks)
	}
	if p.gateway == nil {
		return nil, agentgateway.ErrGatewayNotConnected
	}

	return p.gateway.StreamStatus(ctx, chunks)
}

// buildFlowAttributionGatewayStatus packs the drained events into a
// FlowAttributionEventBatch, marshals it, and wraps the bytes in a
// GatewayServiceStatus envelope. Pure / no IO so it can be unit-tested
// without spinning up a real gateway client.
//
// The batch deliberately carries NO partition field — core uses the
// cert-derived partition from the gateway envelope. The envelope's
// Partition is informational only.
func buildFlowAttributionGatewayStatus(
	events []*netprobepb.FlowAttributionEvent,
	batchStart, batchEnd time.Time,
	droppedSinceLast uint32,
	agentID, gatewayID, partition, kvStoreID string,
) (*proto.GatewayServiceStatus, []byte, error) {
	// Always include the events field (empty repeated is preserved by
	// proto.Marshal automatically); never omit conditionally.
	batch := &netprobepb.FlowAttributionEventBatch{
		Events:             events,
		BatchStartUnixNano: batchStart.UnixNano(),
		BatchEndUnixNano:   batchEnd.UnixNano(),
		DroppedSinceLast:   droppedSinceLast,
	}

	messageBytes, err := gproto.Marshal(batch)
	if err != nil {
		return nil, nil, err
	}

	status := &proto.GatewayServiceStatus{
		ServiceName:  FlowAttributionServiceName,
		Available:    true,
		Message:      messageBytes,
		ServiceType:  FlowAttributionServiceType,
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       FlowAttributionSource,
		KvStoreId:    kvStoreID,
	}
	return status, messageBytes, nil
}

func drainFlowAttributionBatches(s *agentnetprobe.Sidecar) ([][]*netprobepb.FlowAttributionEvent, int, bool) {
	if s == nil {
		return nil, 0, false
	}

	batches := make([][]*netprobepb.FlowAttributionEvent, 0, flowAttributionMaxDrainPerPush/flowAttributionMaxEventsPerChunk)
	totalEvents := 0

	for totalEvents < flowAttributionMaxDrainPerPush {
		remaining := flowAttributionMaxDrainPerPush - totalEvents
		drainLimit := flowAttributionMaxEventsPerChunk
		if remaining < drainLimit {
			drainLimit = remaining
		}

		events := s.DrainFlowAttributionEvents(drainLimit)
		if len(events) == 0 {
			break
		}

		batches = append(batches, events)
		totalEvents += len(events)

		if len(events) < drainLimit {
			break
		}
	}

	return batches, totalEvents, totalEvents >= flowAttributionMaxDrainPerPush
}

func flattenFlowAttributionEventBatches(
	eventBatches [][]*netprobepb.FlowAttributionEvent,
	totalEvents int,
) []*netprobepb.FlowAttributionEvent {
	events := make([]*netprobepb.FlowAttributionEvent, 0, totalEvents)
	for _, batch := range eventBatches {
		events = append(events, batch...)
	}

	return events
}

func buildNextFlowAttributionDeliveryWindow(
	events []*netprobepb.FlowAttributionEvent,
	batchStart, batchEnd time.Time,
	droppedSinceLast uint32,
	agentID, gatewayID, partition, kvStoreID, sourceIP string,
	runtimeMetadata statusRuntimeMetadata,
) (*flowAttributionDeliveryWindow, error) {
	if len(events) == 0 {
		return nil, errFlowAttributionEmptyWindow
	}

	maxEvents := min(len(events), flowAttributionMaxEventsPerChunk)
	batchForSize := func(eventCount int) *netprobepb.FlowAttributionEventBatch {
		return &netprobepb.FlowAttributionEventBatch{
			Events:             events[:eventCount],
			BatchStartUnixNano: batchStart.UnixNano(),
			BatchEndUnixNano:   batchEnd.UnixNano(),
			DroppedSinceLast:   droppedSinceLast,
		}
	}

	firstEventBytes := gproto.Size(batchForSize(1))
	if firstEventBytes > flowAttributionMaxBatchMessageBytes {
		return nil, fmt.Errorf(
			"%w: bytes=%d max=%d",
			errFlowAttributionEventExceedsBatchBudget,
			firstEventBytes,
			flowAttributionMaxBatchMessageBytes,
		)
	}

	// Protobuf size is monotonic as repeated events are appended. Find the
	// largest ordered prefix that fits without repeatedly marshaling candidates.
	low, high := 1, maxEvents
	eventCount := 1
	for low <= high {
		mid := low + (high-low)/2
		if gproto.Size(batchForSize(mid)) <= flowAttributionMaxBatchMessageBytes {
			eventCount = mid
			low = mid + 1
		} else {
			high = mid - 1
		}
	}

	window, err := marshalFlowAttributionDeliveryWindow(
		events[:eventCount],
		batchStart,
		batchEnd,
		droppedSinceLast,
		agentID,
		gatewayID,
		partition,
		kvStoreID,
		sourceIP,
		runtimeMetadata,
	)
	if err != nil {
		return nil, err
	}

	// The message budget normally leaves 2MiB for envelope metadata. If a
	// deployment has unusually large metadata, reduce the event prefix until
	// the complete RPC window also fits. An envelope that cannot carry even one
	// event is a configuration failure, not a poison event.
	for window.streamBytes > flowAttributionMaxStreamWindowBytes && eventCount > 1 {
		eventCount /= 2
		window, err = marshalFlowAttributionDeliveryWindow(
			events[:eventCount],
			batchStart,
			batchEnd,
			droppedSinceLast,
			agentID,
			gatewayID,
			partition,
			kvStoreID,
			sourceIP,
			runtimeMetadata,
		)
		if err != nil {
			return nil, err
		}
	}

	if window.streamBytes > flowAttributionMaxStreamWindowBytes {
		return nil, fmt.Errorf(
			"%w: bytes=%d max=%d",
			errFlowAttributionWindowExceedsBudget,
			window.streamBytes,
			flowAttributionMaxStreamWindowBytes,
		)
	}

	return window, nil
}

func marshalFlowAttributionDeliveryWindow(
	events []*netprobepb.FlowAttributionEvent,
	batchStart, batchEnd time.Time,
	droppedSinceLast uint32,
	agentID, gatewayID, partition, kvStoreID, sourceIP string,
	runtimeMetadata statusRuntimeMetadata,
) (*flowAttributionDeliveryWindow, error) {
	kvStoreID = boundedFlowAttributionOptionalField(kvStoreID, flowAttributionMaxKVStoreIDBytes)
	sourceIP = boundedFlowAttributionOptionalField(sourceIP, flowAttributionMaxRuntimeMetadataBytes)
	runtimeMetadata = boundedFlowAttributionRuntimeMetadata(runtimeMetadata)

	status, messageBytes, err := buildFlowAttributionGatewayStatus(
		events,
		batchStart,
		batchEnd,
		droppedSinceLast,
		agentID,
		gatewayID,
		partition,
		kvStoreID,
	)
	if err != nil {
		return nil, err
	}

	chunk := newFlowAttributionGatewayStatusChunk(
		status,
		agentID,
		gatewayID,
		partition,
		sourceIP,
		runtimeMetadata,
	)
	chunk.ChunkIndex = 0
	chunk.TotalChunks = 1
	chunk.IsFinal = true

	return &flowAttributionDeliveryWindow{
		chunk:        chunk,
		eventCount:   len(events),
		messageBytes: len(messageBytes),
		streamBytes:  gproto.Size(chunk),
	}, nil
}

func boundedFlowAttributionRuntimeMetadata(metadata statusRuntimeMetadata) statusRuntimeMetadata {
	return statusRuntimeMetadata{
		Version:  boundedFlowAttributionOptionalField(metadata.Version, flowAttributionMaxRuntimeMetadataBytes),
		Hostname: boundedFlowAttributionOptionalField(metadata.Hostname, flowAttributionMaxRuntimeMetadataBytes),
		Os:       boundedFlowAttributionOptionalField(metadata.Os, flowAttributionMaxRuntimeMetadataBytes),
		Arch:     boundedFlowAttributionOptionalField(metadata.Arch, flowAttributionMaxRuntimeMetadataBytes),
	}
}

func boundedFlowAttributionOptionalField(value string, maxBytes int) string {
	if len(value) > maxBytes {
		return ""
	}

	return value
}

func newFlowAttributionGatewayStatusChunk(
	status *proto.GatewayServiceStatus,
	agentID, gatewayID, partition, sourceIP string,
	runtimeMetadata statusRuntimeMetadata,
) *proto.GatewayStatusChunk {
	return &proto.GatewayStatusChunk{
		Services:  []*proto.GatewayServiceStatus{status},
		GatewayId: gatewayID,
		AgentId:   agentID,
		Timestamp: time.Now().UnixNano(),
		Partition: partition,
		SourceIp:  sourceIP,
		Version:   runtimeMetadata.Version,
		Hostname:  runtimeMetadata.Hostname,
		Os:        runtimeMetadata.Os,
		Arch:      runtimeMetadata.Arch,
	}
}

// observeFlowAttributionDropped reads the cumulative drop counter from
// the netprobe sidecar's IPC client and returns (cumulative, delta
// since the previous successful push). It does NOT advance the
// baseline — callers must invoke commitFlowAttributionDropped with the
// returned cumulative value only after the gateway has acked the batch.
// A transport failure leaves the baseline unmoved so the next push
// replays the unreported delta.
//
// Tracked per-process; resets across agent restarts but is consistent
// with the rest of the agent's counter conventions.
func observeFlowAttributionDropped(s *agentnetprobe.Sidecar) (cumulative uint64, delta uint32) {
	cumulative = s.DroppedFlowAttributionEvents()
	prev := lastDroppedFlowAttribution.Load()
	if cumulative < prev {
		// Counter wrapped or client was replaced. Treat the current
		// value as the delta and let the commit reset the baseline.
		return cumulative, clampToUint32(cumulative)
	}
	return cumulative, clampToUint32(cumulative - prev)
}

// commitFlowAttributionDropped advances the dropped-counter baseline after a
// successful gateway ack. Storing the same cumulative value again is harmless.
func commitFlowAttributionDropped(cumulative uint64) {
	// Plain Store is sufficient — only one push goroutine reaches here
	// at a time per agent, and a later observe will pick up further
	// drops naturally.
	lastDroppedFlowAttribution.Store(cumulative)
}

// lastDroppedFlowAttribution holds the previously-observed cumulative
// drop count so the next batch can publish a delta. Package-level
// because the counter on the netprobe client is also process-global.
//
//nolint:gochecknoglobals // process-global baseline for cumulative-counter delta
var lastDroppedFlowAttribution atomic.Uint64

func clampToUint32(v uint64) uint32 {
	const maxU32 uint64 = 1<<32 - 1
	if v > maxU32 {
		return uint32(maxU32)
	}
	return uint32(v)
}
