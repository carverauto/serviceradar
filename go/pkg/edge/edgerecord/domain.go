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

package edgerecord

import (
	"bytes"
	"errors"
	"fmt"
	"math"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Domain validators for the sweep/MTR output contracts. The gateway stays
// domain-opaque, but the trusted agent sink and EventWriter dispatch by contract
// and run these fail-closed checks so a malformed real record is rejected, not
// merely a well-formed fixture accepted.

const (
	MaxSweepHostsPerBatch = 2000
	MaxTracesPerBatch     = 128
	MaxHopsPerTrace       = 256
	MaxEcmpPerHop         = 16
	MaxMplsPerHop         = 16
	MaxTraceStrBytes      = 256
	// MaxMtrBatchBytes bounds one decoded MTR batch so an explosively wide trace
	// (thousands of ECMP addresses) cannot slip under the record ceiling.
	MaxMtrBatchBytes = 256 * 1024
)

// knownTransportProtocol reports whether a transport protocol is a defined value.
func knownTransportProtocol(p edgev1.TransportProtocol) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch p {
	case edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP,
		edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP,
		edgev1.TransportProtocol_TRANSPORT_PROTOCOL_UDP:
		return true
	default:
		return false
	}
}

// mtrOutcomeAllocated reports whether an MTR outcome implies a trace was allocated
// (and therefore carries a UUIDv7 trace id). NOT_ADMITTED / QUARANTINED /
// SCHEDULER_LOST allocate no trace and carry none.
func mtrOutcomeAllocated(o edgev1.MtrOutcome) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch o {
	case edgev1.MtrOutcome_MTR_OUTCOME_REACHED,
		edgev1.MtrOutcome_MTR_OUTCOME_TARGET_UNREACHABLE,
		edgev1.MtrOutcome_MTR_OUTCOME_PROBE_FAILED,
		edgev1.MtrOutcome_MTR_OUTCOME_TIMED_OUT:
		return true
	default:
		return false
	}
}

var (
	ErrSweepSource = errors.New("edgerecord: sweep source unspecified/unknown")
	// ErrSweepSourceRunID reports a source_run_id present where its source
	// forbids it, absent where required, or non-canonical where required.
	ErrSweepSourceRunID = errors.New("edgerecord: sweep source_run_id disposition violated")
	ErrSweepChecks      = errors.New("edgerecord: sweep tested-check set invalid")
	ErrSweepModeBits    = errors.New("edgerecord: sweep configured/result mode bits inconsistent")
	ErrSweepModeSummary = errors.New("edgerecord: sweep named mode lacks its summary")
	ErrSweepCheckIndex  = errors.New("edgerecord: sweep open-port/error check index out of range")
	ErrSweepAddress     = errors.New("edgerecord: sweep host address is not 4 or 16 bytes")
	ErrSweepBounds      = errors.New("edgerecord: sweep batch exceeds host bound")
	ErrSweepIdentity    = errors.New("edgerecord: sweep batch identity/plan/range fields invalid")
	ErrSweepSummary     = errors.New("edgerecord: sweep mode summary is semantically invalid")
	ErrMtrSource        = errors.New("edgerecord: MTR source unspecified/unknown")
	ErrMtrCorrelation   = errors.New("edgerecord: MTR batch correlation missing or disagrees with source")
	ErrMtrTrace         = errors.New("edgerecord: MTR trace identity/hops invalid")
	ErrMtrHop           = errors.New("edgerecord: MTR hop is semantically invalid")
	ErrMtrBounds        = errors.New("edgerecord: MTR batch exceeds trace/hop bound")
	ErrMtrCompletion    = errors.New("edgerecord: MTR completion leaf/coverage invalid")
	ErrSweepJoin        = errors.New("edgerecord: sweep/MTR body not joined to signed source authority")
	ErrContractDispatch = errors.New("edgerecord: record output contract is not the registered contract")
	ErrLifecycle        = errors.New("edgerecord: sweep execution lifecycle event invalid")
)

// knownLifecycleKind reports whether a lifecycle event kind is a defined value.
func knownLifecycleKind(k edgev1.SweepExecutionEventKind) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch k {
	case edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_START,
		edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_PROGRESS,
		edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED,
		edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_ABORTED:
		return true
	default:
		return false
	}
}

// isSweepSourceKind reports whether a source-authorization kind is a
// sweep-execution kind that can authorize a lifecycle event.
func isSweepSourceKind(k edgev1.EdgeSourceAuthorizationKind) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch k {
	case edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
		edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE,
		edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
		edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_ON_DEMAND:
		return true
	default:
		return false
	}
}

// ValidateLifecycleRecord is the composed validator for a SweepExecutionEventV1
// RUN_EVENT_V1 record: signed whole-record validation, contract dispatch, bounded
// decode, kind-specific lifecycle invariants, and a join of the event's
// execution/shard/epoch/plan/range/time to the signed source authority.
func ValidateLifecycleRecord(r *edgev1.EdgeRecordV1, expected *edgev1.EdgeOutputContractRef, policy AuthorizationPolicy) error {
	if err := ValidateRecordSigned(r, policy); err != nil {
		return err
	}
	if err := dispatchContract(r, expected); err != nil {
		return err
	}
	if r.GetPayloadFamily() != edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RUN_EVENT_V1 {
		return fmt.Errorf("%w: not a run-event record", ErrLifecycle)
	}
	inner, err := innerPayload(r)
	if err != nil {
		return err
	}
	var ev edgev1.SweepExecutionEventV1
	if err := unmarshalPayload(inner, &ev); err != nil {
		return err
	}
	if err := ValidateSweepExecutionEvent(&ev); err != nil {
		return err
	}
	return joinLifecycleAuthority(r, &ev)
}

// ValidateSweepExecutionEvent fail-closes the structural lifecycle invariants:
// identity, a known kind, and kind-specific relationships (COMPLETED reconciles
// durable<=terminal, MTR counts, and the completion proof; a non-terminal event
// carries no completion proof; ABORTED carries a bounded reason).
func ValidateSweepExecutionEvent(ev *edgev1.SweepExecutionEventV1) error {
	if ev == nil {
		return ErrNilRecord
	}
	// Retained unknown fields are rejected HERE, not only on the outer unmarshal path.
	// This validator is PUBLIC and is what a consumer holding a decoded event calls, so
	// without this a stale sender's RETIRED tag 20 rides through: reserving a tag stops
	// source reuse, it does not stop bytes already on the wire.
	if hasUnknownFields(ev) {
		return ErrUnknownFields
	}
	if ValidateCanonicalUUID(ev.GetExecutionId()) != nil || ValidateCanonicalUUID(ev.GetExecutionPlanId()) != nil ||
		ValidateCanonicalUUID(ev.GetTargetRangeId()) != nil {
		return fmt.Errorf("%w: identity", ErrLifecycle)
	}
	if len(ev.GetExecutionPlanSha256()) != sha256Len {
		return fmt.Errorf("%w: plan digest", ErrLifecycle)
	}
	if ev.GetEmittedAtUnixNano() <= 0 || !knownLifecycleKind(ev.GetKind()) {
		return fmt.Errorf("%w: time/kind", ErrLifecycle)
	}
	completed := ev.GetKind() == edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED
	if completed {
		if ev.GetDurableThroughBatchSequence() > ev.GetTerminalBatchSequence() {
			return fmt.Errorf("%w: durable beyond terminal", ErrLifecycle)
		}
		if ev.GetEmittedMtrSummaries() > ev.GetExpectedMtrSummaries() ||
			ev.GetEmittedMtrTraces() > ev.GetExpectedMtrTraces() {
			return fmt.Errorf("%w: mtr counts", ErrLifecycle)
		}
		// range_root_sha256 (tag 20) is RETIRED: a range binding the producer asserts
		// about its own attempt proves nothing. The authoritative binding is the
		// assignment record's RESOLVABLE target_range_id + target_range_sha256 -- not a
		// range-set commitment, which was proposed and REJECTED for the same reason.
		if ev.GetMtrCompletionDigestVersion() != MtrCompletionDigestVersion ||
			len(ev.GetMtrCompletionDigest()) != sha256Len ||
			len(ev.GetPlanRootSha256()) != sha256Len {
			return fmt.Errorf("%w: completion proof", ErrLifecycle)
		}
	} else if len(ev.GetMtrCompletionDigest()) != 0 {
		return fmt.Errorf("%w: non-terminal event carries a completion proof", ErrLifecycle)
	}
	if ev.GetKind() == edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_ABORTED {
		if l := len(ev.GetAbortReason()); l == 0 || l > MaxTraceStrBytes {
			return fmt.Errorf("%w: abort reason", ErrLifecycle)
		}
	} else if ev.GetAbortReason() != "" {
		return fmt.Errorf("%w: abort reason on non-aborted event", ErrLifecycle)
	}
	return nil
}

