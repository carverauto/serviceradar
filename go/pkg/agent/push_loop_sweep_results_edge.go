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
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/netip"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"github.com/google/uuid"
	gproto "google.golang.org/protobuf/proto"
)

// unleasedSweepProjectedRowBytes is the projected write budget per host row,
// matching the contract's catalog bound in core.
const unleasedSweepProjectedRowBytes = 2048

// unleasedSweepClosedPort is the port error code a tested port that was not
// open travels as, so core can rebuild every port the host was tested on.
const unleasedSweepClosedPort = "closed"

var (
	errSweepResultsExecutionID       = errors.New("sweep results have no canonical execution id")
	errSweepResultsGroupID           = errors.New("sweep results group id is not a canonical uuid")
	errSweepResultsHostForm          = errors.New("sweep host address is not in canonical form")
	errSweepResultsHostTooLarge      = errors.New("one sweep host does not fit an edge record")
	errSweepResultsUnbuildableMetric = errors.New("sweep results chunk metric does not fit an edge record")
	errSweepResultsNoChunks          = errors.New("sweep results response has no results chunk")
)

// sweepResultsEdgePending is the built records of the one sweep results response
// the agent is spooling: each results chunk's metric batch, then every results
// record, including the final one. Records are built once, so a retry after a
// retryable spool refusal appends the unsent ones under their original event
// ids. admitted is set once any record of this response is in the spool. When
// nothing from the response was admitted and the spool permanently refuses a
// record, the response is dropped, counted, and acknowledged so later
// responses are not blocked behind it. Its zero value is empty.
//
// The final results record is appended with the others, carrying the execution's
// total chunk count. Core completes the execution only once it has ingested
// every chunk, so the final does not have to wait here. If the spool permanently
// refuses a record after admission (incomplete counts them), a cancel marker is
// appended once the parts queue drains: a durable record flagged as the marker,
// with no hosts and no data-chunk index, naming exactly the data-chunk indexes
// appended (emitted). It is built from cancelTemplate under capability and kept
// in cancelled so a retry reuses its event id. partChunks is the data-chunk
// index of each unsent part. Core closes the execution as cancelled once those
// data chunks are in, and keeps the host rows it already stored. The response is acknowledged once every record is in the spool;
// delivery is the spool's, and a chunk core never receives leaves the execution
// to core's stale-execution sweeper.
type sweepResultsEdgePending struct {
	mu             sync.Mutex
	groupID        string
	sequence       string
	admitted       bool
	metrics        []edgeMetricsBuilt
	parts          []edgeMetricsBuilt
	partChunks     []uint32
	emitted        []uint32
	capability     *edgev1.EdgeSignedCapabilityV1
	cancelTemplate *edgev1.UnleasedSweepResultsBatchV1
	cancelled      edgeMetricsBuilt
	cancelNeeded   bool
	cancelSent     bool
	incomplete     int
}

// sweepResultsEdgeMetrics carries the metric batch of each sweep results chunk,
// one per chunk.
func sweepResultsEdgeMetrics() edgeMetricsProducer[map[string]any] {
	return edgeMetricsProducer[map[string]any]{
		producer: edgeProducerSweepResultsMetrics, build: buildSweepSummaryMetricBatch,
		nothing: errSweepNoMetricPoints,
	}
}

// sweepResultsEdgeGrants is the results and metrics grants unleased sweep results
// are emitted under at now, or nil when results must wait for them. Both are
// required, because a results chunk and its metric batch are spooled together.
func (p *PushLoop) sweepResultsEdgeGrants(now time.Time) (results, metrics *edgev1.EdgeSignedCapabilityV1) {
	if p.edgeMetricsSpool == nil {
		return nil, nil
	}
	results = p.currentEdgeOutputGrant(edgerecord.UnleasedSweepResultsContractID, now)
	metrics = p.currentEdgeOutputGrant(edgerecord.MetricsBatchContractID, now)
	if results == nil || metrics == nil {
		return nil, nil
	}
	return results, metrics
}

