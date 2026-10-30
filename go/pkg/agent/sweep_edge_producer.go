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
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"sort"
	"sync"
	"syscall"
	"time"

	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/obsbatch"
	"github.com/carverauto/serviceradar/go/pkg/edge/projection"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/sweeper"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

var (
	errEdgeSweepStaticCIDRRequired = errors.New("edge sweep requires static CIDR targets")
	errEdgeSweepCheckSetMismatch   = errors.New("edge sweep check set differs from signed plan")
	errEdgeSweepProjectionBudget   = errors.New("edge sweep grant lacks supported projection budget")
	errEdgeSweepCIDRMismatch       = errors.New("edge sweep targets differ from signed CIDR plan")
	errEdgeSweepOverlappingRanges  = errors.New("edge sweep overlapping ranges are unsupported")
	errEdgeSweepRangeUnauthorized  = errors.New("edge sweep range lacks source authorization")
	errEdgeSweepTargetsMismatch    = errors.New("edge sweep targets differ from signed plan")
	errEdgeSweepNoTCPPorts         = errors.New("edge sweep has no TCP ports")
	errEdgeSweepInvalidPort        = errors.New("edge sweep invalid port")
	errEdgeSweepNoChecks           = errors.New("edge sweep has no checks")
	errEdgeSweepCheckOutsidePlan   = errors.New("edge sweep result check is outside signed plan")
	errEdgeSweepPendingHostLimit   = errors.New("edge sweep pending host window limit reached")
	errEdgeSweepAddressOutsidePlan = errors.New("edge sweep result address is outside signed plan")
	errEdgeSweepDuplicateResult    = errors.New("edge sweep duplicate terminal check result")
	errEdgeSweepWindowExpired      = errors.New("edge sweep collection window expired")
	errEdgeSweepUnsupportedMode    = errors.New("edge sweep unsupported mode")
	errEdgeSweepIncomplete         = errors.New("edge sweep incomplete")
)

// Pending windows are bounded independently of the batch builder. The scanner
// can finish ICMP before TCP, so a pending host is not itself a completed host.
const maxPendingSweepHosts = 4096
const sweepProjectedRowBytes = 2048

// SetEdgeSweepSpool connects leased sweep producers to the sender's one open
// spool. Call before Start; a nil spool keeps the legacy result path.
func (p *PushLoop) SetEdgeSweepSpool(sp *spool.Spool) { p.edgeSweepSpool = sp }

// RunSweepGroupLease consumes the slot durably before its first append. An interrupted
// run stays incomplete, rather than repeating previously emitted host windows
// with different bytes under the same execution and batch sequence.
func (s *MultiSweepService) RunSweepGroupLease(ctx context.Context, groupID string, lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1, sp *spool.Spool, claim func() error) error {
	s.mu.RLock()
	svc := s.groups[groupID]
	s.mu.RUnlock()
	if svc == nil {
		return errSweepGroupNotFound
	}
	return svc.runLeaseToSpool(ctx, lease, slot, sp, claim)
}

func (s *SweepService) runLeaseToSpool(ctx context.Context, lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1, sp *spool.Spool, claim func() error) error {
	runner, ok := s.sweeper.(interface {
		RunOnceWithObserver(context.Context, string, func(*models.Result) error) error
	})
	if !ok {
		return errSweepRunnerUnavailable
	}
	s.runMu.Lock()
	defer s.runMu.Unlock()
	if err := sweeper.CheckExecution(ctx); err != nil {
		return err
	}

	s.mu.Lock()
	// Suppress the live summary and any cached legacy response for this group.
	s.edgeResults = true
	producer, err := newSweepEdgeProducer(s.config, lease, slot, sp, time.Now())
	s.mu.Unlock()
	if err != nil {
		return err
	}
	producer.claim = claim

	runCtx, cancel := context.WithDeadline(ctx, time.Unix(0, slot.GetCollectionExpiresUnixNano()))
	defer cancel()
	err = runner.RunOnceWithObserver(runCtx, uuid.UUID(slot.GetExecutionId()).String(), func(result *models.Result) error {
		if err := producer.observe(result); err != nil {
			cancel()
			return err
		}
		return nil
	})
	if err != nil {
		producer.mu.Lock()
		if producer.err != nil {
			err = producer.err
		}
		producer.mu.Unlock()
		return err
	}
	s.mu.Lock()
	s.lastEdgeExecutionID = uuid.UUID(slot.GetExecutionId()).String()
	s.pendingSweeps = nil
	s.cachedResults = nil
	s.cachedCompletion = nil
	s.mu.Unlock()
	return producer.finish()
}

