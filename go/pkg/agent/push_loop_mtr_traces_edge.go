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
	"math"
	"net/netip"
	"strings"
	"time"

	"github.com/google/uuid"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/mtr"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

var errMTRNoTraces = errors.New("no MTR traces to encode")

// edgeScheduledMtrCapability returns the standing grant new scheduled MTR trace
// records are emitted under at now, or nil when traces take the legacy path.
func (p *PushLoop) edgeScheduledMtrCapability(now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	if p.edgeMetricsSpool == nil {
		return nil
	}
	return p.edgeOutputGrants.current(edgerecord.ScheduledMtrTraceContractID, now)
}

func mtrTraceEdgeQueueProducer() edgeMetricsProducer[mtrCheckResult] {
	return edgeMetricsProducer[mtrCheckResult]{
		producer: edgeProducerMTRTraces,
		nothing:  errMTRNoTraces,
	}
}

// spoolScheduledMtrTraces appends queued and newly collected MTR check results
// as serviceradar.mtr.scheduled_trace edge records under capability.
func spoolScheduledMtrTraces(
	p *PushLoop,
	drained []mtrCheckResult,
	capability *edgev1.EdgeSignedCapabilityV1,
) bool {
	m := mtrTraceEdgeQueueProducer()
	q := &p.mtrTraceEdge
	q.mu.Lock()
	defer q.mu.Unlock()

	pending := append([]edgeMetricsQueued[mtrCheckResult](nil), q.pending...)
	for _, item := range drained {
		pending = append(pending, edgeMetricsQueued[mtrCheckResult]{item: item, hasItem: true})
	}

	ctx := p.metricEnvelopeContext()
	appended := 0
	for len(pending) > 0 {
		head := pending[0]
		taken, parts := 1, head.ready
		if head.hasItem && len(head.ready) == 0 {
			var err error
			items := unbuiltItems(pending)
			taken, parts, err = nextScheduledMtrTraceRecords(items, capability, ctx)
			if err != nil {
				if !errors.Is(err, errMTRNoTraces) {
					p.dropEdgeMetrics(m.producer, edgeDropInvalidRecord, taken, err)
				}
				pending = pending[taken:]
				continue
			}
		}

		admitted, rest := appendEdgeMetricsParts(p, m, parts, len(pending))
		if admitted == 0 && len(rest) > 0 {
			if taken == 1 && head.hasItem {
				pending[0].ready = rest
			}
			break
		}
		if admitted > 0 {
			appended += taken
		}
		pending = append(partEntries[mtrCheckResult](rest), pending[taken:]...)
		if len(rest) > 0 {
			break
		}
	}

	q.pending = trimEdgeMetrics(p, m, pending)

	if appended > 0 {
		p.logger.Debug().Str("producer", m.producer.label()).Int("count", appended).
			Msg("Spooled scheduled MTR traces as edge records")
	}
	return appended > 0
}

func nextScheduledMtrTraceRecords(
	items []mtrCheckResult,
	capability *edgev1.EdgeSignedCapabilityV1,
	ctx metricEnvelopeContext,
) (int, []edgeMetricsBuilt, error) {
	claims := capability.GetProduction()
	maxRows := min(
		uint64(edgerecord.ScheduledMtrTraceMaxRows),
		uint64(claims.GetMaxProjectedRowCount()),
		claims.GetMaxProjectedWriteBytes()/edgerecord.ScheduledMtrTraceProjectedRowBytes,
	)

	head, err := buildScheduledMtrTraceBatch(items[:1], ctx)
	if err != nil {
		return 1, nil, err
	}
	headRecord, err := scheduledMtrEdgeRecord(head, capability, maxRows)
	if err != nil {
		return 1, nil, errEdgeMetricsRecordTooLarge
	}

	limit := len(items)
	if uint64(limit) > maxRows {
		limit = int(maxRows)
	}
	taken, built := longestPrefix(limit, func(k int) (edgeMetricsBuilt, error) {
		if k == 1 {
			return headRecord, nil
		}
		batch, buildErr := buildScheduledMtrTraceBatch(items[:k], ctx)
		if buildErr != nil {
			return edgeMetricsBuilt{}, buildErr
		}
		return scheduledMtrEdgeRecord(batch, capability, maxRows)
	})
	return taken, []edgeMetricsBuilt{built}, nil
}

