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
	"crypto/ed25519"
	"errors"
	"fmt"
	"testing"

	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/reflect/protoreflect"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func validAssignment(t *testing.T) *edgev1.SweepAssignmentRecordV1 {
	t.Helper()
	return &edgev1.SweepAssignmentRecordV1{
		ProducerAssignmentId: mustUUID(t),
		ExecutionId:          mustUUID(t),
		ExecutionPlanId:      mustUUID(t),
		ExecutionPlanSha256:  d32domain(0x10),
		ExecutionShard:       3,
		AssignmentEpoch:      5,
		RecordSequence:       1,
		AuthoredAtUnixNano:   1,
		TargetRangeId:        mustUUID(t),
		TargetRangeSha256:    d32domain(0x20),
		LeaseId:              []byte("lease-1"),
		FenceToken:           7,
		// Wide enough to CONTAIN the compiled carrier's window: collection is constrained
		// to the lease, so a 2ns lease could not host a 100..200 carrier.
		LeaseExpiresAtUnixNano: 200,
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
		RunId:                mustUUID(t),
		// PRESENT in the base fixture so the grant's identity binding is non-vacuous: with a nil
		// identity the grant's identity comparisons are skipped entirely and every
		// mutation of them passes.
		SourceIdentity: &edgev1.EdgeSourceSpanIdentityV1{
			Kind:              edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
			ContextId:         mustUUID(t),
			SourceScopeId:     mustUUID(t),
			SourceScopeSha256: d32domain(0x40),
		},
		CompiledAssignmentId: mustUUID(t),
		// A stand-in digest: tests that need the record/carrier RELATION build a real
		// carrier and overwrite both fields.
		CompiledAssignmentSha256: d32domain(0x70),
	}
}

// validCompiledAssignment builds a carrier whose self-digest and COLLECTION capability
// are both correct, so a test can mutate exactly one thing and see it rejected.
// compiledTestKey is a FIXED-seed Ed25519 key so signing bytes and the artifact digest
// are reproducible across runs and can be pinned as shared vectors.
func compiledTestKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i + 1)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub, ok := priv.Public().(ed25519.PublicKey)
	if !ok {
		t.Fatal("ed25519 public key type assertion failed")
	}
	return pub, priv
}

// hostTestKey is a SEPARATE Ed25519 key for the HOST role. Reusing one key for both roles
// would make the host/scheduler separation untestable: every "wrong signer" case would still
// verify cryptographically.
func hostTestKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(0x80 + i)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub, ok := priv.Public().(ed25519.PublicKey)
	if !ok {
		t.Fatal("ed25519 public key type assertion failed")
	}
	return pub, priv
}

// compiledTestTrust is a PURPOSE-AWARE resolver: each key family is authorized for exactly
// the roles it may issue, and the resolution ECHOES the requested purpose. A resolver that
// ignored purpose would let a scheduler key mint a host execution grant, which is precisely
// the separation under test.
type compiledTestTrust struct {
	schedPub ed25519.PublicKey
	hostPub  ed25519.PublicKey
	status   KeyStatus
	// perKey overrides `status` for one key id, so a single role's trust can be degraded.
	perKey map[string]KeyStatus
	// ignorePurpose reproduces a purpose-blind resolver, for the negative case.
	ignorePurpose bool
}

func (t compiledTestTrust) ResolveKey(issuerID, issuerKeyID []byte, ev KeyEvidence) KeyResolution {
	// (issuer, key id) -> the ROLES that key family may issue, and its public key.
	type entry struct {
		pub   ed25519.PublicKey
		roles []edgev1.EdgeCapabilityPurpose
	}
	catalog := map[string]entry{
		// The SCHEDULER family signs carriers (collection capabilities) and nothing else.
		"sched|k1": {t.schedPub, []edgev1.EdgeCapabilityPurpose{
			edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION,
		}},
		// The HOST family signs execution grants and nothing else.
		"host|host-exec-1": {t.hostPub, []edgev1.EdgeCapabilityPurpose{
			edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION,
		}},
	}
	e, ok := catalog[string(issuerID)+"|"+string(issuerKeyID)]
	if !ok {
		return KeyResolution{Status: KeyInvalid, TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: ev.Purpose}
	}
	if !t.ignorePurpose {
		authorized := false
		for _, role := range e.roles {
			if role == ev.Purpose {
				authorized = true
				break
			}
		}
		if !authorized {
			// The key exists but is NOT authorized for this role: unauthorized, permanent.
			return KeyResolution{Status: KeyInvalid, TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: ev.Purpose}
		}
	}
	st := t.status
	if over, ok := t.perKey[string(issuerKeyID)]; ok {
		st = over
	}
	return KeyResolution{Status: st, Public: e.pub, TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: ev.Purpose}
}

// trustBoth is the honest resolver for both roles.
func trustBoth(t *testing.T, status KeyStatus) compiledTestTrust {
	t.Helper()
	schedPub, _ := compiledTestKey(t)
	hostPub, _ := hostTestKey(t)
	return compiledTestTrust{schedPub: schedPub, hostPub: hostPub, status: status}
}

// signCompiledAssignment recomputes BOTH digests and the signature, in the one order
// that is self-consistent: body digest -> claim binds it -> signature over the claim ->
// artifact digest over body+capability. Every mutation test calls this so the ONLY
// remaining difference is the member under test, never a stale dependent value.
func signCompiledAssignment(t *testing.T, c *edgev1.CompiledSweepAssignmentV1, priv ed25519.PrivateKey) {
	t.Helper()
	c.CompiledAssignmentBodySha256 = CompiledAssignmentBodyDigest(c)
	if cl := c.GetCollectionCapability().GetCollection(); cl != nil {
		cl.CompiledAssignmentBodySha256 = c.GetCompiledAssignmentBodySha256()
	}
	if cap := c.GetCollectionCapability(); cap != nil {
		SignCapability(cap, priv)
	}
	c.CompiledAssignmentSha256 = CompiledAssignmentArtifactDigest(c)
}

func validCompiledAssignment(t *testing.T, r *edgev1.SweepAssignmentRecordV1) *edgev1.CompiledSweepAssignmentV1 {
	t.Helper()
	_, priv := compiledTestKey(t)
	c := &edgev1.CompiledSweepAssignmentV1{
		CompiledAssignmentId: r.GetCompiledAssignmentId(),
		DigestVersion:        CompiledAssignmentDigestVersion,
		ProducerAssignmentId: r.GetProducerAssignmentId(),
		ExecutionId:          r.GetExecutionId(),
		ExecutionPlanId:      r.GetExecutionPlanId(),
		ExecutionPlanSha256:  r.GetExecutionPlanSha256(),
		TargetRangeId:        r.GetTargetRangeId(),
		TargetRangeSha256:    r.GetTargetRangeSha256(),
		NetworkScopeId:       r.GetNetworkScopeId(),
		AuthenticatedAgentId: r.GetAuthenticatedAgentId(),
		ExecutionShard:       r.GetExecutionShard(),
		AssignmentEpoch:      r.GetAssignmentEpoch(),
		ConfigGeneration:     7,
		ResultFormat:         edgev1.SweepResultFormat_SWEEP_RESULT_FORMAT_EDGE_RECORDS_V1,
		CheckSetSha256:       r.GetCheckSetSha256(),
		TrafficClass:         edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
		// The carrier window must lie INSIDE the record's lease: collection is constrained
		// to the lease, so a fixture whose carrier window extends past it would not be valid.
		NotBeforeUnixNano: 100,
		ExpiresAtUnixNano: r.GetLeaseExpiresAtUnixNano(),
	}
	c.CollectionCapability = &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: []byte("sched"), IssuerKeyId: []byte("k1"),
		Algorithm: "ed25519", NotBeforeUnixNano: 100, ExpiresAtUnixNano: c.GetExpiresAtUnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Collection{
			Collection: &edgev1.EdgeCollectionClaimsV1{
				Purpose:              edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION,
				NetworkScopeId:       c.GetNetworkScopeId(),
				AuthenticatedAgentId: c.GetAuthenticatedAgentId(),
				ExecutionPlanId:      c.GetExecutionPlanId(),
				TargetRangeId:        c.GetTargetRangeId(),
				ExecutionShard:       c.GetExecutionShard(),
				AssignmentEpoch:      c.GetAssignmentEpoch(),
				TrafficClass:         c.GetTrafficClass(),
				ProducerAssignmentId: c.GetProducerAssignmentId(),
				ExecutionId:          c.GetExecutionId(),
			},
		},
	}
	signCompiledAssignment(t, c, priv)
	return c
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

	// Pin the frozen ceiling independently of the implementation constant. This
	// is structural validation, not recomputation of billions of plan ordinals.
	at := validAssignment(t)
	at.MtrExpectation = &edgev1.SweepMtrExpectationV1{
		OrdinalCount: 2_147_483_648, OrdinalRangeCommitment: d32domain(0x30), PlanOrdinalOffset: proto.Uint64(0),
	}
	if err := ValidateSweepAssignmentRecord(at); err != nil {
		t.Fatalf("count at the ceiling must be valid: %v", err)
	}

	over := validAssignment(t)
	over.MtrExpectation = &edgev1.SweepMtrExpectationV1{
		OrdinalCount: 2_147_483_649, OrdinalRangeCommitment: d32domain(0x30), PlanOrdinalOffset: proto.Uint64(0),
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

	// An offset drawn from the ordinal SPACE is refused by the lower PLAN WORK ceiling.
	// This does NOT exercise completion-ordinal-space overflow: MtrWindowCommitment bounds
	// against MaxPlanMtrOrdinals, and MaxMtrCompletionOrdinals is far above it, so the
	// refusal here comes from the work ceiling -- the same rule the two rows below assert
	// directly. Kept as a regression guard that a space-sized offset cannot slip through.
	if _, err := MtrWindowCommitment(MaxMtrCompletionOrdinals, 1, d32(0x20)); !errors.Is(err, ErrPlanMtrWindow) {
		t.Fatalf("space-sized offset = %v, want ErrPlanMtrWindow (work ceiling)", err)
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

// TestValidateCompiledSweepAssignment pins the carrier: its own digest, every compiled
// fact's domain, and the COLLECTION capability's binding to it.
func TestValidateCompiledSweepAssignment(t *testing.T) {
	base := validAssignment(t)
	if err := ValidateCompiledSweepAssignment(validCompiledAssignment(t, base)); err != nil {
		t.Fatalf("valid compiled assignment: %v", err)
	}

	// The self-digest covers every compiled fact, so changing ANY of them without
	// resealing is caught -- which is what lets one signature authenticate all of them.
	for name, mutate := range map[string]func(*edgev1.CompiledSweepAssignmentV1){
		"config generation": func(c *edgev1.CompiledSweepAssignmentV1) { c.ConfigGeneration = 9 },
		"result format": func(c *edgev1.CompiledSweepAssignmentV1) {
			c.ResultFormat = edgev1.SweepResultFormat_SWEEP_RESULT_FORMAT_UNSPECIFIED
		},
		"check set": func(c *edgev1.CompiledSweepAssignmentV1) { c.CheckSetSha256 = d32(0xEE) },
		"traffic class": func(c *edgev1.CompiledSweepAssignmentV1) {
			c.TrafficClass = edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE
		},
		"validity window": func(c *edgev1.CompiledSweepAssignmentV1) { c.ExpiresAtUnixNano = 500 },
		"plan digest":     func(c *edgev1.CompiledSweepAssignmentV1) { c.ExecutionPlanSha256 = d32(0xEE) },
	} {
		c := validCompiledAssignment(t, base)
		mutate(c)
		if err := ValidateCompiledSweepAssignment(c); err == nil {
			t.Fatalf("unsealed %s mutation must be rejected", name)
		}
	}

	// An UNAUTHENTICATED carrier is a set of facts nobody stands behind.
	noCap := validCompiledAssignment(t, base)
	noCap.CollectionCapability = nil
	if err := ValidateCompiledSweepAssignment(noCap); !errors.Is(err, ErrCompiledAssignmentCapability) {
		t.Fatalf("absent capability = %v, want ErrCompiledAssignmentCapability", err)
	}

	// A capability of the WRONG PURPOSE cannot attest a collection. The variant is
	// what carries purpose, so a production capability attached here is not merely
	// mislabelled -- it was issued for something else entirely.
	wrongVariant := validCompiledAssignment(t, base)
	wrongVariant.CollectionCapability.Claims = &edgev1.EdgeSignedCapabilityV1_Production{
		Production: &edgev1.EdgeProductionClaimsV1{},
	}
	// The error comes from the OFFICIAL capability validator, which is the point: the
	// carrier does not re-implement purpose checking, so a production capability here
	// fails for exactly the reason it fails in every other capability position.
	if err := ValidateCompiledSweepAssignment(wrongVariant); !errors.Is(err, ErrCapabilityPurpose) {
		t.Fatalf("production claims = %v, want ErrCapabilityPurpose", err)
	}

	// A capability that does not cover the carrier's window leaves part of it
	// unattested while the carrier still claims it.
	shortCap := validCompiledAssignment(t, base)
	shortCap.CollectionCapability.ExpiresAtUnixNano = 150
	if err := ValidateCompiledSweepAssignment(shortCap); !errors.Is(err, ErrCompiledAssignmentCapability) {
		t.Fatalf("capability expiring inside the window = %v, want ErrCompiledAssignmentCapability", err)
	}

	// A capability bound to a DIFFERENT carrier digest.
	crossed := validCompiledAssignment(t, base)
	crossed.CollectionCapability.GetCollection().CompiledAssignmentBodySha256 = d32(0xEE)
	if err := ValidateCompiledSweepAssignment(crossed); !errors.Is(err, ErrCompiledAssignmentCapability) {
		t.Fatalf("capability bound elsewhere = %v, want ErrCompiledAssignmentCapability", err)
	}
}

// TestValidateAssignmentAgainstCompiled pins the record/carrier RELATION: each can be
// internally valid while describing different work.
func TestValidateAssignmentAgainstCompiled(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()

	if err := ValidateAssignmentAgainstCompiled(r, c); err != nil {
		t.Fatalf("bound record and carrier: %v", err)
	}

	// The reference must pin the DIGEST, not just the id: an id alone names a carrier
	// without saying which revision of it was attested.
	staleRef := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
	staleRef.CompiledAssignmentSha256 = d32(0xEE)
	if err := ValidateAssignmentAgainstCompiled(staleRef, c); !errors.Is(err, ErrCompiledAssignmentBinding) {
		t.Fatalf("stale carrier digest = %v, want ErrCompiledAssignmentBinding", err)
	}

	// Facts both carry must agree.
	//
	// EVERY member the relation compares gets a case. A partial table would leave the
	// unlisted members free to disagree, which is exactly the defect the relation exists
	// to prevent -- and is how the assignment identity went unbound in the first place.
	for name, mutate := range map[string]func(*edgev1.SweepAssignmentRecordV1){
		"compiled id":     func(x *edgev1.SweepAssignmentRecordV1) { x.CompiledAssignmentId = mustUUID(t) },
		"compiled digest": func(x *edgev1.SweepAssignmentRecordV1) { x.CompiledAssignmentSha256 = d32(0xEE) },
		"producer assignment": func(x *edgev1.SweepAssignmentRecordV1) {
			x.ProducerAssignmentId = mustUUID(t)
		},
		"execution id":  func(x *edgev1.SweepAssignmentRecordV1) { x.ExecutionId = mustUUID(t) },
		"plan id":       func(x *edgev1.SweepAssignmentRecordV1) { x.ExecutionPlanId = mustUUID(t) },
		"plan digest":   func(x *edgev1.SweepAssignmentRecordV1) { x.ExecutionPlanSha256 = d32(0xEE) },
		"range id":      func(x *edgev1.SweepAssignmentRecordV1) { x.TargetRangeId = mustUUID(t) },
		"range":         func(x *edgev1.SweepAssignmentRecordV1) { x.TargetRangeSha256 = d32(0xEE) },
		"network scope": func(x *edgev1.SweepAssignmentRecordV1) { x.NetworkScopeId = mustUUID(t) },
		"agent":         func(x *edgev1.SweepAssignmentRecordV1) { x.AuthenticatedAgentId = mustUUID(t) },
		"shard":         func(x *edgev1.SweepAssignmentRecordV1) { x.ExecutionShard = 99 },
		"epoch":         func(x *edgev1.SweepAssignmentRecordV1) { x.AssignmentEpoch = 99 },
		"check set":     func(x *edgev1.SweepAssignmentRecordV1) { x.CheckSetSha256 = d32(0xEE) },
	} {
		bad := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
		mutate(bad)
		if err := ValidateAssignmentAgainstCompiled(bad, c); !errors.Is(err, ErrCompiledAssignmentBinding) {
			t.Fatalf("%s mismatch = %v, want ErrCompiledAssignmentBinding", name, err)
		}
	}
}

// TestAssignmentRecordRequiresKeyMembers pins the mapping-key members the record was
// missing, and that run_id is NOT cross-checked against execution_id.
func TestAssignmentRecordRequiresKeyMembers(t *testing.T) {
	for _, field := range []string{"run_id", "compiled_assignment_id", "compiled_assignment_sha256"} {
		r := validAssignment(t)
		switch field {
		case "run_id":
			r.RunId = nil
		case "compiled_assignment_id":
			r.CompiledAssignmentId = nil
		case "compiled_assignment_sha256":
			r.CompiledAssignmentSha256 = nil
		}
		if err := ValidateSweepAssignmentRecord(r); !errors.Is(err, ErrAssignmentIdentity) {
			t.Fatalf("absent %s = %v, want ErrAssignmentIdentity", field, err)
		}
	}

	// run_id is INDEPENDENT of execution_id: equal or different, both are accepted.
	same := validAssignment(t)
	same.RunId = same.GetExecutionId()
	if err := ValidateSweepAssignmentRecord(same); err != nil {
		t.Fatalf("run_id equal to execution_id must be accepted: %v", err)
	}

	// The source identity is OPTIONAL -- joint absence is a legal key shape -- but a
	// PARTIAL one is malformed.
	absent := validAssignment(t)
	absent.SourceIdentity = nil
	if err := ValidateSweepAssignmentRecord(absent); err != nil {
		t.Fatalf("absent source identity must be accepted: %v", err)
	}
	partial := validAssignment(t)
	partial.SourceIdentity = &edgev1.EdgeSourceSpanIdentityV1{
		Kind: edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
	}
	if err := ValidateSweepAssignmentRecord(partial); !errors.Is(err, ErrAssignmentIdentity) {
		t.Fatalf("partial source identity = %v, want ErrAssignmentIdentity", err)
	}
}

// TestCompiledAssignmentDigestCoversEveryBodyMember proves COVERAGE directly: mutate a
// body member and the body digest must CHANGE.
//
// This is deliberately not "mutate and expect validation to fail". A validation-based
// proof passes even when the digest ignores the member, because some unrelated semantic
// or claim-binding check rejects the mutation first -- so it demonstrates the mutation
// is caught, not that the digest covers it. Only the digest is observed here.
func TestCompiledAssignmentDigestCoversEveryBodyMember(t *testing.T) {
	base := validAssignment(t)

	for name, mutate := range map[string]func(*edgev1.CompiledSweepAssignmentV1){
		"digest version":      func(x *edgev1.CompiledSweepAssignmentV1) { x.DigestVersion = 2 },
		"compiled id":         func(x *edgev1.CompiledSweepAssignmentV1) { x.CompiledAssignmentId = mustUUID(t) },
		"producer assignment": func(x *edgev1.CompiledSweepAssignmentV1) { x.ProducerAssignmentId = mustUUID(t) },
		"execution id":        func(x *edgev1.CompiledSweepAssignmentV1) { x.ExecutionId = mustUUID(t) },
		"plan id":             func(x *edgev1.CompiledSweepAssignmentV1) { x.ExecutionPlanId = mustUUID(t) },
		"plan digest":         func(x *edgev1.CompiledSweepAssignmentV1) { x.ExecutionPlanSha256 = d32(0xEE) },
		"range id":            func(x *edgev1.CompiledSweepAssignmentV1) { x.TargetRangeId = mustUUID(t) },
		"range digest":        func(x *edgev1.CompiledSweepAssignmentV1) { x.TargetRangeSha256 = d32(0xEE) },
		"network scope":       func(x *edgev1.CompiledSweepAssignmentV1) { x.NetworkScopeId = mustUUID(t) },
		"agent":               func(x *edgev1.CompiledSweepAssignmentV1) { x.AuthenticatedAgentId = mustUUID(t) },
		"shard":               func(x *edgev1.CompiledSweepAssignmentV1) { x.ExecutionShard = 99 },
		"epoch":               func(x *edgev1.CompiledSweepAssignmentV1) { x.AssignmentEpoch = 99 },
		"config generation":   func(x *edgev1.CompiledSweepAssignmentV1) { x.ConfigGeneration = 99 },
		"result format": func(x *edgev1.CompiledSweepAssignmentV1) {
			x.ResultFormat = edgev1.SweepResultFormat_SWEEP_RESULT_FORMAT_UNSPECIFIED
		},
		"check set": func(x *edgev1.CompiledSweepAssignmentV1) { x.CheckSetSha256 = d32(0xEE) },
		"traffic class": func(x *edgev1.CompiledSweepAssignmentV1) {
			x.TrafficClass = edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE
		},
		"not before": func(x *edgev1.CompiledSweepAssignmentV1) { x.NotBeforeUnixNano = 101 },
		"expires":    func(x *edgev1.CompiledSweepAssignmentV1) { x.ExpiresAtUnixNano = 199 },
	} {
		c := validCompiledAssignment(t, base)
		before := CompiledAssignmentBodyDigest(c)
		mutate(c)
		if bytes.Equal(before, CompiledAssignmentBodyDigest(c)) {
			t.Fatalf("body digest ignores %s: the signature does not cover it", name)
		}
	}

	// The ARTIFACT digest covers the authority the body digest cannot. Swapping the
	// signature alone -- same facts, different signer -- must change the content address,
	// or a reference pinning it would not pin which authority was accepted.
	c := validCompiledAssignment(t, base)
	body := CompiledAssignmentBodyDigest(c)
	artifact := CompiledAssignmentArtifactDigest(c)
	c.CollectionCapability.Signature = append([]byte{}, c.GetCollectionCapability().GetSignature()...)
	c.CollectionCapability.Signature[0] ^= 0xFF
	if !bytes.Equal(body, CompiledAssignmentBodyDigest(c)) {
		t.Fatal("body digest must NOT cover the signature: a signature cannot cover itself")
	}
	if bytes.Equal(artifact, CompiledAssignmentArtifactDigest(c)) {
		t.Fatal("artifact digest ignores the signature: it is a body digest, not a content address")
	}

	// The two digests are separately domained, so neither can be presented as the other.
	if bytes.Equal(CompiledAssignmentBodyDigest(c), CompiledAssignmentArtifactDigest(c)) {
		t.Fatal("body and artifact digests collide")
	}
}

// TestVerifyCompiledAssignmentWithTrust is the REAL authentication proof. Structural
// validation cannot verify a signature, so this pins that a forged one is rejected by
// the trust-aware path.
func TestVerifyCompiledAssignmentWithTrust(t *testing.T) {
	base := validAssignment(t)
	trust := trustBoth(t, KeyValid)

	c := validCompiledAssignment(t, base)
	status, err := VerifyCompiledAssignmentWithTrust(c, trust, 150, 1)
	if err != nil || status != KeyValid {
		t.Fatalf("genuine signature: status=%v err=%v", status, err)
	}

	// A FORGED signature. This is the case the previous revision accepted: a one-byte
	// "sig" satisfied the presence check and nothing ever verified it.
	forged := validCompiledAssignment(t, base)
	forged.CollectionCapability.Signature = []byte("sig")
	forged.CompiledAssignmentSha256 = CompiledAssignmentArtifactDigest(forged)
	if _, err := VerifyCompiledAssignmentWithTrust(forged, trust, 150, 1); !errors.Is(err, ErrCapabilitySignatureInvalid) {
		t.Fatalf("forged signature = %v, want ErrCapabilitySignatureInvalid", err)
	}

	// A signature by an UNTRUSTED issuer is unauthorized, not merely unresolvable.
	wrongIssuer := validCompiledAssignment(t, base)
	wrongIssuer.CollectionCapability.IssuerKeyId = []byte("k2")
	signCompiledAssignment(t, wrongIssuer, mustPrivKey(t))
	if status, _ := VerifyCompiledAssignmentWithTrust(wrongIssuer, trust, 150, 1); status == KeyValid {
		t.Fatal("an untrusted issuer key must never resolve KeyValid")
	}

	// A structural failure must NOT surface as a key verdict.
	broken := validCompiledAssignment(t, base)
	broken.ConfigGeneration = 0
	if status, err := VerifyCompiledAssignmentWithTrust(broken, trust, 150, 1); status != KeyUnavailable || err == nil {
		t.Fatalf("structural failure = (%v, %v), want (KeyUnavailable, error)", status, err)
	}
}

func mustPrivKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(200 - i)
	}
	return ed25519.NewKeyFromSeed(seed)
}

