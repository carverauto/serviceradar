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
	"testing"

	"google.golang.org/protobuf/proto"

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
		TargetRangeId:          mustUUID(t),
		TargetRangeSha256:      d32domain(0x20),
		LeaseId:                []byte("lease-1"),
		FenceToken:             7,
		LeaseExpiresAtUnixNano: 2,
		State:                  edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_OPEN,
		MtrExpectation: &edgev1.SweepMtrExpectationV1{
			OrdinalCount:           2,
			OrdinalRangeCommitment: d32domain(0x30),
			PlanOrdinalOffset:      proto.Uint64(0),
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

	// BOTH halves of the range binding are REQUIRED. An assignment that does not name
	// a resolvable range is the defect that retired range_root_sha256.
	noID := validAssignment(t)
	noID.TargetRangeId = nil
	if err := ValidateSweepAssignmentRecord(noID); !errors.Is(err, ErrAssignmentScope) {
		t.Fatalf("absent target range id = %v, want ErrAssignmentScope", err)
	}
	junk := validAssignment(t)
	junk.TargetRangeId = []byte("not-a-uuid")
	if err := ValidateSweepAssignmentRecord(junk); !errors.Is(err, ErrAssignmentScope) {
		t.Fatalf("junk target range = %v, want ErrAssignmentScope", err)
	}
	for _, bad := range [][]byte{nil, {}, make([]byte, 31), make([]byte, 33)} {
		r := validAssignment(t)
		r.TargetRangeSha256 = bad
		if err := ValidateSweepAssignmentRecord(r); !errors.Is(err, ErrAssignmentScope) {
			t.Fatalf("range sha %d bytes = %v, want ErrAssignmentScope", len(bad), err)
		}
	}
}