// joinLifecycleAuthority binds a lifecycle event to the signed sweep-execution
// authority: execution id == context, range id == scope, plan digest == signed
// plan digest, shard/epoch == attested producer, and event time in the window.
func joinLifecycleAuthority(r *edgev1.EdgeRecordV1, ev *edgev1.SweepExecutionEventV1) error {
	sa := r.GetSourceAuthorization()
	if sa == nil || !isSweepSourceKind(sa.GetKind()) {
		return fmt.Errorf("%w: source kind", ErrLifecycle)
	}
	claims := sa.GetCapability().GetSource()
	p := r.GetProducerContext()
	if !bytes.Equal(claims.GetContextId(), ev.GetExecutionId()) ||
		!bytes.Equal(claims.GetScopeId(), ev.GetTargetRangeId()) ||
		!bytes.Equal(claims.GetExecutionPlanSha256(), ev.GetExecutionPlanSha256()) {
		return fmt.Errorf("%w: execution/range/plan binding", ErrLifecycle)
	}
	if ev.GetExecutionShard() != p.GetRunShard() || ev.GetAssignmentEpoch() != p.GetAuthorityEpoch() {
		return fmt.Errorf("%w: shard/epoch", ErrLifecycle)
	}
	if !withinCollection(ev.GetEmittedAtUnixNano(), claims) {
		return fmt.Errorf("%w: emitted time outside collection window", ErrLifecycle)
	}
	return nil
}

// mtrTerminalOutcome reports whether an MTR outcome is a terminal disposition (a
// non-terminal/unspecified outcome must never appear on a completed trace).
func mtrTerminalOutcome(o edgev1.MtrOutcome) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch o {
	case edgev1.MtrOutcome_MTR_OUTCOME_REACHED,
		edgev1.MtrOutcome_MTR_OUTCOME_TARGET_UNREACHABLE,
		edgev1.MtrOutcome_MTR_OUTCOME_PROBE_FAILED,
		edgev1.MtrOutcome_MTR_OUTCOME_TIMED_OUT,
		edgev1.MtrOutcome_MTR_OUTCOME_NOT_ADMITTED,
		edgev1.MtrOutcome_MTR_OUTCOME_QUARANTINED,
		edgev1.MtrOutcome_MTR_OUTCOME_SCHEDULER_LOST:
		return true
	default:
		return false
	}
}

// sweepModeOutcomeKnown reports whether a per-mode outcome is a defined value.
// The closed range rejects UNSPECIFIED(0), negatives, and any value above the
// last defined member.
func sweepModeOutcomeKnown(o edgev1.SweepModeOutcome) bool {
	return o >= edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS &&
		o <= edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_UNKNOWN
}

// knownSweepMode is the single authority for accepted sweep modes: exactly the modes
// modeProtocolConsistent can satisfy (its default arm rejects anything else). Shared with the
// enum-policy manifest.
func knownSweepMode(m edgev1.SweepMode) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch m {
	case edgev1.SweepMode_SWEEP_MODE_ICMP,
		edgev1.SweepMode_SWEEP_MODE_TCP_SYN,
		edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT,
		edgev1.SweepMode_SWEEP_MODE_MTR:
		return true
	default:
		return false
	}
}

// modeProtocolConsistent reports whether a tested check's transport protocol is
// consistent with its mode (ICMP/MTR ride ICMP; TCP modes ride TCP) and its port
// is legal for that mode (ICMP/MTR carry no port).
func modeProtocolConsistent(c *edgev1.SweepTestV1) bool {
	// GATE: knownSweepMode is the single authority for which modes exist at all; the switch below
	// only decides the protocol/port rule for an accepted mode. Shared with the enum-policy
	// manifest, so the accepted set cannot drift between runtime and the parity fixture.
	if !knownSweepMode(c.GetMode()) {
		return false
	}
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch c.GetMode() {
	case edgev1.SweepMode_SWEEP_MODE_ICMP, edgev1.SweepMode_SWEEP_MODE_MTR:
		return c.GetProtocol() == edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP && c.GetPort() == 0
	case edgev1.SweepMode_SWEEP_MODE_TCP_SYN, edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT:
		return c.GetProtocol() == edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP &&
			c.GetPort() >= 1 && c.GetPort() <= 65535
	default:
		return false
	}
}

func modeBit(m edgev1.SweepMode) uint32 {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch m {
	case edgev1.SweepMode_SWEEP_MODE_ICMP:
		return uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP)
	case edgev1.SweepMode_SWEEP_MODE_TCP_SYN:
		return uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_SYN)
	case edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT:
		return uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT)
	case edgev1.SweepMode_SWEEP_MODE_MTR:
		return uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR)
	default:
		return 0
	}
}

