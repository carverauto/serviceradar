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

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

var (
	ErrAssignmentIdentity = errors.New("edgerecord: assignment record identity invalid")
	ErrAssignmentState    = errors.New("edgerecord: assignment record state invalid")
	ErrAssignmentLease    = errors.New("edgerecord: assignment record lease/fence invalid")
	// ErrAssignmentExpectation fires when the authoritative MTR expectation is absent,
	// malformed, or internally inconsistent. Absent is NOT the same as zero: zero is an
	// assignment that admits no MTR and still owes the canonical zero-leaf proof.
	ErrAssignmentExpectation = errors.New("edgerecord: assignment record mtr expectation invalid")
	ErrAssignmentScope       = errors.New("edgerecord: assignment record scope/config invalid")
	// ErrAssignmentPlanRelation fires when a record and a plan are each internally
	// valid but do not describe the same plan, or the covered range is not a member
	// of it.
	ErrAssignmentPlanRelation = errors.New("edgerecord: assignment record does not match the plan")
)

// zero32 is the empty-set additive multiset hash: the commitment a set with no
// members folds to. It is a VALUE, not an absence, which is the whole reason the
// commitment fields are fixed-width.
//
//nolint:gochecknoglobals // immutable identity value for the empty set
var zero32 = make([]byte, sha256Len)

func knownAssignmentState(s edgev1.SweepAssignmentState) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted/unsupported value
	switch s {
	case edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_OPEN,
		edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_COMPLETED,
		edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_ABORTED,
		edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_LOST,
		edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_EXPIRED,
		edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_SUPERSEDED:
		return true
	default:
		return false
	}
}

// ValidateMtrExpectation fail-closes the authoritative MTR expectation.
//
// The expectation is REQUIRED wherever it appears: a nil expectation is not "zero
// MTR", it is a record that never stated what it expected, and treating the two
// alike is exactly how a missing authority becomes an implicit waiver.
//
// `ordinal_count == 0` and a 32-zero commitment are the SAME fact stated twice, so
// they are required to agree in BOTH directions. That biconditional is what finally
// makes the zero-MTR rule checkable: the commitment alone cannot be inverted to a
// count, so without a carried count "32 zero bytes" was unfalsifiable.
func ValidateMtrExpectation(e *edgev1.SweepMtrExpectationV1) error {
	if e == nil {
		return ErrAssignmentExpectation
	}
	if hasUnknownFields(e) {
		return ErrUnknownFields
	}
	if len(e.GetOrdinalRangeCommitment()) != sha256Len {
		return ErrAssignmentExpectation
	}
	// REQUIRED PRESENCE, enforced by the OWNING validator rather than only by the
	// plan relation: offset 0 is the first range's legal window, so an absent field
	// that defaults to 0 would silently pass as it wherever the relation is not run.
	if e.PlanOrdinalOffset == nil {
		return ErrAssignmentExpectation
	}
	if e.GetOrdinalCount() > MaxMtrCompletionOrdinals {
		return ErrAssignmentExpectation
	}
	empty := bytes.Equal(e.GetOrdinalRangeCommitment(), zero32)
	if (e.GetOrdinalCount() == 0) != empty {
		return ErrAssignmentExpectation
	}
	return nil
}