// pushSweepResultsEdge spools one results response as edge records under the
// unleased results and metrics grants. Leased runs emit observation batches
// from the lease executor and never reach the results provider, so every
// response here is an unleased run. pending means part of the response waits
// in memory for spool room, so no further response may be read. A response
// the typed batch cannot carry is dropped, counted and acknowledged.
func (p *PushLoop) pushSweepResultsEdge(
	sweepSvc SweepResultsProvider,
	response *proto.ResultsResponse,
	resultsGrant, metricsGrant *edgev1.EdgeSignedCapabilityV1,
) (pending, sent bool) {
	parts, cancelTemplate, metricPayloads, err := buildSweepResultsEdgeRecords(response, resultsGrant)
	if err == nil {
		var metrics []edgeMetricsBuilt
		if metrics, err = p.sweepResultsMetricRecords(metricPayloads, metricsGrant); err == nil {
			p.stageSweepResultsEdge(response, metrics, parts, cancelTemplate, resultsGrant)
			return p.finishSweepResultsEdge(sweepSvc)
		}
	}
	// A response the typed batch cannot carry is an invalid record, not a
	// spool refusal; an unbuildable chunk metric keeps its own reason.
	reason := sweepPermanentDropReason(err)
	if reason == edgeDropRefused {
		reason = edgeDropInvalidRecord
	}
	p.dropSweepResultsResponse(sweepSvc, response.SweepGroupId, response.CurrentSequence, 1, reason, err)
	return false, false
}

// stageSweepResultsEdge makes response the one response being spooled.
func (p *PushLoop) stageSweepResultsEdge(
	response *proto.ResultsResponse,
	metrics, parts []edgeMetricsBuilt,
	cancelTemplate *edgev1.UnleasedSweepResultsBatchV1,
	capability *edgev1.EdgeSignedCapabilityV1,
) {
	p.sweepResultsEdge.mu.Lock()
	defer p.sweepResultsEdge.mu.Unlock()
	state := &p.sweepResultsEdge
	state.reset()
	state.groupID = response.SweepGroupId
	state.sequence = response.CurrentSequence
	state.metrics = metrics
	state.parts = parts
	state.partChunks = make([]uint32, len(parts))
	for i := range parts {
		state.partChunks[i] = uint32(i)
	}
	state.capability = capability
	state.cancelTemplate = cancelTemplate
}

// dropSweepResultsResponse counts a response that can never enter the spool and
// acknowledges it, so the provider moves on to its next completed cycle.
func (p *PushLoop) dropSweepResultsResponse(
	sweepSvc SweepResultsProvider,
	groupID, sequence string,
	records int,
	reason edgeDropReason,
	err error,
) {
	p.dropEdgeMetrics(edgeProducerSweepResults, reason, records, err)
	p.logger.Warn().Err(err).Str("sweep_group_id", groupID).
		Msg("Sweep results response cannot enter the edge spool; dropped")
	acknowledgeSweepResults(sweepSvc, groupID, sequence)
	if sequence != "" {
		p.setSweepResultsSequence(sequence)
	}
}

// sweepResultsMetricRecords builds the metric batch record of each results chunk.
// A chunk with no metric points has none; a batch no record can hold is split,
// and only what no record holds is dropped and counted. A chunk that cannot form
// a record at all is an error.
func (p *PushLoop) sweepResultsMetricRecords(payloads []map[string]any, capability *edgev1.EdgeSignedCapabilityV1) ([]edgeMetricsBuilt, error) {
	m := sweepResultsEdgeMetrics()
	ctx := p.metricEnvelopeContext()
	var parts []edgeMetricsBuilt
	dropped := 0
	for _, payload := range payloads {
		_, built, n, err := nextEdgeMetricsRecords([]map[string]any{payload}, m.build, capability, ctx)
		if err != nil {
			if errors.Is(err, m.nothing) {
				continue
			}
			return nil, fmt.Errorf("%w: %w", errSweepResultsUnbuildableMetric, err)
		}
		dropped += n
		parts = append(parts, built...)
	}
	p.dropEdgeMetrics(m.producer, edgeDropInvalidRecord, dropped, errEdgeMetricsRecordTooLarge)
	return parts, nil
}