// ValidateSweepObservationBatch fail-closes a decoded sweep batch: known source,
// a non-empty non-duplicate check set whose derived bitmask equals
// configured_mode_bits, and per host: a result-mode bitmask that is a subset of
// configured, a summary present for each named mode, open-port/error indices in
// range, and a 4/16-byte address.
//
//nolint:gocyclo // flat fail-closed validator; each check is one branch
func ValidateSweepObservationBatch(b *edgev1.SweepObservationBatchV1) error {
	if b == nil {
		return ErrNilRecord
	}
	rule, ok := sweepRuleFor(b.GetSource())
	if !ok {
		return ErrSweepSource
	}
	// The source_run_id disposition is decided HERE, not in the correlation: it is
	// a function of two fields of THIS message (source and source_run_id) and
	// consults no signed authority. Deferring a body-decidable rule past the body
	// validator would carry a malformed batch into authority comparison, where
	// which mismatch is reported depends on which is noticed first.
	if err := validateSourceRunIDDisposition(rule, b.GetSourceRunId()); err != nil {
		return err
	}
	// Batch identity/plan/range/policy/timestamp must be present and well-formed so
	// a body cannot omit the fields that bind it to the authorized work.
	if ValidateCanonicalUUID(b.GetExecutionId()) != nil ||
		ValidateCanonicalUUID(b.GetExecutionPlanId()) != nil ||
		ValidateCanonicalUUID(b.GetTargetRangeId()) != nil {
		return fmt.Errorf("%w: ids", ErrSweepIdentity)
	}
	if len(b.GetExecutionPlanSha256()) != sha256Len || len(b.GetTargetRangeSha256()) != sha256Len {
		return fmt.Errorf("%w: plan/range digest", ErrSweepIdentity)
	}
	if len(b.GetAvailabilityPolicyId()) == 0 || b.GetBatchSequence() == 0 || b.GetObservedAtUnixNano() <= 0 {
		return fmt.Errorf("%w: policy/sequence/timestamp", ErrSweepIdentity)
	}
	if len(b.GetTestedChecks()) == 0 {
		return ErrSweepChecks
	}
	if len(b.GetHosts()) > MaxSweepHostsPerBatch {
		return ErrSweepBounds
	}
	var configured uint32
	seen := map[string]struct{}{}
	for _, c := range b.GetTestedChecks() {
		bit := modeBit(c.GetMode())
		if bit == 0 {
			return ErrSweepChecks
		}
		if !modeProtocolConsistent(c) {
			return fmt.Errorf("%w: mode/protocol/port", ErrSweepChecks)
		}
		key := fmt.Sprintf("%d:%d:%d", c.GetMode(), c.GetProtocol(), c.GetPort())
		if _, dup := seen[key]; dup {
			return fmt.Errorf("%w: duplicate check", ErrSweepChecks)
		}
		seen[key] = struct{}{}
		configured |= bit
	}
	if b.GetConfiguredModeBits() != configured {
		return ErrSweepModeBits
	}
	icmpBit := uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP)
	tcpBits := uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_SYN) | uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT)
	mtrBit := uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR)
	nChecks := len(b.GetTestedChecks())
	for _, h := range b.GetHosts() {
		if l := len(h.GetAddress()); l != 4 && l != 16 {
			return ErrSweepAddress
		}
		rmb := h.GetResultModeBits()
		if rmb == 0 || rmb&^configured != 0 {
			return ErrSweepModeBits
		}
		if rmb&icmpBit != 0 && h.GetIcmp() == nil {
			return ErrSweepModeSummary
		}
		if rmb&tcpBits != 0 && h.GetTcp() == nil {
			return ErrSweepModeSummary
		}
		if rmb&mtrBit != 0 && h.GetMtr() == nil {
			return ErrSweepModeSummary
		}
		// Reject a summary present for a mode NOT in the host's result bits.
		if (rmb&icmpBit == 0) && h.GetIcmp() != nil {
			return ErrSweepModeSummary
		}
		if (rmb&tcpBits == 0) && h.GetTcp() != nil {
			return ErrSweepModeSummary
		}
		if (rmb&mtrBit == 0) && h.GetMtr() != nil {
			return ErrSweepModeSummary // summary present for an unnamed mode
		}
		if err := validateSweepSummaries(h); err != nil {
			return err
		}
		checks := b.GetTestedChecks()
		// An open-port/error entry MUST reference a TCP check whose mode bit is
		// present in THIS fragment's result_mode_bits, and each check index may
		// appear at most once across open_ports and port_errors (no conflicting
		// open+error for the same mode).
		seenIdx := map[uint32]struct{}{}
		checkIdx := func(idx uint32) error {
			i := int(idx)
			if i >= nChecks || !isTCPMode(checks[i].GetMode()) || modeBit(checks[i].GetMode())&rmb == 0 {
				return ErrSweepCheckIndex
			}
			if _, dup := seenIdx[idx]; dup {
				return fmt.Errorf("%w: duplicate/conflicting check index", ErrSweepCheckIndex)
			}
			seenIdx[idx] = struct{}{}
			return nil
		}
		for _, op := range h.GetOpenPorts() {
			if err := checkIdx(op.GetTestedCheckIndex()); err != nil {
				return err
			}
		}
		for _, pe := range h.GetPortErrors() {
			if err := checkIdx(pe.GetTestedCheckIndex()); err != nil {
				return err
			}
		}
		// If a host reports open ports it MUST carry a TCP summary whose open_count
		// equals the listed open ports EXACTLY (tested >= open checked separately).
		if len(h.GetOpenPorts()) > 0 {
			if h.GetTcp() == nil || int(h.GetTcp().GetOpenCount()) != len(h.GetOpenPorts()) {
				return fmt.Errorf("%w: tcp open_count != listed open ports", ErrSweepSummary)
			}
		}
	}
	return nil
}

func isTCPMode(m edgev1.SweepMode) bool {
	return m == edgev1.SweepMode_SWEEP_MODE_TCP_SYN || m == edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT
}

// validateSweepSummaries fail-closes the per-mode summaries of one host: each
// present summary MUST carry a known outcome, and its counters must be physically
// consistent (received <= sent, loss a real percentage in [0,100], MTR hop count
// consistent with reachability).
func validateSweepSummaries(h *edgev1.SweepHostObservationV1) error {
	if icmp := h.GetIcmp(); icmp != nil {
		if !sweepModeOutcomeKnown(icmp.GetOutcome()) {
			return fmt.Errorf("%w: icmp outcome", ErrSweepSummary)
		}
		if icmp.GetReceived() > icmp.GetSent() {
			return fmt.Errorf("%w: icmp received > sent", ErrSweepSummary)
		}
		if !validLossPct(icmp.GetPacketLossPct(), icmp.PacketLossPct != nil) {
			return fmt.Errorf("%w: icmp loss", ErrSweepSummary)
		}
		if icmp.GetTargetReached() && icmp.GetReceived() == 0 {
			return fmt.Errorf("%w: icmp reached with zero received", ErrSweepSummary)
		}
	}
	if tcp := h.GetTcp(); tcp != nil {
		if !sweepModeOutcomeKnown(tcp.GetOutcome()) {
			return fmt.Errorf("%w: tcp outcome", ErrSweepSummary)
		}
		if tcp.GetOpenCount() > tcp.GetTestedCount() {
			return fmt.Errorf("%w: tcp open > tested", ErrSweepSummary)
		}
	}
	if mtr := h.GetMtr(); mtr != nil {
		if !mtrTerminalOutcome(mtr.GetOutcome()) {
			return fmt.Errorf("%w: mtr outcome", ErrSweepSummary)
		}
		// A trace id (UUIDv7) is present ONLY for allocated outcomes; NOT_ADMITTED /
		// QUARANTINED / SCHEDULER_LOST allocate no trace and carry none.
		if mtrOutcomeAllocated(mtr.GetOutcome()) {
			if validateUUIDv7Field(mtr.GetTraceId()) != nil {
				return fmt.Errorf("%w: mtr trace id", ErrSweepSummary)
			}
		} else if len(mtr.GetTraceId()) != 0 {
			return fmt.Errorf("%w: non-allocated mtr carries a trace id", ErrSweepSummary)
		}
		if !validLossPct(mtr.GetPacketLossPct(), mtr.PacketLossPct != nil) {
			return fmt.Errorf("%w: mtr loss", ErrSweepSummary)
		}
		if mtr.GetTargetReached() && mtr.GetTotalHops() == 0 {
			return fmt.Errorf("%w: mtr reached with zero hops", ErrSweepSummary)
		}
	}
	return nil
}

// validLossPct returns true when an optional loss percentage is either absent or
// a real number in [0,100] (rejecting NaN/Inf and out-of-range).
func validLossPct(v float64, present bool) bool {
	if !present {
		return true
	}
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return false
	}
	return v >= 0 && v <= 100
}