// TestCollectionIsConstrainedToTheLease pins the P0 the earlier revision missed: the
// carrier window and the lease were unrelated quantities.
func TestCollectionIsConstrainedToTheLease(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()

	// Control: the fixture's carrier ends exactly at the lease and is accepted, so the
	// rejection below cannot be a fixture artifact.
	if err := ValidateAssignmentAgainstCompiled(r, c); err != nil {
		t.Fatalf("carrier ending at the lease: %v", err)
	}

	// A lease that lapses before the carrier's window closes. This is the shape the
	// earlier fixture had -- lease 2, carrier 100..200 -- and it was accepted.
	short := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
	short.LeaseExpiresAtUnixNano = 150
	if err := ValidateAssignmentAgainstCompiled(short, c); !errors.Is(err, ErrCompiledAssignmentLease) {
		t.Fatalf("carrier outliving the lease = %v, want ErrCompiledAssignmentLease", err)
	}
}

// planBoundAssignment builds a record that genuinely RELATES to a committed plan, plus
// that plan. The authorization boundary validates the record against the plan, so a
// fixture whose range is absent from any plan would make that check unreachable.
func planBoundAssignment(t *testing.T) (*edgev1.SweepAssignmentRecordV1, *edgev1.ScheduledPlanHeaderV1, []*edgev1.ScheduledPlanPageV1) {
	t.Helper()
	h, pages := buildPlan(t, mustUUID(t), d32(0x77), [][]uint64{{256}})
	rng := pages[0].GetRanges()[0]
	r := validAssignment(t)
	r.ExecutionPlanId = h.GetExecutionPlanId()
	r.ExecutionPlanSha256 = h.GetExecutionPlanSha256()
	r.CheckSetSha256 = h.GetCheckSetSha256()
	r.AvailabilityPolicyId = h.GetAvailabilityPolicyId()
	r.NetworkScopeId = h.GetNetworkScopeId()
	r.TargetRangeId = rng.GetRangeId()
	r.TargetRangeSha256 = rng.GetRangeSha256()
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
	if err := ValidateAssignmentAgainstPlan(r, h, pages); err != nil {
		t.Fatalf("fixture must relate to its plan: %v", err)
	}
	return r, h, pages
}

// testAssignmentAuthority answers ONLY for the key it expects, and reports the key it was
// actually asked about. It does NOT echo blindly: a resolver that mirrors whatever it
// receives makes an echo test self-fulfilling, so deleting or misbuilding a key member
// would stay green.
type testAssignmentAuthority struct {
	want     AssignmentKey
	rec      AuthoritativeAssignment
	echoKey  *AssignmentKey
	statusOv *AssignmentAuthorityStatus
	asked    *AssignmentKey
}

func (a *testAssignmentAuthority) ResolveAssignment(key AssignmentKey) AuthoritativeAssignment {
	*a.asked = key
	out := a.rec
	// The REQUEST is checked here, which is what makes the key derivation observable: a
	// boundary that asked under the wrong key gets nothing back.
	if !key.equal(a.want) {
		return AuthoritativeAssignment{Status: AssignmentAuthorityUnknown, Key: key}
	}
	out.Key = key
	if a.echoKey != nil {
		out.Key = *a.echoKey
	}
	if a.statusOv != nil {
		out.Status = *a.statusOv
	}
	return out
}

// testSession is a stand-in for the transport. It holds its OWN attested identity, set
// independently of the record, so a test cannot accidentally prove the identity by
// restating the record.
type testSession struct {
	networkScopeID []byte
	agentID        []byte
	unattested     bool
}

func (s testSession) AuthorizeAgent(networkScopeID, agentID []byte) CallerVerdict {
	if s.unattested {
		return CallerUnattested
	}
	if bytes.Equal(s.networkScopeID, networkScopeID) && bytes.Equal(s.agentID, agentID) {
		return CallerMatches
	}
	return CallerMismatch
}

// authoritativeFor is the case where authority holds exactly the presented record.
func authoritativeFor(
	t *testing.T,
	r *edgev1.SweepAssignmentRecordV1,
	h *edgev1.ScheduledPlanHeaderV1,
	pages []*edgev1.ScheduledPlanPageV1,
) AuthoritativeAssignment {
	t.Helper()
	return AuthoritativeAssignment{
		Status:        AssignmentAuthorityResolved,
		Record:        proto.Clone(r).(*edgev1.SweepAssignmentRecordV1),
		PlanHeaderRaw: headerBytes(t, h),
		PlanPagesRaw:  rawPages(t, pages),
	}
}

// validCollectionAuthority is a fully-resolved authority context. Every field is set
// deliberately, because the zero value of each one must refuse.
func validCollectionAuthority(
	t *testing.T,
	r *edgev1.SweepAssignmentRecordV1,
	h *edgev1.ScheduledPlanHeaderV1,
	pages []*edgev1.ScheduledPlanPageV1,
	now int64,
) (CollectionAuthority, *AssignmentKey) {
	t.Helper()
	asked := &AssignmentKey{}
	return CollectionAuthority{
		Trust: trustBoth(t, KeyValid),
		Assignments: &testAssignmentAuthority{
			want:  assignmentKeyForTest(r),
			rec:   authoritativeFor(t, r, h, pages),
			asked: asked,
		},
		Session:           testSession{networkScopeID: r.GetNetworkScopeId(), agentID: r.GetAuthenticatedAgentId()},
		NowUnixNano:       now,
		TrustEpoch:        1,
		ExecutionGrantRaw: grantBytes(t, executionGrant(t, r, validCompiledAssignment(t, r))),
	}, asked
}

// assignmentKeyForTest mirrors the FROZEN structured key so a test can state it
// independently of the implementation that derives it.
func assignmentKeyForTest(r *edgev1.SweepAssignmentRecordV1) AssignmentKey {
	return AssignmentKey{
		NetworkScopeID:       r.GetNetworkScopeId(),
		AuthenticatedAgentID: r.GetAuthenticatedAgentId(),
		ProducerAssignmentID: r.GetProducerAssignmentId(),
	}
}