// ValidateSweepAssignmentRecord fail-closes one append-only authoritative
// assignment record. This is the SCHEDULER's statement about an attempt, so it is
// validated on its own terms: nothing here is corroborated against a producer's
// lifecycle event, because the whole point of the record is to be the authority the
// event is not.
//
// It is a flat fail-closed rejection list: each branch is one field's rule, and splitting it
// into helpers scatters the very property the function exists to make auditable -- that every
// field is checked.
//
//nolint:gocyclo // flat rejection list; see above
func ValidateSweepAssignmentRecord(r *edgev1.SweepAssignmentRecordV1) error {
	if r == nil {
		return ErrNilRecord
	}
	// Unknown fields are rejected BEFORE anything else: this record is append-only
	// authority, so retained bytes no validator walked would ride along inside a
	// value later readers treat as settled.
	if hasUnknownFields(r) {
		return ErrUnknownFields
	}

	if ValidateCanonicalUUID(r.GetProducerAssignmentId()) != nil ||
		ValidateCanonicalUUID(r.GetExecutionId()) != nil ||
		ValidateCanonicalUUID(r.GetNetworkScopeId()) != nil ||
		ValidateCanonicalUUID(r.GetAuthenticatedAgentId()) != nil ||
		ValidateCanonicalUUID(r.GetProductionScopeId()) != nil {
		return ErrAssignmentIdentity
	}
	if ValidateUUIDv7(r.GetExecutionPlanId()) != nil {
		return ErrAssignmentIdentity
	}
	// run_id is the PRODUCER's run identity and a REQUIRED mapping-key member. It is
	// deliberately NOT compared to execution_id: the spec makes them independent,
	// because resolving a span to an execution is what the mapping lookup does.
	if ValidateCanonicalUUID(r.GetRunId()) != nil {
		return ErrAssignmentIdentity
	}
	// The carrier reference: id AND digest, both required.
	if ValidateUUIDv7(r.GetCompiledAssignmentId()) != nil ||
		len(r.GetCompiledAssignmentSha256()) != sha256Len {
		return ErrAssignmentIdentity
	}
	// The source identity is OPTIONAL -- its joint absence is a legal key shape -- but
	// when present every member must be valid, or the key it builds is malformed.
	if si := r.GetSourceIdentity(); si != nil {
		if !knownSourceAuthKind(si.GetKind()) ||
			ValidateCanonicalUUID(si.GetContextId()) != nil ||
			ValidateCanonicalUUID(si.GetSourceScopeId()) != nil ||
			len(si.GetSourceScopeSha256()) != sha256Len {
			return ErrAssignmentIdentity
		}
	}
	if len(r.GetExecutionPlanSha256()) != sha256Len {
		return ErrAssignmentIdentity
	}
	// record_sequence starts at 1: 0 is the proto default, so accepting it would let
	// an unset field pose as the first record of an append-only series.
	if r.GetRecordSequence() == 0 || r.GetAuthoredAtUnixNano() <= 0 {
		return ErrAssignmentIdentity
	}

	// The covered range is named DIRECTLY and both halves are REQUIRED: an identifier
	// a consumer can look up, and the digest it must match. An opaque commitment
	// checkable only for length is what retired `range_root_sha256`; it would have
	// been no better here.
	if ValidateCanonicalUUID(r.GetTargetRangeId()) != nil ||
		len(r.GetTargetRangeSha256()) != sha256Len {
		return ErrAssignmentScope
	}

	if len(r.GetLeaseId()) == 0 || r.GetFenceToken() == 0 || r.GetLeaseExpiresAtUnixNano() <= 0 {
		return ErrAssignmentLease
	}

	if !knownAssignmentState(r.GetState()) {
		return ErrAssignmentState
	}
	// superseded_by is present EXACTLY when the state is SUPERSEDED. A record naming a
	// successor it was not replaced by, or a SUPERSEDED record naming none, both leave
	// a reader unable to follow the chain.
	superseded := r.GetState() == edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_SUPERSEDED
	if superseded {
		if ValidateCanonicalUUID(r.GetSupersededByAssignmentId()) != nil {
			return ErrAssignmentState
		}
		// A record cannot supersede itself; that is a cycle, not a chain.
		if bytes.Equal(r.GetSupersededByAssignmentId(), r.GetProducerAssignmentId()) {
			return ErrAssignmentState
		}
	} else if len(r.GetSupersededByAssignmentId()) != 0 {
		return ErrAssignmentState
	}
	// An OPEN attempt has closed no evidence interval yet.
	if r.GetState() == edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_OPEN &&
		r.GetTerminalBatchSequence() != 0 {
		return ErrAssignmentState
	}

	// REQUIRED on every record, including OPEN ones: what an attempt is expected to
	// cover is known when it is authorized, not discovered when it finishes.
	if err := ValidateMtrExpectation(r.GetMtrExpectation()); err != nil {
		return err
	}

	if len(r.GetCheckSetSha256()) != sha256Len ||
		len(r.GetScopeSha256()) != sha256Len ||
		len(r.GetContractBundleSha256()) != sha256Len {
		return ErrAssignmentScope
	}
	if l := len(r.GetAvailabilityPolicyId()); l == 0 || l > MaxPolicyIDBytes {
		return ErrAssignmentScope
	}
	return nil
}