// ValidateMtrTraceBatch fail-closes a decoded MTR batch: known source, a
// correlation oneof that is set AND agrees with source (so a scheduled-check
// batch cannot carry a command context), and per-trace UUIDv7 identity + bounded
// 4/16-byte hops.
//
//nolint:gocyclo // flat fail-closed validator; each check is one branch
func ValidateMtrTraceBatch(b *edgev1.MtrTraceBatchV1) error {
	if b == nil {
		return ErrNilRecord
	}
	if !knownSweepSource(b.GetSource()) {
		return ErrMtrSource
	}
	// One decoded MTR batch is byte-bounded so an explosively wide trace cannot
	// slip under the record ceiling.
	if proto.Size(b) > MaxMtrBatchBytes {
		return ErrMtrBounds
	}
	// Batch scope/agent/sequence identity is mandatory; scope/agent are canonical
	// (non-nil) UUIDs, not merely 16 bytes.
	if ValidateCanonicalUUID(b.GetNetworkScopeId()) != nil || ValidateCanonicalUUID(b.GetAgentId()) != nil {
		return fmt.Errorf("%w: scope/agent", ErrMtrTrace)
	}
	if b.GetBatchSequence() == 0 {
		return fmt.Errorf("%w: batch sequence", ErrMtrTrace)
	}
	if len(b.GetTraces()) > MaxTracesPerBatch {
		return ErrMtrBounds
	}
	if err := mtrCorrelationMatchesSource(b); err != nil {
		return err
	}
	sweepCorrelated := isSweepExecutionSource(b.GetSource())
	for _, tr := range b.GetTraces() {
		if validateUUIDv7Field(tr.GetTraceId()) != nil || validateUUIDv7Field(tr.GetEventId()) != nil {
			return ErrMtrTrace
		}
		// sweep_host_address correlates a trace to a sweep host: required (4/16) for
		// sweep-correlated batches, optional (absent, 4 or 16) otherwise.
		switch l := len(tr.GetSweepHostAddress()); {
		case sweepCorrelated && l != 4 && l != 16:
			return fmt.Errorf("%w: sweep host address required", ErrMtrTrace)
		case !sweepCorrelated && l != 0 && l != 4 && l != 16:
			return fmt.Errorf("%w: sweep host address", ErrMtrTrace)
		}
		if !mtrTerminalOutcome(tr.GetOutcome()) {
			return fmt.Errorf("%w: non-terminal trace outcome", ErrMtrTrace)
		}
		// REACHED implies target_reached; target_reached implies attempted.
		if tr.GetOutcome() == edgev1.MtrOutcome_MTR_OUTCOME_REACHED && !tr.GetTargetReached() {
			return fmt.Errorf("%w: reached outcome without target_reached", ErrMtrTrace)
		}
		if tr.GetTargetReached() && !tr.GetAttempted() {
			return fmt.Errorf("%w: reached without attempt", ErrMtrTrace)
		}
		if !knownTransportProtocol(tr.GetProtocol()) {
			return fmt.Errorf("%w: protocol", ErrMtrTrace)
		}
		if v := tr.GetIpVersion(); v != 4 && v != 6 {
			return fmt.Errorf("%w: ip version", ErrMtrTrace)
		}
		if tr.GetTarget() == "" || len(tr.GetTarget()) > MaxTraceStrBytes || len(tr.GetErrorCode()) > MaxTraceStrBytes {
			return fmt.Errorf("%w: target/error strings", ErrMtrTrace)
		}
		if l := len(tr.GetResolvedAddress()); l != 0 && l != 4 && l != 16 {
			return fmt.Errorf("%w: resolved address", ErrMtrTrace)
		}
		if tr.GetTargetReached() && tr.GetTotalHops() == 0 {
			return fmt.Errorf("%w: reached with zero hops", ErrMtrTrace)
		}
		if len(tr.GetHops()) > MaxHopsPerTrace {
			return ErrMtrBounds
		}
		// Hops MUST be strictly increasing (ordered + unique); total_hops must be at
		// least the HIGHEST recorded hop number.
		var maxHop uint32
		for i, hop := range tr.GetHops() {
			if err := validateMtrHop(hop); err != nil {
				return err
			}
			if i > 0 && hop.GetHopNumber() <= maxHop {
				return fmt.Errorf("%w: hops not strictly increasing", ErrMtrHop)
			}
			maxHop = hop.GetHopNumber()
		}
		if maxHop > tr.GetTotalHops() {
			return fmt.Errorf("%w: total_hops below highest recorded hop", ErrMtrTrace)
		}
	}
	return nil
}

// isSweepExecutionSource reports whether a source is a scheduled/profile SWEEP
// (whose traces correlate to sweep hosts).
func isSweepExecutionSource(s edgev1.SweepExecutionSource) bool {
	return s == edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP ||
		s == edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE
}

// validateMtrHop fail-closes one hop: a nonzero hop number, an absent/4-byte/16-byte address
// and ECMP addresses, received <= sent, and a real loss percentage in [0,100].
func validateMtrHop(hop *edgev1.MtrTraceHopV1) error {
	if hop.GetHopNumber() == 0 {
		return fmt.Errorf("%w: hop number 0", ErrMtrHop)
	}
	if l := len(hop.GetAddress()); l != 0 && l != 4 && l != 16 {
		return fmt.Errorf("%w: address", ErrMtrHop)
	}
	if len(hop.GetEcmpAddresses()) > MaxEcmpPerHop || len(hop.GetMplsLabels()) > MaxMplsPerHop {
		return fmt.Errorf("%w: ecmp/mpls fan-out exceeds bound", ErrMtrHop)
	}
	for _, e := range hop.GetEcmpAddresses() {
		if l := len(e); l != 4 && l != 16 {
			return fmt.Errorf("%w: ecmp address", ErrMtrHop)
		}
	}
	if len(hop.GetHostname()) > MaxTraceStrBytes || len(hop.GetAsnOrg()) > MaxTraceStrBytes {
		return fmt.Errorf("%w: hop strings", ErrMtrHop)
	}
	if hop.GetReceived() > hop.GetSent() {
		return fmt.Errorf("%w: received > sent", ErrMtrHop)
	}
	if l := hop.GetLossPct(); math.IsNaN(l) || math.IsInf(l, 0) || l < 0 || l > 100 {
		return fmt.Errorf("%w: loss", ErrMtrHop)
	}
	return nil
}

func mtrCorrelationMatchesSource(b *edgev1.MtrTraceBatchV1) error {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch b.GetSource() {
	case edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
		edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE:
		if b.GetSweep() == nil {
			return ErrMtrCorrelation
		}
	case edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK:
		if b.GetScheduledCheck() == nil {
			return ErrMtrCorrelation
		}
	case edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC:
		if b.GetAdHoc() == nil {
			return ErrMtrCorrelation
		}
	case edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_ON_DEMAND:
		if b.GetCommand() == nil {
			return ErrMtrCorrelation
		}
	default:
		return ErrMtrSource
	}
	return nil
}

// knownSweepSource reports whether a source is admitted. It reads the frozen
// matrix rather than restating its membership: a second list would let the two
// disagree, admitting a source the correlation has no row for.
func knownSweepSource(v edgev1.SweepExecutionSource) bool {
	_, ok := sweepRuleFor(v)
	return ok
}

// ---------------------------------------------------------------------------
// MTR completion proof (canonical, plan-ordinal, order-independent) -- version 1
// ---------------------------------------------------------------------------

// MtrCompletionDigestVersion is the frozen version-2 leaf/root grammar. Version 2
// replaced the sort-based O(N log N) full-materialization proof with an O(N)-time,
// O(1)-active-memory additive multiset accumulator so the million-host execution
// need never buffer or sort every ordinal.
const MtrCompletionDigestVersion = 2

// MaxMtrCompletionOrdinals bounds the expected ordinal count so the canonical
// coverage recomputation stays bounded. 2^31 ordinals is far beyond a single
// execution's host count.
const MaxMtrCompletionOrdinals = 1 << 31

// MtrTerminalDisposition is the per-ordinal terminal state in the completion
// proof. It is an ALIAS of the generated enum, not a parallel declaration: the
// numbering lives ONCE in proto/edge/v1/sweep.proto and is hashed into the frozen
// leaf preimage below, so restating it here is exactly the hand-maintained
// numeric parity that lets two runtimes produce different roots for the same
// completion. Distinct from the per-hop MtrOutcome: the two NUMBER SPACES overlap
// (both allocate 1..5) but the MAPPINGS are independent, so neither enum's
// numbering constrains the other and the same number means different things in
// each. Do not read one through the other.
type MtrTerminalDisposition = edgev1.MtrCompletionDisposition

const (
	MtrDispositionUnspecified    = edgev1.MtrCompletionDisposition_MTR_COMPLETION_DISPOSITION_UNSPECIFIED
	MtrDispositionTraceAllocated = edgev1.MtrCompletionDisposition_MTR_COMPLETION_DISPOSITION_TRACE_ALLOCATED
	MtrDispositionNotAdmitted    = edgev1.MtrCompletionDisposition_MTR_COMPLETION_DISPOSITION_NOT_ADMITTED
	MtrDispositionProbeFailed    = edgev1.MtrCompletionDisposition_MTR_COMPLETION_DISPOSITION_PROBE_FAILED
	MtrDispositionQuarantined    = edgev1.MtrCompletionDisposition_MTR_COMPLETION_DISPOSITION_QUARANTINED
	MtrDispositionSchedulerLost  = edgev1.MtrCompletionDisposition_MTR_COMPLETION_DISPOSITION_SCHEDULER_LOST
)

