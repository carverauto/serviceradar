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
		taken, record, payload, err := nextSysmonEdgeRecord(pending, capability, ctx)
		if err == nil {
			var body []byte
			if body, err = edgerecord.CanonicalRecordBytes(record); err == nil {
				_, err = p.edgeMetricsSpool.Append(record.GetEventId(), body)
				if err != nil && !permanentSpoolRefusal(err) {
					p.logger.Warn().Err(err).Int("pending_samples", len(pending)).
						Msg("Edge spool refused sysmon metrics; retrying on the next push")
					break
				}
			}
			if err != nil {
				p.dropSysmonEdgeSamples(edgeDropRefused, taken, err)
				pending = pending[taken:]
				continue
			}
			p.publishAddonMetricFeed("sysmon", payload)
			appended += taken
			pending = pending[taken:]
			continue
		}
		p.dropSysmonEdgeSamples(edgeDropInvalidRecord, taken, err)
		pending = pending[taken:]
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

// nextSysmonEdgeRecord packs the longest prefix of pending that fits one metrics
// batch record (payload and projected-row bounds) and returns how many samples it
// took. On error the first `taken` samples cannot form a valid record.
func nextSysmonEdgeRecord(
	pending []*sysmon.MetricSample,
	capability *edgev1.EdgeSignedCapabilityV1,
	ctx metricEnvelopeContext,
) (int, *edgev1.EdgeRecordV1, []byte, error) {
	claims := capability.GetProduction()
	maxRows := min(uint64(claims.GetMaxProjectedRowCount()), claims.GetMaxProjectedWriteBytes()/edgeMetricsProjectedRowBytes)

	batch, err := buildSysmonMetricBatch(pending[:1], ctx)
	if err != nil {
		return 1, nil, nil, err
	}
	if uint64(len(batch.GetMetrics())) > maxRows || gproto.Size(batch) > edgeMetricsMaxPayloadBytes {
		return 1, nil, nil, errEdgeMetricsRecordTooLarge
	}

	taken := 1
	for _, sample := range pending[1:] {
		next, err := buildSysmonMetricBatch([]*sysmon.MetricSample{sample}, ctx)
		if err != nil {
			break // the sample is refused on its own as the head of the next record
		}
		kept := len(batch.Metrics)
		batch.Metrics = append(batch.Metrics, next.GetMetrics()...)
		if uint64(len(batch.Metrics)) > maxRows || gproto.Size(batch) > edgeMetricsMaxPayloadBytes {
			batch.Metrics = batch.Metrics[:kept]
			break
		}
		taken++
	}

	payload, err := gproto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		return taken, nil, nil, err
	}
	rows := uint32(len(batch.GetMetrics()))
	record, err := newEdgeRecord(capability, nil, payload, rows, uint64(rows)*edgeMetricsProjectedRowBytes)
	if err != nil {
		return taken, nil, nil, err
	}
	if err := edgerecord.ValidateMetricBatchRecord(record); err != nil {
		return taken, nil, nil, err
	}
	return taken, record, payload, nil
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
