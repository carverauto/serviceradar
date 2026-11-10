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
	"fmt"
	"io"
	"sync"
	"sync/atomic"
	"time"

	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/sysmon"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
)

const (
	// maxPendingEdgeMetrics bounds the entries one metric producer keeps while
	// the spool refuses admission or the agent holds no metrics grant. The
	// oldest beyond it are dropped and counted.
	maxPendingEdgeMetrics = 1024
	// edgeMetricsMaxPayloadBytes bounds one metrics batch record's uncompressed
	// payload, so core can republish it as a single NATS message.
	edgeMetricsMaxPayloadBytes = 512 << 10
	// edgeMetricsProjectedRowBytes is the write budget the metrics batch contract
	// charges per projected row (one metric).
	edgeMetricsProjectedRowBytes = 1024
)

var (
	errEdgeMetricsRecordTooLarge = errors.New("metric item exceeds one edge record")
	errRperfNoMetricPoints       = errors.New("rperf payload has no metric points")
	errRperfSchemaVersion        = errors.New("unexpected rperf metric batch schema_version")
)

// edgeProducer names an edge-record producer in drop telemetry.
type edgeProducer int

const (
	edgeProducerSysmon edgeProducer = iota
	edgeProducerSNMP
	edgeProducerICMP
	edgeProducerRperf
	edgeProducerMTR
	edgeProducerMTRTraces
	edgeProducerSweepSummary
	edgeProducerSweepResults
	edgeProducerSweepResultsMetrics
	edgeProducerPluginTelemetry
	edgeProducerAddonTelemetry
	edgeProducerPluginResults
	edgeProducerFlowAttribution
	edgeProducerOtlpRelay
	edgeProducerMapper
	edgeProducerNetprobe
	edgeProducerSync
	edgeProducerWorkloadIdentity
	edgeProducerK8sPublicEndpoints
	edgeProducerEndpointInventory
	edgeProducerBumblebee
	edgeProducerCount
)

func (p edgeProducer) label() string {
	return [edgeProducerCount]string{
		edgeProducerSysmon:    "sysmon",
		edgeProducerSNMP:      "snmp",
		edgeProducerICMP:      "icmp",
		edgeProducerRperf:     "rperf",
		edgeProducerMTR:       "mtr",
		edgeProducerMTRTraces: "mtr_traces",
		// The periodic sweep summary sample, not the batch carried with sweep results.
		edgeProducerSweepSummary: "sweep",
		// Unleased sweep results records, and the metric batch each results chunk carries.
		edgeProducerSweepResults:        "sweep_results",
		edgeProducerSweepResultsMetrics: "sweep_results_metrics",
		edgeProducerPluginTelemetry:     "plugin_telemetry",
		edgeProducerAddonTelemetry:      "addon_telemetry",
		edgeProducerPluginResults:       "plugin_results",
		edgeProducerFlowAttribution:     "flow_attribution",
		edgeProducerOtlpRelay:           "otlp_relay",
		edgeProducerMapper:              "mapper",
		edgeProducerNetprobe:            "netprobe",
		edgeProducerSync:                "sync",
		edgeProducerWorkloadIdentity:    "workload_identity",
		edgeProducerK8sPublicEndpoints:  "k8s_public_endpoints",
		edgeProducerEndpointInventory:   "endpoint_inventory",
		edgeProducerBumblebee:           "bumblebee",
	}[p]
}

// edgeDropReason is why an edge-record producer dropped items.
type edgeDropReason int

const (
	// edgeDropRetryBufferFull: the spool kept refusing admission and the retry
	// buffer overflowed.
	edgeDropRetryBufferFull edgeDropReason = iota
	// edgeDropAwaitingGrant: the agent held no standing grant for the
	// producer's contract (none issued yet, revoked, or no spool) and the
	// producer's bounded hold overflowed while it waited for one.
	edgeDropAwaitingGrant
	// edgeDropInvalidRecord: the items, or a single point no record can hold,
	// cannot form a valid record, so a retry would fail the same way.
	edgeDropInvalidRecord
	// edgeDropRefused: the spool refused the record permanently, for a reason
	// that is not one of the sweep-results reasons below.
	edgeDropRefused
	// A sweep results record was dropped after part of its response was already
	// in the spool. The reason is the refusal the spool reported.
	edgeDropUnauthorizedScope
	edgeDropMalformedEventID
	edgeDropBodyTooLarge
	edgeDropUnbuildableMetric
	edgeDropReasonCount
)