// MtrCompletionLeaf is one plan ordinal's terminal disposition bound to the plan
// range it belongs to. trace_id is present ONLY for MtrDispositionTraceAllocated;
// range_sha256 binds the leaf into the plan/range composition.
type MtrCompletionLeaf struct {
	Ordinal     uint64
	Disposition MtrTerminalDisposition
	TraceID     []byte
	RangeSha256 []byte
}

// MtrCompletionAccumulator folds completion leaves into an order-independent proof
// in O(1) active memory. It maintains TWO additive 256-bit multiset hashes
// (MSet-Add-Hash): `acc` over the full per-leaf content (the emitted digest), and
// `ordinalAcc` over the leaf ORDINALS alone. Leaves may arrive in ANY order and
// across many batches; Root proves the ordinals form EXACTLY {1..expected} by
// requiring ordinalAcc to equal the canonical multiset hash of {1..expected} -- a
// set-collision-resistant check, unlike count+sum which a duplicate/missing pair
// such as {2,2,2} for {1,2,3} or {1,1,4,4} for {1,2,3,4} defeats.
type MtrCompletionAccumulator struct {
	acc        [32]byte
	ordinalAcc [32]byte
	memberAcc  [32]byte
	count      uint64
	expected   uint64
	// planOrdinalOffset shifts LOCAL leaf ordinals to the PLAN-GLOBAL ordinals the
	// assignment's commitment was built over. Leaf hashes and the coverage
	// accumulator stay LOCAL (the leaf grammar and the exact-set check are frozen);
	// only membership is global, because that is the only accumulator compared
	// against a plan-derived value.
	planOrdinalOffset uint64
	err               error
}

// NewMtrCompletionAccumulator starts an accumulator for a known expected ordinal
// count (the plan's admitted MTR target count).
//
// expected == 0 is LEGAL and is the plan that admits NO MTR targets. It yields the
// canonical zero-leaf proof: no leaves, all three accumulators the 32-byte zero
// value, and the ordinary root framing still bound to plan_root_sha256. A
// COMPLETED event therefore ALWAYS carries a proof, so missing evidence can never
// masquerade as empty work -- the alternative (waive the proof when a producer
// says it did no MTR) would admit both an absent and a present proof for one
// state and would trust a self-reported counter to decide which.
func NewMtrCompletionAccumulator(planOrdinalOffset, expected uint64) *MtrCompletionAccumulator {
	a := &MtrCompletionAccumulator{expected: expected, planOrdinalOffset: planOrdinalOffset}
	if expected > MaxMtrCompletionOrdinals || planOrdinalOffset > MaxMtrCompletionOrdinals-expected {
		a.err = fmt.Errorf("%w: expected/offset out of range", ErrMtrCompletion)
	}
	return a
}

func mtrLeafHash(l MtrCompletionLeaf) [32]byte {
	d := newDigest()
	d.u64(MtrCompletionDigestVersion)
	d.u64(l.Ordinal)
	d.u64(uint64(l.Disposition))
	d.bytes(l.TraceID)
	d.bytes(l.RangeSha256)
	var out [32]byte
	copy(out[:], d.finish())
	return out
}

// mtrOrdinalHash is the per-ordinal element hash of the coverage multiset; its
// domain tag keeps it disjoint from the leaf-content hash.
func mtrOrdinalHash(ordinal uint64) [32]byte {
	d := newDigest()
	d.u64(MtrCompletionDigestVersion)
	d.str("mtr-completion-ordinal")
	d.u64(ordinal)
	var out [32]byte
	copy(out[:], d.finish())
	return out
}

// mtrMemberHash is the per-leaf membership element hash over (ordinal,
// range_sha256). Comparing the fold of these against the plan's committed
// commitment proves each ordinal is bound to THE range the plan assigned it.
func mtrMemberHash(ordinal uint64, rangeSha256 []byte) [32]byte {
	d := newDigest()
	d.u64(MtrCompletionDigestVersion)
	d.str("mtr-completion-member")
	d.u64(ordinal)
	d.bytes(rangeSha256)
	var out [32]byte
	copy(out[:], d.finish())
	return out
}

// MtrOrdinalRangeCommitment folds an additive multiset commitment over the supplied
// (ordinal, range_sha256) pairs. The ordinals are PLAN-GLOBAL: callers building an
// assignment's window use MtrWindowCommitment, which applies the offset.
//
// MtrOrdinalRangeCommitment computes the plan's authenticated commitment over its
// (ordinal, range_sha256) assignments (an additive multiset hash). The scheduler
// stores it in ScheduledPlanHeaderV1.mtr_ordinal_range_commitment; completion is
// checked against it.
func MtrOrdinalRangeCommitment(assignments []MtrCompletionLeaf) []byte {
	var acc [32]byte
	for _, l := range assignments {
		add256(&acc, mtrMemberHash(l.Ordinal, l.RangeSha256))
	}
	return acc[:]
}

// add256 adds b into a in place as a big-endian 256-bit value mod 2^256.
func add256(a *[32]byte, b [32]byte) {
	var carry uint64
	for i := 31; i >= 0; i-- {
		s := uint64(a[i]) + uint64(b[i]) + carry
		a[i] = byte(s)
		carry = s >> 8
	}
}

func validateCompletionLeaf(l MtrCompletionLeaf, expected uint64) error {
	if l.Ordinal == 0 || l.Ordinal > expected {
		return fmt.Errorf("%w: ordinal", ErrMtrCompletion)
	}
	if len(l.RangeSha256) != sha256Len {
		return fmt.Errorf("%w: range digest", ErrMtrCompletion)
	}
	switch l.Disposition {
	case MtrDispositionTraceAllocated:
		if validateUUIDv7Field(l.TraceID) != nil {
			return fmt.Errorf("%w: allocated leaf needs a v7 trace id", ErrMtrCompletion)
		}
	case MtrDispositionNotAdmitted, MtrDispositionProbeFailed,
		MtrDispositionQuarantined, MtrDispositionSchedulerLost:
		if len(l.TraceID) != 0 {
			return fmt.Errorf("%w: non-allocated leaf carries a trace id", ErrMtrCompletion)
		}
	default:
		return fmt.Errorf("%w: unspecified/unknown disposition", ErrMtrCompletion)
	}
	return nil
}

// Add folds one validated leaf. It is O(1). Exact-set coverage is proven at Root
// via the ordinal multiset hash, not by buffering.
func (a *MtrCompletionAccumulator) Add(l MtrCompletionLeaf) error {
	if a.err != nil {
		return a.err
	}
	// A zero-MTR completion admits NO leaves. validateCompletionLeaf would reject
	// each one anyway (every ordinal is > expected), but saying so explicitly keeps
	// the failure legible: the plan admitted no MTR targets, so a leaf is evidence
	// of work the plan never authorized, not merely an out-of-range ordinal.
	if a.expected == 0 {
		a.err = fmt.Errorf("%w: a zero-MTR completion admits no leaves", ErrMtrCompletion)
		return a.err
	}
	if err := validateCompletionLeaf(l, a.expected); err != nil {
		a.err = err
		return err
	}
	if a.count == a.expected { // more leaves than expected
		a.err = fmt.Errorf("%w: too many leaves", ErrMtrCompletion)
		return a.err
	}
	lh := mtrLeafHash(l)
	add256(&a.acc, lh)
	add256(&a.ordinalAcc, mtrOrdinalHash(l.Ordinal))
	add256(&a.memberAcc, mtrMemberHash(a.planOrdinalOffset+l.Ordinal, l.RangeSha256))
	a.count++
	return nil
}