// finishSweepResultsEdge appends the unsent records of the response being spooled,
// metric batches first and every results record, including the final one, as
// soon as the spool accepts it. A retryable refusal leaves the rest queued with
// their event ids (pending). A permanent refusal before anything from this
// response was admitted drops the whole response, counted, and acknowledges it.
// A permanent refusal after a record was admitted drops that record, counts it,
// and continues. A counted refusal appends the cancel record. The response is
// acknowledged once every record is appended.
func (p *PushLoop) finishSweepResultsEdge(sweepSvc SweepResultsProvider) (pending, appended bool) {
	p.sweepResultsEdge.mu.Lock()
	defer p.sweepResultsEdge.mu.Unlock()
	state := &p.sweepResultsEdge
	if state.sequence == "" && len(state.metrics) == 0 && len(state.parts) == 0 && !state.cancelNeeded {
		return false, false
	}

	added, rest, err := p.appendSweepResultsRecords(edgeProducerSweepResultsMetrics, state.metrics, state, nil)
	if err != nil {
		p.abandonSweepResultsEdge(sweepSvc, err)
		return false, false
	}
	state.metrics = rest
	appended = added > 0
	if len(rest) > 0 {
		return true, appended
	}

	chunks := state.partChunks
	added, rest, err = p.appendSweepResultsRecords(edgeProducerSweepResults, state.parts, state, func(i int) {
		state.emitted = append(state.emitted, chunks[i])
	})
	if err != nil {
		p.abandonSweepResultsEdge(sweepSvc, err)
		return false, false
	}
	state.parts = rest
	state.partChunks = chunks[len(chunks)-len(rest):]
	appended = appended || added > 0
	if len(rest) > 0 {
		return true, appended
	}

	if state.incomplete > 0 {
		state.cancelNeeded = true
	}
	cancelAdded, waiting := p.appendSweepCancel(state)
	appended = appended || cancelAdded
	if waiting {
		return true, appended
	}

	acknowledgeSweepResults(sweepSvc, state.groupID, state.sequence)
	if state.sequence != "" {
		p.setSweepResultsSequence(state.sequence)
	}
	state.reset()
	return false, appended
}

// appendSweepCancel builds the response's cancel marker once the parts queue
// has drained, naming exactly the data chunks appended, and appends it once
// under that record's event id. pending means the spool asked for a retry. A
// marker that does not build, or that the spool permanently refuses, is
// counted and not retried: the spool will not take it. The cancel marker is
// appended only after a data record was admitted, so its permanent refusal
// never abandons the response.
func (p *PushLoop) appendSweepCancel(state *sweepResultsEdgePending) (added, pending bool) {
	if !state.cancelNeeded || state.cancelSent {
		return false, false
	}
	if state.cancelled.record == nil {
		marker := gproto.Clone(state.cancelTemplate).(*edgev1.UnleasedSweepResultsBatchV1)
		marker.EmittedChunkIndexes = append([]uint32(nil), state.emitted...)
		marker.TotalChunks = uint32(len(state.emitted))
		built, err := unleasedSweepEdgeRecord(marker, state.capability)
		if err != nil {
			state.cancelSent = true
			p.dropEdgeMetrics(edgeProducerSweepResults, sweepPermanentDropReason(err), 1, err)
			p.logger.Warn().Err(err).Str("sweep_group_id", state.groupID).
				Msg("Sweep results cancel record did not build; the execution stays open")
			return false, false
		}
		state.cancelled = built
	}
	n, rest, _ := p.appendSweepResultsRecords(edgeProducerSweepResults, []edgeMetricsBuilt{state.cancelled}, state, nil)
	if len(rest) > 0 {
		return n > 0, true
	}
	state.cancelSent = true
	if n > 0 {
		p.logger.Warn().Str("sweep_group_id", state.groupID).Int("records", state.incomplete).
			Msg("Sweep results records were not delivered; the execution is reported cancelled, not completed")
	} else {
		p.logger.Warn().Str("sweep_group_id", state.groupID).
			Msg("Sweep results cancel record was not accepted; the execution stays open")
	}
	return n > 0, false
}

func (state *sweepResultsEdgePending) reset() {
	state.groupID, state.sequence = "", ""
	state.admitted = false
	state.metrics, state.parts = nil, nil
	state.partChunks, state.emitted = nil, nil
	state.capability, state.cancelTemplate = nil, nil
	state.cancelled = edgeMetricsBuilt{}
	state.cancelNeeded, state.cancelSent = false, false
	state.incomplete = 0
}