// ValidateAssignmentAgainstPlan proves the assignment/plan RELATION, which
// validating the two artifacts independently cannot: each can be internally perfect
// while describing different plans.
//
// Crucially it RECOMPUTES the assignment's MTR expectation from committed plan data
// rather than accepting the carried bytes. In v1 an assignment covers exactly one
// range and the completion proof requires leaf ordinals to be exactly
// {1..ordinal_count}, so every member of the commitment is
// `(plan_ordinal_offset + i, target_range_sha256)` -- the count and the range digest
// DETERMINE the commitment. Accepting any 32 bytes there would leave the per-attempt
// authority self-asserted, and a completion whose leaves all named some other range
// could verify against an assignment resolving to this one.
//
// NOTE ON INPUTS: this takes DECODED pages, so it inherits `ValidatePlanPages`'
// re-marshal size check and does NOT establish that the RECEIVED page bytes were
// within their physical ceiling. A caller that has not already validated the raw
// bytes must do so; see the exact-received-bytes requirement.
func ValidateAssignmentAgainstPlan(
	r *edgev1.SweepAssignmentRecordV1,
	h *edgev1.ScheduledPlanHeaderV1,
	pages []*edgev1.ScheduledPlanPageV1,
) error {
	if err := ValidateSweepAssignmentRecord(r); err != nil {
		return err
	}
	if err := ValidatePlanPages(h, pages); err != nil {
		return err
	}
	if !bytes.Equal(r.GetExecutionPlanId(), h.GetExecutionPlanId()) ||
		!bytes.Equal(r.GetExecutionPlanSha256(), h.GetExecutionPlanSha256()) {
		return ErrAssignmentPlanRelation
	}
	// Facts both artifacts carry MUST agree. The plan header no longer carries an
	// assignment epoch (tag 9 retired): an immutable plan cannot commit a value that
	// reassignment advances, so the monotonic epoch lives on this record alone.
	if !bytes.Equal(r.GetCheckSetSha256(), h.GetCheckSetSha256()) ||
		!bytes.Equal(r.GetAvailabilityPolicyId(), h.GetAvailabilityPolicyId()) ||
		!bytes.Equal(r.GetNetworkScopeId(), h.GetNetworkScopeId()) {
		return ErrAssignmentPlanRelation
	}

	windows, _, err := PlanMtrWindows(pages)
	if err != nil {
		return err
	}
	for _, p := range pages {
		for _, rng := range p.GetRanges() {
			if !bytes.Equal(rng.GetRangeId(), r.GetTargetRangeId()) {
				continue
			}
			// Right identity, wrong content: a claimed range whose digest is not the
			// plan's is a substitution, not a near miss.
			if !bytes.Equal(rng.GetRangeSha256(), r.GetTargetRangeSha256()) {
				return ErrAssignmentPlanRelation
			}
			return validateExpectationAgainstRange(r.GetMtrExpectation(), rng, windows[string(rng.GetRangeId())])
		}
	}
	return ErrAssignmentPlanRelation
}

// validateExpectationAgainstRange recomputes the whole expectation from the selected
// plan range. Every field is DERIVED here and compared, never trusted.
func validateExpectationAgainstRange(
	e *edgev1.SweepMtrExpectationV1,
	rng *edgev1.TargetRangeV1,
	offset uint64,
) error {
	// v1 replays the SAME COMPLETE window on retry/supersession, so the attempt's
	// count is the range's admitted count -- not a subset of it. Sparse remainders
	// need the deferred bounded-subset representation, not a smaller count here.
	if e.GetOrdinalCount() != rng.GetMtrOrdinalCount() {
		return ErrAssignmentPlanRelation
	}
	// The offset is REQUIRED-PRESENCE: offset 0 is the first range's legal window, so
	// an unset field must not pass as it.
	if e.PlanOrdinalOffset == nil || e.GetPlanOrdinalOffset() != offset {
		return ErrAssignmentPlanRelation
	}
	want, err := MtrWindowCommitment(offset, rng.GetMtrOrdinalCount(), rng.GetRangeSha256())
	if err != nil {
		return err
	}
	if !bytes.Equal(want, e.GetOrdinalRangeCommitment()) {
		return ErrAssignmentPlanRelation
	}
	return nil
}
