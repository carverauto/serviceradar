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
	"encoding/binary"
	"errors"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	gproto "google.golang.org/protobuf/proto"
)

type flowAttributionPendingEdgeRecord struct {
	batch      *flowAttributionPendingBatch
	headEvent  *netprobepb.FlowAttributionEvent
	built      edgeMetricsBuilt
	eventCount int
}

func (q *flowAttributionDeliveryQueue) currentEdgePending(
	batch *flowAttributionPendingBatch,
) *flowAttributionPendingEdgeRecord {
	q.mu.Lock()
	defer q.mu.Unlock()

	if q.edgePending == nil || batch == nil || q.pending != batch {
		return nil
	}
	if len(batch.events) < q.edgePending.eventCount || batch.events[0] != q.edgePending.headEvent {
		q.edgePending = nil
		return nil
	}
	return q.edgePending
}

func (q *flowAttributionDeliveryQueue) setEdgePending(
	batch *flowAttributionPendingBatch,
	headEvent *netprobepb.FlowAttributionEvent,
	built edgeMetricsBuilt,
	eventCount int,
) *flowAttributionPendingEdgeRecord {
	q.mu.Lock()
	defer q.mu.Unlock()

	if batch == nil || q.pending != batch {
		return nil
	}
	q.edgePending = &flowAttributionPendingEdgeRecord{
		batch:      batch,
		headEvent:  headEvent,
		built:      built,
		eventCount: eventCount,
	}
	return q.edgePending
}

func (q *flowAttributionDeliveryQueue) clearEdgePending() {
	q.mu.Lock()
	defer q.mu.Unlock()

	q.edgePending = nil
}

func (p *PushLoop) edgeFlowAttributionTarget(now time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1) {
	if p == nil || p.edgeMetricsSpool == nil {
		return nil, nil
	}
	cap := p.edgeOutputGrants.current(edgerecord.FlowAttributionContractID, now)
	if cap == nil {
		return nil, nil
	}
	return p.edgeMetricsSpool, cap
}

func flowAttributionCapabilityMaxRows(capability *edgev1.EdgeSignedCapabilityV1) int {
	maxRows := edgerecord.FlowAttributionMaxRows
	claims := capability.GetProduction()
	if m := claims.GetMaxProjectedRowCount(); m > 0 && int(m) < maxRows {
		maxRows = int(m)
	}
	if maxWriteBytes := claims.GetMaxProjectedWriteBytes(); maxWriteBytes > 0 {
		byBytes := int(maxWriteBytes / edgerecord.FlowAttributionWriteBytesPerRow)
		if byBytes < maxRows {
			maxRows = byBytes
		}
	}
	return maxRows
}

func buildFlowAttributionEdgeRecord(
	capability *edgev1.EdgeSignedCapabilityV1,
	batch *netprobepb.FlowAttributionEventBatch,
) (edgeMetricsBuilt, error) {
	if err := edgerecord.ValidateFlowAttributionBatch(batch); err != nil {
		return edgeMetricsBuilt{}, err
	}
	payload, err := gproto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		return edgeMetricsBuilt{}, err
	}
	if len(payload) > flowAttributionMaxBatchMessageBytes {
		return edgeMetricsBuilt{}, fmt.Errorf(
			"%w: bytes=%d max=%d",
			errFlowAttributionEventExceedsBatchBudget,
			len(payload),
			flowAttributionMaxBatchMessageBytes,
		)
	}
	rows := uint32(len(batch.GetEvents()))
	writeBytes := uint64(rows) * edgerecord.FlowAttributionWriteBytesPerRow
	record, err := newEdgeRecord(capability, nil, payload, rows, writeBytes)
	if err != nil {
		return edgeMetricsBuilt{}, err
	}
	if err := edgerecord.ValidateFlowAttributionRecord(record); err != nil {
		return edgeMetricsBuilt{}, err
	}
	return edgeMetricsBuilt{record: record, payload: payload}, nil
}

func fitFlowAttributionEdgeChunk(
	pending *flowAttributionPendingBatch,
	droppedSinceLast uint32,
	capability *edgev1.EdgeSignedCapabilityV1,
) (edgeMetricsBuilt, int, error) {
	if pending == nil || len(pending.events) == 0 {
		return edgeMetricsBuilt{}, 0, errFlowAttributionEmptyWindow
	}
	maxRows := flowAttributionCapabilityMaxRows(capability)
	if maxRows <= 0 {
		return edgeMetricsBuilt{}, 0, fmt.Errorf("%w: capability allows 0 rows", edgerecord.ErrProductionGrant)
	}
	limit := min(len(pending.events), maxRows)

	batchFor := func(count int) *netprobepb.FlowAttributionEventBatch {
		events := append([]*netprobepb.FlowAttributionEvent(nil), pending.events[:count]...)
		return &netprobepb.FlowAttributionEventBatch{
			Events:             events,
			BatchStartUnixNano: pending.batchStart.UnixNano(),
			BatchEndUnixNano:   pending.batchEnd.UnixNano(),
			DroppedSinceLast:   droppedSinceLast,
		}
	}

	if fullBuilt, err := buildFlowAttributionEdgeRecord(capability, batchFor(limit)); err == nil {
		return fullBuilt, limit, nil
	} else if limit == 1 {
		return edgeMetricsBuilt{}, 0, err
	}

	headBuilt, headErr := buildFlowAttributionEdgeRecord(capability, batchFor(1))
	if headErr != nil {
		return edgeMetricsBuilt{}, 0, headErr
	}

	count, built := longestPrefix(limit, func(k int) (edgeMetricsBuilt, error) {
		if k == 1 {
			return headBuilt, nil
		}
		if k == limit {
			return edgeMetricsBuilt{}, errEdgeMetricsRecordTooLarge
		}
		return buildFlowAttributionEdgeRecord(capability, batchFor(k))
	})
	if count == 0 {
		return headBuilt, 1, nil
	}
	return built, count, nil
}