// TestValidateAssignmentAgainstPlan pins the RELATION. Each artifact can be
// internally valid while describing a different plan, which independent validation
// cannot notice -- and did not, in the first version of this slice's fixture.
func TestValidateAssignmentAgainstPlan(t *testing.T) {
	planID := mustUUID(t)
	h, pages := buildPlan(t, planID, d32(0x77), [][]uint64{{256}})
	rng := pages[0].GetRanges()[0]

	bound := func() *edgev1.SweepAssignmentRecordV1 {
		r := validAssignment(t)
		r.ExecutionPlanId = h.GetExecutionPlanId()
		r.ExecutionPlanSha256 = h.GetExecutionPlanSha256()
		r.CheckSetSha256 = h.GetCheckSetSha256()
		r.AvailabilityPolicyId = h.GetAvailabilityPolicyId()
		r.NetworkScopeId = h.GetNetworkScopeId()
		r.TargetRangeId = rng.GetRangeId()
		r.TargetRangeSha256 = rng.GetRangeSha256()
		// The expectation is DERIVED from the plan, exactly as the relation recomputes
		// it. A hand-picked commitment would be the self-authoritative hole again.
		windows, _, err := PlanMtrWindows(pages)
		if err != nil {
			t.Fatalf("plan windows: %v", err)
		}
		off := windows[string(rng.GetRangeId())]
		commit, err := MtrWindowCommitment(off, rng.GetMtrOrdinalCount(), rng.GetRangeSha256())
		if err != nil {
			t.Fatalf("window commitment: %v", err)
		}
		r.MtrExpectation = &edgev1.SweepMtrExpectationV1{
			OrdinalCount:           rng.GetMtrOrdinalCount(),
			OrdinalRangeCommitment: commit,
			PlanOrdinalOffset:      proto.Uint64(off),
		}
		return r
	}

	if err := ValidateAssignmentAgainstPlan(bound(), h, pages); err != nil {
		t.Fatalf("bound assignment must relate to its plan: %v", err)
	}

	// A range the plan never committed.
	stranger := bound()
	stranger.TargetRangeId = mustUUID(t)
	if err := ValidateAssignmentAgainstPlan(stranger, h, pages); !errors.Is(err, ErrAssignmentPlanRelation) {
		t.Fatalf("foreign range = %v, want ErrAssignmentPlanRelation", err)
	}
	// The plan's range identity carrying someone else's content digest.
	swapped := bound()
	swapped.TargetRangeSha256 = d32(0xEE)
	if err := ValidateAssignmentAgainstPlan(swapped, h, pages); !errors.Is(err, ErrAssignmentPlanRelation) {
		t.Fatalf("substituted range digest = %v, want ErrAssignmentPlanRelation", err)
	}
	// Facts both artifacts carry must agree -- the epoch mismatch this slice shipped
	// in its first fixture is exactly this case.
	for name, mutate := range map[string]func(*edgev1.SweepAssignmentRecordV1){
		"check set": func(r *edgev1.SweepAssignmentRecordV1) { r.CheckSetSha256 = d32(0xEE) },
		"policy":    func(r *edgev1.SweepAssignmentRecordV1) { r.AvailabilityPolicyId = []byte("other") },
		"scope":     func(r *edgev1.SweepAssignmentRecordV1) { r.NetworkScopeId = mustUUID(t) },
		"plan id":   func(r *edgev1.SweepAssignmentRecordV1) { r.ExecutionPlanId = mustUUID(t) },
		"plan hash": func(r *edgev1.SweepAssignmentRecordV1) { r.ExecutionPlanSha256 = d32(0xEE) },
	} {
		r := bound()
		mutate(r)
		if err := ValidateAssignmentAgainstPlan(r, h, pages); !errors.Is(err, ErrAssignmentPlanRelation) {
			t.Fatalf("%s mismatch = %v, want ErrAssignmentPlanRelation", name, err)
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
		OrdinalCount: 0, OrdinalRangeCommitment: d32domain(0x30), PlanOrdinalOffset: proto.Uint64(0),
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
		PlanOrdinalOffset: proto.Uint64(0),
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
		OrdinalCount: MaxMtrCompletionOrdinals + 1, OrdinalRangeCommitment: d32domain(0x30), PlanOrdinalOffset: proto.Uint64(0),
	}
	if err := ValidateSweepAssignmentRecord(over); !errors.Is(err, ErrAssignmentExpectation) {
		t.Fatalf("count over the ceiling = %v, want ErrAssignmentExpectation", err)
	}
}

// splitPlan builds a TWO-range plan with real MTR windows: range A owns plan-global
// ordinals 1..2, range B owns 3..5. B's window is the case that was previously
// unrepresentable -- a second, NON-PREFIX assignment.
func splitPlan(t *testing.T) (*edgev1.ScheduledPlanHeaderV1, []*edgev1.ScheduledPlanPageV1) {
	t.Helper()
	planID := mustUUID(t)
	checkSet := d32(0x77)
	mk := func(cidr string, count, budget uint64) *edgev1.TargetRangeV1 {
		r := &edgev1.TargetRangeV1{
			RangeId: mustUUID(t), Cidr: cidr, TargetCount: 256, CheckSetSha256: checkSet,
			AvailabilityPolicyId: []byte("policy-1"),
			MtrAdmissionBudget:   budget, MtrOrdinalCount: proto.Uint64(count),
		}
		r.RangeSha256 = RangeDigest(r)
		return r
	}
	page := &edgev1.ScheduledPlanPageV1{
		ExecutionPlanId: planID, PageIndex: 0, PageCount: 1, CheckSetSha256: checkSet,
		DigestVersion: PlanDigestVersion,
		Ranges:        []*edgev1.TargetRangeV1{mk("10.0.0.0/24", 2, 4), mk("10.0.1.0/24", 3, 3)},
	}
	page.PageSha256 = PlanPageDigest(page)
	pages := []*edgev1.ScheduledPlanPageV1{page}
	h := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId: planID, PageCount: 1, TotalTargetCount: 512, PlanRootSha256: PlanRoot(pages),
		DigestVersion: PlanDigestVersion, CheckSetSha256: checkSet,
		AvailabilityPolicyId: []byte("policy-1"), NetworkScopeId: mustUUID(t),
		MtrOrdinalRangeCommitment: mustPlanCommitment(t, pages),
	}
	h.ExecutionPlanSha256 = PlanHeaderDigest(h)
	return h, pages
}