func (r edgeDropReason) label() string {
	return [edgeDropReasonCount]string{
		edgeDropRetryBufferFull:   "retry_buffer_full",
		edgeDropAwaitingGrant:     "awaiting_grant",
		edgeDropInvalidRecord:     "invalid_record",
		edgeDropRefused:           "refused",
		edgeDropUnauthorizedScope: "unauthorized_scope",
		edgeDropMalformedEventID:  "malformed_event_id",
		edgeDropBodyTooLarge:      "body_too_large",
		edgeDropUnbuildableMetric: "unbuildable_chunk_metric",
	}[r]
}

// edgeProducerDropTelemetry counts dropped items (sysmon samples, SNMP readings,
// ICMP check results, record parts or points) per producer and reason, and the
// push cycles in which a producer held its data because the agent had no grant
// for its contract. Its zero value is ready to use.
type edgeProducerDropTelemetry struct {
	dropped    [edgeProducerCount][edgeDropReasonCount]atomic.Uint64
	grantHolds [edgeProducerCount]atomic.Uint64
}

func (t *edgeProducerDropTelemetry) recordGrantHold(producer edgeProducer) {
	t.grantHolds[producer].Add(1)
}

func (t *edgeProducerDropTelemetry) record(producer edgeProducer, reason edgeDropReason, count int) {
	if count > 0 {
		t.dropped[producer][reason].Add(uint64(count))
	}
}

func (t *edgeProducerDropTelemetry) write(w io.Writer) error {
	if _, err := fmt.Fprint(w, "# TYPE agent_edge_record_dropped_samples_total counter\n"); err != nil {
		return fmt.Errorf("write agent edge record drop metric type: %w", err)
	}
	for producer := range edgeProducerCount {
		for reason := range edgeDropReasonCount {
			if _, err := fmt.Fprintf(w, "agent_edge_record_dropped_samples_total{producer=%q,reason=%q} %d\n",
				producer.label(), reason.label(), t.dropped[producer][reason].Load()); err != nil {
				return fmt.Errorf("write agent edge record drop metric: %w", err)
			}
		}
	}
	if _, err := fmt.Fprint(w, "# TYPE agent_edge_record_grant_holds_total counter\n"); err != nil {
		return fmt.Errorf("write agent edge record grant hold metric type: %w", err)
	}
	for producer := range edgeProducerCount {
		if _, err := fmt.Fprintf(w, "agent_edge_record_grant_holds_total{producer=%q} %d\n",
			producer.label(), t.grantHolds[producer].Load()); err != nil {
			return fmt.Errorf("write agent edge record grant hold metric: %w", err)
		}
	}
	return nil
}

// holdForGrant records that producer held its data this push cycle because the
// agent has no standing grant for its contract, or no open spool. A producer
// never sends durable data on the status path; it waits for the grant, as it
// waits on a retryable spool refusal.
func (p *PushLoop) holdForGrant(producer edgeProducer) {
	p.server.edgeProducerDrops.recordGrantHold(producer)
	p.logger.Debug().Str("producer", producer.label()).
		Msg("No standing grant for the producer's contract; holding its data")
}

// edgeMetricsAppender is the spool surface a metrics producer writes. flow is
// the record's admission flow (edgeAdmissionFlow).
type edgeMetricsAppender interface {
	PrepareRecord(raw []byte) (*spool.AttributedAppend, error)
	AppendPrepared(flow string, prepared *spool.AttributedAppend) (spool.Receipt, error)
}