type sweepCheck struct {
	mode models.SweepMode
	port int
}

type sweepHostWindow struct {
	host       *edgev1.SweepHostObservationV1
	seen       map[sweepCheck]bool
	rangeIndex int
}

type sweepRangeBuilder struct {
	prefix    netip.Prefix
	builder   *obsbatch.Builder
	authority *edgev1.EdgeSourceAuthorizationV1
}

type sweepEdgeProducer struct {
	mu         sync.Mutex
	lease      *edgev1.SweepLeaseV1
	slot       *edgev1.SweepLeaseSlotV1
	spool      *spool.Spool
	checks     map[sweepCheck]uint32
	modeBits   uint32
	ranges     []sweepRangeBuilder
	pending    map[netip.Addr]*sweepHostWindow
	observedAt int64
	sequence   uint64
	completed  uint64
	err        error
	claim      func() error
}

func newSweepEdgeProducer(cfg *models.Config, lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1, sp *spool.Spool, now time.Time) (*sweepEdgeProducer, error) {
	checks, keys, bits, err := sweepChecks(cfg)
	if err != nil {
		return nil, err
	}
	if len(cfg.DeviceTargets) != 0 || len(cfg.Networks) == 0 {
		return nil, errEdgeSweepStaticCIDRRequired
	}
	if !bytes.Equal(sweepCheckSetDigest(checks), slot.GetPlanHeader().GetCheckSetSha256()) {
		return nil, errEdgeSweepCheckSetMismatch
	}
	claims := lease.GetProductionCapability().GetProduction()
	maxRows := min(uint64(claims.GetMaxProjectedRowCount()), claims.GetMaxProjectedWriteBytes()/sweepProjectedRowBytes)
	if maxRows == 0 || claims.GetCostModelVersion() != 1 {
		return nil, errEdgeSweepProjectionBudget
	}
	p := &sweepEdgeProducer{lease: lease, slot: slot, spool: sp, checks: keys, modeBits: bits, observedAt: now.UnixNano(), pending: make(map[netip.Addr]*sweepHostWindow)}
	networks := make(map[netip.Prefix]bool, len(cfg.Networks))
	for _, cidr := range cfg.Networks {
		prefix, err := netip.ParsePrefix(cidr)
		if err != nil {
			return nil, fmt.Errorf("edge sweep static target: %w", err)
		}
		networks[prefix.Masked()] = true
	}
	for _, page := range slot.GetPlanPages() {
		for _, targetRange := range page.GetRanges() {
			prefix, err := netip.ParsePrefix(targetRange.GetCidr())
			if err != nil || !networks[prefix] {
				return nil, errEdgeSweepCIDRMismatch
			}
			delete(networks, prefix)
			for _, existing := range p.ranges {
				if prefix.Overlaps(existing.prefix) {
					return nil, errEdgeSweepOverlappingRanges
				}
			}
			var authority *edgev1.EdgeSourceAuthorizationV1
			for _, source := range slot.GetSourceAuthorizations() {
				if bytes.Equal(source.GetScopeId(), targetRange.GetRangeId()) {
					authority = source
					break
				}
			}
			if authority == nil {
				return nil, errEdgeSweepRangeUnauthorized
			}
			batchContext := obsbatch.Context{
				ExecutionID: slot.GetExecutionId(), SweepGroupID: lease.GetSweepGroupId(),
				ExecutionShard: claims.GetRunShard(), AssignmentEpoch: lease.GetAuthorityEpoch(), ObservedAtUnixNano: p.observedAt,
				ExecutionPlanID: slot.GetPlanHeader().GetExecutionPlanId(), ExecutionPlanSHA256: slot.GetPlanHeader().GetExecutionPlanSha256(),
				TargetRangeID: targetRange.GetRangeId(), TargetRangeSHA256: targetRange.GetRangeSha256(),
				TestedChecks: checks, ConfiguredModeBits: bits, AvailabilityPolicy: targetRange.GetAvailabilityPolicyId(),
				Source: edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
			}
			p.ranges = append(p.ranges, sweepRangeBuilder{prefix, obsbatch.NewBuilder(batchContext, obsbatch.Limits{MaxSweepRows: int(min(maxRows, obsbatch.DefaultMaxSweepRows))}), authority})
		}
	}
	if len(networks) != 0 || len(p.ranges) == 0 {
		return nil, errEdgeSweepTargetsMismatch
	}
	return p, nil
}

