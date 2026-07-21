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
	"crypto/ed25519"
	"crypto/sha256"
	"errors"
	"net/netip"
	"testing"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func rng(from, through uint64) *edgev1.EdgeLostRangeV1 {
	return &edgev1.EdgeLostRangeV1{FromSequence: from, ThroughSequence: through}
}

// buildManifest builds a valid single-recovery chained manifest with computed
// page digests, prev-hash links, and an affected scope covering every lost range.
func buildManifest(t *testing.T, recoveryID []byte, pageRanges [][]*edgev1.EdgeLostRangeV1) []*edgev1.EdgeLossManifestPageV1 {
	t.Helper()
	count := len(pageRanges)
	pages := make([]*edgev1.EdgeLossManifestPageV1, count)
	var prev []byte
	for i, ranges := range pageRanges {
		var affected []*edgev1.EdgeAffectedScopeV1
		for _, r := range ranges {
			affected = append(affected, &edgev1.EdgeAffectedScopeV1{
				FromSequence: r.GetFromSequence(), ThroughSequence: r.GetThroughSequence(),
				ContractBundleSha256: d32(0x01), ProducerAssignmentId: mustUUID(t), RunId: mustUUID(t),
				RunShard: 2, AuthorityEpoch: 5, ScopeSha256: d32(0x02), RangeSha256: d32(0x03),
			})
		}
		p := &edgev1.EdgeLossManifestPageV1{
			RecoveryId: recoveryID, PageIndex: uint32(i), PageCount: uint32(count),
			PrevPageSha256: prev, Terminal: i == count-1, DigestVersion: RecoveryDigestVersion,
			LostRanges: ranges, Affected: affected,
		}
		p.PageSha256 = ManifestPageDigest(p)
		pages[i] = p
		prev = p.PageSha256
	}
	return pages
}

func TestManifestChainValid(t *testing.T) {
	rid := mustUUID(t)
	pages := buildManifest(t, rid, [][]*edgev1.EdgeLostRangeV1{{rng(10, 20), rng(30, 40)}, {rng(100, 110)}})
	if err := ValidateManifestChain(pages, ManifestRoot(pages)); err != nil {
		t.Fatalf("valid manifest: %v", err)
	}
	tomb := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: rid, PriorSpoolId: mustUUID(t), NewSpoolId: mustUUID(t),
		LostFromSequence: 10, LostThroughSequence: 110,
		ManifestRootSha256: ManifestRoot(pages), ManifestPageCount: uint32(len(pages)), DigestVersion: RecoveryDigestVersion,
	}
	if err := ValidateTombstone(tomb, pages); err != nil {
		t.Fatalf("valid tombstone: %v", err)
	}
}

func TestManifestRejectsCrossRecoveryAndOverlap(t *testing.T) {
	// Different recovery IDs across pages.
	a := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeLostRangeV1{{rng(1, 2)}, {rng(3, 4)}})
	a[1].RecoveryId = mustUUID(t)
	a[1].PrevPageSha256 = a[0].PageSha256
	a[1].PageSha256 = ManifestPageDigest(a[1])
	if err := ValidateManifestChain(a, nil); !errors.Is(err, ErrManifestRecoveryID) {
		t.Fatalf("cross-recovery = %v, want ErrManifestRecoveryID", err)
	}

	// Ranges overlapping across the page boundary.
	rid := mustUUID(t)
	b := buildManifest(t, rid, [][]*edgev1.EdgeLostRangeV1{{rng(10, 20)}, {rng(15, 25)}})
	if err := ValidateManifestChain(b, nil); !errors.Is(err, ErrManifestRange) {
		t.Fatalf("cross-page overlap = %v, want ErrManifestRange", err)
	}

	// Lost sequence 0 (lane sequences start at 1) is rejected.
	c := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeLostRangeV1{{rng(0, 5)}})
	if err := ValidateManifestChain(c, nil); !errors.Is(err, ErrManifestRange) {
		t.Fatalf("lost sequence 0 = %v, want ErrManifestRange", err)
	}
}

