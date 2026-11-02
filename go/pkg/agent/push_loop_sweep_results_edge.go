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
)

// sweepResultsEdgePending is the built records of the one sweep results response
// the agent is spooling: each legacy chunk's metric batch, then the results.
// Records are built once, so a retry after a retryable spool refusal appends the
// unsent ones under their original event ids. admitted is set once any record of
// this response is in the spool. The response is acknowledged when every record
// is in the spool or, after admitted, has been permanently dropped. When nothing
// from the response was admitted and a record cannot enter the spool, response
// goes back to the legacy path whole. Its zero value is empty.
type sweepResultsEdgePending struct {
	mu       sync.Mutex
	groupID  string
	sequence string
	response *proto.ResultsResponse
	admitted bool
	metrics  []edgeMetricsBuilt
	parts    []edgeMetricsBuilt
}

// sweepResultsEdgeMetrics carries the metric batch of each sweep results chunk:
// the envelope the legacy results push builds for the chunk, one per chunk.
func sweepResultsEdgeMetrics() edgeMetricsProducer[map[string]any] {
	return edgeMetricsProducer[map[string]any]{
		producer: edgeProducerSweepResultsMetrics, build: buildSweepSummaryMetricBatch,
		nothing: errSweepNoMetricPoints,
	}
}

// sweepResultsEdgeGrants is the results and metrics grants unleased sweep results
// are emitted under at now, or nil when results take the legacy path. Both are
// required, because a results chunk and its metric batch take one path together.
func (p *PushLoop) sweepResultsEdgeGrants(now time.Time) (results, metrics *edgev1.EdgeSignedCapabilityV1) {
	if p.edgeMetricsSpool == nil {
		return nil, nil
	}
	results = p.edgeOutputGrants.current(edgerecord.UnleasedSweepResultsContractID, now)
	metrics = p.edgeOutputGrants.current(edgerecord.MetricsBatchContractID, now)
	if results == nil || metrics == nil {
		return nil, nil
	}
	return results, metrics
}

// sweepResultsGroupLeased reports whether a sweep group runs core-leased slots.
// Leased results keep their own path; only unleased groups emit under the
// standing results grant. A provider without leases has no leased group.
func sweepResultsGroupLeased(sweepSvc SweepResultsProvider, groupID string) bool {
	leases, ok := sweepSvc.(interface{ GroupLeaseDriven(groupID string) bool })
	return ok && leases.GroupLeaseDriven(groupID)
}

// pushSweepResultsEdge spools one unleased results response as edge records when
// the agent holds both grants. spooled reports that the response took the edge
// path, so the legacy push must not send it; pending that part of it waits in
// memory for spool room, so no further response may be read. A response the
// typed batch cannot carry is not spooled and keeps the legacy path.
func (p *PushLoop) pushSweepResultsEdge(sweepSvc SweepResultsProvider, response *proto.ResultsResponse) (spooled, pending, sent bool) {
	if sweepResultsGroupLeased(sweepSvc, response.SweepGroupId) {
		return false, false, false
	}
	resultsGrant, metricsGrant := p.sweepResultsEdgeGrants(time.Now())
	if resultsGrant == nil {
		return false, false, false
	}

	parts, metricPayloads, err := buildSweepResultsEdgeRecords(response, resultsGrant)
	if err != nil {
		p.logger.Warn().Err(err).Str("sweep_group_id", response.SweepGroupId).
			Msg("Sweep results response stays on the legacy path")
		return false, false, false
	}

	metrics, err := p.sweepResultsMetricRecords(metricPayloads, metricsGrant)
	if err != nil {
		// Nothing from this response is in the spool yet. The legacy push sends
		// the response unchanged, including the chunk whose metric did not build.
		p.logger.Warn().Err(err).Str("sweep_group_id", response.SweepGroupId).
			Str("reason", sweepPermanentDropReason(err).label()).
			Msg("Sweep results response stays on the legacy path")
		return false, false, false
	}

	p.sweepResultsEdge.mu.Lock()
	p.sweepResultsEdge.groupID = response.SweepGroupId
	p.sweepResultsEdge.sequence = response.CurrentSequence
	p.sweepResultsEdge.response = response
	p.sweepResultsEdge.admitted = false
	p.sweepResultsEdge.metrics = metrics
	p.sweepResultsEdge.parts = parts
	p.sweepResultsEdge.mu.Unlock()

	pending, sent, fallback := p.finishSweepResultsEdge(sweepSvc)
	if fallback != nil {
		return false, false, false
	}
	return true, pending, sent
}