func sweepChecks(cfg *models.Config) ([]*edgev1.SweepTestV1, map[sweepCheck]uint32, uint32, error) {
	type entry struct {
		key   sweepCheck
		check *edgev1.SweepTestV1
		bit   uint32
	}
	entries := make(map[sweepCheck]entry)
	for _, mode := range cfg.SweepModes {
		var m edgev1.SweepMode
		var protocol edgev1.TransportProtocol
		var bit uint32
		ports := cfg.Ports
		switch mode {
		case models.ModeICMP:
			m, protocol, bit, ports = edgev1.SweepMode_SWEEP_MODE_ICMP, edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP, 1, []int{0}
		case models.ModeTCP:
			m, protocol, bit = edgev1.SweepMode_SWEEP_MODE_TCP_SYN, edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, 2
		case models.ModeTCPConnect:
			m, protocol, bit = edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT, edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, 4
		case models.ModeMTR:
			// MTR has no edge sweep producer; reject it explicitly.
			fallthrough
		default:
			return nil, nil, 0, fmt.Errorf("%w %q", errEdgeSweepUnsupportedMode, mode)
		}
		if len(ports) == 0 {
			return nil, nil, 0, errEdgeSweepNoTCPPorts
		}
		for _, port := range ports {
			if port < 0 || port > 65535 || (mode != models.ModeICMP && port == 0) {
				return nil, nil, 0, errEdgeSweepInvalidPort
			}
			key := sweepCheck{mode, port}
			entries[key] = entry{key, &edgev1.SweepTestV1{Mode: m, Protocol: protocol, Port: uint32(port)}, bit}
		}
	}
	ordered := make([]entry, 0, len(entries))
	for _, e := range entries {
		ordered = append(ordered, e)
	}
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].check.Mode != ordered[j].check.Mode {
			return ordered[i].check.Mode < ordered[j].check.Mode
		}
		return ordered[i].check.Port < ordered[j].check.Port
	})
	checks := make([]*edgev1.SweepTestV1, 0, len(ordered))
	keys := make(map[sweepCheck]uint32)
	var bits uint32
	for i, e := range ordered {
		checks = append(checks, e.check)
		keys[e.key] = uint32(i)
		bits |= e.bit
	}
	if len(checks) == 0 {
		return nil, nil, 0, errEdgeSweepNoChecks
	}
	return checks, keys, bits, nil
}

// Matches the shared check_set_digest v1 grammar used by the plan compiler.
func sweepCheckSetDigest(checks []*edgev1.SweepTestV1) []byte {
	h := sha256.New()
	write := func(v uint64) { var b [8]byte; binary.BigEndian.PutUint64(b[:], v); _, _ = h.Write(b[:]) }
	const domain = "serviceradar.edge.check_set.v1"
	write(uint64(len(domain)))
	_, _ = h.Write([]byte(domain))
	write(1)
	write(uint64(len(checks)))
	for _, check := range checks {
		write(uint64(check.GetMode()))
		write(uint64(check.GetProtocol()))
		write(uint64(check.GetPort()))
	}
	return h.Sum(nil)
}

func (p *sweepEdgeProducer) observe(result *models.Result) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.err != nil {
		return p.err
	}
	p.err = p.addResult(result)
	return p.err
}