// abandonSweepResultsEdge drops the response being spooled after the spool
// permanently refused its first record: nothing of it is in the spool and the
// spool will not take it. Every unsent record is counted.
func (p *PushLoop) abandonSweepResultsEdge(sweepSvc SweepResultsProvider, err error) {
	state := &p.sweepResultsEdge
	groupID, sequence := state.groupID, state.sequence
	records := len(state.metrics) + len(state.parts)
	state.reset()
	p.dropSweepResultsResponse(sweepSvc, groupID, sequence, records, sweepPermanentDropReason(err), err)
}

// appendSweepResultsRecords appends parts in order, calling admitted, when
// set, with the position in parts of each record the spool took. added is how
// many this call put in the spool. rest is the unsent suffix after a retryable refusal and includes the
// refused record, whose event id is unchanged. A permanent refusal with nothing
// from this response in the spool returns that error and an empty rest, so the
// caller does not append later records. After a record was admitted, a permanent
// refusal drops that record, counts it in state.incomplete, and continues.
func (p *PushLoop) appendSweepResultsRecords(producer edgeProducer, parts []edgeMetricsBuilt, state *sweepResultsEdgePending, admitted func(i int)) (added int, rest []edgeMetricsBuilt, fallback error) {
	if err := prepareMetricParts(p.edgeMetricsSpool, parts); err != nil {
		p.logger.Warn().Err(err).Msg("Record attribution unavailable; retaining sweep results")
		return 0, parts, nil
	}
	for i := range parts {
		permanent, err := p.appendOneSweepRecord(&parts[i])
		if err == nil {
			if admitted != nil {
				admitted(i)
			}
			state.admitted = true
			added++
			continue
		}
		if !permanent {
			p.logger.Warn().Err(err).Str("producer", producer.label()).
				Msg("Edge spool refused sweep results; retrying on the next push")
			return added, parts[i:], nil
		}
		if !state.admitted {
			return 0, nil, err
		}
		state.incomplete++
		p.dropEdgeMetrics(producer, sweepPermanentDropReason(err), 1, err)
	}
	return added, nil, nil
}

// appendOneSweepRecord appends one built record. permanent is set when repeating
// the append cannot succeed: the body will not encode, or the spool refused it
// for a reason that is not cleared by waiting.
func (p *PushLoop) appendOneSweepRecord(part *edgeMetricsBuilt) (permanent bool, err error) {
	body, err := edgerecord.CanonicalRecordBytes(part.record)
	if err != nil {
		return true, err
	}
	if err = part.prepared.append(p.edgeMetricsSpool, part.record, body); err != nil {
		return permanentSpoolRefusal(err) || errors.Is(err, spool.ErrEventIDLength), err
	}
	return false, nil
}

// sweepPermanentDropReason is the drop-metric reason for a sweep record that
// cannot enter the spool. A generic permanent refusal stays "refused".
func sweepPermanentDropReason(err error) edgeDropReason {
	switch {
	case errors.Is(err, spool.ErrScopeUnauthorized), errors.Is(err, spool.ErrAgentUnauthorized):
		return edgeDropUnauthorizedScope
	case errors.Is(err, spool.ErrEventIDLength):
		return edgeDropMalformedEventID
	case errors.Is(err, spool.ErrBodyTooLarge):
		return edgeDropBodyTooLarge
	case errors.Is(err, errSweepResultsUnbuildableMetric), errors.Is(err, errEdgeMetricsRecordTooLarge):
		return edgeDropUnbuildableMetric
	default:
		return edgeDropRefused
	}
}

// sweepResultsJSON is the agent's sweep results document (SweepService.GetSweepResults).
type sweepResultsJSON struct {
	Network        string                  `json:"network"`
	TotalHosts     int                     `json:"total_hosts"`
	AvailableHosts int                     `json:"available_hosts"`
	LastSweep      int64                   `json:"last_sweep"`
	Ports          []models.PortCount      `json:"ports"`
	Hosts          []models.HostResult     `json:"hosts"`
	ExecutionID    string                  `json:"execution_id"`
	SweepGroupID   string                  `json:"sweep_group_id"`
	Cancelled      bool                    `json:"cancelled"`
	ScannerStats   *models.ScannerStats    `json:"scanner_stats"`
	BannerGrab     *models.BannerGrabStats `json:"banner_grab"`
}