// Root finalizes the proof and binds it to the plan root. It fails unless the
// folded leaves form EXACTLY {1..expected}: count == expected AND the ordinal
// multiset hash equals the canonical multiset hash of {1..expected}, recomputed in
// O(expected) time / O(1) memory. This defeats a duplicate/missing pair such as
// {2,2,2} for expected 3 or {1,1,4,4} for expected 4 that count+sum could not.
func (a *MtrCompletionAccumulator) Root(planRootSha256, ordinalRangeCommitment []byte) ([]byte, error) {
	if a.err != nil {
		return nil, a.err
	}
	if len(planRootSha256) != sha256Len || len(ordinalRangeCommitment) != sha256Len {
		return nil, fmt.Errorf("%w: plan root/commitment", ErrMtrCompletion)
	}
	if a.count != a.expected {
		return nil, fmt.Errorf("%w: incomplete coverage", ErrMtrCompletion)
	}
	var canonical [32]byte
	for i := uint64(1); i <= a.expected; i++ {
		add256(&canonical, mtrOrdinalHash(i))
	}
	if canonical != a.ordinalAcc {
		return nil, fmt.Errorf("%w: ordinal set is not exactly 1..expected", ErrMtrCompletion)
	}
	// Membership: the folded (ordinal, range) multiset MUST equal the plan's
	// committed assignment, so a leaf cannot bind an ordinal to a range the plan
	// never assigned it.
	if !bytesEq32(a.memberAcc, ordinalRangeCommitment) {
		return nil, fmt.Errorf("%w: ordinal->range membership", ErrMtrCompletion)
	}
	d := newDigest()
	d.u64(MtrCompletionDigestVersion)
	d.u64(a.expected)
	d.bytes(planRootSha256)
	d.bytes(ordinalRangeCommitment)
	d.bytes(a.acc[:])
	return d.finish(), nil
}

func bytesEq32(a [32]byte, b []byte) bool { return len(b) == 32 && bytes.Equal(a[:], b) }

// MtrCompletionRoot is a convenience wrapper folding a slice of leaves for a known
// expected count, plan root, and plan ordinal->range commitment. Order-independent;
// O(N) time; O(1) extra memory.
func MtrCompletionRoot(leaves []MtrCompletionLeaf, planOrdinalOffset, expected uint64, planRootSha256, ordinalRangeCommitment []byte) ([]byte, error) {
	a := NewMtrCompletionAccumulator(planOrdinalOffset, expected)
	for _, l := range leaves {
		if err := a.Add(l); err != nil {
			return nil, err
		}
	}
	return a.Root(planRootSha256, ordinalRangeCommitment)
}

// ZeroMtrCompletionRoot is the canonical proof for a plan that admits NO MTR
// targets: expected = 0, no leaves, all three accumulators the 32-byte zero value,
// and the ordinary root framing still bound to planRootSha256. It exists as a
// NAMED constructor because "the completion proof for no MTR" is a specific
// frozen value, not an absence -- a producer that cannot name it will be tempted
// to omit the proof instead.
//
// ordinalRangeCommitment MUST be the ASSIGNMENT's expectation commitment -- NOT the
// plan header's plan-wide field, which is only equal when one assignment covers the
// whole plan. For a zero-MTR window it is 32 zero bytes (the empty-set multiset hash);
// passing empty bytes is rejected.
func ZeroMtrCompletionRoot(planOrdinalOffset uint64, planRootSha256, ordinalRangeCommitment []byte) ([]byte, error) {
	return MtrCompletionRoot(nil, planOrdinalOffset, 0, planRootSha256, ordinalRangeCommitment)
}