func scheduledMtrEdgeRecord(
	batch *edgev1.AgentScheduledMtrTraceBatchV1,
	capability *edgev1.EdgeSignedCapabilityV1,
	maxRows uint64,
) (edgeMetricsBuilt, error) {
	rows := len(batch.GetTraces())
	if rows == 0 || uint64(rows) > maxRows {
		return edgeMetricsBuilt{}, errEdgeMetricsRecordTooLarge
	}
	payload, err := gproto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		return edgeMetricsBuilt{}, err
	}
	if len(payload) > edgeMetricsMaxPayloadBytes {
		return edgeMetricsBuilt{}, errEdgeMetricsRecordTooLarge
	}
	record, err := newEdgeRecord(
		capability,
		nil,
		payload,
		uint32(rows),
		uint64(rows)*edgerecord.ScheduledMtrTraceProjectedRowBytes,
	)
	if err != nil {
		return edgeMetricsBuilt{}, err
	}
	if err := edgerecord.ValidateScheduledMtrTraceRecord(record); err != nil {
		return edgeMetricsBuilt{}, err
	}
	return edgeMetricsBuilt{record: record}, nil
}

func buildScheduledMtrTraceBatch(
	results []mtrCheckResult,
	_ metricEnvelopeContext,
) (*edgev1.AgentScheduledMtrTraceBatchV1, error) {
	if len(results) == 0 {
		return nil, errMTRNoTraces
	}
	traces := make([]*edgev1.AgentScheduledMtrTraceV1, 0, len(results))
	for _, r := range results {
		entry, err := buildScheduledMtrTrace(r)
		if err != nil {
			return nil, err
		}
		traces = append(traces, entry)
	}
	if len(traces) == 0 {
		return nil, errMTRNoTraces
	}
	return &edgev1.AgentScheduledMtrTraceBatchV1{Traces: traces}, nil
}

func buildScheduledMtrTrace(r mtrCheckResult) (*edgev1.AgentScheduledMtrTraceV1, error) {
	target := strings.TrimSpace(r.Target)
	if target == "" && r.Trace != nil {
		target = strings.TrimSpace(r.Trace.Target)
		if target == "" {
			target = strings.TrimSpace(r.Trace.TargetIP)
		}
	}
	if target == "" {
		return nil, fmt.Errorf("%w: missing target", edgerecord.ErrScheduledMtrBatch)
	}

	traceID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, err
	}
	eventID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return nil, err
	}

	entry := &edgev1.AgentScheduledMtrTraceV1{
		CheckId:         r.CheckID,
		CheckName:       r.CheckName,
		DeviceId:        r.DeviceID,
		CommandId:       r.CommandID,
		ExecutionSource: scheduledMtrExecutionSource(r.ExecutionSource),
		ErrorMessage:    r.Error,
	}
	if r.SweepGroupID != "" {
		id, parseErr := uuid.Parse(r.SweepGroupID)
		if parseErr != nil {
			return nil, fmt.Errorf("%w: sweep_group_id %q: %w", edgerecord.ErrScheduledMtrBatch, r.SweepGroupID, parseErr)
		}
		entry.SweepGroupId = id[:]
	}
	if r.ExecutionID != "" {
		id, parseErr := uuid.Parse(r.ExecutionID)
		if parseErr != nil {
			return nil, fmt.Errorf("%w: execution_id %q: %w", edgerecord.ErrScheduledMtrBatch, r.ExecutionID, parseErr)
		}
		entry.ExecutionId = id[:]
	}

	observedNano := r.Timestamp
	if r.Trace != nil && r.Trace.Timestamp != 0 {
		observedNano = normalizeMtrTimestampNano(r.Trace.Timestamp)
	} else {
		observedNano = normalizeMtrTimestampNano(observedNano)
	}
	if observedNano <= 0 {
		observedNano = time.Now().UnixNano()
	}

	targetReached := r.Available
	if r.Trace != nil && r.Trace.TargetReached {
		targetReached = true
	}

	outcome := edgev1.MtrOutcome_MTR_OUTCOME_TARGET_UNREACHABLE
	switch {
	case targetReached:
		outcome = edgev1.MtrOutcome_MTR_OUTCOME_REACHED
	case r.Trace == nil || r.Error != "":
		outcome = edgev1.MtrOutcome_MTR_OUTCOME_PROBE_FAILED
	}

	ipVersion := uint32(4)
	protocol := edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP
	packetSize := uint32(0)
	var resolvedAddr []byte
	var hops []*edgev1.MtrTraceHopV1
	var hopDiags []*edgev1.MtrHopReplyDiagnosticsV1
	var maxHop uint32

	if r.Trace != nil {
		if r.Trace.IPVersion == 4 || r.Trace.IPVersion == 6 {
			ipVersion = uint32(r.Trace.IPVersion)
		}
		protocol = scheduledMtrTransportProtocol(r.Trace.Protocol)
		if r.Trace.PacketSize > 0 {
			packetSize = uint32(r.Trace.PacketSize)
		}
		resolvedAddr = parseMtrAddrBytes(r.Trace.TargetIP)
		if len(resolvedAddr) == 0 {
			resolvedAddr = parseMtrAddrBytes(target)
		}
		if len(resolvedAddr) == 16 && r.Trace.IPVersion == 0 {
			ipVersion = 6
		}
		entry.ProbedHops = uint32(max(r.Trace.ProbedHops, 0))
		entry.LastRespondingHop = uint32(max(r.Trace.LastRespondingHop, 0))
		if r.Trace.TCPPort > 0 && r.Trace.TCPPort <= 65535 {
			entry.TcpPort = uint32(r.Trace.TCPPort)
		}
		entry.TcpProbeMode = scheduledMtrTcpProbeMode(r.Trace.TCPProbeMode)
		entry.TcpHandshake = buildScheduledMtrTcpHandshake(r.Trace.TCPHandshake)

		hops = make([]*edgev1.MtrTraceHopV1, 0, len(r.Trace.Hops))
		for _, hop := range r.Trace.Hops {
			protoHop := buildScheduledMtrHop(hop)
			if protoHop.GetHopNumber() > maxHop {
				maxHop = protoHop.GetHopNumber()
			}
			hops = append(hops, protoHop)
			if diag, ok := buildScheduledMtrHopDiagnostics(hop); ok {
				hopDiags = append(hopDiags, diag)
			}
		}
		entry.HopDiagnostics = hopDiags
	} else {
		resolvedAddr = parseMtrAddrBytes(target)
		if len(resolvedAddr) == 16 {
			ipVersion = 6
		}
	}

	totalHops := maxHop
	if r.Trace != nil && uint32(max(r.Trace.TotalHops, 0)) > totalHops {
		totalHops = uint32(max(r.Trace.TotalHops, 0))
	}
	if targetReached && totalHops == 0 {
		totalHops = 1
	}

	var deviceHint []byte
	if r.DeviceID != "" && len(r.DeviceID) <= edgerecord.MaxTraceStrBytes {
		deviceHint = []byte(r.DeviceID)
	}

	entry.Trace = &edgev1.MtrTraceEventV1{
		TraceId:            traceID,
		EventId:            eventID,
		SweepHostAddress:   resolvedAddr,
		DeviceHint:         deviceHint,
		ObservedAtUnixNano: observedNano,
		Attempted:          r.Trace != nil || targetReached,
		Outcome:            outcome,
		Target:             target,
		ResolvedAddress:    resolvedAddr,
		Protocol:           protocol,
		IpVersion:          ipVersion,
		PacketSize:         packetSize,
		TargetReached:      targetReached,
		TotalHops:          totalHops,
		Hops:               hops,
	}
	return entry, nil
}