// sweepResultsMetricRecords builds the metric batch record of each legacy results
// chunk, as the legacy push builds its envelope. A chunk with no metric points has
// none; a batch no record can hold is split, and only what no record holds is
// dropped and counted. A chunk that cannot form a record at all is an error, so
// the response can stay on the legacy path instead of losing that chunk.
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
// metric batches first. A retryable refusal leaves the rest queued with their
// event ids (pending). A permanent refusal before anything from this response was
// admitted returns the original response for the legacy path and appends nothing
// further. A permanent refusal after a record was admitted drops that record,
// counts it, and continues. The response is acknowledged once nothing remains queued.
func (p *PushLoop) finishSweepResultsEdge(sweepSvc SweepResultsProvider) (pending, appended bool, fallback *proto.ResultsResponse) {
	p.sweepResultsEdge.mu.Lock()
	defer p.sweepResultsEdge.mu.Unlock()
	state := &p.sweepResultsEdge
	if state.sequence == "" && len(state.metrics) == 0 && len(state.parts) == 0 {
		return false, false, nil
	}

	added, rest, err := p.appendSweepResultsRecords(edgeProducerSweepResultsMetrics, state.metrics, state.admitted)
	if err != nil {
		return false, false, p.abandonSweepResultsEdge(err)
	}
	state.admitted = state.admitted || added > 0
	state.metrics = rest
	appended = added > 0
	if len(rest) > 0 {
		return true, appended, nil
	}

	added, rest, err = p.appendSweepResultsRecords(edgeProducerSweepResults, state.parts, state.admitted)
	if err != nil {
		return false, false, p.abandonSweepResultsEdge(err)
	}
	state.admitted = state.admitted || added > 0
	state.parts = rest
	appended = appended || added > 0
	if len(rest) > 0 {
		return true, appended, nil
	}

	acknowledgeSweepResults(sweepSvc, state.groupID, state.sequence)
	if state.sequence != "" {
		p.setSweepResultsSequence(state.sequence)
	}
	state.groupID, state.sequence = "", ""
	state.response = nil
	state.admitted = false
	state.metrics, state.parts = nil, nil
	return false, appended, nil
}

// abandonSweepResultsEdge forgets a response that never entered the spool so the
// caller can send it on the legacy path. The caller acknowledges it only if that
// send succeeds.
func (p *PushLoop) abandonSweepResultsEdge(err error) *proto.ResultsResponse {
	state := &p.sweepResultsEdge
	response := state.response
	groupID := state.groupID
	state.groupID, state.sequence = "", ""
	state.response = nil
	state.admitted = false
	state.metrics, state.parts = nil, nil
	p.logger.Warn().Err(err).Str("sweep_group_id", groupID).
		Str("reason", sweepPermanentDropReason(err).label()).
		Msg("Sweep results response stays on the legacy path")
	return response
}