// TestAuthorizeCollectionNow pins the CURRENT-AUTHORITY boundary. Each case below was
// ADMITTED by the earlier window-only check, which is why the boundary is now a single
// composed function rather than a structural check a caller could mistake for one.
//
//nolint:gocyclo // one branch per authorization rule; the cases are the specification
func TestAuthorizeCollectionNow(t *testing.T) {
	r, h, pages := planBoundAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	const now = 150

	base, asked := validCollectionAuthority(t, r, h, pages, now)
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), base); err != nil {
		t.Fatalf("fully authorized: %v", err)
	}
	// THE KEY THE BOUNDARY ASKED UNDER is the frozen structured tuple, derived from the
	// record. Asserting the REQUEST is what makes the derivation observable; a resolver
	// that echoed whatever it received could not tell a correct key from a truncated one.
	if !asked.equal(assignmentKeyForTest(r)) {
		t.Fatalf("boundary asked under %+v, want the (network scope, agent, assignment) tuple", *asked)
	}
	for name, wrong := range map[string]AssignmentKey{
		"missing network scope": {AuthenticatedAgentID: r.GetAuthenticatedAgentId(), ProducerAssignmentID: r.GetProducerAssignmentId()},
		"missing agent":         {NetworkScopeID: r.GetNetworkScopeId(), ProducerAssignmentID: r.GetProducerAssignmentId()},
		"missing assignment":    {NetworkScopeID: r.GetNetworkScopeId(), AuthenticatedAgentID: r.GetAuthenticatedAgentId()},
	} {
		if asked.equal(wrong) {
			t.Fatalf("the derived key must not be satisfiable by a partial tuple (%s)", name)
		}
	}

	// (1) FORGED SIGNATURE with the artifact digest RESEALED, so every structural check
	// passes and only real verification can refuse it.
	forged := validCompiledAssignment(t, r)
	forged.CollectionCapability.Signature = []byte("sig")
	forged.CompiledAssignmentSha256 = CompiledAssignmentArtifactDigest(forged)
	fr := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
	fr.CompiledAssignmentSha256 = forged.GetCompiledAssignmentSha256()
	if err := AuthorizeCollectionNow(fr, carrierBytes(t, forged), mustAuthority(t, fr, h, pages, now)); err == nil {
		t.Fatal("a forged signature with a resealed artifact digest must not authorize")
	}

	// (2) COMPROMISE-REVOKED key. The signature verifies -- it was valid when made -- so
	// only an explicit "exactly KeyValid" rule refuses it.
	// The CARRIER key's typed statuses, each distinguished. "Not KeyValid" would conflate an
	// unauthorized key with an unresolvable lookup, which demand different handling.
	for _, st := range []KeyStatus{KeyHistoricallyRevoked, KeyInvalid, KeyUnavailable} {
		bad := mustAuthority(t, r, h, pages, now)
		bad.Trust = withPerKey(t, map[string]KeyStatus{"k1": st})
		gotStatus, gotErr := VerifyCompiledAssignmentWithTrust(c, bad.Trust, now, 1)
		switch st {
		case KeyHistoricallyRevoked:
			if gotErr != nil || gotStatus != KeyHistoricallyRevoked {
				t.Fatalf("revoked carrier key: status=%v err=%v", gotStatus, gotErr)
			}
		case KeyInvalid:
			if !errors.Is(gotErr, ErrCapabilityKeyUnresolved) || gotStatus != KeyInvalid {
				t.Fatalf("unauthorized carrier key = (%v, %v), want (KeyInvalid, ErrCapabilityKeyUnresolved)", gotStatus, gotErr)
			}
		case KeyUnavailable:
			if !errors.Is(gotErr, ErrKeyUnavailable) || gotStatus != KeyUnavailable {
				t.Fatalf("unresolvable carrier key = (%v, %v), want (KeyUnavailable, ErrKeyUnavailable)", gotStatus, gotErr)
			}
		case KeyValid:
			t.Fatal("unreachable")
		}
		if err := AuthorizeCollectionNow(r, carrierBytes(t, c), bad); err == nil {
			t.Fatalf("carrier key status %v must not authorize", st)
		}
	}

	revoked := mustAuthority(t, r, h, pages, now)
	revoked.Trust = trustBoth(t, KeyHistoricallyRevoked)
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), revoked); !errors.Is(err, ErrCollectionNotAuthorized) {
		t.Fatalf("revoked key = %v, want ErrCollectionNotAuthorized", err)
	}
	// Control: that same capability still VERIFIES historically, which is the whole reason
	// the two questions are separate functions.
	if status, err := VerifyCompiledAssignmentWithTrust(c, revoked.Trust, now, 1); err != nil || status != KeyHistoricallyRevoked {
		t.Fatalf("historical verification under revocation: status=%v err=%v", status, err)
	}

	// (3) NON-OPEN STATE. A LOST assignment's lease and windows say nothing about the fact
	// that its work must not continue.
	for _, st := range []edgev1.SweepAssignmentState{
		edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_LOST,
		edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_EXPIRED,
		edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_ABORTED,
	} {
		bad := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
		bad.State = st
		if err := AuthorizeCollectionNow(bad, carrierBytes(t, c), mustAuthority(t, bad, h, pages, now)); !errors.Is(err, ErrCollectionNotAuthorized) {
			t.Fatalf("state %v = %v, want ErrCollectionNotAuthorized", st, err)
		}
	}
	// COMPLETED and SUPERSEDED are refused EARLIER, by the record validator: each requires
	// terminal/supersession fields this fixture does not carry. They are asserted as
	// refused-for-some-reason rather than folded into the table above, because claiming
	// ErrCollectionNotAuthorized for them would misstate which layer rejects them.
	for _, st := range []edgev1.SweepAssignmentState{
		edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_COMPLETED,
		edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_SUPERSEDED,
	} {
		bad := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
		bad.State = st
		if err := AuthorizeCollectionNow(bad, carrierBytes(t, c), mustAuthority(t, bad, h, pages, now)); err == nil {
			t.Fatalf("state %v must not authorize collection", st)
		}
	}

	// (4) SUPERSEDED BY SEQUENCE while still nominally OPEN. The series is append-only, so
	// this record stays byte-valid forever; only the record AUTHORITY HOLDS may authorize.
	authWith := func(mutate func(*edgev1.SweepAssignmentRecordV1)) CollectionAuthority {
		a := mustAuthority(t, r, h, pages, now)
		rec := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
		mutate(rec)
		a.Assignments = &testAssignmentAuthority{
			want:  assignmentKeyForTest(r),
			rec:   AuthoritativeAssignment{Status: AssignmentAuthorityResolved, Record: rec, PlanHeaderRaw: headerBytes(t, h), PlanPagesRaw: rawPages(t, pages)},
			asked: &AssignmentKey{},
		}
		return a
	}

	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), authWith(func(x *edgev1.SweepAssignmentRecordV1) {
		x.RecordSequence = r.GetRecordSequence() + 1
	})); !errors.Is(err, ErrCollectionNotAuthorized) {
		t.Fatalf("older OPEN record = %v, want ErrCollectionNotAuthorized", err)
	}

	// (5) A byte-valid OPEN record where authority holds a TERMINAL one. A bare "latest = N"
	// assertion cannot tell these apart.
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), authWith(func(x *edgev1.SweepAssignmentRecordV1) {
		x.State = edgev1.SweepAssignmentState_SWEEP_ASSIGNMENT_STATE_COMPLETED
		x.TerminalBatchSequence = 4
	})); !errors.Is(err, ErrCollectionNotAuthorized) {
		t.Fatalf("OPEN alternative to a terminal record = %v, want ErrCollectionNotAuthorized", err)
	}

	// (6) A fact resolved for ANOTHER assignment (or scope/agent) must not answer here.
	for name, wrongKey := range map[string]AssignmentKey{
		"other assignment": {NetworkScopeID: r.GetNetworkScopeId(), AuthenticatedAgentID: r.GetAuthenticatedAgentId(), ProducerAssignmentID: mustUUID(t)},
		"other agent":      {NetworkScopeID: r.GetNetworkScopeId(), AuthenticatedAgentID: mustUUID(t), ProducerAssignmentID: r.GetProducerAssignmentId()},
		"other scope":      {NetworkScopeID: mustUUID(t), AuthenticatedAgentID: r.GetAuthenticatedAgentId(), ProducerAssignmentID: r.GetProducerAssignmentId()},
	} {
		crossed := mustAuthority(t, r, h, pages, now)
		k := wrongKey
		crossed.Assignments = &testAssignmentAuthority{
			want: assignmentKeyForTest(r), rec: authoritativeFor(t, r, h, pages),
			echoKey: &k, asked: &AssignmentKey{},
		}
		// RETRYABLE, not a refusal: a response about another key is no evidence at all
		// about the assignment we asked for, so it must not become a permanent verdict.
		if err := AuthorizeCollectionNow(r, carrierBytes(t, c), crossed); !errors.Is(err, ErrAssignmentAuthorityUnavailable) {
			t.Fatalf("%s echo = %v, want ErrAssignmentAuthorityUnavailable", name, err)
		}
	}

	// (7) ANY divergence from the authoritative record, not just the fields a projection
	// happened to list. availability_policy_id, mtr_expectation and authored_at were all
	// unconstrained under the old selective projection; whole-message equality covers them
	// and every field added later.
	for name, mutate := range map[string]func(*edgev1.SweepAssignmentRecordV1){
		"lease id":            func(x *edgev1.SweepAssignmentRecordV1) { x.LeaseId = []byte("lease-other") },
		"fence token":         func(x *edgev1.SweepAssignmentRecordV1) { x.FenceToken = 99 },
		"epoch":               func(x *edgev1.SweepAssignmentRecordV1) { x.AssignmentEpoch = 99 },
		"carrier id":          func(x *edgev1.SweepAssignmentRecordV1) { x.CompiledAssignmentId = mustUUID(t) },
		"carrier hash":        func(x *edgev1.SweepAssignmentRecordV1) { x.CompiledAssignmentSha256 = d32(0xEE) },
		"availability policy": func(x *edgev1.SweepAssignmentRecordV1) { x.AvailabilityPolicyId = []byte("policy-other") },
		"authored at":         func(x *edgev1.SweepAssignmentRecordV1) { x.AuthoredAtUnixNano = 2 },
		"mtr expectation": func(x *edgev1.SweepAssignmentRecordV1) {
			x.MtrExpectation.OrdinalCount = r.GetMtrExpectation().GetOrdinalCount() + 1
		},
		"run id":          func(x *edgev1.SweepAssignmentRecordV1) { x.RunId = mustUUID(t) },
		"contract bundle": func(x *edgev1.SweepAssignmentRecordV1) { x.ContractBundleSha256 = d32(0xEE) },
	} {
		if err := AuthorizeCollectionNow(r, carrierBytes(t, c), authWith(mutate)); err == nil {
			t.Fatalf("authoritative %s divergence must not authorize", name)
		}
	}

	// THE COMMITTED PLAN. A record, carrier and source capability can all agree on a range
	// the plan does not contain; only validating against the plan notices.
	strandedPlan := mustAuthority(t, r, h, pages, now)
	otherHeader, otherPages := buildPlan(t, mustUUID(t), d32(0x78), [][]uint64{{256}})
	strandedPlan.Assignments = &testAssignmentAuthority{
		want: assignmentKeyForTest(r),
		rec: AuthoritativeAssignment{
			Status: AssignmentAuthorityResolved,
			Record: proto.Clone(r).(*edgev1.SweepAssignmentRecordV1),
			// A VALID plan that simply is not this record's plan.
			PlanHeaderRaw: headerBytes(t, otherHeader), PlanPagesRaw: rawPages(t, otherPages),
		},
		asked: &AssignmentKey{},
	}
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), strandedPlan); err == nil {
		t.Fatal("a range absent from the committed plan must not authorize")
	}
	// And an ABSENT plan is not a pass.
	noPlan := mustAuthority(t, r, h, pages, now)
	noPlan.Assignments = &testAssignmentAuthority{
		want:  assignmentKeyForTest(r),
		rec:   AuthoritativeAssignment{Status: AssignmentAuthorityResolved, Record: proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)},
		asked: &AssignmentKey{},
	}
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), noPlan); err == nil {
		t.Fatal("an absent committed plan must not authorize")
	}

	// THE ECHO IS CHECKED BEFORE THE STATUS. An "unknown assignment" answer that carries a
	// DIFFERENT key is not proof the requested assignment is absent -- reading status first
	// would convert an answer to another question into a permanent rejection.
	foreignUnknown := mustAuthority(t, r, h, pages, now)
	foreignKey := AssignmentKey{
		NetworkScopeID: r.GetNetworkScopeId(), AuthenticatedAgentID: r.GetAuthenticatedAgentId(),
		ProducerAssignmentID: mustUUID(t),
	}
	unknownSt := AssignmentAuthorityUnknown
	foreignUnknown.Assignments = &testAssignmentAuthority{
		want: assignmentKeyForTest(r), rec: authoritativeFor(t, r, h, pages),
		echoKey: &foreignKey, statusOv: &unknownSt, asked: &AssignmentKey{},
	}
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), foreignUnknown); !errors.Is(err, ErrAssignmentAuthorityUnavailable) {
		t.Fatalf("cross-key unknown = %v, want ErrAssignmentAuthorityUnavailable (never permanent)", err)
	}

	// TYPED OUTCOMES stay distinct: an outage is retryable, an unknown assignment permanent.
	for _, tc := range []struct {
		name string
		st   AssignmentAuthorityStatus
		want error
	}{
		{"unavailable", AssignmentAuthorityUnavailable, ErrAssignmentAuthorityUnavailable},
		{"unknown", AssignmentAuthorityUnknown, ErrAssignmentAuthorityUnknown},
	} {
		a := mustAuthority(t, r, h, pages, now)
		st := tc.st
		a.Assignments = &testAssignmentAuthority{
			want: assignmentKeyForTest(r), rec: authoritativeFor(t, r, h, pages),
			statusOv: &st, asked: &AssignmentKey{},
		}
		if err := AuthorizeCollectionNow(r, carrierBytes(t, c), a); !errors.Is(err, tc.want) {
			t.Fatalf("%s = %v, want %v", tc.name, err, tc.want)
		}
	}

	// (8) THE CALLER. Everything above proves the scheduler NAMED an agent; none of it
	// proves that agent is the one asking.
	for name, mutate := range map[string]func(*CollectionAuthority){
		"unattested session": func(a *CollectionAuthority) { a.Session = testSession{unattested: true} },
		"session attests another agent": func(a *CollectionAuthority) {
			a.Session = testSession{networkScopeID: r.GetNetworkScopeId(), agentID: mustUUID(t)}
		},
		"session attests another scope": func(a *CollectionAuthority) {
			a.Session = testSession{networkScopeID: mustUUID(t), agentID: r.GetAuthenticatedAgentId()}
		},
	} {
		bad := mustAuthority(t, r, h, pages, now)
		mutate(&bad)
		if err := AuthorizeCollectionNow(r, carrierBytes(t, c), bad); !errors.Is(err, ErrCollectionNotAuthorized) {
			t.Fatalf("%s = %v, want ErrCollectionNotAuthorized", name, err)
		}
	}

	// (9) THE COMPOSED EXECUTION GRANT. These facts are not covered by the scheduler's
	// carrier, so without composing the execution grant they were unconstrained.
	for name, mutate := range map[string]func(*edgev1.SweepAssignmentRecordV1){
		"run id":           func(x *edgev1.SweepAssignmentRecordV1) { x.RunId = mustUUID(t) },
		"production scope": func(x *edgev1.SweepAssignmentRecordV1) { x.ProductionScopeId = mustUUID(t) },
		"scope digest":     func(x *edgev1.SweepAssignmentRecordV1) { x.ScopeSha256 = d32(0xEE) },
		"contract bundle":  func(x *edgev1.SweepAssignmentRecordV1) { x.ContractBundleSha256 = d32(0xEE) },
		"source context": func(x *edgev1.SweepAssignmentRecordV1) {
			x.SourceIdentity.ContextId = mustUUID(t)
		},
	} {
		bad := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
		mutate(bad)
		// The authority context is rebuilt from the ORIGINAL record, so authority still
		// attests the original facts -- exactly the substitution the grant must catch.
		auth := mustAuthority(t, r, h, pages, now)
		auth.Assignments = &testAssignmentAuthority{want: assignmentKeyForTest(bad), rec: authoritativeFor(t, bad, h, pages), asked: &AssignmentKey{}}
		auth.Session = testSession{networkScopeID: bad.GetNetworkScopeId(), agentID: bad.GetAuthenticatedAgentId()}
		if err := AuthorizeCollectionNow(bad, carrierBytes(t, c), auth); err == nil {
			t.Fatalf("substituted %s must not authorize", name)
		}
	}

	// (10) A COMPROMISE-REVOKED PRODUCER key. The carrier's own key is still valid, so the
	// scheduler step passes and ONLY the grant's "exactly KeyValid" rule refuses this. Each
	// producer role is checked separately, since either key can be revoked independently.
	for _, keyID := range []string{"host-exec-1"} {
		revokedProducer := mustAuthority(t, r, h, pages, now)
		revokedProducer.Trust = withPerKey(t, map[string]KeyStatus{keyID: KeyHistoricallyRevoked})
		if err := AuthorizeCollectionNow(r, carrierBytes(t, c), revokedProducer); !errors.Is(err, ErrCollectionNotAuthorized) {
			t.Fatalf("revoked %s = %v, want ErrCollectionNotAuthorized", keyID, err)
		}
	}

	// Missing execution grant refuses, even with everything else resolved.
	noGrant := mustAuthority(t, r, h, pages, now)
	noGrant.ExecutionGrantRaw = nil
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), noGrant); err == nil {
		t.Fatal("absent execution grant must not authorize")
	}

	// Every UNRESOLVED input refuses, so a forgotten lookup cannot authorize.
	for name, mutate := range map[string]func(*CollectionAuthority){
		"nil trust":           func(a *CollectionAuthority) { a.Trust = nil },
		"typed-nil trust":     func(a *CollectionAuthority) { a.Trust = (*nilTrustProbe)(nil) },
		"nil authority":       func(a *CollectionAuthority) { a.Assignments = nil },
		"typed-nil authority": func(a *CollectionAuthority) { a.Assignments = (*nilAuthorityProbe)(nil) },
		"nil session":         func(a *CollectionAuthority) { a.Session = nil },
		"typed-nil session":   func(a *CollectionAuthority) { a.Session = (*nilSessionProbe)(nil) },
	} {
		auth := mustAuthority(t, r, h, pages, now)
		mutate(&auth)
		if err := AuthorizeCollectionNow(r, carrierBytes(t, c), auth); !errors.Is(err, ErrCollectionNotAuthorized) {
			t.Fatalf("%s = %v, want ErrCollectionNotAuthorized", name, err)
		}
	}

	// The clock still bounds it, at both ends and on the lease.
	// Outside the windows, collection is refused. WHICH error surfaces depends on the
	// narrowest window that excludes the instant, so these assert refusal rather than
	// claiming a specific layer rejects first.
	for _, at := range []int64{99, 200, 500} {
		if err := AuthorizeCollectionNow(r, carrierBytes(t, c), mustAuthority(t, r, h, pages, at)); err == nil {
			t.Fatalf("at %d must not authorize", at)
		}
	}
	// THE CARRIER'S OWN WINDOW IN ISOLATION. Widening the grant is not enough: the carrier
	// window and the collection capability's window coincide in the fixture, so a mutation
	// deleting the carrier-window check alone stayed green. Here the COLLECTION CAPABILITY is
	// widened past the carrier and the lease is pushed out, leaving c.not_before/expires as
	// the only bound that excludes the instant.
	{
		narrowCarrier := validCompiledAssignment(t, r)
		narrowCarrier.ExpiresAtUnixNano = 160
		narrowCarrier.CollectionCapability.ExpiresAtUnixNano = 10_000
		signCompiledAssignment(t, narrowCarrier, mustCompiledPriv(t))
		cr := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
		cr.CompiledAssignmentSha256 = narrowCarrier.GetCompiledAssignmentSha256()
		cr.LeaseExpiresAtUnixNano = 10_000
		wideGrant := executionGrant(t, cr, narrowCarrier)
		wideGrant.ExpiresAtUnixNano = 10_000
		wideGrant.GetAssignmentExecution().CollectionExpiresUnixNano = 10_000
		a := mustAuthority(t, cr, h, pages, 170)
		a.ExecutionGrantRaw = grantBytes(t, resign(t, wideGrant))
		if err := AuthorizeCollectionNow(cr, carrierBytes(t, narrowCarrier), a); !errors.Is(err, ErrCollectionNotAuthorized) {
			t.Fatalf("carrier window alone = %v, want ErrCollectionNotAuthorized", err)
		}
	}

	// THE CARRIER CLOCK IN ISOLATION: widen the grant so it cannot be the rejecting
	// layer, leaving only the carrier/collection-capability/lease windows.
	for _, at := range []int64{99, 200} {
		wide := mustAuthority(t, r, h, pages, at)
		wideGrant := executionGrant(t, r, c)
		wideGrant.NotBeforeUnixNano = 1
		wideGrant.ExpiresAtUnixNano = 10_000
		wideGrant.GetAssignmentExecution().CollectionNotBeforeUnixNano = 1
		wideGrant.GetAssignmentExecution().CollectionExpiresUnixNano = 10_000
		wide.ExecutionGrantRaw = grantBytes(t, resign(t, wideGrant))
		if err := AuthorizeCollectionNow(r, carrierBytes(t, c), wide); !errors.Is(err, ErrCollectionNotAuthorized) {
			t.Fatalf("carrier clock at %d = %v, want ErrCollectionNotAuthorized", at, err)
		}
	}

	// The NARROWEST window governs: narrow the CAPABILITY and re-seal.
	narrow := validCompiledAssignment(t, r)
	narrow.ExpiresAtUnixNano = 160
	narrow.CollectionCapability.ExpiresAtUnixNano = 160
	signCompiledAssignment(t, narrow, mustCompiledPriv(t))
	nr := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
	nr.CompiledAssignmentSha256 = narrow.GetCompiledAssignmentSha256()
	// A narrowed carrier is a DIFFERENT artifact, so it needs its OWN grant: the grant binds
	// the exact artifact digest, which is what makes it non-reusable across revisions.
	narrowAuth := mustAuthority(t, nr, h, pages, 170)
	narrowAuth.ExecutionGrantRaw = grantBytes(t, executionGrant(t, nr, narrow))
	if err := AuthorizeCollectionNow(nr, carrierBytes(t, narrow), narrowAuth); !errors.Is(err, ErrCollectionNotAuthorized) {
		t.Fatalf("past the narrowed window = %v, want ErrCollectionNotAuthorized", err)
	}

	// HISTORICAL verification remains possible long after authorization lapsed -- that is
	// what makes an archived record re-checkable.
	if status, err := VerifyCompiledAssignmentWithTrust(c, trustBoth(t, KeyValid), 10_000, 1); err != nil || status != KeyValid {
		t.Fatalf("historical verification after expiry: status=%v err=%v", status, err)
	}
}

