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
	"net/netip"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
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
	errSweepResultsExecutionID  = errors.New("sweep results have no execution id")
	errSweepResultsHostTooLarge = errors.New("one sweep host does not fit an edge record")
)

// sweepResultsEdgePending is the built records of the one sweep results response
// the agent is spooling: each legacy chunk's metric batch, then the results.
// Records are built once, so a retry after a spool refusal appends the unsent ones
// under their original event ids; the response is acknowledged to the sweep
// service only when every record is in the spool. Its zero value is empty.
type sweepResultsEdgePending struct {
	mu       sync.Mutex
	groupID  string
	sequence string
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

// sweepResultsEdgeRecords is the producer the results records are counted under.
func sweepResultsEdgeRecords() edgeMetricsProducer[struct{}] {
	return edgeMetricsProducer[struct{}]{producer: edgeProducerSweepResults}
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

	metrics := p.sweepResultsMetricRecords(metricPayloads, metricsGrant)

	p.sweepResultsEdge.mu.Lock()
	p.sweepResultsEdge.groupID = response.SweepGroupId
	p.sweepResultsEdge.sequence = response.CurrentSequence
	p.sweepResultsEdge.metrics = metrics
	p.sweepResultsEdge.parts = parts
	p.sweepResultsEdge.mu.Unlock()

	pending, sent = p.finishSweepResultsEdge(sweepSvc)
	return true, pending, sent
}

// sweepResultsMetricRecords builds the metric batch record of each legacy results
// chunk, as the legacy push builds its envelope. A chunk with no metric points has
// none; a batch no record can hold is split, and only what no record holds is
// dropped and counted.
func (p *PushLoop) sweepResultsMetricRecords(payloads []map[string]any, capability *edgev1.EdgeSignedCapabilityV1) []edgeMetricsBuilt {
	m := sweepResultsEdgeMetrics()
	ctx := p.metricEnvelopeContext()
	var parts []edgeMetricsBuilt
	for _, payload := range payloads {
		_, built, dropped, err := nextEdgeMetricsRecords([]map[string]any{payload}, m.build, capability, ctx)
		if err != nil {
			if !errors.Is(err, m.nothing) {
				p.dropEdgeMetrics(m.producer, edgeDropInvalidRecord, 1, err)
			}
			continue
		}
		p.dropEdgeMetrics(m.producer, edgeDropInvalidRecord, dropped, errEdgeMetricsRecordTooLarge)
		parts = append(parts, built...)
	}
	return parts
}

// finishSweepResultsEdge appends the unsent records of the response being spooled,
// metric batches first. A retryable refusal leaves the rest queued with their
// event ids (pending); a permanent refusal drops only that record. Once every
// record is in the spool the response is acknowledged and its sequence recorded.
func (p *PushLoop) finishSweepResultsEdge(sweepSvc SweepResultsProvider) (pending, appended bool) {
	p.sweepResultsEdge.mu.Lock()
	defer p.sweepResultsEdge.mu.Unlock()
	state := &p.sweepResultsEdge
	if state.sequence == "" && len(state.metrics) == 0 && len(state.parts) == 0 {
		return false, false
	}

	queued := len(state.metrics) + len(state.parts)
	admittedMetrics, restMetrics := appendEdgeMetricsParts(p, sweepResultsEdgeMetrics(), state.metrics, queued)
	state.metrics = restMetrics
	if len(restMetrics) > 0 {
		return true, admittedMetrics > 0
	}
	admitted, rest := appendEdgeMetricsParts(p, sweepResultsEdgeRecords(), state.parts, len(state.parts))
	admitted += admittedMetrics
	state.parts = rest
	if len(rest) > 0 {
		return true, admitted > 0
	}

	acknowledgeSweepResults(sweepSvc, state.groupID, state.sequence)
	if state.sequence != "" {
		p.setSweepResultsSequence(state.sequence)
	}
	state.groupID, state.sequence = "", ""
	return false, admitted > 0
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
	left := withHosts(batch, batch.GetHosts()[:half])
	right := withHosts(batch, batch.GetHosts()[half:])
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

func withHosts(batch *edgev1.UnleasedSweepResultsBatchV1, hosts []*edgev1.SweepHostObservationV1) *edgev1.UnleasedSweepResultsBatchV1 {
	out := gproto.Clone(batch).(*edgev1.UnleasedSweepResultsBatchV1)
	out.Hosts = hosts
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
	executionID, err := uuid.Parse(doc.ExecutionID)
	if err != nil {
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
	if groupID, err := uuid.Parse(doc.SweepGroupID); err == nil {
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
		batch.ConfiguredModeBits |= bits
		batch.Hosts = append(batch.Hosts, host)
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