func assignmentFor(t *testing.T, h *edgev1.ScheduledPlanHeaderV1, pages []*edgev1.ScheduledPlanPageV1, idx int) *edgev1.SweepAssignmentRecordV1 {
	t.Helper()
	rng := pages[0].GetRanges()[idx]
	windows, _, err := PlanMtrWindows(pages)
	if err != nil {
		t.Fatalf("windows: %v", err)
	}
	off := windows[string(rng.GetRangeId())]
	commit, err := MtrWindowCommitment(off, rng.GetMtrOrdinalCount(), rng.GetRangeSha256())
	if err != nil {
		t.Fatalf("window commitment: %v", err)
	}
	r := validAssignment(t)
	r.ExecutionPlanId = h.GetExecutionPlanId()
	r.ExecutionPlanSha256 = h.GetExecutionPlanSha256()
	r.CheckSetSha256 = h.GetCheckSetSha256()
	r.AvailabilityPolicyId = h.GetAvailabilityPolicyId()
	r.NetworkScopeId = h.GetNetworkScopeId()
	r.TargetRangeId = rng.GetRangeId()
	r.TargetRangeSha256 = rng.GetRangeSha256()
	r.MtrExpectation = &edgev1.SweepMtrExpectationV1{
		OrdinalCount: rng.GetMtrOrdinalCount(), OrdinalRangeCommitment: commit,
		PlanOrdinalOffset: proto.Uint64(off),
	}
	return r
}

// TestSplitPlanSecondAssignment proves the frozen ordinal model: a plan divided
// across assignments, where the SECOND one owns a non-prefix window (3..5) and still
// keeps its completion-leaf ordinals local to {1..3}.
func TestSplitPlanSecondAssignment(t *testing.T) {
	h, pages := splitPlan(t)

	first := assignmentFor(t, h, pages, 0)
	second := assignmentFor(t, h, pages, 1)
	if err := ValidateAssignmentAgainstPlan(first, h, pages); err != nil {
		t.Fatalf("first assignment: %v", err)
	}
	if err := ValidateAssignmentAgainstPlan(second, h, pages); err != nil {
		t.Fatalf("SECOND, non-prefix assignment must be representable: %v", err)
	}
	// The windows are genuinely different, so neither test is passing by coincidence.
	if second.GetMtrExpectation().GetPlanOrdinalOffset() == 0 {
		t.Fatal("second assignment's window is a prefix; the split vector is vacuous")
	}
	if bytes.Equal(first.GetMtrExpectation().GetOrdinalRangeCommitment(),
		second.GetMtrExpectation().GetOrdinalRangeCommitment()) {
		t.Fatal("the two window commitments are equal; the split vector is vacuous")
	}

	// The plan-wide commitment is the ADDITIVE SUM of the per-assignment windows --
	// which is what lets a split plan be verified without renumbering any attempt.
	var sum [32]byte
	for _, r := range []*edgev1.SweepAssignmentRecordV1{first, second} {
		var w [32]byte
		copy(w[:], r.GetMtrExpectation().GetOrdinalRangeCommitment())
		add256(&sum, w)
	}
	if !bytes.Equal(sum[:], h.GetMtrOrdinalRangeCommitment()) {
		t.Fatal("plan-wide commitment must equal the sum of the per-assignment windows")
	}
}

