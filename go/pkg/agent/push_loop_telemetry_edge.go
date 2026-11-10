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
	"errors"
	"time"

	"google.golang.org/protobuf/proto"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
)

// Plugin signals and native add-on telemetry share one standing-grant
// contract (serviceradar.telemetry.batch) and this one producer. A batch stays
// queued until the spool has admitted every part that formed a valid record,
// or until it overflows the queue's bound. A record that cannot form a
// valid part is dropped on its own; the parts already built keep the event
// ids they were first built with across spool retries, so a part is never
// re-minted. The host stamp of the producing assignment or add-on is written
// from agent configuration, never from what the guest put in its batch source.

const (
	// maxEdgeTelemetryQueuedRecords bounds either telemetry retry queue, in
	// telemetry records across its queued batches. A batch already admitted
	// (the head, or the only pending item) is kept when it alone exceeds the
	// bound; the bound drops the oldest backlog behind that batch.
	maxEdgeTelemetryQueuedRecords = 8192
	// edgeTelemetryMaxPayloadBytes caps one spooled batch part, like a
	// metrics batch record body.
	edgeTelemetryMaxPayloadBytes = edgeMetricsMaxPayloadBytes
)

// dropEdgeTelemetry counts telemetry records a producer dropped and logs the
// loss once per call, like dropEdgeMetrics.
func (p *PushLoop) dropEdgeTelemetry(producer edgeProducer, reason edgeDropReason, count int) {
	if count <= 0 {
		return
	}
	p.server.edgeProducerDrops.record(producer, reason, count)
	p.logger.Warn().Str("producer", producer.label()).Int("count", count).Str("reason", reason.label()).
		Msg("Dropped telemetry bound for the edge spool")
}

// SetEdgeTelemetrySpool connects telemetry producers to the shared bounded lane
// owner. Call before Start; with a nil spool telemetry is held as it is
// without a grant.
func (p *PushLoop) SetEdgeTelemetrySpool(sp *RecordSpool) {
	if sp != nil {
		sp.SetTrustProvider(p.EdgeRecordTrustSnapshot)
	}
	if sp == nil {
		p.edgeTelemetrySpool = nil
		return
	}
	p.edgeTelemetrySpool = sp
}

// edgeTelemetryCapability is the current standing grant for the telemetry
// batch contract, or nil when telemetry must be held this cycle.
func (p *PushLoop) edgeTelemetryCapability(now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	if p == nil || p.edgeTelemetrySpool == nil {
		return nil
	}
	return p.currentEdgeOutputGrant(edgerecord.TelemetryBatchContractID, now)
}

// telemetryEdgeItem is one drained telemetry batch awaiting the spool.
type telemetryEdgeItem struct {
	producerType string
	producerID   string
	batch        *addonpb.TelemetryBatch
}

func (item telemetryEdgeItem) records() int {
	return len(item.batch.GetRecords())
}

// telemetryBuiltItem is one item expanded into its spooled parts: kept until
// the spool has admitted every part, so a retry appends the same records
// under their original event ids.
type telemetryBuiltItem struct {
	prepared []edgePreparedRecord
	item     telemetryEdgeItem
	records  []*edgev1.EdgeRecordV1
	bodies   [][]byte
	next     int
}

// telemetryEdgeQueue is one producer's bounded retry queue. Only the push
// loop goroutine touches it, like the metric queues.
type telemetryEdgeQueue struct {
	pending []telemetryEdgeItem
	built   *telemetryBuiltItem
}

func (q *telemetryEdgeQueue) queuedRecords() int {
	total := 0
	for _, item := range q.pending {
		total += item.records()
	}
	if q.built != nil {
		total += q.built.item.records()
	}
	return total
}

// enqueue appends items, then sheds records past the queue bound. It returns
// how many telemetry records the bound dropped.
func (q *telemetryEdgeQueue) enqueue(items []telemetryEdgeItem) int {
	q.pending = append(q.pending, items...)
	return q.shedOverflow()
}

