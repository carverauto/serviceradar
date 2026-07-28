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
	"errors"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func validAssignment(t *testing.T) *edgev1.SweepAssignmentRecordV1 {
	t.Helper()
	return &edgev1.SweepAssignmentRecordV1{
		ProducerAssignmentId:   mustUUID(t),
		ExecutionId:            mustUUID(t),
		ExecutionPlanId:        mustUUID(t),
		ExecutionPlanSha256:    d32domain(0x10),
		ExecutionShard:         3,
		AssignmentEpoch:        5,
		RecordSequence:         1,
		AuthoredAtUnixNano:     1,
		RangeSetCommitment:     MtrOrdinalRangeCommitment([]MtrCompletionLeaf{{Ordinal: 1, RangeSha256: d32domain(0x20)}}),
		TargetRangeId:          mustUUID(t),
		LeaseId:                []byte("lease-1"),
		FenceToken:             7,
		LeaseExpiresAtUnixNano: 2,
		State:                  edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_OPEN,
		MtrExpectation: &edgev1.SweepMtrExpectationV1{
			OrdinalCount:           2,
			OrdinalRangeCommitment: d32domain(0x30),
		},
		CheckSetSha256:       d32domain(0x40),
		AvailabilityPolicyId: []byte("policy-1"),
		NetworkScopeId:       mustUUID(t),
		AuthenticatedAgentId: mustUUID(t),
		ProductionScopeId:    mustUUID(t),
		ScopeSha256:          d32domain(0x50),
		ContractBundleSha256: d32domain(0x60),
	}
}

func TestValidateSweepAssignmentRecord(t *testing.T) {
	if err := ValidateSweepAssignmentRecord(validAssignment(t)); err != nil {
		t.Fatalf("valid assignment record: %v", err)
	}

	// record_sequence 0 is the proto default; accepting it would let an unset field
	// pose as the first record of an append-only series.
	seq := validAssignment(t)
	seq.RecordSequence = 0
	if err := ValidateSweepAssignmentRecord(seq); !errors.Is(err, ErrAssignmentIdentity) {
		t.Fatalf("record_sequence 0 = %v, want ErrAssignmentIdentity", err)
	}

	// A lease without a fence token cannot detect a stale holder.
	fence := validAssignment(t)
	fence.FenceToken = 0
	if err := ValidateSweepAssignmentRecord(fence); !errors.Is(err, ErrAssignmentLease) {
		t.Fatalf("fence 0 = %v, want ErrAssignmentLease", err)
	}

	// An OPEN attempt has closed no evidence interval.
	open := validAssignment(t)
	open.TerminalBatchSequence = 4
	if err := ValidateSweepAssignmentRecord(open); !errors.Is(err, ErrAssignmentState) {
		t.Fatalf("OPEN with terminal sequence = %v, want ErrAssignmentState", err)
	}

	// superseded_by is present EXACTLY when the state is SUPERSEDED.
	strayLink := validAssignment(t)
	strayLink.SupersededByAssignmentId = mustUUID(t)
	if err := ValidateSweepAssignmentRecord(strayLink); !errors.Is(err, ErrAssignmentState) {
		t.Fatalf("non-superseded record naming a successor = %v, want ErrAssignmentState", err)
	}
	missingLink := validAssignment(t)
	missingLink.State = edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_SUPERSEDED
	if err := ValidateSweepAssignmentRecord(missingLink); !errors.Is(err, ErrAssignmentState) {
		t.Fatalf("SUPERSEDED without a successor = %v, want ErrAssignmentState", err)
	}
	selfLink := validAssignment(t)
	selfLink.State = edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_SUPERSEDED
	selfLink.SupersededByAssignmentId = selfLink.GetProducerAssignmentId()
	if err := ValidateSweepAssignmentRecord(selfLink); !errors.Is(err, ErrAssignmentState) {
		t.Fatalf("self-supersede = %v, want ErrAssignmentState", err)
	}
	good := validAssignment(t)
	good.State = edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_SUPERSEDED
	good.SupersededByAssignmentId = mustUUID(t)
	good.TerminalBatchSequence = 4
	if err := ValidateSweepAssignmentRecord(good); err != nil {
		t.Fatalf("valid SUPERSEDED record: %v", err)
	}

	// An unknown state number is rejected, not carried.
	unknown := validAssignment(t)
	unknown.State = edgev1.SweepAssignmentState(99)
	if err := ValidateSweepAssignmentRecord(unknown); !errors.Is(err, ErrAssignmentState) {
		t.Fatalf("state 99 = %v, want ErrAssignmentState", err)
	}

	// Multi-range: an empty target_range_id is legal, arbitrary bytes are not.
	multi := validAssignment(t)
	multi.TargetRangeId = nil
	if err := ValidateSweepAssignmentRecord(multi); err != nil {
		t.Fatalf("multi-range assignment: %v", err)
	}
	junk := validAssignment(t)
	junk.TargetRangeId = []byte("not-a-uuid")
	if err := ValidateSweepAssignmentRecord(junk); !errors.Is(err, ErrAssignmentScope) {
		t.Fatalf("junk target range = %v, want ErrAssignmentScope", err)
	}

	// The range-set commitment is ALWAYS 32 bytes, like every other commitment.
	for _, bad := range [][]byte{nil, {}, make([]byte, 31), make([]byte, 33)} {
		r := validAssignment(t)
		r.RangeSetCommitment = bad
		if err := ValidateSweepAssignmentRecord(r); !errors.Is(err, ErrAssignmentScope) {
			t.Fatalf("range-set commitment %d bytes = %v, want ErrAssignmentScope", len(bad), err)
		}
	}
}