func TestManifestRejectsUncoveredAffected(t *testing.T) {
	rid := mustUUID(t)
	pages := buildManifest(t, rid, [][]*edgev1.EdgeLostRangeV1{{rng(10, 20)}})
	// Add an affected entry entirely outside the lost range.
	pages[0].Affected = append(pages[0].Affected, &edgev1.EdgeAffectedScopeV1{
		FromSequence: 100, ThroughSequence: 200, ContractBundleSha256: d32(1),
		ProducerAssignmentId: mustUUID(t), RunId: mustUUID(t), ScopeSha256: d32(2), RangeSha256: d32(3),
	})
	pages[0].PageSha256 = ManifestPageDigest(pages[0])
	if err := ValidateManifestChain(pages, nil); !errors.Is(err, ErrManifestAffected) {
		t.Fatalf("affected outside lost range = %v, want ErrManifestAffected", err)
	}
}

// Reviewer repro (r3-09): a coarsened manifest may not discard ALL identity; it
// must still carry at least one conservative affected scope covering the loss.
func TestCoarsenedManifestNeedsAffectedScope(t *testing.T) {
	rid := mustUUID(t)
	pages := buildManifest(t, rid, [][]*edgev1.EdgeLostRangeV1{{rng(1, 10)}})
	pages[0].Coarsened = true
	pages[0].Affected = nil // discard all identity
	pages[0].PageSha256 = ManifestPageDigest(pages[0])
	if err := ValidateManifestChain(pages, nil); !errors.Is(err, ErrManifestAffected) {
		t.Fatalf("coarsened with zero affected = %v, want ErrManifestAffected", err)
	}
	// Coarsening flags must reconcile: a coarsened page needs a coarsened entry.
	pages2 := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeLostRangeV1{{rng(1, 10)}})
	pages2[0].Coarsened = true // page coarsened but its affected entry is not
	pages2[0].PageSha256 = ManifestPageDigest(pages2[0])
	if err := ValidateManifestChain(pages2, nil); !errors.Is(err, ErrManifestCoarsen) {
		t.Fatalf("coarsen flag mismatch = %v, want ErrManifestCoarsen", err)
	}
}

func TestTombstoneMustReconcile(t *testing.T) {
	rid := mustUUID(t)
	pages := buildManifest(t, rid, [][]*edgev1.EdgeLostRangeV1{{rng(10, 20)}})
	// Tombstone recovery id differs from the manifest's.
	tomb := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: mustUUID(t), PriorSpoolId: mustUUID(t), NewSpoolId: mustUUID(t),
		LostFromSequence: 10, LostThroughSequence: 20,
		ManifestRootSha256: ManifestRoot(pages), ManifestPageCount: 1, DigestVersion: RecoveryDigestVersion,
	}
	if err := ValidateTombstone(tomb, pages); !errors.Is(err, ErrManifestRecoveryID) && !errors.Is(err, ErrTombstoneMismatch) {
		t.Fatalf("cross-recovery tombstone = %v, want reconciliation error", err)
	}
	// Wrong loss interval.
	tomb2 := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: rid, PriorSpoolId: mustUUID(t), NewSpoolId: mustUUID(t),
		LostFromSequence: 999, LostThroughSequence: 1000,
		ManifestRootSha256: ManifestRoot(pages), ManifestPageCount: 1, DigestVersion: RecoveryDigestVersion,
	}
	if err := ValidateTombstone(tomb2, pages); !errors.Is(err, ErrTombstoneMismatch) {
		t.Fatalf("wrong loss interval = %v, want ErrTombstoneMismatch", err)
	}
	// prior_spool_id == new_spool_id is rejected.
	spool := mustUUID(t)
	tomb3 := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: rid, PriorSpoolId: spool, NewSpoolId: spool,
		LostFromSequence: 10, LostThroughSequence: 20,
		ManifestRootSha256: ManifestRoot(pages), ManifestPageCount: 1, DigestVersion: RecoveryDigestVersion,
	}
	if err := ValidateTombstone(tomb3, pages); !errors.Is(err, ErrTombstoneMismatch) {
		t.Fatalf("prior==new spool = %v, want ErrTombstoneMismatch", err)
	}
}

