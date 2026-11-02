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
	"sync/atomic"
	"time"

	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/sysmon"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
)

const (
	// maxPendingSysmonEdgeSamples bounds the sysmon samples kept for retry while
	// the spool refuses admission. The oldest beyond it are dropped and counted.
	maxPendingSysmonEdgeSamples = 1024
	// edgeMetricsMaxPayloadBytes bounds one metrics batch record's uncompressed
	// payload, so core can republish it as a single NATS message.
	edgeMetricsMaxPayloadBytes = 512 << 10
	// edgeMetricsProjectedRowBytes is the write budget the metrics batch contract
	// charges per projected row (one metric).
	edgeMetricsProjectedRowBytes = 1024
)

var errEdgeMetricsRecordTooLarge = errors.New("metric sample exceeds one edge record")

// edgeProducer names an edge-record producer in drop telemetry.
type edgeProducer int

const (
	edgeProducerSysmon edgeProducer = iota
	edgeProducerCount
)

func (p edgeProducer) label() string {
	return [edgeProducerCount]string{edgeProducerSysmon: "sysmon"}[p]
}

// edgeDropReason is why an edge-record producer dropped samples.
type edgeDropReason int

const (
	// edgeDropRetryBufferFull: the spool kept refusing admission and the retry
	// buffer overflowed.
	edgeDropRetryBufferFull edgeDropReason = iota
	// edgeDropInvalidRecord: the samples cannot form a valid record, so a retry
	// would fail the same way.
	edgeDropInvalidRecord
	// edgeDropRefused: the spool refused the record permanently.
	edgeDropRefused
	edgeDropReasonCount
)

func (r edgeDropReason) label() string {
	return [edgeDropReasonCount]string{
		edgeDropRetryBufferFull: "retry_buffer_full",
		edgeDropInvalidRecord:   "invalid_record",
		edgeDropRefused:         "refused",
	}[r]
}

// edgeProducerDropTelemetry counts dropped samples per producer and reason. Its
// zero value is ready to use.
type edgeProducerDropTelemetry struct {
	dropped [edgeProducerCount][edgeDropReasonCount]atomic.Uint64
}