// nilTrustProbe exists only to build a TYPED NIL CapabilityTrust -- a non-nil interface
// boxing a nil pointer, which a bare `== nil` check would let through.
type nilTrustProbe struct{}

func (*nilTrustProbe) ResolveKey([]byte, []byte, KeyEvidence) KeyResolution {
	panic("a typed-nil trust must be refused before it is ever called")
}

// nilAuthorityProbe is the same typed-nil trap for AssignmentAuthority.
type nilAuthorityProbe struct{}

func (*nilAuthorityProbe) ResolveAssignment(AssignmentKey) AuthoritativeAssignment {
	panic("a typed-nil assignment authority must be refused before it is ever called")
}

func mustCompiledPriv(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, priv := compiledTestKey(t)
	return priv
}

// executionGrant builds the VERIFIED ASSIGNMENT_EXECUTION grant for a record + carrier.
// Every member is populated, because the claim is validated in full: an omitted member
// would be a fact nothing enforces.
func executionGrant(
	t *testing.T, r *edgev1.SweepAssignmentRecordV1, c *edgev1.CompiledSweepAssignmentV1,
) *edgev1.EdgeSignedCapabilityV1 {
	t.Helper()
	j := &edgev1.EdgeAssignmentExecutionClaimsV1{
		Purpose:              edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION,
		NetworkScopeId:       r.GetNetworkScopeId(),
		AuthenticatedAgentId: r.GetAuthenticatedAgentId(),
		ProducerAssignmentId: r.GetProducerAssignmentId(),
		ExecutionId:          r.GetExecutionId(),
		RunId:                r.GetRunId(),
		RunShard:             r.GetExecutionShard(),
		AuthorityEpoch:       r.GetAssignmentEpoch(),
		ProductionScopeId:    r.GetProductionScopeId(),
		ScopeSha256:          r.GetScopeSha256(),
		ContractBundleSha256: r.GetContractBundleSha256(),
		ExecutionPlanSha256:  r.GetExecutionPlanSha256(),
		TargetRangeSha256:    r.GetTargetRangeSha256(),
		TrafficClass:         c.GetTrafficClass(),
		// A REAL collection window; 0..0 would be refused.
		CollectionNotBeforeUnixNano: 100,
		CollectionExpiresUnixNano:   200,
		// THE EXACT CARRIER: this grant permits one revision, not a floating set of facts.
		CompiledAssignmentId:     c.GetCompiledAssignmentId(),
		CompiledAssignmentSha256: c.GetCompiledAssignmentSha256(),
	}
	if id := r.GetSourceIdentity(); id != nil {
		j.SourceIdentity = proto.Clone(id).(*edgev1.EdgeSourceSpanIdentityV1)
	}
	cap := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: []byte("host"), IssuerKeyId: []byte("host-exec-1"),
		Algorithm: "ed25519", NotBeforeUnixNano: 100, ExpiresAtUnixNano: 200,
		Claims: &edgev1.EdgeSignedCapabilityV1_AssignmentExecution{AssignmentExecution: j},
	}
	SignCapability(cap, mustHostPriv(t))
	return cap
}

// resign re-seals a mutated capability so the signature stays genuine and ONLY the rule
// under test can refuse it. An unsigned mutation would be killed by verification instead.
func resign(t *testing.T, cap *edgev1.EdgeSignedCapabilityV1) *edgev1.EdgeSignedCapabilityV1 {
	t.Helper()
	// Re-signed with the key matching its ROLE, so a mutation test never accidentally proves
	// the wrong thing by signing an execution grant with the scheduler key.
	if CapabilityPurpose(cap) == edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION {
		SignCapability(cap, mustHostPriv(t))
	} else {
		SignCapability(cap, mustCompiledPriv(t))
	}
	return cap
}

func mustHostPriv(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, priv := hostTestKey(t)
	return priv
}

// TestVerifyAssignmentExecutionGrant pins that execution permission is bound to
// AUTHENTICATED authority, with EVERY claim member interpreted.
func TestVerifyAssignmentExecutionGrant(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	// The verifier validates the record/carrier RELATION itself, so the reference must bind.
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	trust := trustBoth(t, KeyValid)
	cap := executionGrant(t, r, c)

	status, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), grantBytes(t, cap), trust, 150, 1)
	if err != nil || status != KeyValid {
		t.Fatalf("verified grant: status=%v err=%v", status, err)
	}

	// EVERY claim member. A member the signature covers but nothing compares is a fact
	// under no constraint -- which is exactly how a grant for one traffic class came to
	// authorize another.
	for name, mutate := range map[string]func(*edgev1.EdgeAssignmentExecutionClaimsV1){
		"purpose": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.Purpose = edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION
		},
		"network scope":       func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.NetworkScopeId = mustUUID(t) },
		"agent":               func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.AuthenticatedAgentId = mustUUID(t) },
		"producer assignment": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ProducerAssignmentId = mustUUID(t) },
		"execution id":        func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ExecutionId = mustUUID(t) },
		"run id":              func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.RunId = mustUUID(t) },
		"run shard":           func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.RunShard = 99 },
		"authority epoch":     func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.AuthorityEpoch = 99 },
		"production scope":    func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ProductionScopeId = mustUUID(t) },
		"scope digest":        func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ScopeSha256 = d32(0xEE) },
		"contract bundle":     func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ContractBundleSha256 = d32(0xEE) },
		"plan digest":         func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ExecutionPlanSha256 = d32(0xEE) },
		"range digest":        func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.TargetRangeSha256 = d32(0xEE) },
		"absent plan digest":  func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ExecutionPlanSha256 = nil },
		"absent range digest": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.TargetRangeSha256 = nil },
		// THE TRAFFIC CLASS. A capability for INTERACTIVE must not authorize a BULK carrier.
		"traffic class": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.TrafficClass = edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE
		},
		"unknown traffic class": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.TrafficClass = edgev1.EdgeRecordTrafficClass(99)
		},
		"collection window unset": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.CollectionNotBeforeUnixNano, x.CollectionExpiresUnixNano = 0, 0
		},
		"collection window proto-default start": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.CollectionNotBeforeUnixNano, x.CollectionExpiresUnixNano = 0, 1000
		},
		"collection window inverted": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.CollectionNotBeforeUnixNano, x.CollectionExpiresUnixNano = 200, 100
		},
		"collection window expired": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.CollectionExpiresUnixNano = 149
		},
		"collection window not yet open": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.CollectionNotBeforeUnixNano = 151
		},
		"source kind": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.SourceIdentity.Kind = edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP
		},
		"source context":      func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.SourceIdentity.ContextId = mustUUID(t) },
		"source scope":        func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.SourceIdentity.SourceScopeId = mustUUID(t) },
		"source scope digest": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.SourceIdentity.SourceScopeSha256 = d32(0xEE) },
		"source identity absent": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.SourceIdentity = nil
		},
	} {
		bad := proto.Clone(cap).(*edgev1.EdgeSignedCapabilityV1)
		mutate(bad.GetAssignmentExecution())
		if _, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), grantBytes(t, resign(t, bad)), trust, 150, 1); err == nil {
			t.Fatalf("%s mismatch must be refused", name)
		}
	}

	// PRESENT IFF PRESENT, the other direction: no source identity on the record, but the
	// claim asserts one.
	noID := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
	noID.SourceIdentity = nil
	if _, err := VerifyAssignmentExecutionGrant(noID, carrierBytes(t, c), grantBytes(t, cap), trust, 150, 1); !errors.Is(err, ErrAssignmentExecutionGrantBinding) {
		t.Fatalf("identity absent but claimed = %v, want ErrAssignmentExecutionGrantBinding", err)
	}
	// ABSENT/ABSENT is the one legal symmetry.
	if _, err := VerifyAssignmentExecutionGrant(noID, carrierBytes(t, c), grantBytes(t, executionGrant(t, noID, c)), trust, 150, 1); err != nil {
		t.Fatalf("both absent must be accepted: %v", err)
	}

	// THE ENVELOPE must be CURRENT, isolated from the claim's own window so each is proven
	// separately.
	for name, mutate := range map[string]func(*edgev1.EdgeSignedCapabilityV1){
		"envelope not yet valid": func(x *edgev1.EdgeSignedCapabilityV1) {
			x.NotBeforeUnixNano, x.ExpiresAtUnixNano = 151, 300
		},
		// Exactly AT expiry: the window is half-open, so this instant is already outside.
		"envelope expires exactly now": func(x *edgev1.EdgeSignedCapabilityV1) {
			x.ExpiresAtUnixNano = 150
		},
		"envelope expired": func(x *edgev1.EdgeSignedCapabilityV1) { x.ExpiresAtUnixNano = 149 },
	} {
		bad := proto.Clone(cap).(*edgev1.EdgeSignedCapabilityV1)
		mutate(bad)
		if _, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), grantBytes(t, resign(t, bad)), trust, 150, 1); !errors.Is(err, ErrAssignmentExecutionGrantBinding) {
			t.Fatalf("%s = %v, want ErrAssignmentExecutionGrantBinding", name, err)
		}
	}
	// Control: the SAME expired capability still verifies HISTORICALLY inside its old
	// window, which is why freshness must be enforced separately.
	expired := proto.Clone(cap).(*edgev1.EdgeSignedCapabilityV1)
	expired.ExpiresAtUnixNano = 149
	expired.GetAssignmentExecution().CollectionExpiresUnixNano = 149
	if status, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), grantBytes(t, resign(t, expired)), trust, 120, 1); err != nil || status != KeyValid {
		t.Fatalf("historical verification inside the old window: status=%v err=%v", status, err)
	}

	// A capability of the WRONG ROLE cannot stand in.
	if _, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), grantBytes(t, c.GetCollectionCapability()), trust, 150, 1); !errors.Is(err, ErrCapabilityPurpose) {
		t.Fatalf("collection capability in the grant position = %v, want ErrCapabilityPurpose", err)
	}
	// ABSENT grant bytes decode to an empty capability, whose role is UNSPECIFIED -- so the
	// role check reports it, which is the more precise answer.
	if _, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), nil, trust, 150, 1); !errors.Is(err, ErrCapabilityPurpose) {
		t.Fatalf("absent execution grant = %v, want ErrCapabilityPurpose", err)
	}
	if _, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), grantBytes(t, cap), nil, 150, 1); !errors.Is(err, ErrAssignmentExecutionGrantBinding) {
		t.Fatalf("nil trust = %v, want ErrAssignmentExecutionGrantBinding", err)
	}
	forged := proto.Clone(cap).(*edgev1.EdgeSignedCapabilityV1)
	forged.Signature = []byte("sig")
	if _, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), grantBytes(t, forged), trust, 150, 1); !errors.Is(err, ErrCapabilitySignatureInvalid) {
		t.Fatalf("forged signature = %v, want ErrCapabilitySignatureInvalid", err)
	}
}

// TestVerifyExecutionGrantPreservesTypedStatus pins that the execution grant's TYPED key
// status survives. KeyInvalid (unauthorized, permanent) reported as KeyUnavailable
// (retryable) turns a rejection into a retry loop, and the reverse hides an outage.
func TestVerifyExecutionGrantPreservesTypedStatus(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	cap := executionGrant(t, r, c)

	for _, tc := range []struct {
		name       string
		give, want KeyStatus
	}{
		{"unauthorized", KeyInvalid, KeyInvalid},
		{"unresolvable", KeyUnavailable, KeyUnavailable},
	} {
		status, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), grantBytes(t, cap),
			withPerKey(t, map[string]KeyStatus{"host-exec-1": tc.give}), 150, 1)
		if err == nil {
			t.Fatalf("%s: a failed lookup must produce an error", tc.name)
		}
		// EXACTLY the given status, not merely "not KeyValid": the two demand different
		// upstream handling, so a test accepting either would not pin the distinction.
		if status != tc.want {
			t.Fatalf("%s: status = %v, want exactly %v", tc.name, status, tc.want)
		}
	}
}

// TestCompiledAssignmentByteCeiling pins the RECEIVED-BYTE bound. A decoded-struct check
// cannot serve: protobuf lets a known non-repeated field repeat, the decoder keeps the
// last occurrence, and an arbitrarily large encoding collapses to a small struct.
func TestCompiledAssignmentByteCeiling(t *testing.T) {
	c := validCompiledAssignment(t, validAssignment(t))
	raw, err := proto.Marshal(c)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if len(raw) > MaxCompiledAssignmentBytes {
		t.Fatalf("a valid carrier is already over the ceiling: %d", len(raw))
	}
	if _, err := ValidateCompiledSweepAssignmentBytes(raw); err != nil {
		t.Fatalf("valid carrier bytes: %v", err)
	}

	// THE EXACT BOUNDARY. A small-valid plus an unspecified-overshoot pair does not pin
	// the comparison: changing `>` to `>=` survives both. These two differ by ONE byte and
	// straddle the limit, so only `len(raw) > Max` passes them.
	atLimit := padCompiledAssignment(t, c, MaxCompiledAssignmentBytes)
	oneOver := padCompiledAssignment(t, c, MaxCompiledAssignmentBytes+1)

	decodedAt, err := ValidateCompiledSweepAssignmentBytes(atLimit)
	if err != nil {
		t.Fatalf("exactly %d bytes must be ACCEPTED: %v", MaxCompiledAssignmentBytes, err)
	}
	if _, err := ValidateCompiledSweepAssignmentBytes(oneOver); !errors.Is(err, ErrCompiledAssignmentTooLarge) {
		t.Fatalf("%d bytes = %v, want ErrCompiledAssignmentTooLarge", MaxCompiledAssignmentBytes+1, err)
	}

	// Both decode to the SAME message as the small original, and both collapse far below
	// the ceiling on re-encode. That is what makes a decoded-struct check unable to
	// enforce this bound, and it is why the ceiling is measured on received bytes.
	var decodedOver edgev1.CompiledSweepAssignmentV1
	if err := proto.Unmarshal(oneOver, &decodedOver); err != nil {
		t.Fatalf("the one-over vector must still DECODE (it is oversize, not malformed): %v", err)
	}
	if !proto.Equal(decodedAt, c) || !proto.Equal(&decodedOver, c) {
		t.Fatal("padded vectors must decode to the same message as the original")
	}
	if size := proto.Size(&decodedOver); size > MaxCompiledAssignmentBytes {
		t.Fatalf("control failed: the padding did not collapse on re-encode (%d bytes)", size)
	}
}

// padCompiledAssignment returns a valid carrier encoding of EXACTLY `target` bytes.
//
// It works by repeating `check_set_sha256`, a known non-repeated field: the decoder keeps
// the LAST occurrence, so a filler copy followed by the true value decodes identically to
// the unpadded message while inflating the received bytes arbitrarily. Deterministic, so
// the vectors are byte-stable across runs and runtimes.
func padCompiledAssignment(t *testing.T, c *edgev1.CompiledSweepAssignmentV1, target int) []byte {
	t.Helper()
	raw, err := proto.Marshal(c)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// The true value, appended LAST so it wins.
	trueField := protowire.AppendBytes(
		protowire.AppendTag(nil, checkSetSha256Field, protowire.BytesType), c.GetCheckSetSha256())
	// Solve for the filler payload length: tag(1) + len varint + payload.
	fillerTotal := target - len(raw) - len(trueField)
	payloadLen := fillerTotal - 1 - protowire.SizeVarint(uint64(fillerTotal))
	if payloadLen < 0 {
		t.Fatalf("target %d is too small to pad to", target)
	}
	filler := protowire.AppendBytes(
		protowire.AppendTag(nil, checkSetSha256Field, protowire.BytesType), make([]byte, payloadLen))

	out := make([]byte, 0, target)
	out = append(out, raw...)
	out = append(out, filler...)
	out = append(out, trueField...)
	if len(out) != target {
		t.Fatalf("padded to %d bytes, want exactly %d", len(out), target)
	}
	return out
}