// Reviewer repro (r3-02/r4-08): a recovery-control record authorized for context
// A cannot ship a payload body for context B; ValidateRecoveryControl decodes the
// actual record payload.
func TestValidateRecoveryControlBindsContext(t *testing.T) {
	rid := mustUUID(t)
	contract := func(r *edgev1.EdgeRecordV1) *edgev1.EdgeOutputContractRef { return r.GetOutputContract() }
	r, policy := recoveryControlRecord(t, rid, rid, false)
	if err := ValidateRecoveryControl(r, contract(r), policy); err != nil {
		t.Fatalf("matching recovery context: %v", err)
	}
	r2, policy2 := recoveryControlRecord(t, rid, mustUUID(t), false)
	if err := ValidateRecoveryControl(r2, contract(r2), policy2); !errors.Is(err, ErrTombstoneMismatch) {
		t.Fatalf("cross-context recovery = %v, want ErrTombstoneMismatch", err)
	}
	// Reviewer repro (r5-05): reusing the same signed scope while changing the
	// tombstone spool/loss/root is rejected -- scope_sha256 no longer matches.
	r3, policy3 := recoveryControlRecord(t, rid, rid, true)
	if err := ValidateRecoveryControl(r3, contract(r3), policy3); !errors.Is(err, ErrTombstoneMismatch) {
		t.Fatalf("scope substitution = %v, want ErrTombstoneMismatch", err)
	}
}

// recoveryControlRecord builds a fully SIGNED RECOVERY_CONTROL record whose source
// scope fixes the tombstone body, plus a policy accepting it. When mutateBody is
// set, the tombstone loss interval is changed AFTER the scope was signed (the
// r5-05 substitution repro).
func recoveryControlRecord(t *testing.T, sourceCtxID, bodyRecoveryID []byte, mutateBody bool) (*edgev1.EdgeRecordV1, AuthorizationPolicy) {
	t.Helper()
	tomb := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: bodyRecoveryID, PriorSpoolId: mustUUID(t), NewSpoolId: mustUUID(t),
		LostFromSequence: 10, LostThroughSequence: 20, ManifestRootSha256: d32(0x11),
		ManifestPageCount: 1, DigestVersion: RecoveryDigestVersion, DetectedAtUnixNano: 1, Reason: "torn-tail",
	}
	scopeDigest := TombstoneScopeDigest(tomb)
	if mutateBody {
		tomb.LostFromSequence, tomb.LostThroughSequence = 1000, 2000
	}
	pl := &edgev1.EdgeRecoveryControlPayloadV1{Body: &edgev1.EdgeRecoveryControlPayloadV1_Tombstone{Tombstone: tomb}}
	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(pl)
	if err != nil {
		t.Fatalf("marshal recovery payload: %v", err)
	}
	r := validRecord(t)
	r.PayloadFamily = edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1
	r.RouteProfile = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
	r.Payload = payload
	r.EncodedSize = uint32(len(payload))
	r.UncompressedSize = uint32(len(payload))
	sum := sha256.Sum256(payload)
	r.PayloadSha256 = sum[:]

	prodPub, prodPriv, _ := ed25519.GenerateKey(nil)
	pc := r.GetProductionCapability()
	pc.GetProduction().RouteProfile = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
	SignCapability(pc, prodPriv)

	srcPub, srcPriv, _ := ed25519.GenerateKey(nil)
	src := sourceCap(t, r, sourceCtxID, sourceCtxID, edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL)
	src.IssuerId, src.IssuerKeyId = mustUUID(t), mustUUID(t)
	src.GetSource().ScopeSha256 = scopeDigest
	SignCapability(src, srcPriv)
	r.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:       edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL,
		Capability: src, ContextId: sourceCtxID, ScopeId: sourceCtxID, ScopeSha256: scopeDigest,
	}
	reseal(r)
	policy := AuthorizationPolicy{
		Trust: mapTrust{
			trustKey(pc.GetIssuerId(), pc.GetIssuerKeyId()):   prodPub,
			trustKey(src.GetIssuerId(), src.GetIssuerKeyId()): srcPub,
		},
		NowUnixNano:      nowFor(t, r.GetEventId()),
		ActiveFence:      ResolvedFence(r.GetProducerContext().GetAuthorityEpoch()),
		TrustPolicyEpoch: 1,
	}
	return r, policy
}