// buildSweepResultsEdgeRecords converts one results response into its records and
// the metric payload of each results chunk. The results chunking decides the
// metric batches, one per chunk; each chunk's hosts are then split further until every record fits the grant's row ceiling and the
// payload cap. Records are numbered across the whole response.
func buildSweepResultsEdgeRecords(
	response *proto.ResultsResponse,
	capability *edgev1.EdgeSignedCapabilityV1,
) (parts []edgeMetricsBuilt, cancelTemplate *edgev1.UnleasedSweepResultsBatchV1, metrics []map[string]any, err error) {
	chunks, err := buildSweepResultsChunks(response)
	if err != nil {
		return nil, nil, nil, err
	}
	maxRows := capability.GetProduction().GetMaxProjectedRowCount()
	sequence, _ := strconv.ParseUint(response.CurrentSequence, 10, 64)

	var batches []*edgev1.UnleasedSweepResultsBatchV1
	metrics = make([]map[string]any, 0, len(chunks))
	for _, chunk := range chunks {
		var doc sweepResultsJSON
		if err := json.Unmarshal(chunk.Data, &doc); err != nil {
			return nil, nil, nil, fmt.Errorf("parse sweep results chunk: %w", err)
		}
		batch, err := unleasedSweepBatch(&doc, sequence)
		if err != nil {
			return nil, nil, nil, err
		}
		// The response time is the results status time core records the sweep
		// service as observed at.
		batch.BatchCompletedAtUnixNano = uint64(max(response.Timestamp, 0)) * uint64(time.Second)
		split, err := splitUnleasedSweepBatch(batch, uint64(maxRows))
		if err != nil {
			return nil, nil, nil, err
		}
		batches = append(batches, split...)
		metrics = append(metrics, chunk.MetricPayload)
	}
	if len(batches) == 0 {
		return nil, nil, nil, errSweepResultsNoChunks
	}

	parts = make([]edgeMetricsBuilt, 0, len(batches))
	for i, batch := range batches {
		batch.ChunkIndex = uint32(i)
		batch.TotalChunks = uint32(len(batches))
		batch.IsFinal = i == len(batches)-1
		part, err := unleasedSweepEdgeRecord(batch, capability)
		if err != nil {
			return nil, nil, nil, err
		}
		parts = append(parts, part)
	}
	// The cancel marker is not a data chunk. appendSweepCancel completes it
	// with the data-chunk indexes actually appended.
	last := batches[len(batches)-1]
	cancelTemplate = &edgev1.UnleasedSweepResultsBatchV1{
		ExecutionId:              last.GetExecutionId(),
		SweepGroupId:             last.GetSweepGroupId(),
		Sequence:                 last.GetSequence(),
		LastSweepUnixNano:        last.GetLastSweepUnixNano(),
		BatchCompletedAtUnixNano: last.GetBatchCompletedAtUnixNano(),
		IsCancelled:              true,
		IsFinal:                  true,
		IsCancelMarker:           true,
	}
	return parts, cancelTemplate, metrics, nil
}

// splitUnleasedSweepBatch halves a batch's hosts until every part fits maxRows
// and the payload cap. A single host that does not fit is an error.
func splitUnleasedSweepBatch(batch *edgev1.UnleasedSweepResultsBatchV1, maxRows uint64) ([]*edgev1.UnleasedSweepResultsBatchV1, error) {
	if uint64(len(batch.GetHosts())) <= maxRows && gproto.Size(batch) <= edgeMetricsMaxPayloadBytes {
		return []*edgev1.UnleasedSweepResultsBatchV1{batch}, nil
	}
	if len(batch.GetHosts()) <= 1 {
		return nil, errSweepResultsHostTooLarge
	}
	half := len(batch.GetHosts()) / 2
	left := withHosts(batch, 0, half)
	right := withHosts(batch, half, len(batch.GetHosts()))
	a, err := splitUnleasedSweepBatch(left, maxRows)
	if err != nil {
		return nil, err
	}
	b, err := splitUnleasedSweepBatch(right, maxRows)
	if err != nil {
		return nil, err
	}
	return append(a, b...), nil
}

// withHosts is batch carrying only hosts [lo, hi) and their host results.
func withHosts(batch *edgev1.UnleasedSweepResultsBatchV1, lo, hi int) *edgev1.UnleasedSweepResultsBatchV1 {
	hosts, results := batch.Hosts, batch.HostResults
	batch.Hosts, batch.HostResults = nil, nil
	out := gproto.Clone(batch).(*edgev1.UnleasedSweepResultsBatchV1)
	batch.Hosts, batch.HostResults = hosts, results
	out.Hosts, out.HostResults = hosts[lo:hi], results[lo:hi]
	return out
}