func buildScheduledMtrHop(hop mtr.HopSnapshot) *edgev1.MtrTraceHopV1 {
	sent := uint32(max(hop.Sent, 0))
	received := uint32(max(hop.Received, 0))
	if received > sent {
		sent = received
	}
	out := &edgev1.MtrTraceHopV1{
		HopNumber:               uint32(max(hop.HopNumber, 1)),
		Address:                 parseMtrAddrBytes(hop.Addr),
		Hostname:                hop.Hostname,
		Asn:                     uint32(max(hop.ASN.ASN, 0)),
		AsnOrg:                  hop.ASN.Org,
		Sent:                    sent,
		Received:                received,
		LossPct:                 clampLossPct(hop.LossPct),
		LastMicro:               optionalPositiveUint64(hop.LastUs),
		AvgMicro:                optionalPositiveUint64(hop.AvgUs),
		MinMicro:                optionalPositiveUint64(hop.MinUs),
		MaxMicro:                optionalPositiveUint64(hop.MaxUs),
		StddevMicro:             optionalPositiveUint64(hop.StdDevUs),
		JitterMicro:             optionalPositiveUint64(hop.JitterUs),
		JitterWorstMicro:        optionalPositiveUint64(hop.JitterWorstUs),
		JitterInterarrivalMicro: optionalPositiveUint64(hop.JitterInterarrivalUs),
	}
	for _, ecmp := range hop.ECMPAddrs {
		if b := parseMtrAddrBytes(ecmp); len(b) == 4 || len(b) == 16 {
			out.EcmpAddresses = append(out.EcmpAddresses, b)
		}
	}
	for _, lbl := range hop.MPLSLabels {
		out.MplsLabels = append(out.MplsLabels, &edgev1.MtrMplsLabelV1{
			Label:         uint32(max(lbl.Label, 0)),
			Experimental:  uint32(max(lbl.Exp, 0)),
			BottomOfStack: lbl.S,
			Ttl:           uint32(max(lbl.TTL, 0)),
		})
	}
	return out
}