// ipRange returns a canonical first/last IPv4 span of exactly count addresses in
// the 10.uniq.0.0 block.
func ipRange(uniq int, count uint64) (string, string) {
	base := uint32(10)<<24 | uint32(uniq)<<16
	first := netip.AddrFrom4([4]byte{byte(base >> 24), byte(base >> 16), byte(base >> 8), byte(base)})
	l := base + uint32(count) - 1
	last := netip.AddrFrom4([4]byte{byte(l >> 24), byte(l >> 16), byte(l >> 8), byte(l)})
	return first.String(), last.String()
}

// buildPlan builds a valid chained plan whose ranges each expand to EXACTLY their
// declared target count (span form), with per-range identity, computed digests,
// plan root, and a self-consistent header.
func buildPlan(t *testing.T, planID, checkSet []byte, pageRanges [][]uint64) (*edgev1.ScheduledPlanHeaderV1, []*edgev1.ScheduledPlanPageV1) {
	t.Helper()
	count := len(pageRanges)
	pages := make([]*edgev1.ScheduledPlanPageV1, count)
	var prev []byte
	var total uint64
	uniq := 1
	for i, counts := range pageRanges {
		var ranges []*edgev1.TargetRangeV1
		for _, tc := range counts {
			first, last := ipRange(uniq, tc)
			r := &edgev1.TargetRangeV1{
				RangeId: mustUUID(t), FirstAddress: first, LastAddress: last,
				TargetCount: tc, CheckSetSha256: checkSet, AvailabilityPolicyId: []byte("policy-1"),
			}
			uniq++
			r.RangeSha256 = RangeDigest(r)
			ranges = append(ranges, r)
			total += tc
		}
		p := &edgev1.ScheduledPlanPageV1{
			ExecutionPlanId: planID, PageIndex: uint32(i), PageCount: uint32(count),
			PrevPageSha256: prev, CheckSetSha256: checkSet, DigestVersion: PlanDigestVersion, Ranges: ranges,
		}
		p.PageSha256 = PlanPageDigest(p)
		pages[i] = p
		prev = p.PageSha256
	}
	h := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId: planID, PageCount: uint32(count), TotalTargetCount: total,
		PlanRootSha256: PlanRoot(pages), DigestVersion: PlanDigestVersion, CheckSetSha256: checkSet,
		AvailabilityPolicyId: []byte("policy-1"), NetworkScopeId: mustUUID(t),
	}
	h.ExecutionPlanSha256 = PlanHeaderDigest(h)
	return h, pages
}

func TestPlanValidAndConstantSize(t *testing.T) {
	planID := mustUUID(t)
	h, pages := buildPlan(t, planID, d32(0x77), [][]uint64{{256, 256}, {512}})
	if err := ValidatePlanHeader(h); err != nil {
		t.Fatalf("plan header: %v", err)
	}
	if err := ValidatePlanPages(h, pages); err != nil {
		t.Fatalf("plan pages: %v", err)
	}
	if len(h.GetPlanRootSha256()) != 32 {
		t.Fatal("plan root must be constant 32 bytes")
	}
}