// SetEdgeMetricsSpool connects metric, flow-attribution, and OTLP relay
// producers to the shared attributed lane owner. Call before Start; with a nil
// spool those producers hold their data as they do without a grant.
func (p *PushLoop) SetEdgeMetricsSpool(sp *RecordSpool) {
	if sp != nil {
		sp.SetTrustProvider(p.EdgeRecordTrustSnapshot)
	}
	if sp == nil {
		p.edgeMetricsSpool = nil
		return
	}
	p.edgeMetricsSpool = sp
}

// edgeMetricsCapability is the standing grant new metrics batch records are
// emitted under at now, or nil when metric producers must hold their data.
func (p *PushLoop) edgeMetricsCapability(now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	if p.edgeMetricsSpool == nil {
		return nil
	}
	return p.currentEdgeOutputGrant(edgerecord.MetricsBatchContractID, now)
}

// edgeMetricsProducer is one metric producer on the edge-record path: its drop
// telemetry label, its add-on metric feed, and its envelope builder. nothing is
// the builder's error for items with nothing to record: such an item is
// discarded without counting a drop.
// single marks a producer whose items each make their own envelope, so no two
// are packed into one record.
type edgeMetricsProducer[T any] struct {
	producer edgeProducer
	feed     string
	build    func([]T, metricEnvelopeContext) (*metricpb.MetricBatch, error)
	nothing  error
	single   bool
}

func sysmonEdgeMetrics() edgeMetricsProducer[*sysmon.MetricSample] {
	return edgeMetricsProducer[*sysmon.MetricSample]{
		producer: edgeProducerSysmon, feed: "sysmon", build: buildSysmonMetricBatch, nothing: errSysmonNoScalarMetrics,
	}
}

func snmpEdgeMetrics() edgeMetricsProducer[snmpMetricResult] {
	return edgeMetricsProducer[snmpMetricResult]{
		producer: edgeProducerSNMP, feed: "snmp", build: buildSNMPMetricBatch, nothing: errSnmpNoMetricPoints,
	}
}

func icmpEdgeMetrics() edgeMetricsProducer[icmpCheckResult] {
	return edgeMetricsProducer[icmpCheckResult]{
		producer: edgeProducerICMP, feed: "icmp", build: buildICMPMetricBatch, nothing: errICMPNoMetricPoints,
	}
}

// mtrEdgeMetrics carries the MTR scalar metrics only; the traces themselves keep
// their own results path.
func mtrEdgeMetrics() edgeMetricsProducer[mtrCheckResult] {
	return edgeMetricsProducer[mtrCheckResult]{
		producer: edgeProducerMTR, feed: "mtr", build: buildMTRMetricBatch, nothing: errMTRNoMetricPoints,
	}
}

// sweepSummaryEdgeMetrics carries the periodic sweep summary sample (the newest
// group's status payload), one envelope per sample.
func sweepSummaryEdgeMetrics() edgeMetricsProducer[map[string]any] {
	return edgeMetricsProducer[map[string]any]{
		producer: edgeProducerSweepSummary, feed: "sweep", build: buildSweepSummaryMetricBatch,
		nothing: errSweepNoMetricPoints, single: true,
	}
}

// buildSweepSummaryMetricBatch builds the envelope of one sweep summary sample.
// An empty payload has nothing to record.
func buildSweepSummaryMetricBatch(payloads []map[string]any, ctx metricEnvelopeContext) (*metricpb.MetricBatch, error) {
	if len(payloads) != 1 || len(payloads[0]) == 0 {
		return nil, errSweepNoMetricPoints
	}
	return buildSweepMetricBatchFromMap(payloads[0], ctx)
}

// edgeMetricsBuilt is one metrics batch record ready to spool. Its event id is
// fixed when it is built, so a retried part is appended under the same id.
type edgeMetricsBuilt struct {
	prepared edgePreparedRecord
	record   *edgev1.EdgeRecordV1
	payload  []byte
}