// checkSetSha256Field is CompiledSweepAssignmentV1.check_set_sha256's field number, read
// from the descriptor rather than hardcoded so a renumbering cannot silently make the
// padding target a different field.
//
//nolint:gochecknoglobals // immutable descriptor lookup
var checkSetSha256Field = func() protowire.Number {
	fd := (&edgev1.CompiledSweepAssignmentV1{}).ProtoReflect().Descriptor().
		Fields().ByName("check_set_sha256")
	if fd == nil {
		panic("CompiledSweepAssignmentV1.check_set_sha256 missing")
	}
	return fd.Number()
}()

// TestCompiledAssignmentWireNumbersFrozen pins the exact numbers the ABI freezes. A
// symbol-level assertion would pass through a renumbering, which is precisely the
// cross-runtime break these vectors exist to prevent.
func TestCompiledAssignmentWireNumbersFrozen(t *testing.T) {
	if got := int32(edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION); got != 4 {
		t.Fatalf("EDGE_CAPABILITY_PURPOSE_COLLECTION = %d, want 4", got)
	}
	if got := int32(edgev1.SweepResultFormat_SWEEP_RESULT_FORMAT_UNSPECIFIED); got != 0 {
		t.Fatalf("SWEEP_RESULT_FORMAT_UNSPECIFIED = %d, want 0", got)
	}
	if got := int32(edgev1.SweepResultFormat_SWEEP_RESULT_FORMAT_EDGE_RECORDS_V1); got != 1 {
		t.Fatalf("SWEEP_RESULT_FORMAT_EDGE_RECORDS_V1 = %d, want 1", got)
	}
	// The oneof discriminant framed into the signing preimage is the FIELD NUMBER, and
	// `collection` took 11 because `signature` already held 10. A framing that used the
	// switch position instead would silently sign 4.
	if got := int32(edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION); got != 5 {
		t.Fatalf("EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION = %d, want 5", got)
	}
	// EXACT MEMBERSHIP of the other enums this slice freezes. Adding a member to either stayed
	// green with only a single-value assertion, so both use the same descriptor recipe.
	assertExactEnum(t, edgev1.SweepResultFormat(0).Descriptor(), map[int32]string{
		0: "SWEEP_RESULT_FORMAT_UNSPECIFIED",
		1: "SWEEP_RESULT_FORMAT_EDGE_RECORDS_V1",
	})
	assertExactEnum(t, edgev1.SweepAssignmentState(0).Descriptor(), map[int32]string{
		0: "SWEEP_ASSIGNMENT_STATE_UNSPECIFIED",
		1: "SWEEP_ASSIGNMENT_STATE_OPEN",
		2: "SWEEP_ASSIGNMENT_STATE_COMPLETED",
		3: "SWEEP_ASSIGNMENT_STATE_ABORTED",
		4: "SWEEP_ASSIGNMENT_STATE_LOST",
		5: "SWEEP_ASSIGNMENT_STATE_EXPIRED",
		6: "SWEEP_ASSIGNMENT_STATE_SUPERSEDED",
	})
	assertExactEnum(t, edgev1.EdgeCapabilityPurpose(0).Descriptor(), map[int32]string{
		0: "EDGE_CAPABILITY_PURPOSE_UNSPECIFIED",
		1: "EDGE_CAPABILITY_PURPOSE_PRODUCTION",
		2: "EDGE_CAPABILITY_PURPOSE_SOURCE",
		3: "EDGE_CAPABILITY_PURPOSE_DELIVERY",
		4: "EDGE_CAPABILITY_PURPOSE_COLLECTION",
		5: "EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION",
	})

	// The oneof member's FIELD NUMBER, which is the framing discriminant.
	if fd := (&edgev1.EdgeSignedCapabilityV1{}).ProtoReflect().Descriptor().
		Fields().ByName("assignment_execution"); fd == nil || fd.Number() != 12 {
		t.Fatalf("EdgeSignedCapabilityV1.assignment_execution must be field 12, got %v", fd)
	}
	fd := (&edgev1.EdgeSignedCapabilityV1{}).ProtoReflect().Descriptor().Fields().ByName("collection")
	if fd == nil {
		t.Fatal("EdgeSignedCapabilityV1.collection missing")
	}
	if fd.Number() != 11 {
		t.Fatalf("EdgeSignedCapabilityV1.collection = %d, want 11", fd.Number())
	}
}

// mustAuthority is validCollectionAuthority when the asked-key handle is not needed.
func mustAuthority(
	t *testing.T,
	r *edgev1.SweepAssignmentRecordV1,
	h *edgev1.ScheduledPlanHeaderV1,
	pages []*edgev1.ScheduledPlanPageV1,
	now int64,
) CollectionAuthority {
	t.Helper()
	auth, _ := validCollectionAuthority(t, r, h, pages, now)
	return auth
}

// nilSessionProbe is the typed-nil trap for SessionAuthority.
type nilSessionProbe struct{}

func (*nilSessionProbe) AuthorizeAgent([]byte, []byte) CallerVerdict {
	panic("a typed-nil session must be refused before it is ever called")
}

// rawPages encodes plan pages to the RAW bytes the authority contract requires.
func rawPages(t *testing.T, pages []*edgev1.ScheduledPlanPageV1) [][]byte {
	t.Helper()
	out := make([][]byte, 0, len(pages))
	for _, pg := range pages {
		b, err := proto.Marshal(pg)
		if err != nil {
			t.Fatalf("marshal page: %v", err)
		}
		out = append(out, b)
	}
	return out
}

// mutatingAuthority writes through the key it is handed, then returns the ORIGINAL
// authoritative record. This is the sharp form: if the key aliased the message under
// evaluation, the write would corrupt it and the subsequent whole-record comparison would
// FAIL. Authorization SUCCEEDING is therefore the evidence of isolation.
type mutatingAuthority struct {
	rec           AuthoritativeAssignment
	overwriteWith byte
}

func (m mutatingAuthority) ResolveAssignment(key AssignmentKey) AuthoritativeAssignment {
	// Echo a COPY taken before the write, so this case isolates ALIASING: the echo check is
	// satisfied and only a corrupted evaluation message could change the outcome.
	echo := AssignmentKey{
		NetworkScopeID:       append([]byte(nil), key.NetworkScopeID...),
		AuthenticatedAgentID: append([]byte(nil), key.AuthenticatedAgentID...),
		ProducerAssignmentID: append([]byte(nil), key.ProducerAssignmentID...),
	}
	for i := range key.AuthenticatedAgentID {
		key.AuthenticatedAgentID[i] = m.overwriteWith
	}
	for i := range key.NetworkScopeID {
		key.NetworkScopeID[i] = m.overwriteWith
	}
	for i := range key.ProducerAssignmentID {
		key.ProducerAssignmentID[i] = m.overwriteWith
	}
	out := m.rec
	out.Key = echo
	return out
}

// mutatingSession does the same through the session callback's arguments. It runs BEFORE
// the resolver, so a write landing on the evaluated message would break both the echo and
// the record comparison.
type mutatingSession struct{ overwriteWith byte }

func (s mutatingSession) AuthorizeAgent(networkScopeID, agentID []byte) CallerVerdict {
	for i := range agentID {
		agentID[i] = s.overwriteWith
	}
	for i := range networkScopeID {
		networkScopeID[i] = s.overwriteWith
	}
	return CallerMatches
}

// TestAuthorizeCollectionNowIsolatesCallbacksFromValidatedBytes pins that no authority
// callback can reach the bytes under evaluation.
//
// A protobuf bytes field aliases its backing storage, so a key or session argument taken
// straight from the message shares memory with it -- letting a callback overwrite
// authenticated_agent_id AFTER the carrier and capability checks and then return a record
// matching the overwrite.
//
// Two layers enforce this: every callback argument is a COPY, and the boundary evaluates a
// deep-cloned snapshot. The copies are what these cases pin. The snapshot is a second layer
// covering callbacks added later; with the copies in place it is deliberately NOT claimed to
// be individually load-bearing, and a mutation removing it alone does not fail this test.
func TestAuthorizeCollectionNowIsolatesCallbacksFromValidatedBytes(t *testing.T) {
	r, h, pages := planBoundAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	const now = 150

	originalAgent := append([]byte(nil), r.GetAuthenticatedAgentId()...)
	originalScope := append([]byte(nil), r.GetNetworkScopeId()...)

	// Control: with nothing hostile, authorization succeeds -- so the successes below are
	// not vacuous.
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), mustAuthority(t, r, h, pages, now)); err != nil {
		t.Fatalf("control: %v", err)
	}

	hostile := mustAuthority(t, r, h, pages, now)
	hostile.Assignments = mutatingAuthority{
		rec: AuthoritativeAssignment{
			Status: AssignmentAuthorityResolved,
			// The UNCHANGED record: the resolver lies only by mutating its argument.
			Record:        proto.Clone(r).(*edgev1.SweepAssignmentRecordV1),
			PlanHeaderRaw: headerBytes(t, h), PlanPagesRaw: rawPages(t, pages),
		},
		overwriteWith: 0xAB,
	}
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), hostile); err != nil {
		t.Fatalf("a resolver rewriting its key argument must not affect the decision: %v", err)
	}

	hostileSession := mustAuthority(t, r, h, pages, now)
	hostileSession.Session = mutatingSession{overwriteWith: 0xCD}
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), hostileSession); err != nil {
		t.Fatalf("a session rewriting its arguments must not affect the decision: %v", err)
	}

	if !bytes.Equal(r.GetAuthenticatedAgentId(), originalAgent) ||
		!bytes.Equal(r.GetNetworkScopeId(), originalScope) {
		t.Fatal("the caller's record was mutated through a callback argument")
	}
}

// TestAuthorizeCollectionNowBoundsRawPlanPages pins that the PHYSICAL plan-page ceiling is
// established from RAW committed bytes.
//
// ValidateAssignmentAgainstPlan takes DECODED pages and explicitly cannot establish
// MaxPlanPageBytes: a re-marshal collapses duplicate known fields, so an oversize received
// page shrinks to a compliant struct. Only the raw path sees it.
func TestAuthorizeCollectionNowBoundsRawPlanPages(t *testing.T) {
	r, h, pages := planBoundAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	const now = 150

	raw := rawPages(t, pages)
	num := (&edgev1.ScheduledPlanPageV1{}).ProtoReflect().
		Descriptor().Fields().ByName("check_set_sha256").Number()
	trueField := protowire.AppendBytes(
		protowire.AppendTag(nil, num, protowire.BytesType), pages[0].GetCheckSetSha256())
	target := MaxPlanPageBytes + 1
	fillerTotal := target - len(raw[0]) - len(trueField)
	payload := fillerTotal - 1 - protowire.SizeVarint(uint64(fillerTotal))
	if payload < 0 {
		t.Fatalf("cannot pad a page to %d", target)
	}
	bloated := append([]byte(nil), raw[0]...)
	bloated = append(bloated, protowire.AppendBytes(
		protowire.AppendTag(nil, num, protowire.BytesType), make([]byte, payload))...)
	bloated = append(bloated, trueField...)
	if len(bloated) != target {
		t.Fatalf("padded to %d, want %d", len(bloated), target)
	}

	// CONTROL: the oversize bytes decode to the SAME page and collapse far below the ceiling
	// on re-encode, and the DECODED relation accepts them. That is precisely why the raw path
	// has to exist.
	var decoded edgev1.ScheduledPlanPageV1
	if err := proto.Unmarshal(bloated, &decoded); err != nil {
		t.Fatalf("bloated page must still decode: %v", err)
	}
	if !proto.Equal(&decoded, pages[0]) {
		t.Fatal("bloated page must decode to the same page")
	}
	if proto.Size(&decoded) > MaxPlanPageBytes {
		t.Fatal("control failed: the padding did not collapse on re-encode")
	}
	if err := ValidateAssignmentAgainstPlan(r, h, []*edgev1.ScheduledPlanPageV1{&decoded}); err != nil {
		t.Fatalf("control: the decoded relation should accept it: %v", err)
	}

	auth := mustAuthority(t, r, h, pages, now)
	auth.Assignments = &testAssignmentAuthority{
		want: assignmentKeyForTest(r),
		rec: AuthoritativeAssignment{
			Status:        AssignmentAuthorityResolved,
			Record:        proto.Clone(r).(*edgev1.SweepAssignmentRecordV1),
			PlanHeaderRaw: headerBytes(t, h), PlanPagesRaw: [][]byte{bloated},
		},
		asked: &AssignmentKey{},
	}
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), auth); err == nil {
		t.Fatal("an oversize RAW committed page must not authorize")
	}

	// An EMPTY raw page set is not a pass either.
	empty := mustAuthority(t, r, h, pages, now)
	empty.Assignments = &testAssignmentAuthority{
		want: assignmentKeyForTest(r),
		rec: AuthoritativeAssignment{
			Status:        AssignmentAuthorityResolved,
			Record:        proto.Clone(r).(*edgev1.SweepAssignmentRecordV1),
			PlanHeaderRaw: headerBytes(t, h),
		},
		asked: &AssignmentKey{},
	}
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), empty); err == nil {
		t.Fatal("absent raw committed pages must not authorize")
	}
}

// grantBytes encodes an execution grant to the RAW bytes the boundary requires.
func grantBytes(t *testing.T, cap *edgev1.EdgeSignedCapabilityV1) []byte {
	t.Helper()
	b, err := proto.Marshal(cap)
	if err != nil {
		t.Fatalf("marshal grant: %v", err)
	}
	return b
}

// carrierBytes encodes a carrier to the RAW bytes the boundary requires.
func carrierBytes(t *testing.T, c *edgev1.CompiledSweepAssignmentV1) []byte {
	t.Helper()
	b, err := proto.Marshal(c)
	if err != nil {
		t.Fatalf("marshal carrier: %v", err)
	}
	return b
}

// headerBytes encodes a plan header to the RAW bytes the authority contract requires.
func headerBytes(t *testing.T, h *edgev1.ScheduledPlanHeaderV1) []byte {
	t.Helper()
	b, err := proto.Marshal(h)
	if err != nil {
		t.Fatalf("marshal header: %v", err)
	}
	return b
}

// TestAuthorizeCollectionNowEnforcesCarrierByteCeiling pins that the boundary cannot be
// used to bypass the carrier's exact-byte ceiling.
//
// Taking a DECODED carrier was the bypass: a 65 537-byte carrier that
// ValidateCompiledSweepAssignmentBytes rejects decodes to a byte-identical struct, so a
// caller that decoded first got an authorization the raw validator would have refused.
func TestAuthorizeCollectionNowEnforcesCarrierByteCeiling(t *testing.T) {
	r, h, pages := planBoundAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	const now = 150

	atLimit := padCompiledAssignment(t, c, MaxCompiledAssignmentBytes)
	oneOver := padCompiledAssignment(t, c, MaxCompiledAssignmentBytes+1)

	// CONTROL: both decode to the SAME carrier, so nothing but the received-byte count
	// distinguishes them.
	var decodedOver edgev1.CompiledSweepAssignmentV1
	if err := proto.Unmarshal(oneOver, &decodedOver); err != nil {
		t.Fatalf("the one-over carrier must still decode: %v", err)
	}
	if !proto.Equal(&decodedOver, c) {
		t.Fatal("the one-over carrier must decode to the same carrier")
	}

	if err := AuthorizeCollectionNow(r, atLimit, mustAuthority(t, r, h, pages, now)); err != nil {
		t.Fatalf("a carrier at exactly the ceiling must authorize: %v", err)
	}
	if err := AuthorizeCollectionNow(r, oneOver, mustAuthority(t, r, h, pages, now)); !errors.Is(err, ErrCompiledAssignmentTooLarge) {
		t.Fatalf("one byte over the ceiling = %v, want ErrCompiledAssignmentTooLarge", err)
	}
}

// issuerRewritingTrust rewrites the issuer identifiers it is handed, then answers for the
// identity it substituted. This is the attack the capability snapshot exists to stop: the
// artifact digest pins one issuer, the resolver swaps it, and the signature is then computed
// over the substituted identity.
type issuerRewritingTrust struct {
	pub                 ed25519.PublicKey
	newIssuer, newKeyID []byte
}

func (x issuerRewritingTrust) ResolveKey(issuerID, issuerKeyID []byte, ev KeyEvidence) KeyResolution {
	copy(issuerID, x.newIssuer)
	copy(issuerKeyID, x.newKeyID)
	return KeyResolution{
		Status: KeyValid, Public: x.pub,
		TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: ev.Purpose,
	}
}