func unleasedSweepEdgeRecord(batch *edgev1.UnleasedSweepResultsBatchV1, capability *edgev1.EdgeSignedCapabilityV1) (edgeMetricsBuilt, error) {
	payload, err := gproto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		return edgeMetricsBuilt{}, err
	}
	rows := uint32(len(batch.GetHosts()))
	record, err := newEdgeRecord(capability, nil, payload, rows, uint64(rows)*unleasedSweepProjectedRowBytes)
	if err != nil {
		return edgeMetricsBuilt{}, err
	}
	if err := edgerecord.ValidateUnleasedSweepResultsRecord(record); err != nil {
		return edgeMetricsBuilt{}, err
	}
	// No payload: these records feed no add-on metric feed.
	return edgeMetricsBuilt{record: record}, nil
}

// unleasedSweepBatch converts one parsed results chunk into the typed batch. Host
// times are deltas from the chunk's last sweep, the batch anchor. A host whose
// address does not parse is an error.
func unleasedSweepBatch(doc *sweepResultsJSON, sequence uint64) (*edgev1.UnleasedSweepResultsBatchV1, error) {
	// Ids and addresses must be in the canonical form core writes back, or core
	// could not rebuild the results JSON byte for byte.
	executionID, err := uuid.Parse(doc.ExecutionID)
	if err != nil || executionID.String() != doc.ExecutionID {
		return nil, fmt.Errorf("%w: %q", errSweepResultsExecutionID, doc.ExecutionID)
	}
	anchor := doc.LastSweep * int64(time.Second)
	checks, index := unleasedSweepChecks(doc.Hosts)

	batch := &edgev1.UnleasedSweepResultsBatchV1{
		ExecutionId:        executionID[:],
		NetworkCidr:        doc.Network,
		Sequence:           sequence,
		LastSweepUnixNano:  uint64(max(anchor, 0)),
		ObservedAtUnixNano: anchor,
		IsCancelled:        doc.Cancelled,
		ExpectedTotalHosts: uint32(max(doc.TotalHosts, 0)),
		AvailableHosts:     uint32(max(doc.AvailableHosts, 0)),
		TestedChecks:       checks,
		ExecutionSource:    edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
		ScannerStats:       unleasedScannerStats(doc.ScannerStats),
		BannerGrabSummary:  unleasedBannerGrab(doc.BannerGrab),
	}
	if doc.SweepGroupID != "" {
		groupID, err := uuid.Parse(doc.SweepGroupID)
		if err != nil || groupID.String() != doc.SweepGroupID {
			return nil, fmt.Errorf("%w: %q", errSweepResultsGroupID, doc.SweepGroupID)
		}
		batch.SweepGroupId = groupID[:]
	}
	for _, port := range doc.Ports {
		batch.PortCounts = append(batch.PortCounts, &edgev1.UnleasedSweepPortCountV1{
			Port: uint32(max(port.Port, 0)), Available: uint32(max(port.Available, 0)),
		})
	}
	for i := range doc.Hosts {
		host, bits, err := unleasedSweepHost(&doc.Hosts[i], index, anchor)
		if err != nil {
			return nil, err
		}
		result, err := unleasedSweepHostResult(&doc.Hosts[i])
		if err != nil {
			return nil, err
		}
		batch.ConfiguredModeBits |= bits
		batch.Hosts = append(batch.Hosts, host)
		batch.HostResults = append(batch.HostResults, result)
	}
	return batch, nil
}