// TestExpectationIsRecomputedNotTrusted is the P0 this slice missed twice: the
// relation must DERIVE the expectation from the plan, so an assignment cannot assert
// its own MTR authority.
func TestExpectationIsRecomputedNotTrusted(t *testing.T) {
	h, pages := splitPlan(t)

	// An arbitrary 32-byte commitment used to pass; the count and range digest
	// DETERMINE it, so anything else is a different membership claim.
	arbitrary := assignmentFor(t, h, pages, 0)
	arbitrary.MtrExpectation.OrdinalRangeCommitment = d32(0x30)
	if err := ValidateAssignmentAgainstPlan(arbitrary, h, pages); !errors.Is(err, ErrAssignmentPlanRelation) {
		t.Fatalf("arbitrary commitment = %v, want ErrAssignmentPlanRelation", err)
	}

	// Another range's window commitment is equally rejected -- otherwise a completion
	// whose leaves all name range B could verify against an assignment on range A.
	crossed := assignmentFor(t, h, pages, 0)
	crossed.MtrExpectation.OrdinalRangeCommitment =
		assignmentFor(t, h, pages, 1).GetMtrExpectation().GetOrdinalRangeCommitment()
	if err := ValidateAssignmentAgainstPlan(crossed, h, pages); !errors.Is(err, ErrAssignmentPlanRelation) {
		t.Fatalf("other range's window = %v, want ErrAssignmentPlanRelation", err)
	}

	// The count must equal the range's admitted count: v1 replays the WHOLE window.
	shortened := assignmentFor(t, h, pages, 0)
	shortened.MtrExpectation.OrdinalCount = 1
	if err := ValidateAssignmentAgainstPlan(shortened, h, pages); !errors.Is(err, ErrAssignmentPlanRelation) {
		t.Fatalf("partial window = %v, want ErrAssignmentPlanRelation", err)
	}

	// REQUIRED PRESENCE: an absent offset must not pass as the legal offset 0.
	// The OWNING validator rejects an absent offset, so it never reaches the relation:
	// offset 0 is the first range's legal window and an unset field must not pass as it.
	absent := assignmentFor(t, h, pages, 0)
	absent.MtrExpectation.PlanOrdinalOffset = nil
	if err := ValidateSweepAssignmentRecord(absent); !errors.Is(err, ErrAssignmentExpectation) {
		t.Fatalf("absent offset (standalone) = %v, want ErrAssignmentExpectation", err)
	}
	if err := ValidateAssignmentAgainstPlan(absent, h, pages); !errors.Is(err, ErrAssignmentExpectation) {
		t.Fatalf("absent offset = %v, want ErrAssignmentExpectation", err)
	}
	// ABSENT vs PRESENT-ZERO: the same bytes on the wire, different verdicts.
	presentZero := assignmentFor(t, h, pages, 0)
	if presentZero.GetMtrExpectation().GetPlanOrdinalOffset() != 0 {
		t.Fatal("first range's offset should be 0; the absent-vs-zero control is vacuous")
	}
	if err := ValidateSweepAssignmentRecord(presentZero); err != nil {
		t.Fatalf("explicit offset 0 must be accepted: %v", err)
	}
	// Same distinction for the plan's admitted count.
	absentCount := proto.Clone(pages[0]).(*edgev1.ScheduledPlanPageV1)
	absentCount.Ranges[0].MtrOrdinalCount = nil
	if _, _, err := PlanMtrWindows([]*edgev1.ScheduledPlanPageV1{absentCount}); !errors.Is(err, ErrPlanMtrWindow) {
		t.Fatalf("absent range count = %v, want ErrPlanMtrWindow", err)
	}
	wrongOff := assignmentFor(t, h, pages, 1)
	wrongOff.MtrExpectation.PlanOrdinalOffset = proto.Uint64(0)
	if err := ValidateAssignmentAgainstPlan(wrongOff, h, pages); !errors.Is(err, ErrAssignmentPlanRelation) {
		t.Fatalf("wrong offset = %v, want ErrAssignmentPlanRelation", err)
	}
}