// shedOverflow applies maxEdgeTelemetryQueuedRecords. The head pending batch
// is kept when it is the only one, or when it alone exceeds the bound; a
// built batch already handed to the spool is kept too. The oldest backlog
// behind that admitted batch is what the bound drops.
func (q *telemetryEdgeQueue) shedOverflow() int {
	dropped := 0
	for q.queuedRecords() > maxEdgeTelemetryQueuedRecords && len(q.pending) > 0 {
		headExceeds := q.pending[0].records() > maxEdgeTelemetryQueuedRecords
		if len(q.pending) == 1 && (headExceeds || q.built == nil) {
			break
		}
		if headExceeds {
			dropped += q.pending[1].records()
			q.pending = append(q.pending[:1], q.pending[2:]...)
			continue
		}
		dropped += q.pending[0].records()
		q.pending = q.pending[1:]
	}
	return dropped
}

// spoolTelemetry appends a producer's queued batches to the durable spool
// under capability. It reports whether anything was handed off durably.
func (p *PushLoop) spoolTelemetry(
	producer edgeProducer,
	queue *telemetryEdgeQueue,
	capability *edgev1.EdgeSignedCapabilityV1,
) bool {
	sent := false
	for {
		if queue.built == nil {
			if len(queue.pending) == 0 {
				return sent
			}
			item := queue.pending[0]
			built, filtered, err := buildTelemetryItem(item, capability)
			if filtered > 0 {
				p.dropEdgeTelemetry(producer, edgeDropInvalidRecord, filtered)
			}
			if err != nil {
				queue.pending = queue.pending[1:]
				p.logger.Warn().
					Err(err).
					Str("producer_type", item.producerType).
					Str("producer_id", item.producerID).
					Msg("Dropping telemetry batch the durable contract refuses")
				if rest := item.records() - filtered; rest > 0 {
					p.dropEdgeTelemetry(producer, edgeDropInvalidRecord, rest)
				}
				continue
			}
			queue.pending = queue.pending[1:]
			queue.built = built
		}
		if !p.appendTelemetryBuilt(producer, queue.built) {
			return sent
		}
		queue.built = nil
		sent = true
	}
}

func (p *PushLoop) appendTelemetryBuilt(producer edgeProducer, built *telemetryBuiltItem) bool {
	if err := prepareRecordParts(p.edgeTelemetrySpool, built.records, built.bodies, &built.prepared); err != nil {
		p.logger.Warn().Err(err).Msg("Record attribution unavailable; retaining pending records")
		return false
	}
	for built.next < len(built.records) {
		record := built.records[built.next]
		if err := built.prepared[built.next].append(p.edgeTelemetrySpool, record, built.bodies[built.next]); err != nil {
			p.logger.Warn().Err(err).Msg("Failed to spool telemetry batch part; will retry")
			return false
		}
		built.next++
	}
	_ = producer
	return true
}

// buildTelemetryItem stamps the host producer identity onto a clone of the
// batch, drops records the contract does not route (the OTLP relay kinds,
// which travel on the OTLP relay contract), and expands the
// batch into spooled parts that each form one valid record under the grant.
// A record that cannot form a part is counted with the filtered records and
// does not discard parts already built. The spool counters ride the first
// part only, so a split batch reports them once. An error refuses the batch
// before any part exists; filtered is then only the records already counted.
func buildTelemetryItem(
	item telemetryEdgeItem,
	capability *edgev1.EdgeSignedCapabilityV1,
) (built *telemetryBuiltItem, filtered int, err error) {
	stamped, filtered := stampTelemetryBatch(item)
	if len(stamped.GetRecords()) == 0 {
		// Nothing routable remains; the filtered records were already
		// counted, and an empty batch is not an error worth retrying.
		return &telemetryBuiltItem{item: item}, filtered, nil
	}
	if err := edgerecord.ValidateTelemetryBatch(stamped); err != nil {
		return nil, filtered, err
	}

	built = &telemetryBuiltItem{item: item}
	records := stamped.GetRecords()
	counters := stamped.GetCounters()
	skipped := 0
	for len(records) > 0 {
		n, record, body, _ := longestTelemetryPrefix(
			stamped.GetSource(), counters, records, capability)
		if n == 0 {
			skipped++
			records = records[1:]
			continue
		}
		built.records = append(built.records, record)
		built.bodies = append(built.bodies, body)
		records = records[n:]
		counters = nil
	}
	return built, filtered + skipped, nil
}