// unleasedSweepChecks is the batch's tested checks: ICMP and MTR when any host
// carries them, then each TCP port any host was tested on, ascending. index maps
// a port to its check.
func unleasedSweepChecks(hosts []models.HostResult) ([]*edgev1.SweepTestV1, map[int]uint32) {
	var icmp, mtr bool
	ports := map[int]bool{}
	for i := range hosts {
		icmp = icmp || hosts[i].ICMPStatus != nil
		mtr = mtr || hosts[i].MTRStatus != nil
		for _, port := range hosts[i].PortResults {
			if port != nil {
				ports[port.Port] = true
			}
		}
	}
	var checks []*edgev1.SweepTestV1
	if icmp {
		checks = append(checks, &edgev1.SweepTestV1{Mode: edgev1.SweepMode_SWEEP_MODE_ICMP, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP})
	}
	if mtr {
		checks = append(checks, &edgev1.SweepTestV1{Mode: edgev1.SweepMode_SWEEP_MODE_MTR, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP})
	}
	sorted := make([]int, 0, len(ports))
	for port := range ports {
		sorted = append(sorted, port)
	}
	sort.Ints(sorted)
	index := make(map[int]uint32, len(sorted))
	for _, port := range sorted {
		index[port] = uint32(len(checks))
		checks = append(checks, &edgev1.SweepTestV1{
			Mode: edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, Port: uint32(max(port, 0)),
		})
	}
	return checks, index
}

func unleasedSweepHost(h *models.HostResult, index map[int]uint32, anchor int64) (*edgev1.SweepHostObservationV1, uint32, error) {
	addr, err := netip.ParseAddr(h.Host)
	if err != nil {
		return nil, 0, fmt.Errorf("sweep host %q: %w", h.Host, err)
	}
	if addr.Unmap().String() != h.Host {
		return nil, 0, fmt.Errorf("%w: %q", errSweepResultsHostForm, h.Host)
	}
	host := &edgev1.SweepHostObservationV1{Address: addr.Unmap().AsSlice(), ModeRevision: 1}
	if !h.LastSeen.IsZero() {
		host.ObservedAtDeltaNano = h.LastSeen.UnixNano() - anchor
		last := host.ObservedAtDeltaNano
		host.LastSeenDeltaNano = &last
	}
	if !h.FirstSeen.IsZero() {
		first := h.FirstSeen.UnixNano() - anchor
		host.FirstSeenDeltaNano = &first
	}

	var bits uint32
	if s := h.ICMPStatus; s != nil {
		bits |= uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP)
		rtt := uint64(max(s.RoundTrip.Microseconds(), 0))
		loss := s.PacketLoss
		host.Icmp = &edgev1.SweepIcmpSummaryV1{
			Outcome: outcome(s.Available), TargetReached: s.Available, RoundTripMicro: &rtt, PacketLossPct: &loss,
		}
	}
	if s := h.MTRStatus; s != nil {
		bits |= uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR)
		rtt := uint64(max(s.RoundTrip.Microseconds(), 0))
		loss := s.PacketLoss
		mtrOutcome := edgev1.MtrOutcome_MTR_OUTCOME_TARGET_UNREACHABLE
		if s.Reached {
			mtrOutcome = edgev1.MtrOutcome_MTR_OUTCOME_REACHED
		}
		host.Mtr = &edgev1.SweepMtrSummaryV1{
			Outcome: mtrOutcome, TargetReached: s.Reached, FinalRttMicro: &rtt, PacketLossPct: &loss,
			TotalHops: uint32(max(s.TotalHops, 0)),
		}
	}
	if len(h.PortResults) > 0 {
		bits |= uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT)
		var open uint32
		for _, port := range h.PortResults {
			if port == nil {
				continue
			}
			check := index[port.Port]
			if port.Available {
				open++
				rt := uint64(max(port.RespTime.Nanoseconds(), 0))
				host.OpenPorts = append(host.OpenPorts, &edgev1.SweepOpenPortV1{TestedCheckIndex: check, ResponseTimeNano: &rt, Service: port.Service})
				continue
			}
			host.PortErrors = append(host.PortErrors, &edgev1.SweepPortErrorV1{TestedCheckIndex: check, ErrorCode: unleasedSweepClosedPort})
		}
		host.Tcp = &edgev1.SweepTcpSummaryV1{Outcome: outcome(open > 0), TestedCount: uint32(len(h.PortResults)), OpenCount: open}
	}
	host.ResultModeBits = bits
	return host, bits, nil
}