// TestMtrExpectationIsRequiredAndSelfConsistent pins the field that makes the
// zero-MTR rule checkable at all. Before the expectation was carried, "32 zero bytes
// means no MTR admitted" was unfalsifiable: the commitment is an additive multiset
// hash and cannot be inverted to a count, so nothing could contradict it.
func TestMtrExpectationIsRequiredAndSelfConsistent(t *testing.T) {
	// ABSENT is not ZERO. A record that never stated an expectation is rejected;
	// treating it as "expects nothing" is how a missing authority becomes a waiver.
	absent := validAssignment(t)
	absent.MtrExpectation = nil
	if err := ValidateSweepAssignmentRecord(absent); !errors.Is(err, ErrAssignmentExpectation) {
		t.Fatalf("absent expectation = %v, want ErrAssignmentExpectation", err)
	}

	// count == 0 <=> commitment == 32 zero bytes, in BOTH directions.
	countNoCommit := validAssignment(t)
	countNoCommit.MtrExpectation = &edgev1.SweepMtrExpectationV1{
		OrdinalCount: 0, OrdinalRangeCommitment: d32domain(0x30),
	}
	if err := ValidateSweepAssignmentRecord(countNoCommit); !errors.Is(err, ErrAssignmentExpectation) {
		t.Fatalf("zero count with a non-empty commitment = %v, want ErrAssignmentExpectation", err)
	}
	commitNoCount := validAssignment(t)
	commitNoCount.MtrExpectation = &edgev1.SweepMtrExpectationV1{
		OrdinalCount: 3, OrdinalRangeCommitment: make([]byte, 32),
	}
	if err := ValidateSweepAssignmentRecord(commitNoCount); !errors.Is(err, ErrAssignmentExpectation) {
		t.Fatalf("non-zero count with the empty-set commitment = %v, want ErrAssignmentExpectation", err)
	}

	// The zero-MTR assignment: count 0 AND the 32-zero empty-set commitment.
	zeroMtr := validAssignment(t)
	zeroMtr.MtrExpectation = &edgev1.SweepMtrExpectationV1{
		OrdinalCount: 0, OrdinalRangeCommitment: make([]byte, 32),
	}
	if err := ValidateSweepAssignmentRecord(zeroMtr); err != nil {
		t.Fatalf("zero-MTR expectation must be valid: %v", err)
	}

	// The commitment is always 32 bytes -- empty is not the empty-set hash.
	for _, bad := range [][]byte{nil, {}, make([]byte, 31), make([]byte, 33)} {
		r := validAssignment(t)
		r.MtrExpectation = &edgev1.SweepMtrExpectationV1{OrdinalCount: 0, OrdinalRangeCommitment: bad}
		if err := ValidateSweepAssignmentRecord(r); !errors.Is(err, ErrAssignmentExpectation) {
			t.Fatalf("commitment %d bytes = %v, want ErrAssignmentExpectation", len(bad), err)
		}
	}

	// The count is bounded by the same ceiling the accumulator enforces.
	over := validAssignment(t)
	over.MtrExpectation = &edgev1.SweepMtrExpectationV1{
		OrdinalCount: MaxMtrCompletionOrdinals + 1, OrdinalRangeCommitment: d32domain(0x30),
	}
	if err := ValidateSweepAssignmentRecord(over); !errors.Is(err, ErrAssignmentExpectation) {
		t.Fatalf("count over the ceiling = %v, want ErrAssignmentExpectation", err)
	}
}
