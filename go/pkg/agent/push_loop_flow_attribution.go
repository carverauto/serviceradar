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
// loop tick while the agent holds the serviceradar.netprobe.flow_attribution
// grant and the bulk spool is connected, and pushFlowAttributionEdge commits
// the batch to the spool. Payload rules live on FlowAttributionEventBatch in
// proto/agent/netprobe/v1/netprobe.proto.
//
// The core-side 5-tuple join consumer reads the published observations
// and pairs them with AttributedFlowMessage records published by the
// host-slice flow collector on `flow.host-slice.<agent_id>`.
//
// Partition guard (B-4 defeater): the agent does NOT populate any
// partition field inside the batch payload; core resolves the partition
// from the record's network_scope_id.
package agent

import (
	"errors"
	"sync"
	"sync/atomic"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

const (
	// flowAttributionMaxEventsPerChunk bounds each drained sidecar batch.
	flowAttributionMaxEventsPerChunk = 4096

	// flowAttributionMaxDrainPerPush bounds the total number of
	// FlowAttributionEvents drained per push loop tick. This keeps the agent
	// from spending an unbounded amount of time in one status pass, but no
	// longer caps a busy worker to a single 4096-event chunk every 30s.
	flowAttributionMaxDrainPerPush = 32 * 1024

	// flowAttributionMaxBatchMessageBytes is the target maximum size for a
	// single marshaled FlowAttributionEventBatch.
	flowAttributionMaxBatchMessageBytes = 6 * 1024 * 1024

	// flowAttributionMaxDeliveryStepsPerPush bounds the records appended in
	// one push-loop pass. A step either spools one window or quarantines one
	// permanently oversized event.
	flowAttributionMaxDeliveryStepsPerPush = 8
)

var (
	errFlowAttributionEmptyWindow             = errors.New("cannot build flow attribution delivery window without events")
	errFlowAttributionEventExceedsBatchBudget = errors.New("flow attribution event exceeds batch message byte budget")
)

// flowAttributionPendingBatch owns events removed from the sidecar channel
// until the spool has admitted them. The batch is bounded by
// flowAttributionMaxDrainPerPush.
type flowAttributionPendingBatch struct {
	events              []*netprobepb.FlowAttributionEvent
	hitDrainLimit       bool
	batchStart          time.Time
	batchEnd            time.Time
	cumulativeDropped   uint64
	dropped             uint32
	dropBaselinePending bool
}

// flowAttributionDeliveryQueue keeps at most one drained batch in memory. A
// retryable spool refusal leaves the prefix pending for the next push tick.
// Prefixes leave only once the spool admits them; a permanently oversized
// single event is explicitly quarantined. This is intentionally bounded, and
// what it holds does not survive an agent restart.
type flowAttributionDeliveryQueue struct {
	mu          sync.Mutex
	pending     *flowAttributionPendingBatch
	edgePending *flowAttributionPendingEdgeRecord
	// droppedAcked is the netprobe sidecar's cumulative drop count as of the
	// last batch the spool admitted, so each batch reports only the
	// drops since then. It resets across agent restarts, as the sidecar's
	// counter does.
	droppedAcked atomic.Uint64
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
	q.edgePending = nil

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
	q.edgePending = nil

	remaining := len(batch.events)
	if remaining == 0 {
		q.pending = nil
	}

	return quarantined, remaining, true
}

func (q *flowAttributionDeliveryQueue) dropPrefix(
	batch *flowAttributionPendingBatch,
	eventCount int,
) bool {
	q.mu.Lock()
	defer q.mu.Unlock()

	if batch == nil || q.pending != batch || eventCount <= 0 || eventCount > len(batch.events) {
		return false
	}

	for i := range eventCount {
		batch.events[i] = nil
	}
	batch.events = batch.events[eventCount:len(batch.events):len(batch.events)]
	q.edgePending = nil
	if len(batch.events) == 0 {
		q.pending = nil
	}

	return true
}

// pushFlowAttribution drains buffered FlowAttributionEvents from the netprobe
// sidecar into a bounded pending batch and spools it as edge records under the
// flow attribution grant. Spooled prefixes are removed only once the spool has
// admitted them; a retryable refusal retries the same prefix on the next tick.
// A permanently oversized single event is quarantined so later events progress.
// Without a grant nothing is drained: the sidecar keeps its events and counts
// what its channel drops, and the next batch reports that count.
//
// Returns false when:
//   - the agent holds no flow attribution grant or no spool;
//   - the netprobe sidecar is not attached (e.g. host-network
//     visibility disabled);
//   - no events were available to drain;
//   - nothing was admitted to the spool.
func (p *PushLoop) pushFlowAttribution() bool {
	spoolApp, capability := p.edgeFlowAttributionTarget(time.Now())
	if spoolApp == nil || capability == nil {
		p.holdForGrant(edgeProducerFlowAttribution)
		return false
	}

	p.server.mu.RLock()
	netprobeSidecar := p.server.netprobeSidecar
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

		cumulativeDropped := netprobeSidecar.DroppedFlowAttributionEvents()
		dropped := p.flowAttributionDelivery.observeDropped(cumulativeDropped)

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

	return p.pushFlowAttributionEdge(pending, spoolApp, capability)
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

// observeDropped returns the drops since the acknowledged baseline, given the
// sidecar's cumulative drop count. It does NOT advance the baseline: callers
// commit the cumulative value only after the gateway has acked the batch, so a
// transport failure leaves the baseline unmoved and the next push replays the
// unreported delta.
func (q *flowAttributionDeliveryQueue) observeDropped(cumulative uint64) uint32 {
	prev := q.droppedAcked.Load()
	if cumulative < prev {
		// Counter wrapped or client was replaced. Treat the current
		// value as the delta and let the commit reset the baseline.
		return clampToUint32(cumulative)
	}
	return clampToUint32(cumulative - prev)
}

// commitDropped advances the drop baseline after a successful gateway ack.
// Storing the same cumulative value again is harmless.
func (q *flowAttributionDeliveryQueue) commitDropped(cumulative uint64) {
	// Plain Store is sufficient — only one push goroutine reaches here
	// at a time per agent, and a later observe will pick up further
	// drops naturally.
	q.droppedAcked.Store(cumulative)
}

func clampToUint32(v uint64) uint32 {
	const maxU32 uint64 = 1<<32 - 1
	if v > maxU32 {
		return uint32(maxU32)
	}
	return uint32(v)
}