func (p *sweepEdgeProducer) addResult(result *models.Result) error {
	addr, err := netip.ParseAddr(result.Target.Host)
	if err != nil {
		return fmt.Errorf("edge sweep result address: %w", err)
	}
	addr = addr.Unmap()
	key := sweepCheck{result.Target.Mode, result.Target.Port}
	index, ok := p.checks[key]
	if !ok {
		return errEdgeSweepCheckOutsidePlan
	}
	window := p.pending[addr]
	if window == nil {
		if len(p.pending) >= maxPendingSweepHosts {
			return errEdgeSweepPendingHostLimit
		}
		rangeIndex := -1
		for i, r := range p.ranges {
			if r.prefix.Contains(addr) {
				rangeIndex = i
				break
			}
		}
		if rangeIndex < 0 {
			return errEdgeSweepAddressOutsidePlan
		}
		window = &sweepHostWindow{host: &edgev1.SweepHostObservationV1{Address: addr.AsSlice(), ModeRevision: 1, ResultModeBits: p.modeBits}, seen: make(map[sweepCheck]bool), rangeIndex: rangeIndex}
		p.pending[addr] = window
	}
	if window.seen[key] {
		return errEdgeSweepDuplicateResult
	}
	window.seen[key] = true
	h := window.host
	updateSweepHostTimes(h, result, p.observedAt)
	addSweepCheckResult(h, result, index)
	if len(window.seen) != len(p.checks) {
		return nil
	}
	sort.Slice(h.OpenPorts, func(i, j int) bool { return h.OpenPorts[i].TestedCheckIndex < h.OpenPorts[j].TestedCheckIndex })
	sort.Slice(h.PortErrors, func(i, j int) bool { return h.PortErrors[i].TestedCheckIndex < h.PortErrors[j].TestedCheckIndex })
	r := &p.ranges[window.rangeIndex]
	batches, err := r.builder.Add(h)
	if err != nil {
		return err
	}
	for _, batch := range batches {
		if err := p.emit(batch, r.authority); err != nil {
			return err
		}
	}
	delete(p.pending, addr)
	p.completed++
	return nil
}

func updateSweepHostTimes(h *edgev1.SweepHostObservationV1, result *models.Result, observedAt int64) {
	completed := result.LastSeen
	if completed.IsZero() {
		completed = time.Now()
	}
	delta := completed.UnixNano() - observedAt
	if h.LastSeenDeltaNano == nil || delta > *h.LastSeenDeltaNano {
		h.LastSeenDeltaNano = proto.Int64(delta)
		h.ObservedAtDeltaNano = delta
	}
	if !result.FirstSeen.IsZero() {
		first := result.FirstSeen.UnixNano() - observedAt
		if h.FirstSeenDeltaNano == nil || first < *h.FirstSeenDeltaNano {
			h.FirstSeenDeltaNano = proto.Int64(first)
		}
	}
	if hostname, ok := result.Target.Metadata["hostname"].(string); ok {
		h.Hostname = hostname
	}
}

func addSweepCheckResult(h *edgev1.SweepHostObservationV1, result *models.Result, index uint32) {
	if result.Target.Mode == models.ModeICMP {
		outcome := edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_FAILURE
		if result.Available {
			outcome = edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS
		}
		h.Icmp = &edgev1.SweepIcmpSummaryV1{Outcome: outcome, TargetReached: result.Available, Sent: result.PacketsSent, Received: result.PacketsReceived}
		if result.PacketsSent > 0 {
			h.Icmp.PacketLossPct = proto.Float64(result.PacketLoss)
		}
		if result.Available && result.RespTime >= 0 {
			h.Icmp.RoundTripMicro = proto.Uint64(uint64(result.RespTime / time.Microsecond))
		}
	} else {
		if h.Tcp == nil {
			h.Tcp = &edgev1.SweepTcpSummaryV1{Outcome: edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_FAILURE}
		}
		h.Tcp.TestedCount++
		if result.Available {
			h.Tcp.OpenCount++
			h.Tcp.Outcome = edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS
			port := &edgev1.SweepOpenPortV1{TestedCheckIndex: index}
			if result.RespTime >= 0 {
				port.ResponseTimeNano = proto.Uint64(uint64(result.RespTime))
			}
			h.OpenPorts = append(h.OpenPorts, port)
		} else if result.Error != nil {
			h.PortErrors = append(h.PortErrors, &edgev1.SweepPortErrorV1{TestedCheckIndex: index, ErrorCode: sweepErrorCode(result.Error)})
		}
	}
}