// TestPlanMtrWindowBounds pins the ceiling rule and the overflow guard.
func TestPlanMtrWindowBounds(t *testing.T) {
	h, pages := splitPlan(t)

	// The admitted count may never exceed the ceiling. The count is carried, not
	// derived from the budget -- but the budget still bounds it.
	over := proto.Clone(pages[0]).(*edgev1.ScheduledPlanPageV1)
	over.Ranges[0].MtrOrdinalCount = proto.Uint64(over.Ranges[0].GetMtrAdmissionBudget() + 1)
	if _, _, err := PlanMtrWindows([]*edgev1.ScheduledPlanPageV1{over}); !errors.Is(err, ErrPlanMtrWindow) {
		t.Fatalf("count over budget = %v, want ErrPlanMtrWindow", err)
	}

	// Overflow of the ordinal space is rejected rather than wrapping.
	if _, err := MtrWindowCommitment(MaxMtrCompletionOrdinals, 1, d32(0x20)); !errors.Is(err, ErrPlanMtrWindow) {
		t.Fatalf("window overflow = %v, want ErrPlanMtrWindow", err)
	}
	// A WIDTH over the ceiling, tested DIRECTLY. Without this the `count >
	// MaxPlanMtrOrdinals` guard can be deleted and the suite stays green -- and worse,
	// deleting it exposes UNSIGNED UNDERFLOW: `MaxPlanMtrOrdinals - count` wraps to a
	// huge value, so the window-end check then passes and the fold runs unbounded.
	if _, err := MtrWindowCommitment(0, MaxPlanMtrOrdinals+1, d32(0x20)); !errors.Is(err, ErrPlanMtrWindow) {
		t.Fatalf("width over the ceiling = %v, want ErrPlanMtrWindow", err)
	}
	// The window END is bounded, not merely the width: a one-ordinal window starting
	// AT the ceiling names an ordinal no plan can contain.
	if _, err := MtrWindowCommitment(MaxPlanMtrOrdinals, 1, d32(0x20)); !errors.Is(err, ErrPlanMtrWindow) {
		t.Fatalf("window ending past the ceiling = %v, want ErrPlanMtrWindow", err)
	}
	if _, err := MtrWindowCommitment(MaxPlanMtrOrdinals-1, 1, d32(0x20)); err != nil {
		t.Fatalf("a window ending exactly AT the ceiling must be accepted: %v", err)
	}
	// Go rejects a non-32-byte range digest; the Elixir peer must not be laxer.
	if _, err := MtrWindowCommitment(0, 1, []byte{7}); !errors.Is(err, ErrPlanMtrWindow) {
		t.Fatalf("short range digest = %v, want ErrPlanMtrWindow", err)
	}

	// A header whose commitment is not the recomputed sum is rejected.
	bad := proto.Clone(h).(*edgev1.ScheduledPlanHeaderV1)
	bad.MtrOrdinalRangeCommitment = d32(0x30)
	bad.ExecutionPlanSha256 = PlanHeaderDigest(bad)
	if err := ValidatePlanPages(bad, pages); !errors.Is(err, ErrPlanMtrCommitment) {
		t.Fatalf("unrecomputable header commitment = %v, want ErrPlanMtrCommitment", err)
	}
}