func (t *edgeProducerDropTelemetry) record(producer edgeProducer, reason edgeDropReason, samples int) {
	if samples > 0 {
		t.dropped[producer][reason].Add(uint64(samples))
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
	return nil
}

// SetEdgeMetricsSpool connects metric producers to the sender's one open spool.
// Call before Start; a nil spool keeps every metric on its legacy path.
func (p *PushLoop) SetEdgeMetricsSpool(sp *spool.Spool) { p.edgeMetricsSpool = sp }

// edgeMetricsCapability is the standing grant new metrics batch records are
// emitted under at now, or nil when metrics take the legacy path.
func (p *PushLoop) edgeMetricsCapability(now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	if p.edgeMetricsSpool == nil {
		return nil
	}
	return p.edgeOutputGrants.current(edgerecord.MetricsBatchContractID, now)
}

// takeSysmonEdgePending returns and clears the samples the spool never admitted,
// so they can take the legacy path once the agent no longer holds a grant. None
// of them was spooled, so nothing is sent twice.
func (p *PushLoop) takeSysmonEdgePending() []*sysmon.MetricSample {
	p.sysmonEdgeMu.Lock()
	defer p.sysmonEdgeMu.Unlock()
	pending := p.sysmonEdgePending
	p.sysmonEdgePending = nil
	return pending
}

// spoolSysmonSamples appends the pending and newly drained samples, oldest first,
// as metrics batch records under capability. Samples behind a retryable refusal
// stay pending for the next push; they never take the legacy path while the grant
// holds. It reports whether any record was appended.
func (p *PushLoop) spoolSysmonSamples(drained []*sysmon.MetricSample, capability *edgev1.EdgeSignedCapabilityV1) bool {
	p.sysmonEdgeMu.Lock()
	defer p.sysmonEdgeMu.Unlock()

	pending := append([]*sysmon.MetricSample(nil), p.sysmonEdgePending...)
	for _, sample := range drained {
		if sample != nil {
			pending = append(pending, sample)
		}
	}

	ctx := p.metricEnvelopeContext()
	appended := 0
	for len(pending) > 0 {
		taken, built, droppedPoints, err := nextSysmonEdgeRecord(pending, capability, ctx)
		if err != nil {
			p.dropSysmonEdgeSamples(edgeDropInvalidRecord, taken, err)
			pending = pending[taken:]
			continue
		}
		if droppedPoints > 0 {
			p.dropSysmonEdgeSamples(edgeDropInvalidRecord, droppedPoints, errEdgeMetricsRecordTooLarge)
		}
		wrote, retry, appendErr := p.appendSysmonEdgeRecords(built, len(pending))
		if retry {
			break
		}
		if appendErr != nil {
			p.dropSysmonEdgeSamples(edgeDropRefused, taken, appendErr)
			pending = pending[taken:]
			continue
		}
		if wrote {
			appended += taken
			pending = pending[taken:]
		}
	}

	if over := len(pending) - maxPendingSysmonEdgeSamples; over > 0 {
		p.dropSysmonEdgeSamples(edgeDropRetryBufferFull, over, nil)
		pending = pending[over:]
	}
	p.sysmonEdgePending = pending

	if appended > 0 {
		p.logger.Debug().Int("sample_count", appended).Msg("Spooled sysmon metrics as edge records")
	}
	return appended > 0
}

func (p *PushLoop) dropSysmonEdgeSamples(reason edgeDropReason, samples int, err error) {
	p.server.edgeProducerDrops.record(edgeProducerSysmon, reason, samples)
	p.logger.Warn().Err(err).Int("sample_count", samples).Str("reason", reason.label()).
		Msg("Dropped sysmon metrics bound for the edge spool")
}

// permanentSpoolRefusal reports an append no retry can fix.
func permanentSpoolRefusal(err error) bool {
	return errors.Is(err, spool.ErrPermanent) || errors.Is(err, spool.ErrBodyTooLarge)
}

// sysmonEdgeBuilt is one metrics batch record ready to spool.
type sysmonEdgeBuilt struct {
	record  *edgev1.EdgeRecordV1
	payload []byte
}

// appendSysmonEdgeRecords writes built in order. A retryable refusal stops the
// caller with the samples still pending. wrote is false when nothing was admitted.
func (p *PushLoop) appendSysmonEdgeRecords(built []sysmonEdgeBuilt, pending int) (bool, bool, error) {
	for _, piece := range built {
		body, err := edgerecord.CanonicalRecordBytes(piece.record)
		if err != nil {
			return false, false, err
		}
		if _, err = p.edgeMetricsSpool.Append(piece.record.GetEventId(), body); err != nil {
			if !permanentSpoolRefusal(err) {
				p.logger.Warn().Err(err).Int("pending_samples", pending).
					Msg("Edge spool refused sysmon metrics; retrying on the next push")
				return false, true, err
			}
			return false, false, err
		}
		p.publishAddonMetricFeed("sysmon", piece.payload)
	}
	return true, false, nil
}

// nextSysmonEdgeRecord packs the longest prefix of pending that fits one metrics
// batch record. A sample whose batch exceeds the payload cap or the grant's row
// ceiling is split into records that keep resource, ingest identity, metric order,
// and point order. A multi-sample prefix whose canonical record is over the record
// ceiling is shortened. droppedPoints is the count of single points that cannot
// form a valid record. On error the first taken samples cannot form one.
func nextSysmonEdgeRecord(
	pending []*sysmon.MetricSample,
	capability *edgev1.EdgeSignedCapabilityV1,
	ctx metricEnvelopeContext,
) (int, []sysmonEdgeBuilt, int, error) {
	claims := capability.GetProduction()
	maxRows := min(uint64(claims.GetMaxProjectedRowCount()), claims.GetMaxProjectedWriteBytes()/edgeMetricsProjectedRowBytes)

	head, err := buildSysmonMetricBatch(pending[:1], ctx)
	if err != nil {
		return 1, nil, 0, err
	}
	if metricBatchExceeds(head, maxRows) {
		return splitSysmonSample(head, capability, maxRows)
	}
	headRecord, err := metricsEdgeRecord(head, capability, maxRows)
	if metricsRecordTooLarge(err) {
		return splitSysmonSample(head, capability, maxRows)
	}
	if err != nil {
		return 1, nil, 0, err
	}

	batch := gproto.Clone(head).(*metricpb.MetricBatch)
	taken := 1
	for _, sample := range pending[1:] {
		next, buildErr := buildSysmonMetricBatch([]*sysmon.MetricSample{sample}, ctx)
		if buildErr != nil {
			break
		}
		kept := len(batch.Metrics)
		batch.Metrics = append(batch.Metrics, next.GetMetrics()...)
		if metricBatchExceeds(batch, maxRows) {
			batch.Metrics = batch.Metrics[:kept]
			break
		}
		taken++
	}
	if taken == 1 {
		return 1, []sysmonEdgeBuilt{headRecord}, 0, nil
	}

	built, err := metricsEdgeRecord(batch, capability, maxRows)
	if err == nil {
		return taken, []sysmonEdgeBuilt{built}, 0, nil
	}
	if !metricsRecordTooLarge(err) {
		return taken, nil, 0, err
	}
	fitted, fitTaken, fitErr := shortenSysmonPrefix(pending[:taken], capability, ctx, maxRows)
	if fitErr != nil {
		return taken, nil, 0, fitErr
	}
	if fitTaken == 0 {
		return splitSysmonSample(head, capability, maxRows)
	}
	return fitTaken, fitted, 0, nil
}

func splitSysmonSample(
	batch *metricpb.MetricBatch,
	capability *edgev1.EdgeSignedCapabilityV1,
	maxRows uint64,
) (int, []sysmonEdgeBuilt, int, error) {
	built, dropped, err := splitMetricBatch(batch, capability, maxRows)
	if err != nil {
		return 1, nil, 0, err
	}
	if len(built) == 0 {
		return 1, nil, 0, errEdgeMetricsRecordTooLarge
	}
	return 1, built, dropped, nil
}

func shortenSysmonPrefix(
	pending []*sysmon.MetricSample,
	capability *edgev1.EdgeSignedCapabilityV1,
	ctx metricEnvelopeContext,
	maxRows uint64,
) ([]sysmonEdgeBuilt, int, error) {
	taken, built, err := longestPrefix(len(pending)-1, func(k int) (sysmonEdgeBuilt, error) {
		batch, buildErr := buildSysmonMetricBatch(pending[:k], ctx)
		if buildErr != nil {
			return sysmonEdgeBuilt{}, buildErr
		}
		return metricsEdgeRecord(batch, capability, maxRows)
	})
	if err != nil || taken == 0 {
		return nil, 0, err
	}
	return []sysmonEdgeBuilt{built}, taken, nil
}

func splitMetricBatch(
	batch *metricpb.MetricBatch,
	capability *edgev1.EdgeSignedCapabilityV1,
	maxRows uint64,
) ([]sysmonEdgeBuilt, int, error) {
	envelope := metricBatchEnvelope(batch)
	metrics := append([]*metricpb.Metric(nil), batch.GetMetrics()...)
	var built []sysmonEdgeBuilt
	dropped := 0
	for len(metrics) > 0 {
		n, piece, err := longestMetricPrefix(envelope, metrics, capability, maxRows)
		if err != nil {
			return nil, 0, err
		}
		if n > 0 {
			built = append(built, piece)
			metrics = metrics[n:]
			continue
		}
		shards, pointsDropped, err := shardMetricPoints(envelope, metrics[0], capability, maxRows)
		if err != nil {
			return nil, 0, err
		}
		dropped += pointsDropped
		built = append(built, shards...)
		metrics = metrics[1:]
	}
	return built, dropped, nil
}

func longestMetricPrefix(
	envelope *metricpb.MetricBatch,
	metrics []*metricpb.Metric,
	capability *edgev1.EdgeSignedCapabilityV1,
	maxRows uint64,
) (int, sysmonEdgeBuilt, error) {
	limit := len(metrics)
	if uint64(limit) > maxRows {
		limit = int(maxRows)
	}
	return longestPrefix(limit, func(k int) (sysmonEdgeBuilt, error) {
		return metricsEdgeRecord(batchWithMetrics(envelope, metrics[:k]), capability, maxRows)
	})
}

func shardMetricPoints(
	envelope *metricpb.MetricBatch,
	metric *metricpb.Metric,
	capability *edgev1.EdgeSignedCapabilityV1,
	maxRows uint64,
) ([]sysmonEdgeBuilt, int, error) {
	points := append([]*metricpb.MetricPoint(nil), metric.GetPoints()...)
	if len(points) == 0 {
		return nil, 1, nil
	}
	var built []sysmonEdgeBuilt
	dropped := 0
	for len(points) > 0 {
		n, piece, err := longestPrefix(len(points), func(k int) (sysmonEdgeBuilt, error) {
			part := batchWithMetrics(envelope, []*metricpb.Metric{metricWithPoints(metric, points[:k])})
			return metricsEdgeRecord(part, capability, maxRows)
		})
		if err != nil {
			return nil, 0, err
		}
		if n == 0 {
			dropped++
			points = points[1:]
			continue
		}
		built = append(built, piece)
		points = points[n:]
	}
	return built, dropped, nil
}

func longestPrefix(limit int, fit func(int) (sysmonEdgeBuilt, error)) (int, sysmonEdgeBuilt, error) {
	bestN := 0
	var best sysmonEdgeBuilt
	lo, hi := 1, limit
	for lo <= hi {
		mid := lo + (hi-lo)/2
		built, err := fit(mid)
		if err == nil {
			bestN, best = mid, built
			lo = mid + 1
			continue
		}
		if !metricsRecordTooLarge(err) {
			return 0, sysmonEdgeBuilt{}, err
		}
		hi = mid - 1
	}
	return bestN, best, nil
}

func metricsEdgeRecord(
	batch *metricpb.MetricBatch,
	capability *edgev1.EdgeSignedCapabilityV1,
	maxRows uint64,
) (sysmonEdgeBuilt, error) {
	rows := len(batch.GetMetrics())
	if rows == 0 || uint64(rows) > maxRows {
		return sysmonEdgeBuilt{}, errEdgeMetricsRecordTooLarge
	}
	payload, err := gproto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		return sysmonEdgeBuilt{}, err
	}
	if len(payload) > edgeMetricsMaxPayloadBytes {
		return sysmonEdgeBuilt{}, errEdgeMetricsRecordTooLarge
	}
	record, err := newEdgeRecord(capability, nil, payload, uint32(rows), uint64(rows)*edgeMetricsProjectedRowBytes)
	if err != nil {
		return sysmonEdgeBuilt{}, err
	}
	if err := edgerecord.ValidateMetricBatchRecord(record); err != nil {
		return sysmonEdgeBuilt{}, err
	}
	return sysmonEdgeBuilt{record: record, payload: payload}, nil
}

func metricBatchExceeds(batch *metricpb.MetricBatch, maxRows uint64) bool {
	return uint64(len(batch.GetMetrics())) > maxRows || gproto.Size(batch) > edgeMetricsMaxPayloadBytes
}

func metricsRecordTooLarge(err error) bool {
	return errors.Is(err, errEdgeMetricsRecordTooLarge) ||
		errors.Is(err, edgerecord.ErrRecordTooLarge) ||
		errors.Is(err, edgerecord.ErrPayloadTooLarge)
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
