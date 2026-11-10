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
	"errors"
	"fmt"
	"net"
	"net/netip"
	"slices"
	"sort"
	"strings"
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
	errEdgeSweepCheckSetNotCarried = errors.New("edge sweep slot check set is not carried by its lease")
	errEdgeSweepProjectionBudget   = errors.New("edge sweep grant lacks supported projection budget")
	errEdgeSweepOverlappingRanges  = errors.New("edge sweep overlapping ranges are unsupported")
	errEdgeSweepRangeUnauthorized  = errors.New("edge sweep range lacks source authorization")
	errEdgeSweepNoRanges           = errors.New("edge sweep plan has no ranges")
	errEdgeSweepCheckOutsidePlan   = errors.New("edge sweep result check is outside signed plan")
	errEdgeSweepPendingHostLimit   = errors.New("edge sweep pending host window limit reached")
	errEdgeSweepAddressOutsidePlan = errors.New("edge sweep result address is outside signed plan")
	errEdgeSweepDuplicateResult    = errors.New("edge sweep duplicate terminal check result")
	errEdgeSweepWindowExpired      = errors.New("edge sweep collection window expired")
	errEdgeSweepIncomplete         = errors.New("edge sweep incomplete")
)

// Pending windows are bounded independently of the batch builder. The scanner
// can finish ICMP before TCP, so a pending host is not itself a completed host.
const maxPendingSweepHosts = 4096
const sweepProjectedRowBytes = 2048

// A full spool refuses an append until the sender drains and reclaims it. The
// producer waits for that, backing off between attempts, instead of failing the
// execution: the scanner calls emit synchronously, so a waiting emit pauses the
// scan. The wait ends when the collection window closes or the scan context ends.
const (
	sweepAdmissionInitialBackoff = 250 * time.Millisecond
	sweepAdmissionMaxBackoff     = 5 * time.Second
)

// SetEdgeSweepSpool connects leased sweep producers to the shared bounded lane
// owner. Call before Start; a nil spool keeps the legacy result path.
func (p *PushLoop) SetEdgeSweepSpool(sp *RecordSpool) {
	if sp != nil {
		sp.SetTrustProvider(p.EdgeRecordTrustSnapshot)
	}
	p.edgeSweepSpool = sp
}

// sweepSlotClaim consumes a leased slot durably before a record of its run can
// land in the spool, and release gives the slot back after that record was
// refused unwritten, so the executor may run the slot again. A nil func does
// nothing.
type sweepSlotClaim struct {
	claim   func() error
	release func() error
}

// RunSweepGroupLease claims the slot before each append until a record of the
// run is admitted. An interrupted run that already admitted a record stays
// incomplete, rather than repeating previously emitted host windows
// with different bytes under the same execution and batch sequence. A run that
// never gets a record admitted does not consume the slot. icmpUnavailable is
// the startup socket probe: a carried ICMP check is refused before claim.
func (s *MultiSweepService) RunSweepGroupLease(ctx context.Context, groupID string, lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1, sp *RecordSpool, icmpUnavailable bool, claim sweepSlotClaim) error {
	s.mu.RLock()
	svc := s.groups[groupID]
	s.mu.RUnlock()
	if svc == nil {
		return errSweepGroupNotFound
	}
	return svc.runLeaseToSpool(ctx, lease, slot, sp, icmpUnavailable, claim)
}