// edgeMetricsQueued is one entry of a producer's retry queue.
//
//   - An item entry (hasItem) is an item no part of which the spool has admitted.
//     Its parts, once built, are kept in ready so a retry reuses their event ids
//     and counts an unsplittable point once.
//   - A part entry is one built record of an item whose earlier parts are in the
//     spool. It is appended as built.
type edgeMetricsQueued[T any] struct {
	item    T
	hasItem bool
	ready   []edgeMetricsBuilt
}

// edgeMetricsQueue is one metric producer's bounded retry queue, oldest first.
// Its zero value is empty.
type edgeMetricsQueue[T any] struct {
	mu      sync.Mutex
	pending []edgeMetricsQueued[T]
}

// holdEdgeMetrics queues newly drained items, oldest first, while the agent
// holds no metrics grant. Nothing is built, appended, or sent elsewhere; the
// next push under a grant spools them. Overflow of the queue's bound drops the
// oldest entries and counts them as awaiting_grant.
func holdEdgeMetrics[T any](p *PushLoop, m edgeMetricsProducer[T], q *edgeMetricsQueue[T], drained []T) {
	p.holdForGrant(m.producer)
	if len(drained) == 0 {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, item := range drained {
		q.pending = append(q.pending, edgeMetricsQueued[T]{item: item, hasItem: true})
	}
	q.pending = trimEdgeMetrics(p, m, q.pending, edgeDropAwaitingGrant)
}

// trimEdgeMetrics drops, and counts, the oldest entries beyond the queue bound.
func trimEdgeMetrics[T any](p *PushLoop, m edgeMetricsProducer[T], pending []edgeMetricsQueued[T], reason edgeDropReason) []edgeMetricsQueued[T] {
	if over := len(pending) - maxPendingEdgeMetrics; over > 0 {
		p.dropEdgeMetrics(m.producer, reason, over, nil)
		return pending[over:]
	}
	return pending
}

// spoolEdgeMetrics appends a producer's queue and newly drained items, oldest
// first, as metrics batch records under capability. Each record part is appended
// exactly once: a retryable refusal leaves the unsent parts queued with their
// event ids. It reports whether any record was appended.
func spoolEdgeMetrics[T any](
	p *PushLoop,
	m edgeMetricsProducer[T],
	q *edgeMetricsQueue[T],
	drained []T,
	capability *edgev1.EdgeSignedCapabilityV1,
) bool {
	q.mu.Lock()
	defer q.mu.Unlock()

	pending := append([]edgeMetricsQueued[T](nil), q.pending...)
	for _, item := range drained {
		pending = append(pending, edgeMetricsQueued[T]{item: item, hasItem: true})
	}

	ctx := p.metricEnvelopeContext()
	appended := 0
	for len(pending) > 0 {
		head := pending[0]
		taken, parts := 1, head.ready
		if head.hasItem && len(head.ready) == 0 {
			var dropped int
			var err error
			items := unbuiltItems(pending)
			if m.single {
				items = items[:1]
			}
			taken, parts, dropped, err = nextEdgeMetricsRecords(items, m.build, capability, ctx)
			if err != nil {
				if !errors.Is(err, m.nothing) {
					p.dropEdgeMetrics(m.producer, edgeDropInvalidRecord, taken, err)
				}
				pending = pending[taken:]
				continue
			}
			p.dropEdgeMetrics(m.producer, edgeDropInvalidRecord, dropped, errEdgeMetricsRecordTooLarge)
		}

		admitted, rest := appendEdgeMetricsParts(p, m, parts, len(pending))
		if admitted == 0 && len(rest) > 0 {
			// Nothing of this entry is in the spool. A single item keeps its built
			// parts, so the retry reuses their event ids; a packed run is rebuilt.
			if taken == 1 && head.hasItem {
				pending[0].ready = rest
			}
			break
		}
		if admitted > 0 {
			appended += taken
		}
		pending = append(partEntries[T](rest), pending[taken:]...)
		if len(rest) > 0 {
			break
		}
	}

	q.pending = trimEdgeMetrics(p, m, pending, edgeDropRetryBufferFull)

	if appended > 0 {
		p.logger.Debug().Str("producer", m.producer.label()).Int("count", appended).
			Msg("Spooled metrics as edge records")
	}
	return appended > 0
}

// unbuiltItems is the run of item entries at the head of pending with no built
// parts yet: the items the next record may pack together.
func unbuiltItems[T any](pending []edgeMetricsQueued[T]) []T {
	items := make([]T, 0, len(pending))
	for _, entry := range pending {
		if !entry.hasItem || len(entry.ready) > 0 {
			break
		}
		items = append(items, entry.item)
	}
	return items
}

func partEntries[T any](parts []edgeMetricsBuilt) []edgeMetricsQueued[T] {
	entries := make([]edgeMetricsQueued[T], len(parts))
	for i, part := range parts {
		entries[i] = edgeMetricsQueued[T]{ready: []edgeMetricsBuilt{part}}
	}
	return entries
}

// appendEdgeMetricsParts appends parts in order and returns how many the spool
// admitted. A retryable refusal stops and returns the unsent suffix, including
// the refused part, with the event ids already on those records. A permanent
// refusal drops that part and continues.
func appendEdgeMetricsParts[T any](
	p *PushLoop,
	m edgeMetricsProducer[T],
	parts []edgeMetricsBuilt,
	pending int,
) (int, []edgeMetricsBuilt) {
	admitted := 0
	if err := prepareMetricParts(p.edgeMetricsSpool, parts); err != nil {
		p.logger.Warn().Err(err).Msg("Record attribution unavailable; retaining metrics")
		return 0, parts
	}
	for i, part := range parts {
		body, err := edgerecord.CanonicalRecordBytes(part.record)
		if err != nil {
			p.dropEdgeMetrics(m.producer, edgeDropRefused, 1, err)
			continue
		}
		if err := parts[i].prepared.append(p.edgeMetricsSpool, part.record, body); err != nil {
			if permanentSpoolRefusal(err) {
				p.dropEdgeMetrics(m.producer, edgeDropRefused, 1, err)
				continue
			}
			p.logger.Warn().Err(err).Str("producer", m.producer.label()).Int("pending", pending).
				Msg("Edge spool refused metrics; retrying on the next push")
			return admitted, parts[i:]
		}
		if m.feed != "" {
			p.publishAddonMetricFeed(m.feed, part.payload)
		}
		admitted++
	}
	return admitted, nil
}

func (p *PushLoop) dropEdgeMetrics(producer edgeProducer, reason edgeDropReason, count int, err error) {
	if count <= 0 {
		return
	}
	p.server.edgeProducerDrops.record(producer, reason, count)
	p.logger.Warn().Err(err).Str("producer", producer.label()).Int("count", count).Str("reason", reason.label()).
		Msg("Dropped metrics bound for the edge spool")
}

// permanentSpoolRefusal reports an append no retry can fix.
func permanentSpoolRefusal(err error) bool {
	return errors.Is(err, spool.ErrPermanent) || errors.Is(err, spool.ErrBodyTooLarge)
}

// nextEdgeMetricsRecords packs the longest prefix of items whose batch forms one
// valid metrics batch record and returns how many items it took. An item whose
// own batch exceeds the payload cap or the grant's row ceiling is split into
// records that keep the resource, ingest identity, metric order and point order;
// droppedPoints counts single points no record can hold. A packed run is found by
// bisection, since a batch only grows as items are added. On error the first
// `taken` items cannot form a record.
func nextEdgeMetricsRecords[T any](
	items []T,
	build func([]T, metricEnvelopeContext) (*metricpb.MetricBatch, error),
	capability *edgev1.EdgeSignedCapabilityV1,
	ctx metricEnvelopeContext,
) (int, []edgeMetricsBuilt, int, error) {
	claims := capability.GetProduction()
	maxRows := min(uint64(claims.GetMaxProjectedRowCount()), claims.GetMaxProjectedWriteBytes()/edgeMetricsProjectedRowBytes)

	head, err := build(items[:1], ctx)
	if err != nil {
		return 1, nil, 0, err
	}
	// A head that cannot form one record (too large, or any other failure) is
	// split, keeping every part that does; only a point no record can hold is lost.
	headRecord, err := metricsEdgeRecord(head, capability, maxRows)
	if err != nil {
		parts, dropped := splitMetricBatch(head, capability, maxRows)
		if len(parts) == 0 {
			return 1, nil, 0, errEdgeMetricsRecordTooLarge
		}
		return 1, parts, dropped, nil
	}

	// The packed run stops before the first item whose batch does not form a
	// record, for any reason; that item is then the head of the next record.
	taken, built := longestPrefix(len(items), func(k int) (edgeMetricsBuilt, error) {
		if k == 1 {
			return headRecord, nil
		}
		batch, buildErr := build(items[:k], ctx)
		if buildErr != nil {
			return edgeMetricsBuilt{}, buildErr
		}
		return metricsEdgeRecord(batch, capability, maxRows)
	})
	return taken, []edgeMetricsBuilt{built}, 0, nil
}

func splitMetricBatch(
	batch *metricpb.MetricBatch,
	capability *edgev1.EdgeSignedCapabilityV1,
	maxRows uint64,
) ([]edgeMetricsBuilt, int) {
	envelope := metricBatchEnvelope(batch)
	metrics := append([]*metricpb.Metric(nil), batch.GetMetrics()...)
	var built []edgeMetricsBuilt
	dropped := 0
	for len(metrics) > 0 {
		n, piece := longestMetricPrefix(envelope, metrics, capability, maxRows)
		if n > 0 {
			built = append(built, piece)
			metrics = metrics[n:]
			continue
		}
		shards, pointsDropped := shardMetricPoints(envelope, metrics[0], capability, maxRows)
		dropped += pointsDropped
		built = append(built, shards...)
		metrics = metrics[1:]
	}
	return built, dropped
}

func longestMetricPrefix(
	envelope *metricpb.MetricBatch,
	metrics []*metricpb.Metric,
	capability *edgev1.EdgeSignedCapabilityV1,
	maxRows uint64,
) (int, edgeMetricsBuilt) {
	limit := len(metrics)
	if uint64(limit) > maxRows {
		limit = int(maxRows)
	}
	return longestPrefix(limit, func(k int) (edgeMetricsBuilt, error) {
		return metricsEdgeRecord(batchWithMetrics(envelope, metrics[:k]), capability, maxRows)
	})
}

func shardMetricPoints(
	envelope *metricpb.MetricBatch,
	metric *metricpb.Metric,
	capability *edgev1.EdgeSignedCapabilityV1,
	maxRows uint64,
) ([]edgeMetricsBuilt, int) {
	points := append([]*metricpb.MetricPoint(nil), metric.GetPoints()...)
	if len(points) == 0 {
		return nil, 1
	}
	var built []edgeMetricsBuilt
	dropped := 0
	for len(points) > 0 {
		n, piece := longestPrefix(len(points), func(k int) (edgeMetricsBuilt, error) {
			part := batchWithMetrics(envelope, []*metricpb.Metric{metricWithPoints(metric, points[:k])})
			return metricsEdgeRecord(part, capability, maxRows)
		})
		if n == 0 {
			dropped++
			points = points[1:]
			continue
		}
		built = append(built, piece)
		points = points[n:]
	}
	return built, dropped
}

func longestPrefix(limit int, fit func(int) (edgeMetricsBuilt, error)) (int, edgeMetricsBuilt) {
	bestN := 0
	var best edgeMetricsBuilt
	lo, hi := 1, limit
	for lo <= hi {
		mid := lo + (hi-lo)/2
		built, err := fit(mid)
		if err == nil {
			bestN, best = mid, built
			lo = mid + 1
			continue
		}
		hi = mid - 1
	}
	return bestN, best
}

func metricsEdgeRecord(
	batch *metricpb.MetricBatch,
	capability *edgev1.EdgeSignedCapabilityV1,
	maxRows uint64,
) (edgeMetricsBuilt, error) {
	record, _, payload, err := edgeBatchRecord(
		batch, capability, len(batch.GetMetrics()), maxRows, edgeMetricsProjectedRowBytes,
		errEdgeMetricsRecordTooLarge, edgerecord.ValidateMetricBatchRecord,
	)
	if err != nil {
		return edgeMetricsBuilt{}, err
	}
	return edgeMetricsBuilt{record: record, payload: payload}, nil
}

func metricBatchEnvelope(batch *metricpb.MetricBatch) *metricpb.MetricBatch {
	envelope := gproto.Clone(batch).(*metricpb.MetricBatch)
	envelope.Metrics = nil
	return envelope
}

func batchWithMetrics(envelope *metricpb.MetricBatch, metrics []*metricpb.Metric) *metricpb.MetricBatch {
	out := gproto.Clone(envelope).(*metricpb.MetricBatch)
	out.Metrics = metrics
	return out
}

func metricWithPoints(metric *metricpb.Metric, points []*metricpb.MetricPoint) *metricpb.Metric {
	out := gproto.Clone(metric).(*metricpb.Metric)
	out.Points = points
	return out
}

// metricEnvelopeContext is the agent identity the metric envelopes are stamped with.
func (p *PushLoop) metricEnvelopeContext() metricEnvelopeContext {
	gatewayID := p.gateway.GetGatewayID()

	p.server.mu.RLock()
	defer p.server.mu.RUnlock()
	return metricEnvelopeContext{
		AgentID:   p.server.config.AgentID,
		GatewayID: gatewayID,
		Partition: p.server.config.Partition,
		KvStoreID: p.server.config.KVAddress,
	}
}

// rperfEdgePending is at most one drained rperf metrics status on its way to
// the spool: held unbuilt while the agent has no metrics grant, then its built
// record(s) while the spool refuses admission. While either is pending, the
// push loop pauses polling the rperf service rather than buffering or dropping
// statuses.
type rperfEdgePending struct {
	mu    sync.Mutex
	held  *rperfHeldStatus
	built []edgeMetricsBuilt
}

// rperfHeldStatus is a drained rperf metrics status not yet built into records,
// with the routing and poll time its records are built with.
type rperfHeldStatus struct {
	status      *proto.StatusResponse
	serviceName string
	serviceType string
	polledAt    time.Time
}

func (r *rperfEdgePending) hasPending() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.held != nil || len(r.built) > 0
}