// longestTelemetryPrefix packs the longest prefix of records that forms one
// valid telemetry batch record under capability. A packed run is found by
// bisection, since a batch only grows as records are added.
func longestTelemetryPrefix(
	source *addonpb.TelemetrySource,
	counters *addonpb.TelemetryCounters,
	records []*addonpb.TelemetryRecord,
	capability *edgev1.EdgeSignedCapabilityV1,
) (int, *edgev1.EdgeRecordV1, []byte, error) {
	limit := len(records)
	if maxRows := telemetryMaxRows(capability); uint64(limit) > maxRows {
		limit = int(maxRows)
	}

	bestN := 0
	var bestRecord *edgev1.EdgeRecordV1
	var bestBody []byte
	var lastErr error
	lo, hi := 1, limit
	for lo <= hi {
		mid := lo + (hi-lo)/2
		part := &addonpb.TelemetryBatch{
			Source:   source,
			Counters: counters,
			Records:  records[:mid],
		}
		record, body, err := telemetryEdgeRecord(part, capability)
		if err == nil {
			bestN, bestRecord, bestBody = mid, record, body
			lo = mid + 1
			continue
		}
		lastErr = err
		hi = mid - 1
	}
	if bestN == 0 {
		if lastErr != nil {
			return 0, nil, nil, lastErr
		}
		return 0, nil, nil, errTelemetryRecordTooLarge
	}
	return bestN, bestRecord, bestBody, nil
}

// telemetryMaxRows is how many telemetry records one record may carry under
// the grant's row and write-byte ceilings.
func telemetryMaxRows(capability *edgev1.EdgeSignedCapabilityV1) uint64 {
	claims := capability.GetProduction()
	return min(uint64(claims.GetMaxProjectedRowCount()),
		claims.GetMaxProjectedWriteBytes()/edgerecord.TelemetryProjectedWriteBytesPerRecord)
}

func telemetryEdgeRecord(
	batch *addonpb.TelemetryBatch,
	capability *edgev1.EdgeSignedCapabilityV1,
) (*edgev1.EdgeRecordV1, []byte, error) {
	record, body, _, err := edgeBatchRecord(
		batch, capability, len(batch.GetRecords()), telemetryMaxRows(capability),
		edgerecord.TelemetryProjectedWriteBytesPerRecord, errTelemetryRecordTooLarge,
		edgerecord.ValidateTelemetryBatchRecord,
	)
	return record, body, err
}

// stampTelemetryBatch clones a batch, overwrites the host producer identity
// in its source metadata, and keeps only the payload kinds the contract
// routes. It returns how many records the filter dropped.
func stampTelemetryBatch(item telemetryEdgeItem) (*addonpb.TelemetryBatch, int) {
	batch, _ := proto.Clone(item.batch).(*addonpb.TelemetryBatch)
	if batch == nil {
		batch = &addonpb.TelemetryBatch{}
	}
	if batch.Source == nil {
		batch.Source = &addonpb.TelemetrySource{}
	}
	if batch.Source.Metadata == nil {
		batch.Source.Metadata = map[string]string{}
	}
	batch.Source.Metadata[edgerecord.TelemetryProducerTypeMetadataKey] = item.producerType
	batch.Source.Metadata[edgerecord.TelemetryProducerIDMetadataKey] = item.producerID

	filtered := 0
	kept := batch.Records[:0]
	for _, record := range batch.Records {
		if edgerecord.TelemetryPayloadKindRouted(record.GetPayloadKind()) {
			kept = append(kept, record)
		} else {
			filtered++
		}
	}
	batch.Records = kept
	return batch, filtered
}

var errTelemetryRecordTooLarge = errors.New("telemetry record exceeds the durable record body bound")
