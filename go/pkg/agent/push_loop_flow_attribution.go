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
	// preserves the existing per-message behavior while allowing a single
	// push tick to forward multiple chunks when a busy host accumulated more
	// than one chunk during the 30s agent push interval.
	flowAttributionMaxEventsPerChunk = 4096

	// flowAttributionMaxDrainPerPush bounds the total number of
	// FlowAttributionEvents drained per push loop tick. This keeps the agent
	// from spending an unbounded amount of time in one status pass, but no
	// longer caps a busy worker to a single 4096-event chunk every 30s.
	flowAttributionMaxDrainPerPush = 32 * 1024

	// flowAttributionMaxBatchMessageBytes is the target maximum size for a
	// single marshaled FlowAttributionEventBatch. It sits below the
	// GatewayClient's 16MiB StreamStatus chunk limit to leave room for the
	// surrounding GatewayStatusChunk envelope.
	flowAttributionMaxBatchMessageBytes = 6 * 1024 * 1024
)

var errFlowAttributionEventExceedsBatchBudget = errors.New("flow attribution event exceeds batch message byte budget")

// flowAttributionPendingBatch owns events removed from the sidecar channel
// until core has durably accepted them through the gateway. The batch is
// bounded by flowAttributionMaxDrainPerPush.
type flowAttributionPendingBatch struct {
	eventBatches      [][]*netprobepb.FlowAttributionEvent
	totalEvents       int
	hitDrainLimit     bool
	batchStart        time.Time
	batchEnd          time.Time
	cumulativeDropped uint64
	dropped           uint32
}

// flowAttributionDeliveryQueue keeps at most one drained batch in memory. A
// failed StreamStatus call leaves the batch pending for the next push tick;
// only a positive acknowledgement clears it. This is intentionally bounded,
// but it is not a disk spool and does not survive an agent process restart.
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

func (q *flowAttributionDeliveryQueue) acknowledge(batch *flowAttributionPendingBatch) bool {
	q.mu.Lock()
	defer q.mu.Unlock()

	if batch == nil || q.pending != batch {
		return false
	}

	q.pending = nil

	return true
}

// agentFlowAttributionEventsForwardedTotal counts the number of
// FlowAttributionEvent records the agent has successfully forwarded
// to the gateway, surfaced as
// `agent_flow_attribution_events_forwarded_total` by the Prometheus
// exporter.
//
//nolint:gochecknoglobals // process-global Prometheus counter
var agentFlowAttributionEventsForwardedTotal atomic.Uint64

// AgentFlowAttributionEventsForwardedTotal returns the current value
// of the agent-side forwarded-events counter. Exposed for the
// Prometheus exporter and tests.
func AgentFlowAttributionEventsForwardedTotal() uint64 {
	return agentFlowAttributionEventsForwardedTotal.Load()
}

// resetAgentFlowAttributionEventsForwardedTotal is exposed for tests.
func resetAgentFlowAttributionEventsForwardedTotal() {
	agentFlowAttributionEventsForwardedTotal.Store(0)
}