// flushRperfEdgeMetrics builds a held rperf status under the current metrics
// grant and appends any unsent parts to the edge metrics spool. It returns true
// when nothing remains pending; without a grant a held status stays held.
func (p *PushLoop) flushRperfEdgeMetrics(now time.Time) bool {
	p.rperfEdge.mu.Lock()
	defer p.rperfEdge.mu.Unlock()

	if held := p.rperfEdge.held; held != nil {
		capability := p.edgeMetricsCapability(now)
		if capability == nil {
			p.holdForGrant(edgeProducerRperf)
			return false
		}
		p.rperfEdge.held = nil
		p.rperfEdge.built = p.buildRperfEdgeParts(held, capability)
	}
	if len(p.rperfEdge.built) == 0 {
		return true
	}

	m := edgeMetricsProducer[struct{}]{producer: edgeProducerRperf, feed: "rperf"}
	_, rest := appendEdgeMetricsParts(p, m, p.rperfEdge.built, 1)
	p.rperfEdge.built = rest
	if len(rest) > 0 {
		return false
	}

	p.logger.Debug().Str("producer", edgeProducerRperf.label()).Int("count", 1).
		Msg("Spooled metrics as edge records")
	return true
}

// spoolRperfMetricsStatus takes an rperf metrics status off the status push and
// onto the edge metrics spool: built and appended under the metrics grant, or
// held unbuilt until one is held.
func (p *PushLoop) spoolRperfMetricsStatus(
	statusResp *proto.StatusResponse,
	serviceName string,
	serviceType string,
	now time.Time,
) {
	if statusResp == nil || len(statusResp.GetMessage()) == 0 {
		return
	}
	p.rperfEdge.mu.Lock()
	p.rperfEdge.held = &rperfHeldStatus{status: statusResp, serviceName: serviceName, serviceType: serviceType, polledAt: now}
	p.rperfEdge.mu.Unlock()
	p.flushRperfEdgeMetrics(now)
}

