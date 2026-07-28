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
)

// zero32 is the empty-set additive multiset hash: the commitment a set with no
// members folds to. It is a VALUE, not an absence, which is the whole reason the
// commitment fields are fixed-width.
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
	if len(r.GetExecutionPlanSha256()) != sha256Len {
		return ErrAssignmentIdentity
	}
	// record_sequence starts at 1: 0 is the proto default, so accepting it would let
	// an unset field pose as the first record of an append-only series.
	if r.GetRecordSequence() == 0 || r.GetAuthoredAtUnixNano() <= 0 {
		return ErrAssignmentIdentity
	}

	// The covered-range commitment is ALWAYS 32 bytes, exactly like the expectation's:
	// an assignment covering no ranges carries the 32-zero empty-set hash.
	if len(r.GetRangeSetCommitment()) != sha256Len {
		return ErrAssignmentScope
	}
	// target_range_id is the single-range convenience name. Empty means multi-range;
	// present means it must be a real identifier, never arbitrary bytes.
	if len(r.GetTargetRangeId()) != 0 && ValidateCanonicalUUID(r.GetTargetRangeId()) != nil {
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