func (p *PushLoop) pushFlowAttributionEdge(
	pending *flowAttributionPendingBatch,
	spoolApp edgeMetricsAppender,
	cap *edgev1.EdgeSignedCapabilityV1,
) bool {
	telemetry := &p.server.deliveryTelemetry
	sentAny := false

	for range flowAttributionMaxDeliveryStepsPerPush {
		if len(pending.events) == 0 {
			break
		}

		droppedSinceLast := uint32(0)
		if pending.dropBaselinePending {
			droppedSinceLast = pending.dropped
		}

		cached := p.flowAttributionDelivery.currentEdgePending(pending)
		if cached == nil {
			built, eventCount, err := fitFlowAttributionEdgeChunk(pending, droppedSinceLast, cap)
			if err != nil {
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

				telemetry.flowAttributionQuarantined.Add(1)
				telemetry.recordPoisonDrop(poisonReasonPayloadTooLarge, 1, poisonBytes)
				p.dropEdgeMetrics(edgeProducerFlowAttribution, edgeDropInvalidRecord, 1, err)
				p.logger.Error().Err(err).
					Uint32("pid", quarantined.GetPid()).
					Str("comm", quarantined.GetComm()).
					Int("remaining_events", remaining).
					Msg("Quarantined permanently oversized flow attribution event")
				continue
			}

			cached = p.flowAttributionDelivery.setEdgePending(pending, pending.events[0], built, eventCount)
			if cached == nil {
				break
			}
		}

		body, err := edgerecord.CanonicalRecordBytes(cached.built.record)
		if err != nil {
			p.flowAttributionDelivery.clearEdgePending()
			if !p.flowAttributionDelivery.dropPrefix(pending, cached.eventCount) {
				break
			}
			telemetry.recordPoisonDrop(poisonReasonInvalidArgument, cached.eventCount, len(cached.built.payload))
			p.dropEdgeMetrics(edgeProducerFlowAttribution, edgeDropRefused, cached.eventCount, err)
			continue
		}

		if err := appendEdgeMetricsRecord(spoolApp, cached.built.record, body); err != nil {
			if permanentSpoolRefusal(err) || errors.Is(err, spool.ErrEventIDLength) {
				p.flowAttributionDelivery.clearEdgePending()
				if !p.flowAttributionDelivery.dropPrefix(pending, cached.eventCount) {
					break
				}
				poison := poisonReasonInvalidArgument
				if errors.Is(err, spool.ErrBodyTooLarge) {
					poison = poisonReasonPayloadTooLarge
				}
				telemetry.recordPoisonDrop(poison, cached.eventCount, len(body))
				p.dropEdgeMetrics(edgeProducerFlowAttribution, sweepPermanentDropReason(err), cached.eventCount, err)
				continue
			}

			p.logger.Warn().Err(err).
				Int("event_count", cached.eventCount).
				Int("remaining_events", len(pending.events)).
				Msg("Edge spool refused flow attribution batch; retrying on the next push")
			break
		}

		p.flowAttributionDelivery.clearEdgePending()
		cumulativeDropped, commitDropBaseline, remaining, ok :=
			p.flowAttributionDelivery.acknowledgePrefix(pending, cached.eventCount)
		if !ok {
			p.logger.Warn().
				Int("event_count", cached.eventCount).
				Msg("Flow attribution prefix acknowledgement did not match the pending batch")
			break
		}

		telemetry.flowAttributionForwarded.Add(uint64(cached.eventCount))
		if commitDropBaseline {
			p.flowAttributionDelivery.commitDropped(cumulativeDropped)
		}
		sentAny = true

		logEvent := p.logger.Info()
		if pending.hitDrainLimit {
			logEvent = p.logger.Warn()
		}
		logEvent.
			Int("event_count", cached.eventCount).
			Int("remaining_events", remaining).
			Int("message_bytes", len(cached.built.payload)).
			Uint32("dropped_since_last", droppedSinceLast).
			Msg("Spooled flow attribution delivery window as edge record")
	}

	return sentAny
}

// appendEdgeMetricsRecord writes one canonical record through AppendFlow,
// keyed by the record's admission flow.
func appendEdgeMetricsRecord(spoolApp edgeMetricsAppender, record *edgev1.EdgeRecordV1, body []byte) error {
	_, err := spoolApp.AppendFlow(edgeRecordAdmissionFlow(record), record.GetEventId(), body)
	return err
}

// edgeRecordAdmissionFlow matches edgeAdmissionFlow: length-prefixed identity
// fields, then the run shard, origin kind, and traffic class.
func edgeRecordAdmissionFlow(record *edgev1.EdgeRecordV1) string {
	c := record.GetProducerContext()
	var key []byte
	for _, part := range [][]byte{
		record.GetNetworkScopeId(), c.GetOriginPrincipalId(), c.GetProducerAssignmentId(), c.GetRunId(),
		[]byte(record.GetOutputContract().GetContractId()),
	} {
		key = binary.AppendUvarint(key, uint64(len(part)))
		key = append(key, part...)
	}
	key = binary.AppendUvarint(key, uint64(c.GetRunShard()))
	key = binary.AppendUvarint(key, uint64(c.GetOriginKind()))
	key = binary.AppendUvarint(key, uint64(record.GetTrafficClass()))
	return string(key)
}