// unleasedSweepHostResult is the host's results JSON beyond its frozen
// observation: the agent's own verdict, its times at full precision, every port
// result in order, and the seen times exactly as the agent encodes them.
func unleasedSweepHostResult(h *models.HostResult) (*edgev1.UnleasedSweepHostResultV1, error) {
	firstSeen, err := jsonTime(h.FirstSeen)
	if err != nil {
		return nil, err
	}
	lastSeen, err := jsonTime(h.LastSeen)
	if err != nil {
		return nil, err
	}
	result := &edgev1.UnleasedSweepHostResultV1{
		Available:        h.Available,
		ResponseTimeNano: h.ResponseTime.Nanoseconds(),
		FirstSeen:        firstSeen,
		LastSeen:         lastSeen,
	}
	if h.ICMPStatus != nil {
		result.IcmpRoundTripNano = h.ICMPStatus.RoundTrip.Nanoseconds()
	}
	if h.MTRStatus != nil {
		result.MtrRoundTripNano = h.MTRStatus.RoundTrip.Nanoseconds()
	}
	for _, port := range h.PortResults {
		if port == nil {
			continue
		}
		result.PortResults = append(result.PortResults, &edgev1.UnleasedSweepPortResultV1{
			Port: int32(max(min(port.Port, math.MaxInt32), math.MinInt32)), Available: port.Available,
			ResponseTimeNano: port.RespTime.Nanoseconds(), Service: port.Service,
		})
	}
	for _, mode := range h.SweepModes {
		result.SweepModes = append(result.SweepModes, string(mode))
	}
	return result, nil
}

// jsonTime is t as the agent's results JSON encodes it, without the quotes.
func jsonTime(t time.Time) (string, error) {
	encoded, err := t.MarshalJSON()
	if err != nil {
		return "", err
	}
	return strings.Trim(string(encoded), `"`), nil
}

func outcome(ok bool) edgev1.SweepModeOutcome {
	if ok {
		return edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS
	}
	return edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_FAILURE
}

func unleasedScannerStats(s *models.ScannerStats) *edgev1.UnleasedSweepScannerStatsV1 {
	if s == nil {
		return nil
	}
	return &edgev1.UnleasedSweepScannerStatsV1{
		Protocol: s.Protocol, AddressFamily: s.AddressFamily, ScannerPath: s.ScannerPath,
		PacketsSent: s.PacketsSent, PacketsRecv: s.PacketsRecv, PacketsDropped: s.PacketsDropped,
		RingBlocksProcessed: s.RingBlocksProcessed, RingBlocksDropped: s.RingBlocksDropped,
		RetriesAttempted: s.RetriesAttempted, RetriesSuccessful: s.RetriesSuccessful, RetriesDropped: s.RetriesDropped,
		PortsAllocated: s.PortsAllocated, PortsReleased: s.PortsReleased, PortExhaustionCount: s.PortExhaustionCount,
		RateLimitDeferrals: s.RateLimitDeferrals, RateLimitWaits: s.RateLimitWaits, SourcePortWaits: s.SourcePortWaits,
		RateLimitWaitTimeMs: s.RateLimitWaitTimeMs, SourcePortWaitTimeMs: s.SourcePortWaitTimeMs,
		RxDropRatePercent: s.RxDropRatePercent, DialsStarted: s.DialsStarted, DialsSucceeded: s.DialsSucceeded,
		DialTimeouts: s.DialTimeouts, DialResets: s.DialResets, DialResourceErrors: s.DialResourceErrors,
		ActiveDials: s.ActiveDials, MaxActiveDials: s.MaxActiveDials, QueueDepth: s.QueueDepth, MaxQueueDepth: s.MaxQueueDepth,
	}
}

func unleasedBannerGrab(s *models.BannerGrabStats) *edgev1.UnleasedSweepBannerGrabSummaryV1 {
	if s == nil {
		return nil
	}
	return &edgev1.UnleasedSweepBannerGrabSummaryV1{
		CandidatesTotal: s.CandidatesTotal, ProbesTotal: s.ProbesTotal, Inflight: s.InFlight, QueueDepth: s.QueueDepth,
		MatchBatchesTotal: s.MatchBatchesTotal, MatchBatchBytesTotal: s.MatchBatchBytesTotal,
		BytesReceivedTotal: s.BannerBytesTotal, SkippedFreshTotal: s.SkippedFreshTotal,
		SkippedBackoffTotal: s.SkippedBackoffTotal, MatchesTotal: s.MatchesTotal,
		EmptyResponseTotal: s.EmptyResponseTotal, ConnectionResetTotal: s.ConnectionResetTotal,
		TimeoutTotal: s.TimeoutTotal, ErrorsTotal: s.ErrorsTotal,
	}
}