// VerifyCompletionAgainstPlanState compares a COMPLETED lifecycle event's proof
// against an expected count, plan root, commitment, and leaf set supplied BY THE
// CALLER. It is a GRAMMAR PRIMITIVE, not plan-aware verification.
//
// READ THIS BEFORE CALLING. Every authoritative input is an argument, so this
// function cannot tell where they came from. A caller that derives them from the
// event itself gets a VACUOUS check that always passes -- `(ev, 0, ev.PlanRootSha256,
// zero32, nil)` succeeds no matter what the real plan said. Nothing here establishes
// that the event's completion matches reality; that requires the caller to hold
// state it obtained from a validated, authenticated plan/assignment carrier.
//
// The carrier now EXISTS -- `SweepAssignmentRecordV1` -- and
// `ValidateAssignmentAgainstPlan` is what derives trustworthy values from it by
// recomputing the expectation from committed plan data. Callers should obtain the
// count and commitment THAT way and pass them here. There is still deliberately no
// production caller in this repository: wiring one is downstream runtime work. Do not
// read the existence of this function as consumer verification being implemented.
//
// planExpectedMtr == 0 is the zero-MTR case and requires the canonical zero-leaf
// proof; it is NOT a licence to omit one.
func VerifyCompletionAgainstPlanState(
	ev *edgev1.SweepExecutionEventV1,
	planOrdinalOffset, planExpectedMtr uint64,
	planRootSha256, planOrdinalRangeCommitment []byte,
	leaves []MtrCompletionLeaf,
) error {
	if ev == nil {
		return ErrNilRecord
	}
	if ev.GetKind() != edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED {
		return fmt.Errorf("%w: not a completed event", ErrLifecycle)
	}
	// Shape first, so a malformed event fails as a lifecycle error rather than as a
	// confusing proof mismatch.
	if err := ValidateSweepExecutionEvent(ev); err != nil {
		return err
	}
	// The event's roots must be the PLAN's roots. Without this the proof could be a
	// perfectly valid completion of some other plan.
	if !bytes.Equal(ev.GetPlanRootSha256(), planRootSha256) {
		return fmt.Errorf("%w: event plan root is not the plan's", ErrMtrCompletion)
	}
	want, err := MtrCompletionRoot(leaves, planOrdinalOffset, planExpectedMtr, planRootSha256, planOrdinalRangeCommitment)
	if err != nil {
		return err
	}
	if !bytes.Equal(ev.GetMtrCompletionDigest(), want) {
		return fmt.Errorf("%w: completion digest does not match the plan-derived proof", ErrMtrCompletion)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Composed envelope <-> body validation (contract-dispatched)
// ---------------------------------------------------------------------------

// sweepContextOperand names WHICH body field a source's signed context_id is
// compared against. There is exactly ONE selected operand per source and never
// two: the non-selected field is not a second thing the context may agree with.
type sweepContextOperand uint8

const (
	operandExecutionID sweepContextOperand = iota
	operandSourceRunID
)

// sourceRunIDDisposition names whether a source may carry source_run_id.
// Permitting it where the signed context names the execution would leave a
// SECOND, unchecked correlation candidate on the wire: a consumer could bind on
// it while the validator bound on execution_id, with nothing saying which is
// authoritative. So it is REQUIRED or FORBIDDEN, never optional.
type sourceRunIDDisposition uint8

const (
	sourceRunIDForbidden sourceRunIDDisposition = iota
	sourceRunIDRequired
)

// sweepSourceRule is one row of the FROZEN sweep correlation matrix.
type sweepSourceRule struct {
	kind        edgev1.EdgeSourceAuthorizationKind
	operand     sweepContextOperand
	sourceRunID sourceRunIDDisposition
}

// sweepSourceMatrix IS the frozen mapping, and it is the SOLE kind lookup in the
// correlation. Nothing else may derive a source's authorization kind, operand or
// disposition.
//
// Why one table rather than three switches: five sources against seven declared
// kinds is a 5x7 accept/reject matrix with five accepting cells, so a per-source
// sample of wrong kinds exercises five of thirty rejecting cells and leaves an
// implementation free to accept an untested pair. With a single lookup the
// exhaustive inventory test IS the behavioural coverage.
//
// The kind ordinals deliberately do NOT line up with the source ordinals -- only
// SCHEDULED_SWEEP and SWEEP_PROFILE coincide. Correlating by NUMBER instead of by
// this table accepts an ad-hoc body under scheduled-check authority.
//
//nolint:gochecknoglobals // immutable authority table; see the note above
var sweepSourceMatrix = map[edgev1.SweepExecutionSource]sweepSourceRule{
	edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP: {
		kind:        edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
		operand:     operandExecutionID,
		sourceRunID: sourceRunIDForbidden,
	},
	edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE: {
		kind:        edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE,
		operand:     operandExecutionID,
		sourceRunID: sourceRunIDForbidden,
	},
	edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC: {
		kind:        edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
		operand:     operandSourceRunID,
		sourceRunID: sourceRunIDRequired,
	},
	edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_ON_DEMAND: {
		kind:        edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_ON_DEMAND,
		operand:     operandSourceRunID,
		sourceRunID: sourceRunIDRequired,
	},
	edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK: {
		kind:        edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		operand:     operandSourceRunID,
		sourceRunID: sourceRunIDRequired,
	},
}

// sweepRuleFor returns the frozen row for a source. UNSPECIFIED (the proto
// default) is absent from the table, so an unset field cannot select a mapping.
func sweepRuleFor(s edgev1.SweepExecutionSource) (sweepSourceRule, bool) {
	r, ok := sweepSourceMatrix[s]
	return r, ok
}

// sourceKindForExecution maps a sweep/MTR execution source to the source
// authorization kind a record MUST carry to authorize that collection. It reads
// the frozen matrix; it does not restate it.
func sourceKindForExecution(s edgev1.SweepExecutionSource) (edgev1.EdgeSourceAuthorizationKind, bool) {
	r, ok := sweepRuleFor(s)
	if !ok {
		return edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_UNSPECIFIED, false
	}
	return r.kind, true
}

// validateSourceRunIDDisposition enforces the frozen per-row disposition. Where
// required, source_run_id MUST be a canonical UUID -- ONE source-independent
// predicate, the same check on every required row.
func validateSourceRunIDDisposition(rule sweepSourceRule, id []byte) error {
	if rule.sourceRunID == sourceRunIDForbidden {
		if len(id) != 0 {
			return sweepBodyErr(SweepLabelSourceRunIDDisposition, ErrSweepSourceRunID)
		}
		return nil
	}
	if ValidateCanonicalUUID(id) != nil {
		return sweepBodyErr(SweepLabelSourceRunIDDisposition, ErrSweepSourceRunID)
	}
	return nil
}

// sweepContextOperandValue returns the ONE body field this source's signed
// context_id is compared against.
func sweepContextOperandValue(rule sweepSourceRule, b *edgev1.SweepObservationBatchV1) []byte {
	if rule.operand == operandSourceRunID {
		return b.GetSourceRunId()
	}
	return b.GetExecutionId()
}

// requireFramingFamily enforces the FAMILY <-> TYPED ENTRY POINT invariant.
//
// `payload_family` is an immutable FRAMING and LIFECYCLE discriminator. It is not a
// contract-selection key -- the exact output contract selects the semantic validator and the
// projector, and there is deliberately NO registry-wide contract-to-family table -- and it is
// not authorization. What it fixes is which typed ingress a record may enter.
//
// The check has to exist HERE, at each typed boundary, because protobuf bytes are not
// intrinsically type-tagged: a sweep body decodes under an unintended schema without complaint,
// so a record declaring SNAPSHOT_PAGE_V1 while entering sweep admission would be AUTHENTICATED
// carrying contradictory metadata. Every later reader that selects a decoder from the family
// would then be choosing from a value nothing validated.
//
// The GENERIC validator stays permissive across the known non-recovery families on purpose: it
// has no entry-point context and cannot choose one of them.
func requireFramingFamily(
	r *edgev1.EdgeRecordV1, want edgev1.EdgeRecordPayloadFamily, sentinel error,
) error {
	if r.GetPayloadFamily() != want {
		return fmt.Errorf("%w: payload family %v may not enter this ingress, want %v",
			sentinel, r.GetPayloadFamily(), want)
	}

	return nil
}

// ValidateSweepRecord is the composed sweep validator the trusted sink/EventWriter
// use: it validates the whole EdgeRecordV1, decodes and deep-validates the sweep
// body, then JOINS body to signed authority -- the body's source MUST map to the
// record's source-authorization kind, and the body's plan/range digests MUST equal
// the signed source claims. This stops output permission from substituting for
// scan authority.
func ValidateSweepRecord(r *edgev1.EdgeRecordV1, expected *edgev1.EdgeOutputContractRef, policy AuthorizationPolicy) error {
	if err := ValidateRecordSigned(r, policy); err != nil {
		return err
	}
	if err := dispatchContract(r, expected); err != nil {
		return err
	}
	if err := requireFramingFamily(r,
		edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
		ErrPayloadFraming); err != nil {
		return err
	}
	inner, err := innerPayload(r)
	if err != nil {
		return err
	}
	var batch edgev1.SweepObservationBatchV1
	if err := unmarshalPayload(inner, &batch); err != nil {
		return err
	}
	if err := ValidateSweepObservationBatch(&batch); err != nil {
		return err
	}
	return joinSweepAuthority(r, &batch)
}

// ValidateMtrRecord is the composed MTR validator: signed whole-record validation,
// contract dispatch, bounded decompression, canonical decode, deep MTR body
// validation, then a full join of body identity/time to signed authority.
func ValidateMtrRecord(r *edgev1.EdgeRecordV1, expected *edgev1.EdgeOutputContractRef, policy AuthorizationPolicy) error {
	if err := ValidateRecordSigned(r, policy); err != nil {
		return err
	}
	if err := dispatchContract(r, expected); err != nil {
		return err
	}
	if err := requireFramingFamily(r,
		edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
		ErrPayloadFraming); err != nil {
		return err
	}
	inner, err := innerPayload(r)
	if err != nil {
		return err
	}
	var batch edgev1.MtrTraceBatchV1
	if err := unmarshalPayload(inner, &batch); err != nil {
		return err
	}
	if err := ValidateMtrTraceBatch(&batch); err != nil {
		return err
	}
	return joinMtrAuthority(r, &batch)
}

// dispatchContract fail-closes contract dispatch: the record's output contract
// MUST be exactly the registered contract (id, version, bundle, epoch) the
// EventWriter invoked this validator for, so a body cannot be validated under the
// wrong projection contract.
func dispatchContract(r *edgev1.EdgeRecordV1, expected *edgev1.EdgeOutputContractRef) error {
	if expected == nil {
		return fmt.Errorf("%w: no registered contract", ErrContractDispatch)
	}
	c := r.GetOutputContract()
	if c.GetContractId() != expected.GetContractId() ||
		c.GetContractVersion() != expected.GetContractVersion() ||
		!bytes.Equal(c.GetContractBundleSha256(), expected.GetContractBundleSha256()) ||
		c.GetRegistryEpoch() != expected.GetRegistryEpoch() {
		return ErrContractDispatch
	}
	return nil
}

// joinSweepAuthority binds a decoded sweep body to the record's signed source
// authority AND attested producer: source kind; the SELECTED CONTEXT identity
// (context_id == the ONE operand this source's row names -- execution_id on the
// scheduled-sweep and sweep-profile rows, source_run_id on the other three); the
// range identity (scope_id == target_range_id); plan/range digests; the
// fence/assignment epoch; and the observed collection time -- so a valid signature
// cannot be paired with a body naming a different run, range, epoch, or time
// window. Not every row binds the EXECUTION: three bind a source-side run.
func joinSweepAuthority(r *edgev1.EdgeRecordV1, batch *edgev1.SweepObservationBatchV1) error {
	rule, ok := sweepRuleFor(batch.GetSource())
	if !ok {
		return ErrSweepSource
	}
	sa := r.GetSourceAuthorization()
	// ABSENT authority and WRONG-KIND authority are separate labels, so they are
	// separate checks: a combined branch could not say which one refused.
	if sa == nil {
		return sweepJoinErr(SweepLabelSourceAuthorityAbsent)
	}
	if sa.GetKind() != rule.kind {
		return sweepJoinErr(SweepLabelSourceKind)
	}
	claims := sa.GetCapability().GetSource()
	p := r.GetProducerContext()
	// The signed context is compared against the ONE operand this source selects
	// -- execution_id for the scheduled/profile rows, source_run_id for the
	// ad-hoc/on-demand/scheduled-check rows. Comparing the non-selected field
	// would accept a body whose signed authority names a different run.
	if !bytes.Equal(claims.GetContextId(), sweepContextOperandValue(rule, batch)) {
		return sweepJoinErr(SweepLabelContextID)
	}
	// The generic signed scope identity MUST be the range identity, in BOTH id and
	// digest. These are two labels and therefore two checks: the signed claim
	// carries scope_sha256 AND target_range_sha256, so a single combined branch
	// would let either predicate be deleted while the manifest still matched.
	if !bytes.Equal(claims.GetScopeId(), batch.GetTargetRangeId()) {
		return sweepJoinErr(SweepLabelRangeID)
	}
	if !bytes.Equal(claims.GetScopeSha256(), batch.GetTargetRangeSha256()) {
		return sweepJoinErr(SweepLabelScopeDigest)
	}
	if !bytes.Equal(claims.GetTargetRangeSha256(), batch.GetTargetRangeSha256()) {
		return sweepJoinErr(SweepLabelTargetRangeDigest)
	}
	if !bytes.Equal(claims.GetExecutionPlanSha256(), batch.GetExecutionPlanSha256()) {
		return sweepJoinErr(SweepLabelPlanDigest)
	}
	// The attested producer shard AND fence epoch MUST match the body.
	if batch.GetExecutionShard() != p.GetRunShard() {
		return sweepJoinErr(SweepLabelExecutionShard)
	}
	if batch.GetAssignmentEpoch() != p.GetAuthorityEpoch() {
		return sweepJoinErr(SweepLabelAssignmentEpoch)
	}
	// The observed batch time must fall inside the signed collection window.
	if !withinCollection(batch.GetObservedAtUnixNano(), claims) {
		return sweepJoinErr(SweepLabelBatchTimeWindow)
	}
	// Every per-host absolute time (batch time + signed sint64 delta, OVERFLOW-SAFE)
	// and every per-host MTR trace identity time must also fall inside the window.
	for _, h := range batch.GetHosts() {
		// OVERFLOW and OUT-OF-WINDOW are separate labels, so they are separate
		// checks. A wrapped sum can land INSIDE the window, so folding them
		// together would report the wrong reason for the case that matters most.
		abs, ok := addInt64(batch.GetObservedAtUnixNano(), h.GetObservedAtDeltaNano())
		if !ok {
			return sweepJoinErr(SweepLabelHostTimeOverflow)
		}
		if !withinCollection(abs, claims) {
			return sweepJoinErr(SweepLabelHostTimeWindow)
		}
		if mtr := h.GetMtr(); mtr != nil && mtrOutcomeAllocated(mtr.GetOutcome()) {
			ns, err := UUIDv7Nanos(mtr.GetTraceId())
			if err != nil {
				return sweepJoinErr(SweepLabelTraceTimeOverflow)
			}
			if !withinCollection(ns, claims) {
				return sweepJoinErr(SweepLabelTraceTimeWindow)
			}
		}
	}
	return nil
}

// addInt64 adds two int64 values and reports whether the result overflowed.
func addInt64(a, b int64) (int64, bool) {
	s := a + b
	if (b > 0 && s < a) || (b < 0 && s > a) {
		return 0, false
	}
	return s, true
}

// joinMtrAuthority binds a decoded MTR batch to signed authority + attested
// producer: source kind, network scope == record scope, agent == attested
// producer instance, the correlation context id == signed context_id, and every
// trace observation/identity time inside the collection window.
func joinMtrAuthority(r *edgev1.EdgeRecordV1, batch *edgev1.MtrTraceBatchV1) error {
	wantKind, ok := sourceKindForExecution(batch.GetSource())
	if !ok {
		return ErrMtrSource
	}
	sa := r.GetSourceAuthorization()
	if sa == nil || sa.GetKind() != wantKind {
		return fmt.Errorf("%w: source kind", ErrSweepJoin)
	}
	if !bytes.Equal(batch.GetNetworkScopeId(), r.GetNetworkScopeId()) {
		return fmt.Errorf("%w: network scope", ErrSweepJoin)
	}
	if !bytes.Equal(batch.GetAgentId(), r.GetProducerContext().GetProducerInstanceId()) {
		return fmt.Errorf("%w: agent", ErrSweepJoin)
	}
	claims := sa.GetCapability().GetSource()
	p := r.GetProducerContext()
	if !bytes.Equal(mtrCorrelationContextID(batch), claims.GetContextId()) {
		return fmt.Errorf("%w: correlation context", ErrSweepJoin)
	}
	// For a SWEEP correlation every trace shares the sweep execution authority: the
	// sweep context's shard/epoch MUST match the attested producer, its range id
	// MUST equal the signed scope, and the signed plan digest binds the plan.
	if sc := batch.GetSweep(); sc != nil {
		if sc.GetExecutionShard() != p.GetRunShard() || sc.GetAssignmentEpoch() != p.GetAuthorityEpoch() {
			return fmt.Errorf("%w: sweep shard/epoch", ErrSweepJoin)
		}
		if !bytes.Equal(sc.GetTargetRangeId(), claims.GetScopeId()) {
			return fmt.Errorf("%w: sweep range id", ErrSweepJoin)
		}
	}
	for _, tr := range batch.GetTraces() {
		if !withinCollection(tr.GetObservedAtUnixNano(), claims) {
			return fmt.Errorf("%w: trace time outside collection window", ErrSweepJoin)
		}
		// Bind BOTH the trace id and inner event id identity times to the window.
		if !uuidTimeWithin(tr.GetTraceId(), claims) || !uuidTimeWithin(tr.GetEventId(), claims) {
			return fmt.Errorf("%w: trace/event identity time outside collection window", ErrSweepJoin)
		}
	}
	return nil
}

// uuidTimeWithin reports whether a UUIDv7's embedded millisecond time (as nanos)
// falls inside the collection window.
func uuidTimeWithin(id []byte, c *edgev1.EdgeSourceClaimsV1) bool {
	ns, err := UUIDv7Nanos(id)
	return err == nil && withinCollection(ns, c)
}

func withinCollection(ns int64, c *edgev1.EdgeSourceClaimsV1) bool {
	return ns >= c.GetCollectionNotBeforeUnixNano() && ns <= c.GetCollectionExpiresUnixNano()
}

// mtrCorrelationContextID returns the correlation id of whichever context variant
// is set (used to bind the batch to the signed source context_id).
func mtrCorrelationContextID(b *edgev1.MtrTraceBatchV1) []byte {
	switch {
	case b.GetSweep() != nil:
		return b.GetSweep().GetSweepExecutionId()
	case b.GetScheduledCheck() != nil:
		return b.GetScheduledCheck().GetCheckId()
	case b.GetAdHoc() != nil:
		return b.GetAdHoc().GetScanRunId()
	case b.GetCommand() != nil:
		return b.GetCommand().GetCommandId()
	default:
		return nil
	}
}

// innerPayload returns the DECODED inner contract bytes: the raw payload for NONE,
// or the bounded Zstd decompression for ZSTD. The composed domain validators must
// decode the body the wire feature actually carries, not the compressed frame.
func innerPayload(r *edgev1.EdgeRecordV1) ([]byte, error) {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch r.GetCompression() {
	case edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE:
		return r.GetPayload(), nil
	case edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD:
		// The frame was already structurally validated by ValidateRecord; decode the
		// body ONCE here rather than re-validating and decoding a third time.
		return decompressZstdValidated(r.GetPayload(), r.GetUncompressedSize())
	default:
		return nil, ErrCompression
	}
}

// unmarshalPayload decodes an inner contract payload for field-level validation.
// It rejects retained unknown fields (recursively) but does NOT impose byte-
// canonicity via a decode->re-encode->bytes.Equal admission, which is prohibited:
// the payload's identity is payload_sha256 over the EXACT received bytes, so a
// re-encode-equality check is both unnecessary and would reject a conforming
// encoder that emits equivalent but non-identical bytes.
func unmarshalPayload(b []byte, m interface {
	Reset()
	proto.Message
}) error {
	if err := proto.Unmarshal(b, m); err != nil {
		return ErrRecordDecode
	}
	if hasUnknownFields(m) {
		return ErrUnknownFields
	}
	return nil
}