// TestAuthorizeCollectionNowResistsIssuerRewrite pins that a resolver cannot rewrite a
// capability's issuer identity between digest validation and signature verification.
//
// The fixture is the whole point: the signature is valid over the SUBSTITUTED identity
// (sched/k1) while the artifact digest pins the DECLARED one (evils/xx). So an honest
// resolver refuses -- evils/xx is untrusted -- but a resolver that rewrites the identifiers
// it is handed makes the stale signature verify. Only verifying against an immutable
// snapshot, and handing the resolver copies, defeats it.
func TestAuthorizeCollectionNowResistsIssuerRewrite(t *testing.T) {
	r, h, pages := planBoundAssignment(t)
	pub, priv := compiledTestKey(t)
	const now = 150

	c := validCompiledAssignment(t, r)
	// Signed as the TRUSTED identity...
	c.CollectionCapability.IssuerId = []byte("sched")
	c.CollectionCapability.IssuerKeyId = []byte("k1")
	signCompiledAssignment(t, c, priv)
	// ...then RE-LABELLED as an untrusted one, WITHOUT re-signing. The artifact digest is
	// recomputed so the carrier is internally consistent and commits to evils/xx.
	c.CollectionCapability.IssuerId = []byte("evils")
	c.CollectionCapability.IssuerKeyId = []byte("xx")
	c.CompiledAssignmentSha256 = CompiledAssignmentArtifactDigest(c)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	if err := ValidateCompiledSweepAssignment(c); err != nil {
		t.Fatalf("the fixture must be structurally valid, or the test proves nothing: %v", err)
	}

	// CONTROL: an honest resolver refuses the untrusted issuer.
	honest := mustAuthority(t, r, h, pages, now)
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), honest); err == nil {
		t.Fatal("control: an untrusted issuer must not authorize")
	}

	// CONTROL: the stale signature genuinely DOES verify under the substituted identity, so
	// the rewrite below would otherwise succeed.
	relabelled := proto.Clone(c.GetCollectionCapability()).(*edgev1.EdgeSignedCapabilityV1)
	relabelled.IssuerId = []byte("sched")
	relabelled.IssuerKeyId = []byte("k1")
	if err := VerifyCapabilitySignature(relabelled,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION, pub); err != nil {
		t.Fatalf("control: the signature must verify under the substituted identity: %v", err)
	}

	hostile := mustAuthority(t, r, h, pages, now)
	hostile.Trust = issuerRewritingTrust{pub: pub, newIssuer: []byte("sched"), newKeyID: []byte("k1")}
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), hostile); err == nil {
		t.Fatal("a resolver rewriting the issuer must not authorize")
	}
	if !bytes.Equal(c.GetCollectionCapability().GetIssuerId(), []byte("evils")) {
		t.Fatal("the caller's capability issuer was mutated through the resolver")
	}
}

// TestVerifyCompiledAssignmentWithTrustResistsIssuerRewrite tests the function whose
// CONTRACT is at stake, not the whole boundary.
//
// Through AuthorizeCollectionNow a rewrite is also caught later, because the grant verifier
// re-validates the record/carrier relation and the artifact digest no longer matches. That is
// genuine defence in depth, but it MASKS the defect here: the trust-aware verifier itself
// must not report a signature as valid when the identity it verified under was substituted
// after the digest pinned a different one.
func TestVerifyCompiledAssignmentWithTrustResistsIssuerRewrite(t *testing.T) {
	r := validAssignment(t)
	pub, priv := compiledTestKey(t)

	c := validCompiledAssignment(t, r)
	c.CollectionCapability.IssuerId = []byte("sched")
	c.CollectionCapability.IssuerKeyId = []byte("k1")
	signCompiledAssignment(t, c, priv)
	// Re-labelled to an UNTRUSTED identity without re-signing; the artifact digest commits to
	// the re-labelled form, so the carrier is internally consistent.
	c.CollectionCapability.IssuerId = []byte("evils")
	c.CollectionCapability.IssuerKeyId = []byte("xx")
	c.CompiledAssignmentSha256 = CompiledAssignmentArtifactDigest(c)
	if err := ValidateCompiledSweepAssignment(c); err != nil {
		t.Fatalf("fixture must be structurally valid: %v", err)
	}

	// CONTROL: an honest resolver refuses the declared identity.
	if _, err := VerifyCompiledAssignmentWithTrust(c,
		trustBoth(t, KeyValid), 150, 1); err == nil {
		t.Fatal("control: the untrusted declared issuer must not verify")
	}
	// CONTROL: the stale signature really does verify under the substituted identity.
	relabelled := proto.Clone(c.GetCollectionCapability()).(*edgev1.EdgeSignedCapabilityV1)
	relabelled.IssuerId = []byte("sched")
	relabelled.IssuerKeyId = []byte("k1")
	if err := VerifyCapabilitySignature(relabelled,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION, pub); err != nil {
		t.Fatalf("control: signature must verify under the substituted identity: %v", err)
	}

	// THE ATTACK: a resolver that rewrites the identifiers it is handed.
	status, err := VerifyCompiledAssignmentWithTrust(c,
		issuerRewritingTrust{pub: pub, newIssuer: []byte("sched"), newKeyID: []byte("k1")}, 150, 1)
	if err == nil && status == KeyValid {
		t.Fatal("a resolver rewriting the issuer must not yield a valid verification")
	}
	if !bytes.Equal(c.GetCollectionCapability().GetIssuerId(), []byte("evils")) {
		t.Fatal("the caller's capability issuer was mutated through the resolver")
	}
}

// TestExecutionGrantBindsExactCarrier pins that a grant permits ONE carrier revision. This
// is the property that separates a permission from a floating attestation.
func TestExecutionGrantBindsExactCarrier(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	trust := trustBoth(t, KeyValid)
	grant := executionGrant(t, r, c)

	if _, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), grantBytes(t, grant), trust, 150, 1); err != nil {
		t.Fatalf("control: a grant for this carrier must verify: %v", err)
	}
	for name, mutate := range map[string]func(*edgev1.EdgeAssignmentExecutionClaimsV1){
		"other carrier id":     func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.CompiledAssignmentId = mustUUID(t) },
		"other artifact hash":  func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.CompiledAssignmentSha256 = d32(0xEE) },
		"absent carrier id":    func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.CompiledAssignmentId = nil },
		"absent artifact hash": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.CompiledAssignmentSha256 = nil },
	} {
		bad := proto.Clone(grant).(*edgev1.EdgeSignedCapabilityV1)
		mutate(bad.GetAssignmentExecution())
		if _, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), grantBytes(t, resign(t, bad)), trust, 150, 1); !errors.Is(err, ErrAssignmentExecutionGrantBinding) {
			t.Fatalf("%s = %v, want ErrAssignmentExecutionGrantBinding", name, err)
		}
	}

	// A RECOMPILED carrier needs a NEW grant: the old one names the old artifact digest.
	recompiled := validCompiledAssignment(t, r)
	recompiled.ConfigGeneration = c.GetConfigGeneration() + 1
	signCompiledAssignment(t, recompiled, mustCompiledPriv(t))
	rr := proto.Clone(r).(*edgev1.SweepAssignmentRecordV1)
	rr.CompiledAssignmentSha256 = recompiled.GetCompiledAssignmentSha256()
	if _, err := VerifyAssignmentExecutionGrant(rr, carrierBytes(t, recompiled), grantBytes(t, grant), trust, 150, 1); err == nil {
		t.Fatal("a grant must not carry over to a recompiled carrier")
	}
}

// TestExecutionGrantValidatesCarrierAndRelation pins that the verifier does not take the
// carrier on trust. An earlier revision accepted a "carrier" carrying nothing but a traffic
// class, because it validated neither the carrier nor its relation to the record.
func TestExecutionGrantValidatesCarrierAndRelation(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	trust := trustBoth(t, KeyValid)

	stub := &edgev1.CompiledSweepAssignmentV1{TrafficClass: c.GetTrafficClass()}
	grant := executionGrant(t, r, stub)
	if status, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, stub), grantBytes(t, grant), trust, 150, 1); err == nil || status == KeyValid {
		t.Fatalf("a stub carrier must not verify: status=%v err=%v", status, err)
	}

	// A VALID but UNRELATED carrier is also refused.
	other := validCompiledAssignment(t, validAssignment(t))
	if _, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, other), grantBytes(t, executionGrant(t, r, other)), trust, 150, 1); err == nil {
		t.Fatal("a carrier unrelated to the record must not verify")
	}
}

// TestExecutionGrantByteCeiling pins the standalone grant's received-byte bound.
func TestExecutionGrantByteCeiling(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	trust := trustBoth(t, KeyValid)

	raw := grantBytes(t, executionGrant(t, r, c))
	if _, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), raw, trust, 150, 1); err != nil {
		t.Fatalf("control: %v", err)
	}
	// Duplicate a known field until the ENCODING exceeds the bound. The decoded struct is
	// unchanged, which is why the bound must be measured on received bytes.
	num := (&edgev1.EdgeSignedCapabilityV1{}).ProtoReflect().
		Descriptor().Fields().ByName("issuer_id").Number()
	bloated := append([]byte(nil), raw...)
	for len(bloated) <= MaxExecutionGrantBytes {
		bloated = append(bloated, protowire.AppendBytes(
			protowire.AppendTag(nil, num, protowire.BytesType), []byte("sched"))...)
	}
	if _, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), bloated, trust, 150, 1); !errors.Is(err, ErrExecutionGrantTooLarge) {
		t.Fatalf("oversize grant = %v, want ErrExecutionGrantTooLarge", err)
	}
}

// TestAuthorizeCollectionNowBoundsRawPlanHeader pins the plan HEADER ceiling on received
// bytes. Returning a decoded header while returning raw pages split the contract: an
// oversize header decoded identically, so Go accepted what Elixir's raw boundary rejected.
func TestAuthorizeCollectionNowBoundsRawPlanHeader(t *testing.T) {
	r, h, pages := planBoundAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	const now = 150

	raw := headerBytes(t, h)
	num := (&edgev1.ScheduledPlanHeaderV1{}).ProtoReflect().
		Descriptor().Fields().ByName("check_set_sha256").Number()
	bloated := append([]byte(nil), raw...)
	for len(bloated) <= MaxPlanHeaderBytes {
		bloated = append(bloated, protowire.AppendBytes(
			protowire.AppendTag(nil, num, protowire.BytesType), h.GetCheckSetSha256())...)
	}
	// CONTROL: it decodes to the SAME header and collapses on re-encode.
	var decoded edgev1.ScheduledPlanHeaderV1
	if err := proto.Unmarshal(bloated, &decoded); err != nil {
		t.Fatalf("bloated header must decode: %v", err)
	}
	if !proto.Equal(&decoded, h) {
		t.Fatal("bloated header must decode to the same header")
	}
	if proto.Size(&decoded) > MaxPlanHeaderBytes {
		t.Fatal("control failed: the padding did not collapse on re-encode")
	}

	auth := mustAuthority(t, r, h, pages, now)
	auth.Assignments = &testAssignmentAuthority{
		want: assignmentKeyForTest(r),
		rec: AuthoritativeAssignment{
			Status:        AssignmentAuthorityResolved,
			Record:        proto.Clone(r).(*edgev1.SweepAssignmentRecordV1),
			PlanHeaderRaw: bloated, PlanPagesRaw: rawPages(t, pages),
		},
		asked: &AssignmentKey{},
	}
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), auth); !errors.Is(err, ErrPlanHeaderTooLarge) {
		t.Fatalf("oversize raw plan header = %v, want ErrPlanHeaderTooLarge", err)
	}
}

// TestExecutionGrantCurrentVersusHistorical pins the SPLIT between the two questions: the
// current check refuses an expired grant, while historical verification still answers. It is not
// a purely historical test -- it exercises both APIs, and the old name said otherwise.
func TestExecutionGrantCurrentVersusHistorical(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	raw := grantBytes(t, executionGrant(t, r, c))

	// CURRENT verification refuses after the window closes.
	if _, err := VerifyAssignmentExecutionGrant(r, carrierBytes(t, c), raw,
		trustBoth(t, KeyValid), 5_000, 1); err == nil {
		t.Fatal("an expired grant must not pass the CURRENT check")
	}
	// HISTORICAL verification still answers, and reports the key's CURRENT compromise state.
	if status, err := VerifyAssignmentExecutionGrantHistorical(r, carrierBytes(t, c), raw,
		trustBoth(t, KeyValid), 150, 1); err != nil || status != KeyValid {
		t.Fatalf("historical verification: status=%v err=%v", status, err)
	}
	if status, err := VerifyAssignmentExecutionGrantHistorical(r, carrierBytes(t, c), raw,
		trustBoth(t, KeyHistoricallyRevoked), 150, 1); err != nil || status != KeyHistoricallyRevoked {
		t.Fatalf("historical revocation: status=%v err=%v", status, err)
	}
}

// withPerKey is the honest resolver with one key's status degraded.
func withPerKey(t *testing.T, per map[string]KeyStatus) compiledTestTrust {
	t.Helper()
	tr := trustBoth(t, KeyValid)
	tr.perKey = per
	return tr
}

// TestSchedulerKeyCannotMintExecutionGrant pins the HOST/SCHEDULER separation.
//
// The two roles must use distinct keys AND purpose-aware resolution. With one shared key, or a
// resolver that ignores KeyEvidence.Purpose, an execution grant re-signed as the scheduler
// verifies -- which makes the whole "separate principal" claim decorative.
func TestSchedulerKeyCannotMintExecutionGrant(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	raw := carrierBytes(t, c)
	honest := trustBoth(t, KeyValid)

	// Control: the HOST-issued grant verifies.
	if status, err := VerifyAssignmentExecutionGrant(r, raw, grantBytes(t, executionGrant(t, r, c)), honest, 150, 1); err != nil || status != KeyValid {
		t.Fatalf("control: host-issued grant must verify: status=%v err=%v", status, err)
	}

	// The SCHEDULER key family, re-signed with the scheduler key so the signature is genuine.
	// Only purpose-aware resolution can refuse this.
	asSched := executionGrant(t, r, c)
	asSched.IssuerId = []byte("sched")
	asSched.IssuerKeyId = []byte("k1")
	SignCapability(asSched, mustCompiledPriv(t))
	status, err := VerifyAssignmentExecutionGrant(r, raw, grantBytes(t, asSched), honest, 150, 1)
	if err == nil || status == KeyValid {
		t.Fatalf("a scheduler-issued execution grant must not verify: status=%v err=%v", status, err)
	}
	if status != KeyInvalid {
		t.Fatalf("an unauthorized ROLE is a permanent rejection: status=%v, want KeyInvalid", status)
	}

	// And a HOST key presented for the CARRIER's collection capability is equally refused.
	asHost := validCompiledAssignment(t, r)
	asHost.CollectionCapability.IssuerId = []byte("host")
	asHost.CollectionCapability.IssuerKeyId = []byte("host-exec-1")
	SignCapability(asHost.CollectionCapability, mustHostPriv(t))
	asHost.CompiledAssignmentSha256 = CompiledAssignmentArtifactDigest(asHost)
	if st, err := VerifyCompiledAssignmentWithTrust(asHost, honest, 150, 1); err == nil || st == KeyValid {
		t.Fatalf("a host-issued collection capability must not verify: status=%v err=%v", st, err)
	}

	// THE LIMIT, stated rather than papered over. A resolver that ECHOES the purpose but
	// ignores role authorization DOES authorize -- and must, because only the resolver knows
	// which roles a key may issue. The response binding proves the resolver was ASKED the
	// right question; it cannot prove the answer was honest, exactly as with SessionAuthority.
	// What IS enforced protocol-side is that a resolver failing to answer the purpose question
	// never authorizes; see TestPurposeIsResponseBound.
	blind := trustBoth(t, KeyValid)
	blind.ignorePurpose = true
	if st, err := VerifyAssignmentExecutionGrant(r, raw, grantBytes(t, asSched), blind, 150, 1); err != nil || st != KeyValid {
		t.Fatalf("a purpose-blind resolver is TRUSTED, so this documents the limit: status=%v err=%v", st, err)
	}
}

// purposeDroppingTrust answers correctly except that it does NOT echo the requested purpose.
type purposeDroppingTrust struct{ pub ed25519.PublicKey }

func (x purposeDroppingTrust) ResolveKey(_, _ []byte, ev KeyEvidence) KeyResolution {
	return KeyResolution{Status: KeyValid, Public: x.pub, TrustPolicyEpoch: ev.TrustPolicyEpoch}
}

// purposeSwappingTrust echoes a DIFFERENT, DECLARED, NONZERO purpose. Without this case a check
// weakened to "reject only UNSPECIFIED" stays green, so the echo would not be pinned to
// EQUALITY.
type purposeSwappingTrust struct {
	pub     ed25519.PublicKey
	instead edgev1.EdgeCapabilityPurpose
}

func (x purposeSwappingTrust) ResolveKey(_, _ []byte, ev KeyEvidence) KeyResolution {
	return KeyResolution{
		Status: KeyValid, Public: x.pub,
		TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: x.instead,
	}
}

// TestPurposeIsResponseBound pins that a resolver which does not echo the requested purpose is
// treated as not having answered, exactly as with the trust-policy epoch.
func TestPurposeIsResponseBound(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	pub, _ := compiledTestKey(t)
	if status, err := VerifyCompiledAssignmentWithTrust(c, purposeDroppingTrust{pub: pub}, 150, 1); !errors.Is(err, ErrKeyUnavailable) || status != KeyUnavailable {
		t.Fatalf("unechoed purpose = (%v, %v), want (KeyUnavailable, ErrKeyUnavailable)", status, err)
	}
	// A DIFFERENT DECLARED purpose must be refused too. The echo is pinned to EQUALITY, not
	// merely to being set -- otherwise a resolver answering about another role would be trusted.
	for _, instead := range []edgev1.EdgeCapabilityPurpose{
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_SOURCE,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_DELIVERY,
		edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION,
	} {
		swapped := purposeSwappingTrust{pub: pub, instead: instead}
		if status, err := VerifyCompiledAssignmentWithTrust(c, swapped, 150, 1); !errors.Is(err, ErrKeyUnavailable) || status != KeyUnavailable {
			t.Fatalf("purpose echoed as %v = (%v, %v), want (KeyUnavailable, ErrKeyUnavailable)", instead, status, err)
		}
	}
}