func sweepErrorCode(err error) string {
	if errors.Is(err, syscall.ECONNREFUSED) {
		return "connection_refused"
	}
	var netErr net.Error
	if errors.Is(err, context.DeadlineExceeded) || errors.As(err, &netErr) && netErr.Timeout() {
		return "timeout"
	}
	return "scan_error"
}

func (p *sweepEdgeProducer) finish() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.err != nil {
		return p.err
	}
	if len(p.pending) != 0 || p.completed != p.slot.GetPlanHeader().GetTotalTargetCount() {
		return fmt.Errorf("%w: completed %d of %d hosts, %d open windows", errEdgeSweepIncomplete, p.completed, p.slot.GetPlanHeader().GetTotalTargetCount(), len(p.pending))
	}
	for _, r := range p.ranges {
		if batch := r.builder.Flush(); batch != nil {
			if err := p.emit(batch, r.authority); err != nil {
				return err
			}
		}
	}
	return nil
}

func (p *sweepEdgeProducer) emit(batch *edgev1.SweepObservationBatchV1, source *edgev1.EdgeSourceAuthorizationV1) error {
	if time.Now().UnixNano() >= p.slot.GetCollectionExpiresUnixNano() {
		return errEdgeSweepWindowExpired
	}
	p.sequence++
	batch.BatchSequence = p.sequence
	if err := edgerecord.ValidateSweepObservationBatch(batch); err != nil {
		return fmt.Errorf("edge sweep batch: %w", err)
	}
	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		return err
	}
	eventID, err := edgerecord.NewUUIDv7()
	if err != nil {
		return err
	}
	c := p.lease.GetProductionCapability().GetProduction()
	sum := sha256.Sum256(payload)
	rows := uint32(projection.SweepRows(batch))
	record := &edgev1.EdgeRecordV1{
		EventId: eventID, PayloadFamily: edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
		Compression: edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE, EncodedSize: uint32(len(payload)), UncompressedSize: uint32(len(payload)), PayloadSha256: sum[:], Payload: payload,
		OutputContract:  &edgev1.EdgeOutputContractRef{ContractId: c.GetContractId(), ContractVersion: c.GetContractVersion(), ContractBundleSha256: c.GetContractBundleSha256(), RegistryEpoch: c.GetRegistryEpoch(), RegistrySnapshotSha256: c.GetRegistrySnapshotSha256(), EffectiveGrantSha256: c.GetEffectiveGrantSha256()},
		ProducerContext: &edgev1.EdgeProducerContext{OriginKind: c.GetOriginKind(), OriginPrincipalId: c.GetOriginPrincipalId(), ProducerInstanceId: c.GetProducerInstanceId(), ProducerAssignmentId: c.GetProducerAssignmentId(), RunId: c.GetRunId(), RunShard: c.GetRunShard(), AuthorityEpoch: proto.Uint64(c.GetAuthorityEpoch()), ScopeId: c.GetScopeId(), ScopeSha256: c.GetScopeSha256(), PackageId: c.GetPackageId(), PackageSha256: c.GetPackageSha256()},
		RouteProfile:    c.GetRouteProfile(), TrafficClass: c.GetTrafficClass(), NetworkScopeId: c.GetNetworkScopeId(), ProductionCapability: p.lease.GetProductionCapability(), SourceAuthorization: source,
		ProjectedRowCount: rows, ProjectedWriteBytes: uint64(rows) * sweepProjectedRowBytes, CostModelVersion: c.GetCostModelVersion(),
	}
	record.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(record)
	if err := edgerecord.ValidateRecord(record); err != nil {
		return fmt.Errorf("edge sweep record: %w", err)
	}
	body, err := edgerecord.CanonicalRecordBytes(record)
	if err != nil {
		return err
	}
	if p.claim != nil {
		if err := p.claim(); err != nil {
			return fmt.Errorf("persist sweep slot start: %w", err)
		}
		p.claim = nil
	}
	_, err = p.spool.Append(eventID, body)
	return err
}