func (s *SweepService) runLeaseToSpool(ctx context.Context, lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1, sp *RecordSpool, icmpUnavailable bool, claim sweepSlotClaim) error {
	if !sp.Ready() {
		return edgerecord.ErrTrustMissing
	}
	runner, ok := s.sweeper.(interface {
		RunPlannedWithObserver(context.Context, string, sweeper.RunSpec, func(context.Context, *models.Result) error) error
		EffectivePlannedSweepModes(string, sweeper.RunSpec) ([]models.SweepMode, error)
	})
	if !ok {
		return errSweepRunnerUnavailable
	}
	s.runMu.Lock()
	defer s.runMu.Unlock()
	if err := sweeper.CheckExecution(ctx); err != nil {
		return err
	}

	producer, err := newSweepEdgeProducer(lease, slot, sp, time.Now())
	if errors.Is(err, edgerecord.ErrSweepCheckSetUnsupported) {
		return refuseUnsupportedPlan(err)
	}
	if err != nil {
		return err
	}
	// The scanner may run a signed mode as another one for some ranges (raw
	// SYN on IPv6 falls back to connect), and this agent may be unable to open
	// ICMP sockets. Either way the records would claim checks that never ran,
	// so the slot is refused once before it claims anything.
	signedModes := producer.spec.Modes
	var markers []string
	var details []string
	if icmpUnavailable && slices.Contains(signedModes, models.ModeICMP) {
		markers = append(markers, capabilityICMPUnavailable)
		details = append(details, "ICMP sweep sockets cannot be opened")
	}
	for _, r := range producer.ranges {
		effective, err := runner.EffectivePlannedSweepModes(r.prefix.String(), producer.spec)
		if err != nil {
			return err
		}
		if sameSweepModes(effective, signedModes) {
			continue
		}
		for _, marker := range unavailableSweepModeMarkers(signedModes, effective) {
			if !slices.Contains(markers, marker) {
				markers = append(markers, marker)
			}
		}
		details = append(details, fmt.Sprintf("%s runs %v, signed %v", r.prefix, effective, signedModes))
	}
	if len(markers) > 0 {
		return refuseUnavailableChecks(markers, strings.Join(details, "; "))
	}

	s.mu.Lock()
	executionID := uuid.UUID(slot.GetExecutionId()).String()
	previousEdgeExecutionID := s.lastEdgeExecutionID
	s.lastEdgeExecutionID = executionID
	s.sweepRunInProgress = true
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.sweepRunInProgress = false
		s.mu.Unlock()
	}()
	producer.claim = claim

	runCtx, cancel := context.WithDeadline(ctx, time.Unix(0, slot.GetCollectionExpiresUnixNano()))
	defer cancel()
	producer.ctx = runCtx
	err = runner.RunPlannedWithObserver(runCtx, executionID, producer.spec, func(scanCtx context.Context, result *models.Result) error {
		if err := producer.observe(scanCtx, result); err != nil {
			cancel()
			return err
		}
		return nil
	})
	if err != nil {
		s.mu.Lock()
		s.lastEdgeExecutionID = previousEdgeExecutionID
		s.mu.Unlock()
		producer.mu.Lock()
		if producer.err != nil {
			err = producer.err
		}
		producer.mu.Unlock()
		return err
	}
	return producer.finish()
}

func sameSweepModes(a, b []models.SweepMode) bool {
	set := func(modes []models.SweepMode) map[models.SweepMode]struct{} {
		out := make(map[models.SweepMode]struct{}, len(modes))
		for _, m := range modes {
			if m == models.ModeMTR {
				continue
			}
			out[m] = struct{}{}
		}
		return out
	}
	sa, sb := set(a), set(b)
	if len(sa) != len(sb) {
		return false
	}
	for m := range sa {
		if _, ok := sb[m]; !ok {
			return false
		}
	}
	return true
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
	spool      *RecordSpool
	checks     map[sweepCheck]uint32
	modeBits   uint32
	ranges     []sweepRangeBuilder
	pending    map[netip.Addr]*sweepHostWindow
	observedAt int64
	sequence   uint64
	completed  uint64
	err        error
	claim      sweepSlotClaim
	// admitted is set once a record of this run is in the spool. From then on
	// the slot stays consumed whatever happens to the run.
	admitted bool
	// spec is what the scanner runs for this slot, from its carried checks.
	spec sweeper.RunSpec
	// ctx bounds admission waits; its deadline is the slot's collection expiry.
	ctx context.Context
}

// sweepPlan is what one leased slot executes: the check set its push carried
// for the slot's signed plan header, indexed for result matching, and the
// scanner run spec it implies.
type sweepPlan struct {
	checks   []*edgev1.SweepTestV1
	index    map[sweepCheck]uint32
	modeBits uint32
	spec     sweeper.RunSpec
}