// TestCarrierHistoricalTrustUsesCurrentInstant pins that the CARRIER's trust resolution asks
// about the CURRENT compromise state, not "was this key trusted back then".
//
// Querying trust at the capability's own not_before instead of the evaluation instant left the
// whole package green: nothing exercised a key compromised AFTER the window it signed within.
func TestCarrierHistoricalTrustUsesCurrentInstant(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	// The scheduler key is compromise-revoked from t=1000, long after the carrier's window
	// (100..200) closed.
	trust := compromiseAfter{
		schedPub: mustPub(t, compiledTestKey), hostPub: mustPub(t, hostTestKey), at: 1000,
	}
	if status, err := VerifyCompiledAssignmentWithTrust(c, trust, 5_000, 1); err != nil || status != KeyHistoricallyRevoked {
		t.Fatalf("compromise after the signing window must surface: status=%v err=%v", status, err)
	}
	// Asked before the compromise it is valid, so the case above is the trust INSTANT and not a
	// broken fixture.
	if status, err := VerifyCompiledAssignmentWithTrust(c, trust, 150, 1); err != nil || status != KeyValid {
		t.Fatalf("before the compromise: status=%v err=%v", status, err)
	}
}

// TestExecutionGrantWindowMustBeContained pins that the inner collection window CANNOT reach
// outside the envelope carrying it. Calling it a "tighter grant" does not make it one.
func TestExecutionGrantWindowMustBeContained(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	raw := carrierBytes(t, c)
	trust := trustBoth(t, KeyValid)

	for name, mutate := range map[string]func(*edgev1.EdgeAssignmentExecutionClaimsV1){
		// Both of these CONTAIN the evaluation instant 150, so only containment refuses them.
		"starts before the envelope": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.CollectionNotBeforeUnixNano = 99
		},
		"ends after the envelope": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.CollectionExpiresUnixNano = 201
		},
		"strictly wider than the envelope": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.CollectionNotBeforeUnixNano, x.CollectionExpiresUnixNano = 99, 201
		},
	} {
		bad := executionGrant(t, r, c)
		mutate(bad.GetAssignmentExecution())
		if _, err := VerifyAssignmentExecutionGrant(r, raw, grantBytes(t, resign(t, bad)), trust, 150, 1); !errors.Is(err, ErrAssignmentExecutionGrantBinding) {
			t.Fatalf("%s = %v, want ErrAssignmentExecutionGrantBinding", name, err)
		}
	}

	// A window EQUAL to the envelope is contained, so the rejections above are containment and
	// not an off-by-one.
	equal := executionGrant(t, r, c)
	equal.GetAssignmentExecution().CollectionNotBeforeUnixNano = equal.GetNotBeforeUnixNano()
	equal.GetAssignmentExecution().CollectionExpiresUnixNano = equal.GetExpiresAtUnixNano()
	if _, err := VerifyAssignmentExecutionGrant(r, raw, grantBytes(t, resign(t, equal)), trust, 150, 1); err != nil {
		t.Fatalf("a window equal to the envelope must be accepted: %v", err)
	}
}

// TestExecutionGrantSigningGrammarCoversEveryMember proves the SIGNING PREIMAGE covers each
// claim member, by observing the PREIMAGE.
//
// The relation-mutation table cannot prove this: every mutation is re-signed through the same
// framer, so a member omitted from the preimage still signs and still verifies, and the
// mutation is caught only by the separate relation comparison. Only comparing signing bytes
// before and after shows what the signature actually binds.
func TestExecutionGrantSigningGrammarCoversEveryMember(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	base := executionGrant(t, r, c)

	for name, mutate := range map[string]func(*edgev1.EdgeAssignmentExecutionClaimsV1){
		"purpose": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.Purpose = edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_COLLECTION
		},
		"network scope":       func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.NetworkScopeId = mustUUID(t) },
		"agent":               func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.AuthenticatedAgentId = mustUUID(t) },
		"producer assignment": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ProducerAssignmentId = mustUUID(t) },
		"execution id":        func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ExecutionId = mustUUID(t) },
		"run id":              func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.RunId = mustUUID(t) },
		"run shard":           func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.RunShard = 99 },
		"authority epoch":     func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.AuthorityEpoch = 99 },
		"production scope":    func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ProductionScopeId = mustUUID(t) },
		"scope digest":        func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ScopeSha256 = d32(0xEE) },
		"contract bundle":     func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ContractBundleSha256 = d32(0xEE) },
		"plan digest":         func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.ExecutionPlanSha256 = d32(0xEE) },
		"range digest":        func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.TargetRangeSha256 = d32(0xEE) },
		"traffic class": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.TrafficClass = edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE
		},
		"collection not before": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.CollectionNotBeforeUnixNano = 101 },
		"collection expires":    func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.CollectionExpiresUnixNano = 199 },
		"carrier id":            func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.CompiledAssignmentId = mustUUID(t) },
		"carrier digest":        func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.CompiledAssignmentSha256 = d32(0xEE) },
		"source kind": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.SourceIdentity.Kind = edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP
		},
		"source context":      func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.SourceIdentity.ContextId = mustUUID(t) },
		"source scope":        func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.SourceIdentity.SourceScopeId = mustUUID(t) },
		"source scope digest": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) { x.SourceIdentity.SourceScopeSha256 = d32(0xEE) },
		"source identity presence": func(x *edgev1.EdgeAssignmentExecutionClaimsV1) {
			x.SourceIdentity = nil
		},
	} {
		before := CapabilitySigningBytes(base)
		mutated := proto.Clone(base).(*edgev1.EdgeSignedCapabilityV1)
		mutate(mutated.GetAssignmentExecution())
		if bytes.Equal(before, CapabilitySigningBytes(mutated)) {
			t.Fatalf("the signing preimage ignores %s: the signature does not bind it", name)
		}
	}
}

// padToExactBytes inflates an encoding to EXACTLY `target` bytes by repeating one known
// non-repeated `bytes` field: the decoder keeps the LAST occurrence, so the padded bytes decode
// identically while the received count is arbitrary. Deterministic, so the vectors are stable.
func padToExactBytes(t *testing.T, raw []byte, field protowire.Number, trueValue []byte, target int) []byte {
	t.Helper()
	trueField := protowire.AppendBytes(protowire.AppendTag(nil, field, protowire.BytesType), trueValue)
	fillerTotal := target - len(raw) - len(trueField)
	payload := fillerTotal - 1 - protowire.SizeVarint(uint64(fillerTotal))
	if payload < 0 {
		t.Fatalf("target %d is too small to pad to", target)
	}
	out := make([]byte, 0, target)
	out = append(out, raw...)
	out = append(out, protowire.AppendBytes(
		protowire.AppendTag(nil, field, protowire.BytesType), make([]byte, payload))...)
	out = append(out, trueField...)
	if len(out) != target {
		t.Fatalf("padded to %d, want exactly %d", len(out), target)
	}
	return out
}

// fieldNumber reads a field's number from the descriptor, so padding never targets a field that
// was renumbered out from under it.
func fieldNumber(t *testing.T, m proto.Message, name string) protowire.Number {
	t.Helper()
	fd := m.ProtoReflect().Descriptor().Fields().ByName(protoreflect.Name(name))
	if fd == nil {
		t.Fatalf("field %q missing", name)
	}
	return fd.Number()
}

// TestExecutionGrantExactByteCeiling pins MaxExecutionGrantBytes at the BOUNDARY: 16 384
// accepted, 16 385 rejected. An unspecified overshoot would survive changing > to >=.
func TestExecutionGrantExactByteCeiling(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	raw := carrierBytes(t, c)
	trust := trustBoth(t, KeyValid)

	grant := executionGrant(t, r, c)
	base := grantBytes(t, grant)
	num := fieldNumber(t, &edgev1.EdgeSignedCapabilityV1{}, "issuer_id")

	if MaxExecutionGrantBytes != 16*1024 {
		t.Fatalf("MaxExecutionGrantBytes = %d, want 16384", MaxExecutionGrantBytes)
	}
	atLimit := padToExactBytes(t, base, num, grant.GetIssuerId(), 16384)
	oneOver := padToExactBytes(t, base, num, grant.GetIssuerId(), 16385)

	// CONTROLS: both decode to the same grant and collapse far below the ceiling on re-encode.
	for name, padded := range map[string][]byte{"at": atLimit, "over": oneOver} {
		var round edgev1.EdgeSignedCapabilityV1
		if err := proto.Unmarshal(padded, &round); err != nil {
			t.Fatalf("%s-limit grant must decode: %v", name, err)
		}
		if !proto.Equal(&round, grant) {
			t.Fatalf("%s-limit grant must decode to the same grant", name)
		}
		if proto.Size(&round) > MaxExecutionGrantBytes {
			t.Fatalf("%s-limit grant did not collapse on re-encode", name)
		}
	}

	if _, err := VerifyAssignmentExecutionGrant(r, raw, atLimit, trust, 150, 1); err != nil {
		t.Fatalf("exactly 16384 bytes must be accepted: %v", err)
	}
	if _, err := VerifyAssignmentExecutionGrant(r, raw, oneOver, trust, 150, 1); !errors.Is(err, ErrExecutionGrantTooLarge) {
		t.Fatalf("16385 bytes = %v, want ErrExecutionGrantTooLarge", err)
	}
}

// TestPlanHeaderExactByteCeiling pins MaxPlanHeaderBytes at the BOUNDARY: 524 288 accepted,
// 524 289 rejected.
func TestPlanHeaderExactByteCeiling(t *testing.T) {
	r, h, pages := planBoundAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	const now = 150

	if MaxPlanHeaderBytes != 512*1024 {
		t.Fatalf("MaxPlanHeaderBytes = %d, want 524288", MaxPlanHeaderBytes)
	}
	base := headerBytes(t, h)
	num := fieldNumber(t, &edgev1.ScheduledPlanHeaderV1{}, "check_set_sha256")
	atLimit := padToExactBytes(t, base, num, h.GetCheckSetSha256(), 524288)
	oneOver := padToExactBytes(t, base, num, h.GetCheckSetSha256(), 524289)

	for name, padded := range map[string][]byte{"at": atLimit, "over": oneOver} {
		var round edgev1.ScheduledPlanHeaderV1
		if err := proto.Unmarshal(padded, &round); err != nil {
			t.Fatalf("%s-limit header must decode: %v", name, err)
		}
		if !proto.Equal(&round, h) {
			t.Fatalf("%s-limit header must decode to the same header", name)
		}
		if proto.Size(&round) > MaxPlanHeaderBytes {
			t.Fatalf("%s-limit header did not collapse on re-encode", name)
		}
	}

	authFor := func(raw []byte) CollectionAuthority {
		a := mustAuthority(t, r, h, pages, now)
		a.Assignments = &testAssignmentAuthority{
			want: assignmentKeyForTest(r),
			rec: AuthoritativeAssignment{
				Status:        AssignmentAuthorityResolved,
				Record:        proto.Clone(r).(*edgev1.SweepAssignmentRecordV1),
				PlanHeaderRaw: raw, PlanPagesRaw: rawPages(t, pages),
			},
			asked: &AssignmentKey{},
		}
		return a
	}
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), authFor(atLimit)); err != nil {
		t.Fatalf("exactly 524288 header bytes must be accepted: %v", err)
	}
	if err := AuthorizeCollectionNow(r, carrierBytes(t, c), authFor(oneOver)); !errors.Is(err, ErrPlanHeaderTooLarge) {
		t.Fatalf("524289 header bytes = %v, want ErrPlanHeaderTooLarge", err)
	}
}

// TestExecutionGrantAPIsEnforceCarrierCeiling pins that the STANDALONE grant verifiers cannot
// be used to bypass the carrier's exact-byte ceiling either.
//
// AuthorizeCollectionNow was fixed first, but both public grant APIs still took a decoded
// carrier -- so decoding the over-limit carrier and calling the verifier returned KeyValid.
// Every public entry point now obtains the carrier from the raw validator.
func TestExecutionGrantAPIsEnforceCarrierCeiling(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	trust := trustBoth(t, KeyValid)
	grant := grantBytes(t, executionGrant(t, r, c))

	atLimit := padCompiledAssignment(t, c, MaxCompiledAssignmentBytes)
	oneOver := padCompiledAssignment(t, c, MaxCompiledAssignmentBytes+1)

	if _, err := VerifyAssignmentExecutionGrant(r, atLimit, grant, trust, 150, 1); err != nil {
		t.Fatalf("a carrier at exactly the ceiling must verify: %v", err)
	}
	if _, err := VerifyAssignmentExecutionGrant(r, oneOver, grant, trust, 150, 1); !errors.Is(err, ErrCompiledAssignmentTooLarge) {
		t.Fatalf("current verifier, oversize carrier = %v, want ErrCompiledAssignmentTooLarge", err)
	}
	// The HISTORICAL verifier is a public entry point too, so it needs the same bound.
	if _, err := VerifyAssignmentExecutionGrantHistorical(r, oneOver, grant, trust, 150, 1); !errors.Is(err, ErrCompiledAssignmentTooLarge) {
		t.Fatalf("historical verifier, oversize carrier = %v, want ErrCompiledAssignmentTooLarge", err)
	}
}

// TestExecutionGrantHistoricalUsesCurrentTrustTime pins that historical verification reports
// the key's CURRENT compromise state.
//
// The parameter is the CURRENT trust time, not the grant's old validity time: the signed grant
// already carries its evidence interval. An earlier revision documented two times, accepted
// one, and spent it as the evaluation time -- so a caller following the documentation passed
// the old evidence time and a time-sensitive resolver answered KeyValid for a key compromised
// since.
func TestExecutionGrantHistoricalUsesCurrentTrustTime(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	raw := carrierBytes(t, c)
	grant := grantBytes(t, executionGrant(t, r, c))

	// A resolver where the host key is compromised from t=1000 -- AFTER the grant expired at 200.
	compromisedFrom := compromiseAfter{
		schedPub: mustPub(t, compiledTestKey), hostPub: mustPub(t, hostTestKey), at: 1000,
	}
	// Asked at a CURRENT time past the compromise, the answer must be revoked.
	if status, err := VerifyAssignmentExecutionGrantHistorical(r, raw, grant, compromisedFrom, 5_000, 1); err != nil || status != KeyHistoricallyRevoked {
		t.Fatalf("compromise after expiry must surface: status=%v err=%v", status, err)
	}
	// Asked at a time before the compromise it is valid -- which is why the parameter must be
	// the CURRENT instant and not the grant's own old window.
	if status, err := VerifyAssignmentExecutionGrantHistorical(r, raw, grant, compromisedFrom, 150, 1); err != nil || status != KeyValid {
		t.Fatalf("before the compromise: status=%v err=%v", status, err)
	}
}

// compromiseAfter is a TIME-SENSITIVE resolver: the host key is compromise-revoked from `at`.
type compromiseAfter struct {
	schedPub, hostPub ed25519.PublicKey
	at                int64
}

func (x compromiseAfter) ResolveKey(issuerID, keyID []byte, ev KeyEvidence) KeyResolution {
	pub := x.schedPub
	if bytes.Equal(issuerID, []byte("host")) {
		pub = x.hostPub
	}
	st := KeyValid
	if ev.EvalNowUnixNano >= x.at {
		st = KeyHistoricallyRevoked
	}
	return KeyResolution{Status: st, Public: pub, TrustPolicyEpoch: ev.TrustPolicyEpoch, Purpose: ev.Purpose}
}

func mustPub(t *testing.T, gen func(*testing.T) (ed25519.PublicKey, ed25519.PrivateKey)) ed25519.PublicKey {
	t.Helper()
	pub, _ := gen(t)
	return pub
}

// fieldSpec is one pinned schema member: number, name, kind and cardinality.
type fieldSpec struct {
	num  int32
	name string
	kind string
	// repeated/optional presence, so a scalar quietly becoming repeated is a failure.
	card string
}

// assertExactSchema pins a message's COMPLETE field inventory from the descriptor.
//
// This is what the mutation tables cannot do. They enumerate today's KNOWN members, so a field
// ADDED later can be absent from every fixture, omitted from the signing grammar and from
// validation, and nothing fails -- the tables simply never mention it. Pinning the inventory
// means adding a field breaks this test first, forcing a deliberate decision about hashing and
// validating it.
func assertExactSchema(t *testing.T, m proto.Message, want []fieldSpec) {
	t.Helper()
	fields := m.ProtoReflect().Descriptor().Fields()
	name := string(m.ProtoReflect().Descriptor().FullName())
	if fields.Len() != len(want) {
		var got []string
		for i := 0; i < fields.Len(); i++ {
			f := fields.Get(i)
			got = append(got, fmt.Sprintf("%d:%s:%s", f.Number(), f.Name(), f.Kind()))
		}
		t.Fatalf("%s has %d fields, want exactly %d.\nA field was added or removed: decide "+
			"deliberately whether the signing grammar and validator must cover it, then update "+
			"this inventory.\ngot: %v", name, fields.Len(), len(want), got)
	}
	byNum := map[int32]fieldSpec{}
	for _, w := range want {
		byNum[w.num] = w
	}
	for i := 0; i < fields.Len(); i++ {
		f := fields.Get(i)
		w, ok := byNum[int32(f.Number())]
		if !ok {
			t.Fatalf("%s field %d (%s) is not in the pinned inventory", name, f.Number(), f.Name())
		}
		card := "singular"
		switch {
		case f.IsList():
			card = "repeated"
		case f.HasOptionalKeyword():
			card = "optional"
		}
		if string(f.Name()) != w.name || f.Kind().String() != w.kind || card != w.card {
			t.Fatalf("%s field %d = (%s, %s, %s), pinned as (%s, %s, %s)",
				name, f.Number(), f.Name(), f.Kind(), card, w.name, w.kind, w.card)
		}
	}
}