// buildRperfEdgeParts builds a held rperf status into metrics batch records under
// capability, splitting a batch no record holds; what no record can hold is
// dropped and counted.
func (p *PushLoop) buildRperfEdgeParts(held *rperfHeldStatus, capability *edgev1.EdgeSignedCapabilityV1) []edgeMetricsBuilt {
	batch, err := p.buildRperfMetricBatch(held.status, held.serviceName, held.serviceType, held.polledAt)
	if err != nil {
		p.dropEdgeMetrics(edgeProducerRperf, edgeDropInvalidRecord, 1, err)
		return nil
	}

	claims := capability.GetProduction()
	maxRows := min(uint64(claims.GetMaxProjectedRowCount()), claims.GetMaxProjectedWriteBytes()/edgeMetricsProjectedRowBytes)
	if record, recErr := metricsEdgeRecord(batch, capability, maxRows); recErr == nil {
		return []edgeMetricsBuilt{record}
	}
	parts, dropped := splitMetricBatch(batch, capability, maxRows)
	if len(parts) == 0 && dropped == 0 {
		dropped = 1
	}
	p.dropEdgeMetrics(edgeProducerRperf, edgeDropInvalidRecord, dropped, errEdgeMetricsRecordTooLarge)
	return parts
}

func (p *PushLoop) buildRperfMetricBatch(
	statusResp *proto.StatusResponse,
	serviceName string,
	serviceType string,
	now time.Time,
) (*metricpb.MetricBatch, error) {
	var batch metricpb.MetricBatch
	if err := gproto.Unmarshal(statusResp.GetMessage(), &batch); err != nil {
		return nil, fmt.Errorf("decode rperf metric batch: %w", err)
	}
	if batch.GetSchemaVersion() != "" && batch.GetSchemaVersion() != metricEnvelopeSchemaVersion {
		return nil, fmt.Errorf("%w %q", errRperfSchemaVersion, batch.GetSchemaVersion())
	}
	if len(batch.GetMetrics()) == 0 {
		return nil, errRperfNoMetricPoints
	}

	ctx := p.metricEnvelopeContext()
	res := batch.GetResource()
	meta := currentRuntimeMetadata()
	batch.SchemaVersion = metricEnvelopeSchemaVersion
	batch.Resource = metricResource(
		firstMetricNonEmpty(ctx.AgentID, statusResp.GetAgentId(), res.GetAgentId()),
		firstMetricNonEmpty(ctx.GatewayID, statusResp.GetGatewayId(), res.GetGatewayId()),
		firstMetricNonEmpty(ctx.Partition, res.GetPartition()),
		firstMetricNonEmpty(res.GetServiceName(), statusResp.GetServiceName(), serviceName, rperfServiceType),
		firstMetricNonEmpty(res.GetServiceType(), statusResp.GetServiceType(), serviceType, rperfServiceType),
		firstMetricNonEmpty(res.GetHostId(), meta.Hostname),
		firstMetricNonEmpty(res.GetHostIp(), p.getSourceIP()),
		firstMetricNonEmpty(ctx.KvStoreID, res.GetKvStoreId()),
	)
	ingest := batch.GetIngestIdentity()
	batch.IngestIdentity = metricIngest(
		rperfMetricsSource,
		rperfCheckerName,
		firstMetricNonEmpty(ctx.AgentID, statusResp.GetAgentId(), ingest.GetProducerId()),
		firstMetricNonEmpty(ctx.GatewayID, statusResp.GetGatewayId(), ingest.GetAttestedBy()),
	)
	if batch.GetEmittedAtUnixNano() == 0 {
		batch.EmittedAtUnixNano = timeToUnixNano(now, time.Now())
	}
	return &batch, nil
}