// TestNonPrefixCompletionProof is the end-to-end case the split model exists for and
// that the first version of it could NOT satisfy: the assignment commitment hashed
// PLAN-GLOBAL ordinals while the completion verifier folded LOCAL ones, so any window
// with a non-zero offset failed its ordinal->range membership check.
func TestNonPrefixCompletionProof(t *testing.T) {
	h, pages := splitPlan(t)
	second := assignmentFor(t, h, pages, 1)
	exp := second.GetMtrExpectation()

	// Offset 2, count 3: the second range owns plan-global ordinals 3..5 while its
	// completion leaves stay LOCAL at {1..3}.
	if exp.GetPlanOrdinalOffset() != 2 || exp.GetOrdinalCount() != 3 {
		t.Fatalf("fixture drift: offset=%d count=%d, want 2/3",
			exp.GetPlanOrdinalOffset(), exp.GetOrdinalCount())
	}

	rangeSha := second.GetTargetRangeSha256()
	leaves := make([]MtrCompletionLeaf, 0, exp.GetOrdinalCount())
	for i := uint64(1); i <= exp.GetOrdinalCount(); i++ {
		leaves = append(leaves, MtrCompletionLeaf{
			Ordinal: i, Disposition: MtrDispositionNotAdmitted, RangeSha256: rangeSha,
		})
	}

	root, err := MtrCompletionRoot(leaves, exp.GetPlanOrdinalOffset(), exp.GetOrdinalCount(),
		h.GetPlanRootSha256(), exp.GetOrdinalRangeCommitment())
	if err != nil {
		t.Fatalf("a valid non-prefix completion must prove: %v", err)
	}
	if len(root) != sha256Len {
		t.Fatalf("root is %d bytes, want %d", len(root), sha256Len)
	}

	// Dropping the offset reproduces the original defect: the same leaves against the
	// same commitment no longer prove membership.
	if _, err := MtrCompletionRoot(leaves, 0, exp.GetOrdinalCount(),
		h.GetPlanRootSha256(), exp.GetOrdinalRangeCommitment()); !errors.Is(err, ErrMtrCompletion) {
		t.Fatal("without the offset the non-prefix proof must FAIL; the test is vacuous otherwise")
	}

	// A wrong offset is rejected too -- the window is bound, not merely shifted.
	if _, err := MtrCompletionRoot(leaves, exp.GetPlanOrdinalOffset()+1, exp.GetOrdinalCount(),
		h.GetPlanRootSha256(), exp.GetOrdinalRangeCommitment()); !errors.Is(err, ErrMtrCompletion) {
		t.Fatal("a shifted offset must not prove the committed window")
	}
}

// TestVerifyCompletionForwardsTheOffset pins the WRAPPER, not just the accumulator.
// The split tests call MtrCompletionRoot directly, so hardcoding a zero offset inside
// VerifyCompletionAgainstPlanState would leave them all green while every non-prefix
// consumer silently failed.
func TestVerifyCompletionForwardsTheOffset(t *testing.T) {
	h, pages := splitPlan(t)
	second := assignmentFor(t, h, pages, 1)
	exp := second.GetMtrExpectation()
	if exp.GetPlanOrdinalOffset() == 0 {
		t.Fatal("fixture drift: the second window must be non-prefix")
	}

	leaves := make([]MtrCompletionLeaf, 0, exp.GetOrdinalCount())
	for i := uint64(1); i <= exp.GetOrdinalCount(); i++ {
		leaves = append(leaves, MtrCompletionLeaf{
			Ordinal: i, Disposition: MtrDispositionNotAdmitted, RangeSha256: second.GetTargetRangeSha256(),
		})
	}
	root, err := MtrCompletionRoot(leaves, exp.GetPlanOrdinalOffset(), exp.GetOrdinalCount(),
		h.GetPlanRootSha256(), exp.GetOrdinalRangeCommitment())
	if err != nil {
		t.Fatalf("split root: %v", err)
	}

	ev := &edgev1.SweepExecutionEventV1{
		ExecutionId: mustUUID(t), ExecutionPlanId: mustUUID(t), TargetRangeId: mustUUID(t),
		ExecutionPlanSha256: d32(0x10),
		Kind:                edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED,
		EmittedAtUnixNano:   1, TerminalBatchSequence: 1,
		MtrCompletionDigestVersion: MtrCompletionDigestVersion,
		MtrCompletionDigest:        root,
		PlanRootSha256:             h.GetPlanRootSha256(),
	}

	if err := VerifyCompletionAgainstPlanState(ev, exp.GetPlanOrdinalOffset(), exp.GetOrdinalCount(),
		h.GetPlanRootSha256(), exp.GetOrdinalRangeCommitment(), leaves); err != nil {
		t.Fatalf("the wrapper must forward the offset: %v", err)
	}
	// Passing zero must FAIL -- otherwise the assertion above would hold even if the
	// wrapper ignored its offset argument entirely.
	if err := VerifyCompletionAgainstPlanState(ev, 0, exp.GetOrdinalCount(),
		h.GetPlanRootSha256(), exp.GetOrdinalRangeCommitment(), leaves); err == nil {
		t.Fatal("a zero offset must not verify a non-prefix window; the test is vacuous otherwise")
	}
}