// sweepPlanChecks resolves slot's carried check set and verifies it digests to
// the plan header's check_set_sha256, the one comparison between a slot and its
// checks. The run spec's networks are the plan ranges' CIDRs in plan order. A
// set the scanner cannot express is edgerecord.ErrSweepCheckSetUnsupported.
func sweepPlanChecks(lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1) (*sweepPlan, error) {
	key := slot.GetPlanHeader().GetCheckSetSha256()

	var set *edgev1.SweepCheckSetV1
	for _, carried := range lease.GetCheckSets() {
		if bytes.Equal(carried.GetCheckSetSha256(), key) {
			set = carried
			break
		}
	}
	if set == nil || set.GetDigestVersion() != edgerecord.CheckSetDigestVersion ||
		!bytes.Equal(edgerecord.CheckSetDigest(set.GetChecks()), key) {
		return nil, errEdgeSweepCheckSetNotCarried
	}

	run, err := edgerecord.SweepCheckSetRun(set)
	if err != nil {
		return nil, err
	}

	plan := &sweepPlan{checks: set.GetChecks(), index: make(map[sweepCheck]uint32, len(set.GetChecks()))}
	for i, check := range set.GetChecks() {
		mode, bit := plannedSweepMode(check.GetMode())
		plan.index[sweepCheck{mode, int(check.GetPort())}] = uint32(i)
		plan.modeBits |= bit
	}
	for _, mode := range run.Modes {
		planned, _ := plannedSweepMode(mode)
		plan.spec.Modes = append(plan.spec.Modes, planned)
	}
	for _, port := range run.Ports {
		plan.spec.Ports = append(plan.spec.Ports, int(port))
	}
	for _, page := range slot.GetPlanPages() {
		for _, targetRange := range page.GetRanges() {
			plan.spec.Networks = append(plan.spec.Networks, targetRange.GetCidr())
		}
	}
	return plan, nil
}

// plannedSweepMode is the scanner mode and SweepModeBit of a carried check mode.
// edgerecord.SweepCheckSetRun admits only ICMP and the two TCP modes.
func plannedSweepMode(mode edgev1.SweepMode) (models.SweepMode, uint32) {
	switch mode {
	case edgev1.SweepMode_SWEEP_MODE_ICMP:
		return models.ModeICMP, uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP)
	case edgev1.SweepMode_SWEEP_MODE_TCP_SYN:
		return models.ModeTCP, uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_SYN)
	case edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT:
		return models.ModeTCPConnect, uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT)
	case edgev1.SweepMode_SWEEP_MODE_UNSPECIFIED, edgev1.SweepMode_SWEEP_MODE_MTR:
		return "", 0
	default:
		return "", 0
	}
}

func newSweepEdgeProducer(lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1, sp *RecordSpool, now time.Time) (*sweepEdgeProducer, error) {
	plan, err := sweepPlanChecks(lease, slot)
	if err != nil {
		return nil, err
	}
	claims := lease.GetProductionCapability().GetProduction()
	maxRows := min(uint64(claims.GetMaxProjectedRowCount()), claims.GetMaxProjectedWriteBytes()/sweepProjectedRowBytes)
	if maxRows == 0 || claims.GetCostModelVersion() != 1 {
		return nil, errEdgeSweepProjectionBudget
	}
	p := &sweepEdgeProducer{lease: lease, slot: slot, spool: sp, checks: plan.index, modeBits: plan.modeBits, spec: plan.spec, observedAt: now.UnixNano(), pending: make(map[netip.Addr]*sweepHostWindow)}
	for _, page := range slot.GetPlanPages() {
		for _, targetRange := range page.GetRanges() {
			prefix, err := netip.ParsePrefix(targetRange.GetCidr())
			if err != nil {
				return nil, fmt.Errorf("edge sweep plan range: %w", err)
			}
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
				TestedChecks: plan.checks, ConfiguredModeBits: plan.modeBits, AvailabilityPolicy: targetRange.GetAvailabilityPolicyId(),
				Source: edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
			}
			p.ranges = append(p.ranges, sweepRangeBuilder{prefix, obsbatch.NewBuilder(batchContext, obsbatch.Limits{MaxSweepRows: int(min(maxRows, obsbatch.DefaultMaxSweepRows))}), authority})
		}
	}
	if len(p.ranges) == 0 {
		return nil, errEdgeSweepNoRanges
	}
	return p, nil
}