// appendSweepResultsRecords appends parts in order. added is how many this call
// put in the spool. rest is the unsent suffix after a retryable refusal and
// includes the refused record, whose event id is unchanged. A permanent refusal
// with nothing from this response in the spool returns that error and an empty
// rest, so the caller does not append later records. After a record was admitted,
// a permanent refusal drops that record and continues.
func (p *PushLoop) appendSweepResultsRecords(producer edgeProducer, parts []edgeMetricsBuilt, already bool) (added int, rest []edgeMetricsBuilt, fallback error) {
	for i, part := range parts {
		permanent, err := p.appendOneSweepRecord(part)
		if err == nil {
			added++
			continue
		}
		if !permanent {
			p.logger.Warn().Err(err).Str("producer", producer.label()).
				Msg("Edge spool refused sweep results; retrying on the next push")
			return added, parts[i:], nil
		}
		if !already && added == 0 {
			return 0, nil, err
		}
		p.dropEdgeMetrics(producer, sweepPermanentDropReason(err), 1, err)
	}
	return added, nil, nil
}

// appendOneSweepRecord appends one built record. permanent is set when repeating
// the append cannot succeed: the body will not encode, or the spool refused it
// for a reason that is not cleared by waiting.
func (p *PushLoop) appendOneSweepRecord(part edgeMetricsBuilt) (permanent bool, err error) {
	body, err := edgerecord.CanonicalRecordBytes(part.record)
	if err != nil {
		return true, err
	}
	if _, err = p.edgeMetricsSpool.Append(part.record.GetEventId(), body); err != nil {
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
// the metric payload of each legacy chunk. The legacy chunking still decides the
// metric batches, so they equal what the legacy push sends; each chunk's hosts
// are then split further until every record fits the grant's row ceiling and the
// payload cap. Records are numbered across the whole response.
func buildSweepResultsEdgeRecords(
	response *proto.ResultsResponse,
	capability *edgev1.EdgeSignedCapabilityV1,
) ([]edgeMetricsBuilt, []map[string]any, error) {
	chunks, err := buildSweepResultsChunks(response)
	if err != nil {
		return nil, nil, err
	}
	maxRows := capability.GetProduction().GetMaxProjectedRowCount()
	sequence, _ := strconv.ParseUint(response.CurrentSequence, 10, 64)

	var batches []*edgev1.UnleasedSweepResultsBatchV1
	metrics := make([]map[string]any, 0, len(chunks))
	for _, chunk := range chunks {
		var doc sweepResultsJSON
		if err := json.Unmarshal(chunk.Data, &doc); err != nil {
			return nil, nil, fmt.Errorf("parse sweep results chunk: %w", err)
		}
		batch, err := unleasedSweepBatch(&doc, sequence)
		if err != nil {
			return nil, nil, err
		}
		// The response time is the legacy results status time core records the
		// sweep service as observed at.
		batch.BatchCompletedAtUnixNano = uint64(max(response.Timestamp, 0)) * uint64(time.Second)
		split, err := splitUnleasedSweepBatch(batch, uint64(maxRows))
		if err != nil {
			return nil, nil, err
		}
		batches = append(batches, split...)
		metrics = append(metrics, chunk.MetricPayload)
	}

	parts := make([]edgeMetricsBuilt, 0, len(batches))
	for i, batch := range batches {
		batch.ChunkIndex = uint32(i)
		batch.TotalChunks = uint32(len(batches))
		batch.IsFinal = i == len(batches)-1
		part, err := unleasedSweepEdgeRecord(batch, capability)
		if err != nil {
			return nil, nil, err
		}
		parts = append(parts, part)
	}
	return parts, metrics, nil
}

// splitUnleasedSweepBatch halves a batch's hosts until every part fits maxRows
// and the payload cap. A single host that does not fit is an error, so the
// response keeps the legacy path instead of losing that host.
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

// withHosts is batch carrying only hosts [lo, hi) and their legacy host results.
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
// address does not parse keeps the response on the legacy path.
func unleasedSweepBatch(doc *sweepResultsJSON, sequence uint64) (*edgev1.UnleasedSweepResultsBatchV1, error) {
	// Ids and addresses must be in the canonical form core writes back, or core
	// could not rebuild the results JSON byte for byte; such a response keeps the
	// legacy path.
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

// unleasedSweepHostResult is the host's legacy results JSON beyond its frozen
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