// pushFlowAttribution drains buffered FlowAttributionEvents from the netprobe
// sidecar into a bounded pending batch and streams it to the agent-gateway.
// The pending batch is cleared only after a positive gateway acknowledgement;
// transport or persistence failures retry the same events on the next tick.
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
			eventBatches:      eventBatches,
			totalEvents:       totalEvents,
			hitDrainLimit:     hitDrainLimit,
			batchStart:        batchStart,
			batchEnd:          time.Now().UTC(),
			cumulativeDropped: cumulativeDropped,
			dropped:           dropped,
		}
	})
	if pending == nil {
		return false
	}

	gatewayID := p.gateway.GetGatewayID()

	runtimeMetadata := currentRuntimeMetadata()
	chunks, totalMessageBytes, err := buildFlowAttributionGatewayStatusChunks(
		pending.eventBatches,
		pending.batchStart,
		pending.batchEnd,
		pending.dropped,
		agentID,
		gatewayID,
		partition,
		kvStoreID,
		p.getSourceIP(),
		runtimeMetadata,
	)
	if err != nil {
		p.logger.Error().Err(err).
			Int("event_count", pending.totalEvents).
			Msg("Failed to marshal flow attribution batch")
		return false
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	resp, err := p.gateway.StreamStatus(pushCtx, chunks)
	if err != nil {
		p.logger.Error().Err(err).
			Int("event_count", pending.totalEvents).
			Int("chunk_count", len(chunks)).
			Msg("Failed to stream flow attribution batch to gateway")
		return false
	}

	if resp == nil || !resp.Received {
		p.logger.Warn().
			Int("event_count", pending.totalEvents).
			Int("chunk_count", len(chunks)).
			Msg("Gateway did not acknowledge flow attribution batch")
		return false
	}

	if !p.flowAttributionDelivery.acknowledge(pending) {
		p.logger.Warn().
			Int("event_count", pending.totalEvents).
			Msg("Flow attribution acknowledgement did not match the pending batch")
		return false
	}

	agentFlowAttributionEventsForwardedTotal.Add(uint64(pending.totalEvents))
	commitFlowAttributionDropped(pending.cumulativeDropped)

	logEvent := p.logger.Info()
	if pending.hitDrainLimit {
		logEvent = p.logger.Warn()
	}
	logEvent.
		Int("event_count", pending.totalEvents).
		Int("chunk_count", len(chunks)).
		Int("message_bytes", totalMessageBytes).
		Uint32("dropped_since_last", pending.dropped).
		Msg("Streamed flow attribution batch to gateway")

	return true
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

func buildFlowAttributionGatewayStatusChunks(
	eventBatches [][]*netprobepb.FlowAttributionEvent,
	batchStart, batchEnd time.Time,
	droppedSinceLast uint32,
	agentID, gatewayID, partition, kvStoreID, sourceIP string,
	runtimeMetadata statusRuntimeMetadata,
) ([]*proto.GatewayStatusChunk, int, error) {
	statusChunks := make([]*proto.GatewayStatusChunk, 0, len(eventBatches))
	totalMessageBytes := 0
	droppedForNextChunk := droppedSinceLast

	for _, events := range eventBatches {
		if len(events) == 0 {
			continue
		}

		chunks, messageBytes, err := appendFlowAttributionGatewayStatusChunks(
			nil,
			events,
			batchStart,
			batchEnd,
			droppedForNextChunk,
			agentID,
			gatewayID,
			partition,
			kvStoreID,
			sourceIP,
			runtimeMetadata,
		)
		if err != nil {
			return nil, 0, err
		}

		statusChunks = append(statusChunks, chunks...)
		totalMessageBytes += messageBytes
		droppedForNextChunk = 0
	}

	if len(statusChunks) == 0 {
		return nil, 0, nil
	}

	totalChunks := int32(len(statusChunks))
	for i, chunk := range statusChunks {
		chunk.ChunkIndex = int32(i)
		chunk.TotalChunks = totalChunks
		chunk.IsFinal = int32(i) == totalChunks-1
	}

	return statusChunks, totalMessageBytes, nil
}

func appendFlowAttributionGatewayStatusChunks(
	chunks []*proto.GatewayStatusChunk,
	events []*netprobepb.FlowAttributionEvent,
	batchStart, batchEnd time.Time,
	droppedSinceLast uint32,
	agentID, gatewayID, partition, kvStoreID, sourceIP string,
	runtimeMetadata statusRuntimeMetadata,
) ([]*proto.GatewayStatusChunk, int, error) {
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
		return nil, 0, err
	}

	if len(messageBytes) <= flowAttributionMaxBatchMessageBytes {
		return append(chunks, newFlowAttributionGatewayStatusChunk(
			status,
			agentID,
			gatewayID,
			partition,
			sourceIP,
			runtimeMetadata,
		)), len(messageBytes), nil
	}

	if len(events) <= 1 {
		return nil, 0, fmt.Errorf(
			"%w: bytes=%d max=%d",
			errFlowAttributionEventExceedsBatchBudget,
			len(messageBytes),
			flowAttributionMaxBatchMessageBytes,
		)
	}

	mid := len(events) / 2
	leftChunks, leftBytes, err := appendFlowAttributionGatewayStatusChunks(
		chunks,
		events[:mid],
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
		return nil, 0, err
	}

	rightChunks, rightBytes, err := appendFlowAttributionGatewayStatusChunks(
		leftChunks,
		events[mid:],
		batchStart,
		batchEnd,
		0,
		agentID,
		gatewayID,
		partition,
		kvStoreID,
		sourceIP,
		runtimeMetadata,
	)
	if err != nil {
		return nil, 0, err
	}

	return rightChunks, leftBytes + rightBytes, nil
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

// commitFlowAttributionDropped advances the dropped-counter baseline
// after a successful gateway ack. Idempotent: a second commit with the
// same cumulative value is a no-op via CompareAndSwap semantics.
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