func (p *sweepEdgeProducer) observe(ctx context.Context, result *models.Result) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.err != nil {
		return p.err
	}
	p.err = p.addResult(ctx, result)
	return p.err
}

func (p *sweepEdgeProducer) addResult(ctx context.Context, result *models.Result) error {
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
		if err := p.emit(ctx, batch, r.authority); err != nil {
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
			if err := p.emit(p.ctx, batch, r.authority); err != nil {
				return err
			}
		}
	}
	return nil
}

func (p *sweepEdgeProducer) emit(scanCtx context.Context, batch *edgev1.SweepObservationBatchV1, source *edgev1.EdgeSourceAuthorizationV1) error {
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
	rows := uint32(projection.SweepRows(batch))
	record, err := newEdgeRecord(p.lease.GetProductionCapability(), source, payload, rows, uint64(rows)*sweepProjectedRowBytes)
	if err != nil {
		return err
	}
	if err := edgerecord.ValidateRecord(record); err != nil {
		return fmt.Errorf("edge sweep record: %w", err)
	}
	body, err := edgerecord.CanonicalRecordBytes(record)
	if err != nil {
		return err
	}
	prepared, err := p.spool.PrepareRecord(body)
	if err != nil {
		return err
	}
	return p.appendWithBackpressure(scanCtx, edgeAdmissionFlow(record), prepared)
}

// appendClaimed appends body. Until a record of this run is in the spool, each
// attempt claims the slot first, so no record lands under an unconsumed slot,
// and an admission refusal, which writes nothing, releases that claim. A run
// whose records are all refused therefore leaves its slot runnable, including
// when the agent stops while the producer waits for admission.
func (p *sweepEdgeProducer) appendClaimed(flow string, prepared *spool.AttributedAppend) error {
	if p.admitted {
		_, err := p.spool.AppendPrepared(flow, prepared)
		return err
	}
	if p.claim.claim != nil {
		if err := p.claim.claim(); err != nil {
			return fmt.Errorf("persist sweep slot start: %w", err)
		}
	}
	_, err := p.spool.AppendPrepared(flow, prepared)
	switch {
	case err == nil:
		p.admitted = true
	case errors.Is(err, spool.ErrAdmissionRefused) && p.claim.release != nil:
		if releaseErr := p.claim.release(); releaseErr != nil {
			// The claim stands, so the slot is not run again under it.
			return fmt.Errorf("release sweep slot start after an admission refusal: %w", releaseErr)
		}
	}
	return err
}

// appendWithBackpressure appends body, waiting out admission refusals until the
// spool has room or either the run context or the scan context ends. Any other
// append error is returned at once.
func (p *sweepEdgeProducer) appendWithBackpressure(scanCtx context.Context, flow string, prepared *spool.AttributedAppend) error {
	backoff := sweepAdmissionInitialBackoff
	for {
		err := p.appendClaimed(flow, prepared)
		if !errors.Is(err, spool.ErrAdmissionRefused) {
			return err
		}
		var runDone, scanDone <-chan struct{}
		if p.ctx != nil {
			runDone = p.ctx.Done()
		}
		if scanCtx != nil {
			scanDone = scanCtx.Done()
		}
		timer := time.NewTimer(backoff)
		select {
		case <-runDone:
			timer.Stop()
			return fmt.Errorf("%w: %w", err, p.ctx.Err())
		case <-scanDone:
			timer.Stop()
			return fmt.Errorf("%w: %w", err, scanCtx.Err())
		case <-timer.C:
		}
		backoff = min(backoff*2, sweepAdmissionMaxBackoff)
	}
}