func buildScheduledMtrHopDiagnostics(hop mtr.HopSnapshot) (*edgev1.MtrHopReplyDiagnosticsV1, bool) {
	hasUnreachable := hop.UnreachableCode != nil
	hasReplies := hop.ReplyTimeExceeded > 0 || hop.ReplyUnreachable > 0 || hop.ReplySynack > 0 || hop.ReplyRst > 0
	if !hasUnreachable && !hasReplies {
		return nil, false
	}
	diag := &edgev1.MtrHopReplyDiagnosticsV1{
		HopNumber:          uint32(max(hop.HopNumber, 1)),
		HasUnreachableCode: hasUnreachable,
		ReplyTimeExceeded:  uint32(max(hop.ReplyTimeExceeded, 0)),
		ReplyUnreachable:   uint32(max(hop.ReplyUnreachable, 0)),
		ReplySynack:        uint32(max(hop.ReplySynack, 0)),
		ReplyRst:           uint32(max(hop.ReplyRst, 0)),
	}
	if hasUnreachable {
		diag.UnreachableCode = uint32(max(*hop.UnreachableCode, 0))
	}
	return diag, true
}

func buildScheduledMtrTcpHandshake(hs *mtr.TCPHandshakeStats) *edgev1.MtrTcpHandshakeDiagnosticsV1 {
	if hs == nil {
		return nil
	}
	out := &edgev1.MtrTcpHandshakeDiagnosticsV1{
		Ttl:               uint32(max(hs.TTL, 0)),
		Attempts:          uint32(max(hs.Attempts, 0)),
		SynSent:           uint32(max(hs.SYNSent, 0)),
		SynackReceived:    uint32(max(hs.SYNACKReceived, 0)),
		RstReceived:       uint32(max(hs.RSTReceived, 0)),
		Unanswered:        uint32(max(hs.Unanswered, 0)),
		SynDropPct:        hs.DropPct,
		SynRetransmits:    uint32(max(hs.Retransmits, 0)),
		AnsweredAfterRetx: uint32(max(hs.AnsweredAfterRetx, 0)),
		AckMismatch:       uint32(max(hs.AckMismatch, 0)),
		SynackDuplicates:  uint32(max(hs.SYNACKDuplicates, 0)),
		RttMinUs:          hs.RTTMinUs,
		RttAvgUs:          hs.RTTAvgUs,
		RttMaxUs:          hs.RTTMaxUs,
	}
	if hs.ServerResponseUs != nil {
		out.HasServerResponseUs = true
		out.ServerResponseUs = *hs.ServerResponseUs
	}
	return out
}

func optionalPositiveUint64(v int64) *uint64 {
	if v <= 0 {
		return nil
	}
	u := uint64(v)
	return &u
}

func clampLossPct(v float64) float64 {
	if math.IsNaN(v) || math.IsInf(v, 0) || v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}

func parseMtrAddrBytes(raw string) []byte {
	addr, err := netip.ParseAddr(strings.TrimSpace(raw))
	if err != nil {
		return nil
	}
	return addr.Unmap().AsSlice()
}

func scheduledMtrTransportProtocol(protoName string) edgev1.TransportProtocol {
	switch strings.ToLower(strings.TrimSpace(protoName)) {
	case "tcp":
		return edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP
	case "udp":
		return edgev1.TransportProtocol_TRANSPORT_PROTOCOL_UDP
	default:
		return edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP
	}
}

func scheduledMtrTcpProbeMode(mode string) edgev1.MtrTcpProbeModeV1 {
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "syn":
		return edgev1.MtrTcpProbeModeV1_MTR_TCP_PROBE_MODE_V1_SYN
	case "connect":
		return edgev1.MtrTcpProbeModeV1_MTR_TCP_PROBE_MODE_V1_CONNECT
	default:
		return edgev1.MtrTcpProbeModeV1_MTR_TCP_PROBE_MODE_V1_UNSPECIFIED
	}
}

func scheduledMtrExecutionSource(src string) edgev1.SweepExecutionSource {
	switch strings.ToLower(strings.TrimSpace(src)) {
	case "scheduled_sweep":
		return edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP
	case "sweep_profile":
		return edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE
	case "on_demand":
		return edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_ON_DEMAND
	case "ad_hoc", "bulk_job":
		return edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC
	default:
		return edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK
	}
}

func normalizeMtrTimestampNano(ts int64) int64 {
	switch {
	case ts > 1_000_000_000_000_000:
		return ts
	case ts > 1_000_000_000_000:
		return ts * 1_000
	case ts > 0:
		return ts * 1_000_000_000
	default:
		return 0
	}
}