func TestPlanRejectsTotalsAndPolicy(t *testing.T) {
	planID := mustUUID(t)
	h, pages := buildPlan(t, planID, d32(0x77), [][]uint64{{10}})
	// Corrupt the header total (must not equal the range sum).
	h.TotalTargetCount = 999
	h.ExecutionPlanSha256 = PlanHeaderDigest(h)
	if err := ValidatePlanPages(h, pages); !errors.Is(err, ErrPlanTotals) {
		t.Fatalf("total mismatch = %v, want ErrPlanTotals", err)
	}
	// Header with no availability policy.
	h2, _ := buildPlan(t, planID, d32(0x77), [][]uint64{{10}})
	h2.AvailabilityPolicyId = nil
	h2.ExecutionPlanSha256 = PlanHeaderDigest(h2)
	if err := ValidatePlanHeader(h2); !errors.Is(err, ErrPlanPolicy) {
		t.Fatalf("missing policy = %v, want ErrPlanPolicy", err)
	}
}

// Reviewer repro (r3-08): a rehashed range whose declared target count exceeds its
// address span, or whose CIDR is unparseable/non-canonical, is rejected.
func TestPlanRejectsSemanticallyInvalidRange(t *testing.T) {
	planID := mustUUID(t)
	// target_count must equal the span exactly; +1 breaks it.
	h, pages := buildPlan(t, planID, d32(0x77), [][]uint64{{256}})
	pages[0].Ranges[0].TargetCount = 257
	pages[0].Ranges[0].RangeSha256 = RangeDigest(pages[0].Ranges[0])
	pages[0].PageSha256 = PlanPageDigest(pages[0])
	h.TotalTargetCount = 257
	h.PlanRootSha256 = PlanRoot(pages)
	h.ExecutionPlanSha256 = PlanHeaderDigest(h)
	if err := ValidatePlanPages(h, pages); !errors.Is(err, ErrPlanRange) {
		t.Fatalf("count != span = %v, want ErrPlanRange", err)
	}

	// A non-canonical IPv6 CIDR spelling is rejected.
	h2, pages2 := buildPlan(t, planID, d32(0x77), [][]uint64{{1}})
	pages2[0].Ranges[0].FirstAddress = ""
	pages2[0].Ranges[0].LastAddress = ""
	pages2[0].Ranges[0].Cidr = "2001:0DB8::/128" // non-canonical (should be 2001:db8::)
	pages2[0].Ranges[0].TargetCount = 1
	pages2[0].Ranges[0].RangeSha256 = RangeDigest(pages2[0].Ranges[0])
	pages2[0].PageSha256 = PlanPageDigest(pages2[0])
	h2.PlanRootSha256 = PlanRoot(pages2)
	h2.ExecutionPlanSha256 = PlanHeaderDigest(h2)
	if err := ValidatePlanPages(h2, pages2); !errors.Is(err, ErrPlanRange) {
		t.Fatalf("non-canonical cidr spelling = %v, want ErrPlanRange", err)
	}

	// A range check set that disagrees with its page/header check set is rejected.
	h3, pages3 := buildPlan(t, planID, d32(0x77), [][]uint64{{1}})
	pages3[0].Ranges[0].CheckSetSha256 = d32(0x55)
	pages3[0].Ranges[0].RangeSha256 = RangeDigest(pages3[0].Ranges[0])
	pages3[0].PageSha256 = PlanPageDigest(pages3[0])
	h3.PlanRootSha256 = PlanRoot(pages3)
	h3.ExecutionPlanSha256 = PlanHeaderDigest(h3)
	if err := ValidatePlanPages(h3, pages3); !errors.Is(err, ErrPlanCheckSet) {
		t.Fatalf("range check set mismatch = %v, want ErrPlanCheckSet", err)
	}
}