// TestFrozenSchemaInventories pins the EXACT membership of every message this slice hashes or
// validates, so an added field cannot slip past both the grammar and the validator unnoticed.
func TestFrozenSchemaInventories(t *testing.T) {
	assertExactSchema(t, &edgev1.CompiledSweepAssignmentV1{}, []fieldSpec{
		{1, "compiled_assignment_id", "bytes", "singular"},
		{2, "compiled_assignment_body_sha256", "bytes", "singular"},
		{3, "digest_version", "uint32", "singular"},
		{4, "execution_plan_id", "bytes", "singular"},
		{5, "execution_plan_sha256", "bytes", "singular"},
		{6, "target_range_id", "bytes", "singular"},
		{7, "target_range_sha256", "bytes", "singular"},
		{8, "network_scope_id", "bytes", "singular"},
		{9, "authenticated_agent_id", "bytes", "singular"},
		{10, "execution_shard", "uint32", "singular"},
		{11, "assignment_epoch", "uint64", "singular"},
		{12, "config_generation", "uint64", "singular"},
		{13, "result_format", "enum", "singular"},
		{14, "check_set_sha256", "bytes", "singular"},
		{15, "traffic_class", "enum", "singular"},
		{16, "not_before_unix_nano", "int64", "singular"},
		{17, "expires_at_unix_nano", "int64", "singular"},
		{18, "collection_capability", "message", "singular"},
		{19, "compiled_assignment_sha256", "bytes", "singular"},
		{20, "producer_assignment_id", "bytes", "singular"},
		{21, "execution_id", "bytes", "singular"},
	})
	assertExactSchema(t, &edgev1.EdgeCollectionClaimsV1{}, []fieldSpec{
		{1, "purpose", "enum", "singular"},
		{2, "network_scope_id", "bytes", "singular"},
		{3, "authenticated_agent_id", "bytes", "singular"},
		{4, "execution_plan_id", "bytes", "singular"},
		{5, "target_range_id", "bytes", "singular"},
		{6, "execution_shard", "uint32", "singular"},
		{7, "assignment_epoch", "uint64", "singular"},
		{8, "compiled_assignment_body_sha256", "bytes", "singular"},
		{9, "traffic_class", "enum", "singular"},
		{10, "producer_assignment_id", "bytes", "singular"},
		{11, "execution_id", "bytes", "singular"},
	})
	assertExactSchema(t, &edgev1.EdgeAssignmentExecutionClaimsV1{}, []fieldSpec{
		{1, "purpose", "enum", "singular"},
		{2, "network_scope_id", "bytes", "singular"},
		{3, "authenticated_agent_id", "bytes", "singular"},
		{4, "producer_assignment_id", "bytes", "singular"},
		{5, "execution_id", "bytes", "singular"},
		{6, "run_id", "bytes", "singular"},
		{7, "run_shard", "uint32", "singular"},
		{8, "authority_epoch", "uint64", "singular"},
		{9, "production_scope_id", "bytes", "singular"},
		{10, "scope_sha256", "bytes", "singular"},
		{11, "contract_bundle_sha256", "bytes", "singular"},
		{12, "execution_plan_sha256", "bytes", "singular"},
		{13, "target_range_sha256", "bytes", "singular"},
		{14, "traffic_class", "enum", "singular"},
		{15, "collection_not_before_unix_nano", "int64", "singular"},
		{16, "collection_expires_unix_nano", "int64", "singular"},
		{17, "source_identity", "message", "singular"},
		{18, "compiled_assignment_id", "bytes", "singular"},
		{19, "compiled_assignment_sha256", "bytes", "singular"},
	})
	assertExactSchema(t, &edgev1.EdgeSourceSpanIdentityV1{}, []fieldSpec{
		{1, "kind", "enum", "singular"},
		{2, "context_id", "bytes", "singular"},
		{3, "source_scope_id", "bytes", "singular"},
		{4, "source_scope_sha256", "bytes", "singular"},
	})

	// THE RECORD AND THE PLAN. Omitting SweepAssignmentRecordV1 left a generated-known field 29
	// invisible: retained-unknown rejection cannot see a field the schema declares, so a new member
	// would be neither hashed nor validated with both suites green. The plan and expectation
	// messages are inventoried for the same reason, which is what lets the doc comment say "every
	// message this slice hashes or validates" truthfully.
	assertExactSchema(t, &edgev1.SweepAssignmentRecordV1{}, []fieldSpec{
		{1, "producer_assignment_id", "bytes", "singular"},
		{2, "execution_id", "bytes", "singular"},
		{3, "execution_plan_id", "bytes", "singular"},
		{4, "execution_plan_sha256", "bytes", "singular"},
		{5, "execution_shard", "uint32", "singular"},
		{6, "assignment_epoch", "uint64", "singular"},
		{7, "record_sequence", "uint64", "singular"},
		{8, "authored_at_unix_nano", "int64", "singular"},
		{9, "target_range_id", "bytes", "singular"},
		{10, "target_range_sha256", "bytes", "singular"},
		{11, "lease_id", "bytes", "singular"},
		{12, "fence_token", "uint64", "singular"},
		{13, "lease_expires_at_unix_nano", "int64", "singular"},
		{14, "state", "enum", "singular"},
		{15, "superseded_by_assignment_id", "bytes", "singular"},
		{16, "terminal_batch_sequence", "uint64", "singular"},
		{17, "mtr_expectation", "message", "singular"},
		{18, "check_set_sha256", "bytes", "singular"},
		{19, "availability_policy_id", "bytes", "singular"},
		{20, "network_scope_id", "bytes", "singular"},
		{21, "authenticated_agent_id", "bytes", "singular"},
		{22, "production_scope_id", "bytes", "singular"},
		{23, "scope_sha256", "bytes", "singular"},
		{24, "contract_bundle_sha256", "bytes", "singular"},
		{25, "run_id", "bytes", "singular"},
		{26, "source_identity", "message", "singular"},
		{27, "compiled_assignment_id", "bytes", "singular"},
		{28, "compiled_assignment_sha256", "bytes", "singular"},
	})
	assertExactSchema(t, &edgev1.SweepMtrExpectationV1{}, []fieldSpec{
		{1, "ordinal_count", "uint64", "singular"},
		{2, "ordinal_range_commitment", "bytes", "singular"},
		{3, "plan_ordinal_offset", "uint64", "optional"},
	})
	assertExactSchema(t, &edgev1.ScheduledPlanHeaderV1{}, []fieldSpec{
		{1, "execution_plan_id", "bytes", "singular"},
		{2, "execution_plan_sha256", "bytes", "singular"},
		{3, "page_count", "uint32", "singular"},
		{4, "total_target_count", "uint64", "singular"},
		{5, "plan_root_sha256", "bytes", "singular"},
		{6, "digest_version", "uint32", "singular"},
		{7, "check_set_sha256", "bytes", "singular"},
		{8, "availability_policy_id", "bytes", "singular"},
		{10, "network_scope_id", "bytes", "singular"},
		{11, "mtr_ordinal_range_commitment", "bytes", "singular"},
	})
	assertExactSchema(t, &edgev1.ScheduledPlanPageV1{}, []fieldSpec{
		{1, "execution_plan_id", "bytes", "singular"},
		{2, "page_index", "uint32", "singular"},
		{3, "page_count", "uint32", "singular"},
		{4, "prev_page_sha256", "bytes", "singular"},
		{5, "page_sha256", "bytes", "singular"},
		{6, "check_set_sha256", "bytes", "singular"},
		{7, "digest_version", "uint32", "singular"},
		{8, "ranges", "message", "repeated"},
	})
	assertExactSchema(t, &edgev1.TargetRangeV1{}, []fieldSpec{
		{1, "range_id", "bytes", "singular"},
		{2, "range_sha256", "bytes", "singular"},
		{3, "cidr", "string", "singular"},
		{4, "first_address", "string", "singular"},
		{5, "last_address", "string", "singular"},
		{6, "target_count", "uint64", "singular"},
		{7, "check_set_sha256", "bytes", "singular"},
		{8, "availability_policy_id", "bytes", "singular"},
		{9, "mtr_admission_budget", "uint64", "singular"},
		{10, "mtr_ordinal_count", "uint64", "optional"},
	})

	// The CAPABILITY ENVELOPE ITSELF, fields 1-12. Pinning only the oneof left a top-level field
	// free: adding a known field 13 would be signed by nothing and validated by nothing while
	// both suites stayed green.
	assertExactSchema(t, &edgev1.EdgeSignedCapabilityV1{}, []fieldSpec{
		{1, "capability_version", "uint32", "singular"},
		{2, "issuer_id", "bytes", "singular"},
		{3, "issuer_key_id", "bytes", "singular"},
		{4, "algorithm", "string", "singular"},
		{5, "not_before_unix_nano", "int64", "singular"},
		{6, "expires_at_unix_nano", "int64", "singular"},
		{7, "production", "message", "singular"},
		{8, "source", "message", "singular"},
		{9, "delivery", "message", "singular"},
		{10, "signature", "bytes", "singular"},
		{11, "collection", "message", "singular"},
		{12, "assignment_execution", "message", "singular"},
	})

	// THE CLAIMS ONEOF. Its member field NUMBERS are the framing discriminants, so a new member
	// must be added to claimsFramed deliberately -- a missing case silently frames discriminant 0.
	od := (&edgev1.EdgeSignedCapabilityV1{}).ProtoReflect().Descriptor().Oneofs().ByName("claims")
	if od == nil {
		t.Fatal("EdgeSignedCapabilityV1.claims oneof missing")
	}
	wantMembers := map[int32]string{
		7: "production", 8: "source", 9: "delivery", 11: "collection", 12: "assignment_execution",
	}
	if od.Fields().Len() != len(wantMembers) {
		t.Fatalf("claims oneof has %d members, want exactly %d -- a new member needs a claimsFramed case",
			od.Fields().Len(), len(wantMembers))
	}
	for i := 0; i < od.Fields().Len(); i++ {
		f := od.Fields().Get(i)
		if want, ok := wantMembers[int32(f.Number())]; !ok || want != string(f.Name()) {
			t.Fatalf("claims oneof member %d = %q, not in the pinned set", f.Number(), f.Name())
		}
	}
}

// TestExecutionGrantDeniesNonValidStatus pins that the CURRENT permission check never returns a
// nil error alongside a non-KeyValid status.
//
// Returning (KeyHistoricallyRevoked, nil) made an error-only caller fail OPEN: a
// compromise-revoked key read as permission to execute. The HISTORICAL verifier is where a
// caller goes for the status without the permission, and it deliberately still reports it.
func TestExecutionGrantDeniesNonValidStatus(t *testing.T) {
	r := validAssignment(t)
	c := validCompiledAssignment(t, r)
	r.CompiledAssignmentSha256 = c.GetCompiledAssignmentSha256()
	raw := carrierBytes(t, c)
	grant := grantBytes(t, executionGrant(t, r, c))

	// A revoked HOST key: the signature still verifies, so only the status rule refuses it.
	revoked := withPerKey(t, map[string]KeyStatus{"host-exec-1": KeyHistoricallyRevoked})

	status, err := VerifyAssignmentExecutionGrant(r, raw, grant, revoked, 150, 1)
	if err == nil {
		t.Fatalf("a revoked key must be an ERROR here, or an error-only caller fails open (status=%v)", status)
	}
	if status != KeyHistoricallyRevoked {
		t.Fatalf("the status must still be reported for triage: got %v", status)
	}

	// The HISTORICAL verifier reports the same status WITHOUT an error: that is its contract,
	// and it is why the current check can afford to be strict.
	hstatus, herr := VerifyAssignmentExecutionGrantHistorical(r, raw, grant, revoked, 150, 1)
	if herr != nil || hstatus != KeyHistoricallyRevoked {
		t.Fatalf("historical verification: status=%v err=%v", hstatus, herr)
	}

	// Control: with the key valid, the current check permits.
	if st, err := VerifyAssignmentExecutionGrant(r, raw, grant, trustBoth(t, KeyValid), 150, 1); err != nil || st != KeyValid {
		t.Fatalf("control: status=%v err=%v", st, err)
	}
}

// assertExactEnum pins an enum's COMPLETE membership: count, numbers and names. A single-value
// assertion cannot do this -- a member ADDED later is simply never mentioned, so the frozen wire
// meaning drifts silently across runtimes.
func assertExactEnum(t *testing.T, ed protoreflect.EnumDescriptor, want map[int32]string) {
	t.Helper()
	values := ed.Values()
	if values.Len() != len(want) {
		var got []string
		for i := 0; i < values.Len(); i++ {
			v := values.Get(i)
			got = append(got, fmt.Sprintf("%d:%s", v.Number(), v.Name()))
		}
		t.Fatalf("%s has %d members, want exactly %d.\nA member was added or removed: decide "+
			"deliberately whether every policy table and validator admits it, then update this "+
			"inventory.\ngot: %v", ed.FullName(), values.Len(), len(want), got)
	}
	for i := 0; i < values.Len(); i++ {
		v := values.Get(i)
		if name, ok := want[int32(v.Number())]; !ok || name != string(v.Name()) {
			t.Fatalf("%s member %d = %q, not in the pinned set", ed.FullName(), v.Number(), v.Name())
		}
	}
}

// TestValidatePlanFromRawPreflightsAllSizesBeforeDecoding pins the ORDER, not just the bounds.
//
// A malformed EARLY page plus an oversize LATER one distinguishes the two algorithms: preflighting
// every size first reports the OVERSIZE page, while bound-and-decode interleaving decodes page 0,
// fails, and reports malformedness -- never reaching the oversize one. Reverting to interleaving
// left both suites green because nothing observed which failure surfaced.
func TestValidatePlanFromRawPreflightsAllSizesBeforeDecoding(t *testing.T) {
	h, pages := buildPlan(t, mustUUID(t), d32(0x77), [][]uint64{{256}})
	raw := rawPages(t, pages)

	// Page 0: syntactically MALFORMED but within the size bound.
	malformed := []byte{0xFF, 0xFF, 0xFF, 0xFF}
	// Page 1: valid bytes padded ONE BYTE over the page ceiling.
	num := fieldNumber(t, &edgev1.ScheduledPlanPageV1{}, "check_set_sha256")
	oversize := padToExactBytes(t, raw[0], num, pages[0].GetCheckSetSha256(), MaxPlanPageBytes+1)

	rawHeader := headerBytes(t, h)

	// PREFLIGHT-FIRST reports the oversize page, which is only reachable if page 0 was never
	// decoded. The distinct sentinel is what makes that observable.
	_, _, err := ValidatePlanFromRaw(rawHeader, [][]byte{malformed, oversize})
	if !errors.Is(err, ErrPlanPageTooLarge) {
		t.Fatalf("malformed-then-oversize = %v, want ErrPlanPageTooLarge (sizes checked before any decode)", err)
	}
	// It is still an ErrPlanBounds for callers matching the general bound.
	if !errors.Is(err, ErrPlanBounds) {
		t.Fatal("ErrPlanPageTooLarge must wrap ErrPlanBounds")
	}
	// CONTROL: with NO oversize page, the malformed one is reported -- so the case above is the
	// ordering and not a fixture that always returns the same error.
	if _, _, err := ValidatePlanFromRaw(rawHeader, [][]byte{malformed}); errors.Is(err, ErrPlanPageTooLarge) {
		t.Fatalf("a malformed page alone must not report an oversize page: %v", err)
	}
}

// TestValidatePlanFromRawReportsHeaderFailureFirst pins that the HEADER's authoritative failure is
// not masked by whichever page happens to break first.
func TestValidatePlanFromRawReportsHeaderFailureFirst(t *testing.T) {
	h, pages := buildPlan(t, mustUUID(t), d32(0x77), [][]uint64{{256}})
	raw := rawPages(t, pages)

	// An UNSUPPORTED header digest version, plus a malformed page.
	bad := proto.Clone(h).(*edgev1.ScheduledPlanHeaderV1)
	bad.DigestVersion = PlanDigestVersion + 99
	headerErr := ValidatePlanHeader(bad)
	if headerErr == nil {
		t.Fatal("control: the mutated header must be invalid on its own")
	}

	_, _, err := ValidatePlanFromRaw(headerBytes(t, bad), [][]byte{{0xFF, 0xFF, 0xFF, 0xFF}})
	if !errors.Is(err, headerErr) {
		t.Fatalf("unsupported header + malformed page = %v, want the HEADER error %v", err, headerErr)
	}
	// CONTROL: a GOOD header with the same malformed page reports the page, so the case above is
	// the header check running first.
	if _, _, err := ValidatePlanFromRaw(headerBytes(t, h), [][]byte{{0xFF, 0xFF, 0xFF, 0xFF}}); errors.Is(err, headerErr) {
		t.Fatalf("a good header must not report the header error: %v", err)
	}
	_ = raw
}
