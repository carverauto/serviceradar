package edgerecord

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// The SHARED VERSION corpus (tasks 1.5-b, 1.6-a, 1.6-b): one exhaustive object inventory, and
// for every member a committed artifact that a peer running a DIFFERENT grammar version would
// emit, which both runtimes must REFUSE.
//
// ## Two proof classes, because most versions are not on the wire
//
//	CLASS A -- the object DECODES a version from its input. Set it unsupported and require
//	           refusal. Seven members here plus Sr-Edge-Transport-Provenance, whose framed
//	           envelope carries a decodable version and whose vector already exists in
//	           pubid_reject_vectors.txt.
//	CLASS B -- the version is a COMPILE-TIME CONSTANT inside a preimage and the received value
//	           is a digest, so there is no version input to corrupt. The artifact is instead
//	           RECOMPUTED under an altered constant and must be refused as a mismatch.
//
// An object appears in exactly ONE class. Listing one in both would double-count it, and a
// Class-B object asked for an unsupported-INPUT vector cannot supply one.
//
// ## How the Class-B artifacts are authored, and why not any other way
//
// Each Class-B digest builder is split into an exported wrapper that passes its frozen
// constant and an unexported `...WithVersion` helper. THE GENERATOR IS THE ONLY CALLER that
// passes anything else, and it does so once, to commit the artifact.
//
// The alternative was re-implementing each transcript in the test with a different leading
// version. That is the failure this design avoids: a second copy of a grammar agrees on the
// day it is written and drifts silently afterwards, so the corpus would stop describing the
// grammar it is supposed to freeze. Exposing preimages as runtime API was rejected for the
// opposite reason -- it widens the shipped surface for a test's convenience.
//
// ## Every row drives a PRODUCTION verifier
//
// The altered artifact is fed to the same exported function that trusts that digest in
// production -- ValidateRecord, ValidatePlanPages, ValidateTombstone, ValidateRecoveryControl
// and friends -- never to a check written for the corpus. A "version validator" invented here
// would prove only that the corpus can reject its own inputs.
//
// ## The cross-runtime contract is ACCEPT vs REFUSE
//
// Not the error name, and not the retry classification: which of `:poison`/`:systemic` a
// refusal carries is task 1.5-l's, and freezing it here would freeze two things at once.
const versionManifest = "version_corpus.txt"

// versionVector is one inventory member: a control the verifier must ACCEPT and an altered
// artifact it must REFUSE, both committed, plus the verifier that decides.
//
// `peer` is the companion fixture for objects whose verifier takes two inputs (a plan header
// with its page, a tombstone with its manifest page). It is committed too, so a row is
// reproducible from the corpus alone rather than from another test's fixtures.
type versionVector struct {
	object string
	class  string
	// ok/alt are the committed control and altered artifacts; peer completes a two-input
	// verifier and is shared by both.
	ok, alt, peer string
	build         func(t *testing.T) (okBytes, altBytes, peerBytes []byte)
	// reuse marks a row whose artifacts are authored ELSEWHERE and only consumed here. The
	// nineteenth object is the already-landed transport-provenance vector: duplicating its
	// bytes would create a second source of truth, and merely NAMING it would leave the row a
	// pointer rather than a proof, so the row reads the existing artifact and EXECUTES it.
	reuse bool
	// goOnly marks an object NO ELIXIR CONSUMER ENFORCES. It is recorded in the manifest as
	// data rather than described in prose, so the peer suite must assert the asymmetry instead
	// of silently having nothing to run -- and so a row that later gains a peer, or loses one,
	// changes a committed byte.
	goOnly bool
	// verify runs the PRODUCTION verifier over one artifact plus the peer.
	verify func(t *testing.T, artifact, peer []byte) error
}

// altVersion is the version every Class-B artifact is authored under: the frozen constant
// plus one. A peer that shipped a NEW grammar version is exactly the case these vectors
// exist for, and +1 is the value such a peer would use first.
func altVersion(frozen uint64) uint64 { return frozen + 1 }

func mustMarshalMsg(t *testing.T, m proto.Message) []byte {
	t.Helper()

	raw, err := proto.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	return raw
}

func unmarshalRecord(t *testing.T, raw []byte) *edgev1.EdgeRecordV1 {
	t.Helper()

	var r edgev1.EdgeRecordV1
	if err := proto.Unmarshal(raw, &r); err != nil {
		t.Fatalf("unmarshal record: %v", err)
	}

	return &r
}

// ---- CLASS B: semantic envelope ---------------------------------------------------------

func semanticEnvelopeVector() versionVector {
	return versionVector{
		object: "semantic_envelope", class: "B",
		ok:  "version_semantic_envelope_ok.bin",
		alt: "version_semantic_envelope_alt.bin",
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			ok := validRecordFixed(t)

			alt, _ := proto.Clone(ok).(*edgev1.EdgeRecordV1)
			// The ONLY difference: the carried envelope digest is the one a peer on the next
			// grammar version would compute over these exact fields.
			alt.SemanticEnvelopeSha256 = semanticEnvelopeDigestWithVersion(alt, altVersion(semanticDigestVersion))

			return mustMarshalMsg(t, ok), mustMarshalMsg(t, alt), nil
		},
		verify: func(t *testing.T, artifact, _ []byte) error {
			t.Helper()
			return ValidateRecord(unmarshalRecord(t, artifact))
		},
	}
}

// ---- CLASS A: capability version --------------------------------------------------------

func capabilityVersionVector() versionVector {
	return versionVector{
		object: "capability", class: "A",
		ok:  "version_capability_ok.bin",
		alt: "version_capability_alt.bin",
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			ok := validRecordFixed(t)

			alt, _ := proto.Clone(ok).(*edgev1.EdgeRecordV1)
			// 1 is the only member of knownCapabilityVersions, so 2 is what a peer running the
			// next capability grammar would present.
			alt.GetProductionCapability().CapabilityVersion = 2
			// The envelope digest is resealed so the version is the ONLY thing wrong: a stale
			// digest would be refused for a reason that has nothing to do with versions.
			alt.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(alt)

			return mustMarshalMsg(t, ok), mustMarshalMsg(t, alt), nil
		},
		verify: func(t *testing.T, artifact, _ []byte) error {
			t.Helper()
			return ValidateRecord(unmarshalRecord(t, artifact))
		},
	}
}

// ---- CLASS A: recovery manifest page + tombstone ----------------------------------------

// recoveryPages is the deterministic two-page manifest every recovery row is built from.
func recoveryPages(t *testing.T) []*edgev1.EdgeLossManifestPageV1 {
	t.Helper()

	return stabilizeSpanIdentities(t, buildManifest(t, stableUUID(0x61),
		[][]*edgev1.EdgeClassificationSpanV1{
			{activeSpan(t, 10, 20)},
			{passiveSpan(t, 100, 110)},
		}))
}

// stabilizeSpanIdentities replaces every span identity minted by mustUUID -- which is RANDOM,
// fine for an in-process assertion and useless for a COMMITTED vector -- and rebuilds the page
// chain over the result.
func stabilizeSpanIdentities(
	t *testing.T, pages []*edgev1.EdgeLossManifestPageV1,
) []*edgev1.EdgeLossManifestPageV1 {
	t.Helper()

	seed := byte(0x90)

	var prev []byte

	for _, p := range pages {
		for _, sp := range p.GetClassificationSpans() {
			for _, id := range []*edgev1.EdgeAttributedSpanIdentityV1{
				sp.GetAttributedActive().GetIdentity(), sp.GetAttributedPassive().GetIdentity(),
			} {
				if id == nil {
					continue
				}

				id.ProducerAssignmentId = stableUUID(seed)
				id.RunId = stableUUID(seed + 1)
				id.ProductionScopeId = stableUUID(seed + 2)
				seed += 3
			}
		}

		p.PrevPageSha256 = prev
		p.PageSha256 = ManifestPageDigest(p)
		prev = p.PageSha256
	}

	return pages
}

func manifestPageVersionVector() versionVector {
	// A genuinely SINGLE-page manifest, so both runtimes validate the committed bytes AS THEY
	// ARE. An earlier version committed page 0 of a two-page chain and normalised it inside the
	// Go verifier, which meant the peer runtime could not run the same row without repeating
	// that surgery -- a shared vector each side has to reshape differently is not shared.
	onePage := func(t *testing.T) *edgev1.EdgeLossManifestPageV1 {
		t.Helper()

		return buildManifest(t, stableUUID(0x61), [][]*edgev1.EdgeClassificationSpanV1{
			{activeSpan(t, 10, 20)},
		})[0]
	}

	return versionVector{
		object: "manifest_page", class: "A",
		ok:  "version_manifest_page_ok.bin",
		alt: "version_manifest_page_alt.bin",
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			ok := stabilizeSpanIdentities(t, []*edgev1.EdgeLossManifestPageV1{onePage(t)})[0]

			alt, _ := proto.Clone(ok).(*edgev1.EdgeLossManifestPageV1)
			alt.DigestVersion = RecoveryDigestVersion + 1
			// Self-consistent under its own declared version, so the refusal is the version and
			// not a stale self-digest.
			alt.PageSha256 = ManifestPageDigest(alt)

			return mustMarshalMsg(t, ok), mustMarshalMsg(t, alt), nil
		},
		verify: func(t *testing.T, artifact, _ []byte) error {
			t.Helper()
			var p edgev1.EdgeLossManifestPageV1
			if err := proto.Unmarshal(artifact, &p); err != nil {
				t.Fatalf("unmarshal page: %v", err)
			}

			return ValidateManifestChain([]*edgev1.EdgeLossManifestPageV1{&p}, nil)
		},
	}
}

func tombstoneVersionVector() versionVector {
	return versionVector{
		object: "tombstone", class: "A",
		ok:   "version_tombstone_ok.bin",
		alt:  "version_tombstone_alt.bin",
		peer: "version_tombstone_pages.bin",
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			pages := recoveryPages(t)
			ok := tombstoneFor(pages)

			alt, _ := proto.Clone(ok).(*edgev1.SpoolLossTombstoneV1)
			alt.DigestVersion = RecoveryDigestVersion + 1

			return mustMarshalMsg(t, ok), mustMarshalMsg(t, alt), marshalPages(t, pages)
		},
		verify: func(t *testing.T, artifact, peer []byte) error {
			t.Helper()
			var tomb edgev1.SpoolLossTombstoneV1
			if err := proto.Unmarshal(artifact, &tomb); err != nil {
				t.Fatalf("unmarshal tombstone: %v", err)
			}

			return ValidateTombstone(&tomb, unmarshalPages(t, peer))
		},
	}
}

// ---- CLASS B: manifest root -------------------------------------------------------------

func manifestRootVector() versionVector {
	return versionVector{
		object: "manifest_root", class: "B",
		ok:   "version_manifest_root_ok.bin",
		alt:  "version_manifest_root_alt.bin",
		peer: "version_manifest_root_pages.bin",
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			pages := recoveryPages(t)
			ok := tombstoneFor(pages)

			alt, _ := proto.Clone(ok).(*edgev1.SpoolLossTombstoneV1)
			// The root a peer on the next recovery grammar would commit over these same pages.
			alt.ManifestRootSha256 = manifestRootWithVersion(pages, altVersion(RecoveryDigestVersion))

			return mustMarshalMsg(t, ok), mustMarshalMsg(t, alt), marshalPages(t, pages)
		},
		verify: func(t *testing.T, artifact, peer []byte) error {
			t.Helper()
			var tomb edgev1.SpoolLossTombstoneV1
			if err := proto.Unmarshal(artifact, &tomb); err != nil {
				t.Fatalf("unmarshal tombstone: %v", err)
			}

			return ValidateTombstone(&tomb, unmarshalPages(t, peer))
		},
	}
}

func tombstoneFor(pages []*edgev1.EdgeLossManifestPageV1) *edgev1.SpoolLossTombstoneV1 {
	return &edgev1.SpoolLossTombstoneV1{
		RecoveryId: pages[0].GetRecoveryId(), PriorSpoolId: stableUUID(0x62), NewSpoolId: stableUUID(0x63),
		ManifestRootSha256: ManifestRoot(pages), ManifestPageCount: uint32(len(pages)),
		DigestVersion: RecoveryDigestVersion, DetectedAtUnixNano: 1, Reason: "torn-tail",
	}
}

// marshalPages frames a page list as a length-delimited run so a multi-input verifier's peer
// is ONE committed file rather than a naming convention the peer runtime has to guess.
func marshalPages(t *testing.T, pages []*edgev1.EdgeLossManifestPageV1) []byte {
	t.Helper()

	var out []byte

	for _, p := range pages {
		raw := mustMarshalMsg(t, p)
		out = protowire.AppendBytes(out, raw)
	}

	return out
}

func unmarshalPages(t *testing.T, framed []byte) []*edgev1.EdgeLossManifestPageV1 {
	t.Helper()

	var pages []*edgev1.EdgeLossManifestPageV1

	for len(framed) > 0 {
		raw, n := protowire.ConsumeBytes(framed)
		if n < 0 {
			t.Fatalf("peer framing: bad length prefix")
		}

		var p edgev1.EdgeLossManifestPageV1
		if err := proto.Unmarshal(raw, &p); err != nil {
			t.Fatalf("unmarshal peer page: %v", err)
		}

		pages = append(pages, &p)
		framed = framed[n:]
	}

	return pages
}

// ---- the deterministic plan every plan row is built from --------------------------------

// stablePlan is buildPlan with every minted identity replaced by a fixed one and every digest
// recomputed bottom-up. buildPlan uses mustUUID, which is random -- fine for an in-process
// assertion, useless for a COMMITTED vector, which must be byte-identical on every run.
func stablePlan(t *testing.T) (*edgev1.ScheduledPlanHeaderV1, []*edgev1.ScheduledPlanPageV1) {
	t.Helper()

	h, pages := buildPlan(t, stableUUID(0x70), d32(0x71), [][]uint64{{4}, {6}})

	seed := byte(0x80)

	var prev []byte

	for _, p := range pages {
		for _, r := range p.GetRanges() {
			r.RangeId = stableUUID(seed)
			seed++
			r.RangeSha256 = RangeDigest(r)
		}

		p.PrevPageSha256 = prev
		p.PageSha256 = PlanPageDigest(p)
		prev = p.PageSha256
	}

	h.NetworkScopeId = stableUUID(0x7F)
	h.PlanRootSha256 = PlanRoot(pages)
	h.MtrOrdinalRangeCommitment = mustPlanCommitment(t, pages)
	h.ExecutionPlanSha256 = PlanHeaderDigest(h)

	return h, pages
}

func marshalPlanPages(t *testing.T, pages []*edgev1.ScheduledPlanPageV1) []byte {
	t.Helper()

	var out []byte

	for _, p := range pages {
		out = protowire.AppendBytes(out, mustMarshalMsg(t, p))
	}

	return out
}

func unmarshalPlanPages(t *testing.T, framed []byte) []*edgev1.ScheduledPlanPageV1 {
	t.Helper()

	var pages []*edgev1.ScheduledPlanPageV1

	for len(framed) > 0 {
		raw, n := protowire.ConsumeBytes(framed)
		if n < 0 {
			t.Fatalf("peer framing: bad length prefix")
		}

		var p edgev1.ScheduledPlanPageV1
		if err := proto.Unmarshal(raw, &p); err != nil {
			t.Fatalf("unmarshal peer plan page: %v", err)
		}

		pages = append(pages, &p)
		framed = framed[n:]
	}

	return pages
}

func unmarshalPlanHeader(t *testing.T, raw []byte) *edgev1.ScheduledPlanHeaderV1 {
	t.Helper()

	var h edgev1.ScheduledPlanHeaderV1
	if err := proto.Unmarshal(raw, &h); err != nil {
		t.Fatalf("unmarshal plan header: %v", err)
	}

	return &h
}

// ---- CLASS A: plan header + plan page ----------------------------------------------------

func planHeaderVersionVector() versionVector {
	return versionVector{
		object: "plan_header", class: "A",
		ok:  "version_plan_header_ok.bin",
		alt: "version_plan_header_alt.bin",
		// The pages are committed as this row's peer even though Go's boundary
		// (ValidatePlanHeader) does not need them: the Elixir peer has no header-only entry
		// point, and a row the other runtime cannot execute is not a shared vector.
		peer: "version_plan_header_pages.bin",
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			ok, pages := stablePlan(t)

			alt, _ := proto.Clone(ok).(*edgev1.ScheduledPlanHeaderV1)
			alt.DigestVersion = PlanDigestVersion + 1
			// Self-consistent under its own declared version, so the refusal is the version and
			// not a stale self-digest.
			alt.ExecutionPlanSha256 = PlanHeaderDigest(alt)

			return mustMarshalMsg(t, ok), mustMarshalMsg(t, alt), marshalPlanPages(t, pages)
		},
		verify: func(t *testing.T, artifact, _ []byte) error {
			t.Helper()
			return ValidatePlanHeader(unmarshalPlanHeader(t, artifact))
		},
	}
}

func planPageVersionVector() versionVector {
	return versionVector{
		object: "plan_page", class: "A",
		ok:   "version_plan_page_ok.bin",
		alt:  "version_plan_page_alt.bin",
		peer: "version_plan_page_header.bin",
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			h, pages := stablePlan(t)

			alt := make([]*edgev1.ScheduledPlanPageV1, len(pages))
			for i, p := range pages {
				c, _ := proto.Clone(p).(*edgev1.ScheduledPlanPageV1)
				alt[i] = c
			}

			alt[0].DigestVersion = PlanDigestVersion + 1
			alt[0].PageSha256 = PlanPageDigest(alt[0])
			alt[1].PrevPageSha256 = alt[0].GetPageSha256()
			alt[1].PageSha256 = PlanPageDigest(alt[1])

			// The header is re-rooted over the ALTERED pages, so the chain and root still
			// reconcile and only the page version is wrong.
			ah, _ := proto.Clone(h).(*edgev1.ScheduledPlanHeaderV1)
			ah.PlanRootSha256 = PlanRoot(alt)
			ah.ExecutionPlanSha256 = PlanHeaderDigest(ah)

			return marshalPlanPages(t, pages), marshalPlanPages(t, alt), mustMarshalMsg(t, h)
		},
		verify: func(t *testing.T, artifact, peer []byte) error {
			t.Helper()
			pages := unmarshalPlanPages(t, artifact)
			h := unmarshalPlanHeader(t, peer)
			// The committed header roots the CONTROL pages. Re-root a copy over whatever pages
			// arrive so the row tests the page version, not the root.
			hc, _ := proto.Clone(h).(*edgev1.ScheduledPlanHeaderV1)
			hc.PlanRootSha256 = PlanRoot(pages)
			hc.ExecutionPlanSha256 = PlanHeaderDigest(hc)

			return ValidatePlanPages(hc, pages)
		},
	}
}

// ---- CLASS B: plan root + range digest ---------------------------------------------------

func planRootVector() versionVector {
	return versionVector{
		object: "plan_root", class: "B",
		ok:   "version_plan_root_ok.bin",
		alt:  "version_plan_root_alt.bin",
		peer: "version_plan_root_pages.bin",
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			h, pages := stablePlan(t)

			alt, _ := proto.Clone(h).(*edgev1.ScheduledPlanHeaderV1)
			alt.PlanRootSha256 = planRootWithVersion(pages, altVersion(PlanDigestVersion))
			alt.ExecutionPlanSha256 = PlanHeaderDigest(alt)

			return mustMarshalMsg(t, h), mustMarshalMsg(t, alt), marshalPlanPages(t, pages)
		},
		verify: func(t *testing.T, artifact, peer []byte) error {
			t.Helper()
			return ValidatePlanPages(unmarshalPlanHeader(t, artifact), unmarshalPlanPages(t, peer))
		},
	}
}

func rangeDigestVector() versionVector {
	return versionVector{
		object: "range_digest", class: "B",
		ok:   "version_range_digest_ok.bin",
		alt:  "version_range_digest_alt.bin",
		peer: "version_range_digest_header.bin",
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			h, pages := stablePlan(t)

			alt := make([]*edgev1.ScheduledPlanPageV1, len(pages))
			for i, p := range pages {
				c, _ := proto.Clone(p).(*edgev1.ScheduledPlanPageV1)
				alt[i] = c
			}

			// The range digest a peer on the next plan grammar would commit. Every enclosing
			// digest is recomputed so the ONLY unreconciled value is the range's own.
			alt[0].GetRanges()[0].RangeSha256 =
				rangeDigestWithVersion(alt[0].GetRanges()[0], altVersion(PlanDigestVersion))
			alt[0].PageSha256 = PlanPageDigest(alt[0])
			alt[1].PrevPageSha256 = alt[0].GetPageSha256()
			alt[1].PageSha256 = PlanPageDigest(alt[1])

			return marshalPlanPages(t, pages), marshalPlanPages(t, alt), mustMarshalMsg(t, h)
		},
		verify: func(t *testing.T, artifact, peer []byte) error {
			t.Helper()
			pages := unmarshalPlanPages(t, artifact)
			hc, _ := proto.Clone(unmarshalPlanHeader(t, peer)).(*edgev1.ScheduledPlanHeaderV1)
			hc.PlanRootSha256 = PlanRoot(pages)
			hc.ExecutionPlanSha256 = PlanHeaderDigest(hc)

			return ValidatePlanPages(hc, pages)
		},
	}
}

// ---- CLASS B: the three recovery-operation scope transcripts -----------------------------
//
// These are the only rows whose verifier is reachable ONLY through a valid signature:
// ValidateRecoveryControl calls ValidateRecordSigned first, so the scope comparison is not
// reachable at all unless the record verifies. That ordering is part of the boundary being
// frozen, which is why the row drives the signed path rather than calling the scope digest
// directly -- computing a digest and comparing it here would prove the arithmetic and say
// nothing about where production actually checks it.
//
// THE MINI-GATE each row asserts, in order:
//
//	1. ValidateRecordSigned ACCEPTS both the control and the altered record, under the same
//	   policy. If the altered record failed here, the row would be proving a broken signature
//	   or a stale envelope, not a version.
//	2. ValidateRecoveryControl ACCEPTS the control.
//	3. ValidateRecoveryControl REFUSES the altered record, which by construction differs only
//	   in the claimed scope digest.

// recoveryScopeSeed is a dedicated, test-only Ed25519 seed. One seed for all three rows, and
// the matching PUBLIC key is the only part committed -- the peer runtime needs it to verify
// and must never need the private half.
const recoveryScopeSeed = 0x5C

// recoveryScopeIssuerPub is the committed 32-byte public half. The PRIVATE key is derived from
// the seed above and never leaves this file.
const recoveryScopeIssuerPub = "version_recovery_scope_issuer.pub"

func recoveryScopeKey() (ed25519.PublicKey, ed25519.PrivateKey) {
	priv := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{recoveryScopeSeed}, ed25519.SeedSize))

	pub, _ := priv.Public().(ed25519.PublicKey)

	return pub, priv
}

// scopeControlRecord builds a signed recovery-control record whose source claims assert
// `claimedScope`. Passing the true digest yields the control; passing the altered-version one
// yields a record that is VALID IN EVERY OTHER RESPECT -- correctly signed, correctly sealed --
// and wrong only where the scope is compared.
func scopeControlRecord(
	t *testing.T, body *edgev1.EdgeRecoveryControlPayloadV1, recoveryID, claimedScope []byte,
) (*edgev1.EdgeRecordV1, AuthorizationPolicy) {
	t.Helper()

	pub, priv := recoveryScopeKey()

	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(body)
	if err != nil {
		t.Fatalf("marshal recovery payload: %v", err)
	}

	r := validRecordFixed(t)
	r.PayloadFamily = edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1
	r.RouteProfile = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
	r.Payload = payload
	r.EncodedSize = uint32(len(payload))
	r.UncompressedSize = uint32(len(payload))
	sum := sha256.Sum256(payload)
	r.PayloadSha256 = sum[:]

	pc := r.GetProductionCapability()
	pc.IssuerId, pc.IssuerKeyId = stableUUID(0x50), stableUUID(0x51)
	pc.GetProduction().RouteProfile = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
	SignCapability(pc, priv)

	src := sourceCap(t, r, recoveryID, recoveryID,
		edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL)
	src.IssuerId, src.IssuerKeyId = stableUUID(0x52), stableUUID(0x53)
	// BOTH the signed claim and the outer echo carry the claim, so no unsigned outer value is
	// what the comparison reads.
	src.GetSource().ScopeSha256 = claimedScope
	SignCapability(src, priv)

	r.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:       edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL,
		Capability: src, ContextId: recoveryID, ScopeId: recoveryID, ScopeSha256: claimedScope,
	}
	// Resealed LAST, so the envelope digest covers the claim it ships with.
	r.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(r)

	policy := AuthorizationPolicy{
		Trust: mapTrust{
			trustKey(pc.GetIssuerId(), pc.GetIssuerKeyId()):   pub,
			trustKey(src.GetIssuerId(), src.GetIssuerKeyId()): pub,
		},
		NowUnixNano:      nowFor(t, r.GetEventId()),
		ActiveFence:      ResolvedFence(r.GetProducerContext().GetAuthorityEpoch()),
		TrustPolicyEpoch: 1,
	}

	return r, policy
}

// scopeVector is the shared shape of the three rows: a body, its true scope digest, and the
// digest the same body would carry under the next scope-grammar version.
func scopeVector(
	object, okFile, altFile string,
	build func(t *testing.T) (body *edgev1.EdgeRecoveryControlPayloadV1, recoveryID, trueScope, altScope []byte),
) versionVector {
	return versionVector{
		object: object, class: "B",
		ok: okFile, alt: altFile,
		// BOTH RUNTIMES, since task 1.6-d. This was go_only while Elixir had no signed
		// recovery-control path: the peer could only have recomputed the scope digest and
		// compared it, which is a check written for the corpus rather than the boundary
		// production trusts. Recomputation equality is the allowed fallback only where that
		// equality IS the boundary, and here it is not -- the comparison is reachable only
		// through the signed path, and that ordering is half the rule. Elixir now runs these
		// through `RecoveryValidate.recovery_control/3`, which composes them in the same order.
		// ONE committed public key serves all three rows. It is the peer input every scope row
		// needs, and committing it is what lets the Elixir consumer verify the same records
		// instead of trusting a key only the generator holds.
		peer: recoveryScopeIssuerPub,
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			body, rid, trueScope, altScope := build(t)

			ok, _ := scopeControlRecord(t, body, rid, trueScope)
			alt, _ := scopeControlRecord(t, body, rid, altScope)

			pub, _ := recoveryScopeKey()

			return mustMarshalMsg(t, ok), mustMarshalMsg(t, alt), pub
		},
		verify: func(t *testing.T, artifact, peer []byte) error {
			t.Helper()
			r := unmarshalRecord(t, artifact)
			policy := scopePolicyFor(t, r, peer)

			// THE ORDERING GATE. A refusal from the signed path would mean this row is proving
			// something other than the scope comparison, so it is a hard failure rather than the
			// row's expected refusal.
			if err := ValidateRecordSigned(r, policy); err != nil {
				t.Fatalf("%s: the signed path must accept BOTH records; this one failed: %v",
					shortName(artifact), err)
			}

			return ValidateRecoveryControl(r, r.GetOutputContract(), policy)
		},
	}
}

// scopePolicyFor rebuilds the trust policy from the COMMITTED public key, so the peer file is
// what authorises the record rather than a key the generator happens to still hold.
func scopePolicyFor(t *testing.T, r *edgev1.EdgeRecordV1, pub []byte) AuthorizationPolicy {
	t.Helper()

	if len(pub) != ed25519.PublicKeySize {
		t.Fatalf("committed issuer key is %d bytes, want %d", len(pub), ed25519.PublicKeySize)
	}

	pc := r.GetProductionCapability()
	src := r.GetSourceAuthorization().GetCapability()

	return AuthorizationPolicy{
		Trust: mapTrust{
			trustKey(pc.GetIssuerId(), pc.GetIssuerKeyId()):   ed25519.PublicKey(pub),
			trustKey(src.GetIssuerId(), src.GetIssuerKeyId()): ed25519.PublicKey(pub),
		},
		NowUnixNano:      nowFor(t, r.GetEventId()),
		ActiveFence:      ResolvedFence(r.GetProducerContext().GetAuthorityEpoch()),
		TrustPolicyEpoch: 1,
	}
}

func shortName(b []byte) string { return fmt.Sprintf("record(%d bytes)", len(b)) }

func tombstoneScopeVector() versionVector {
	return scopeVector("tombstone_scope", "version_tombstone_scope_ok.bin", "version_tombstone_scope_alt.bin",
		func(t *testing.T) (*edgev1.EdgeRecoveryControlPayloadV1, []byte, []byte, []byte) {
			t.Helper()
			pages := recoveryPages(t)
			tomb := tombstoneFor(pages)

			return &edgev1.EdgeRecoveryControlPayloadV1{
					Body: &edgev1.EdgeRecoveryControlPayloadV1_Tombstone{Tombstone: tomb},
				},
				tomb.GetRecoveryId(),
				TombstoneScopeDigest(tomb),
				tombstoneScopeDigestWithVersion(tomb, altVersion(RecoveryScopeDigestVersion))
		})
}

func manifestPageScopeVector() versionVector {
	return scopeVector("manifest_page_scope", "version_manifest_page_scope_ok.bin", "version_manifest_page_scope_alt.bin",
		func(t *testing.T) (*edgev1.EdgeRecoveryControlPayloadV1, []byte, []byte, []byte) {
			t.Helper()
			page := recoveryPages(t)[0]
			// A single-page manifest, so validateSingleManifestPage accepts it on its own.
			page.PageIndex, page.PageCount, page.Terminal, page.PrevPageSha256 = 0, 1, true, nil
			page.PageSha256 = ManifestPageDigest(page)

			return &edgev1.EdgeRecoveryControlPayloadV1{
					Body: &edgev1.EdgeRecoveryControlPayloadV1_ManifestPage{ManifestPage: page},
				},
				page.GetRecoveryId(),
				ManifestPageScopeDigest(page),
				manifestPageScopeDigestWithVersion(page, altVersion(RecoveryScopeDigestVersion))
		})
}

func resolvedScopeVector() versionVector {
	return scopeVector("resolved_scope", "version_resolved_scope_ok.bin", "version_resolved_scope_alt.bin",
		func(t *testing.T) (*edgev1.EdgeRecoveryControlPayloadV1, []byte, []byte, []byte) {
			t.Helper()
			pages := recoveryPages(t)
			rv := &edgev1.RecoveryResolvedV1{
				RecoveryId: pages[0].GetRecoveryId(), ManifestRootSha256: ManifestRoot(pages),
				AppliedThroughSequence: 110,
			}

			return &edgev1.EdgeRecoveryControlPayloadV1{
					Body: &edgev1.EdgeRecoveryControlPayloadV1_Resolved{Resolved: rv},
				},
				rv.GetRecoveryId(),
				ResolvedScopeDigest(rv),
				resolvedScopeDigestWithVersion(rv, altVersion(RecoveryScopeDigestVersion))
		})
}

// ---- CLASS A: compiled assignment + MTR completion ---------------------------------------

func compiledAssignmentVersionVector() versionVector {
	return versionVector{
		object: "compiled_assignment", class: "A",
		ok:  "version_compiled_assignment_ok.bin",
		alt: "version_compiled_assignment_alt.bin",
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			_, priv := compiledTestKey(t)

			r := validAssignment(t)
			// validAssignment mints its identities with mustUUID; fix them before the carrier is
			// built, so the compiled digests and signature are deterministic too.
			r.ProducerAssignmentId = stableUUID(0xB0)
			r.ExecutionId = stableUUID(0xB1)
			r.ExecutionPlanId = stableUUID(0xB2)
			r.TargetRangeId = stableUUID(0xB3)
			r.CompiledAssignmentId = stableUUID(0xB4)
			r.NetworkScopeId = stableUUID(0xB5)
			r.AuthenticatedAgentId = stableUUID(0xB6)
			r.ProductionScopeId = stableUUID(0xB7)
			r.RunId = stableUUID(0xB8)

			ok := validCompiledAssignment(t, r)

			alt, _ := proto.Clone(ok).(*edgev1.CompiledSweepAssignmentV1)
			// ONE version field governs BOTH Appendix A grammars 9 and 10 -- the body digest and
			// the artifact address -- so this single member covers both, and re-signing keeps
			// the version the only unreconciled value.
			alt.DigestVersion = CompiledAssignmentDigestVersion + 1
			signCompiledAssignment(t, alt, priv)

			return mustMarshalMsg(t, ok), mustMarshalMsg(t, alt), nil
		},
		verify: func(t *testing.T, artifact, _ []byte) error {
			t.Helper()
			var c edgev1.CompiledSweepAssignmentV1
			if err := proto.Unmarshal(artifact, &c); err != nil {
				t.Fatalf("unmarshal compiled assignment: %v", err)
			}

			return ValidateCompiledSweepAssignment(&c)
		},
	}
}

func mtrCompletionVersionVector() versionVector {
	return versionVector{
		object: "mtr_completion", class: "A",
		// NO ELIXIR CONSUMER EXISTS. `mtr_completion_digest_version` appears in the Elixir tree
		// only in the generated struct and in golden assertions that read it; nothing refuses an
		// unsupported value. Writing a version check into the peer suite would be inventing a
		// validator for the corpus, so the asymmetry is RECORDED instead -- and it is why parent
		// 1.6, whose rule is that BOTH runtimes prove every member, cannot close on this slice.
		goOnly: true,
		ok:     "version_mtr_completion_ok.bin",
		alt:    "version_mtr_completion_alt.bin",
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			planRoot := d32domain(0x90)
			zero32 := make([]byte, sha256.Size)

			root, err := ZeroMtrCompletionRoot(0, planRoot, zero32)
			if err != nil {
				t.Fatalf("zero completion root: %v", err)
			}

			ok := &edgev1.SweepExecutionEventV1{
				ExecutionId: stableUUID(0xC0), ExecutionPlanId: stableUUID(0xC1),
				TargetRangeId:       stableUUID(0xC2),
				ExecutionPlanSha256: d32domain(0x10),
				Kind:                edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED,
				EmittedAtUnixNano:   1, TerminalBatchSequence: 1,
				MtrCompletionDigestVersion: MtrCompletionDigestVersion,
				MtrCompletionDigest:        root,
				PlanRootSha256:             planRoot,
			}

			alt, _ := proto.Clone(ok).(*edgev1.SweepExecutionEventV1)
			alt.MtrCompletionDigestVersion = MtrCompletionDigestVersion + 1

			return mustMarshalMsg(t, ok), mustMarshalMsg(t, alt), nil
		},
		verify: func(t *testing.T, artifact, _ []byte) error {
			t.Helper()
			var ev edgev1.SweepExecutionEventV1
			if err := proto.Unmarshal(artifact, &ev); err != nil {
				t.Fatalf("unmarshal execution event: %v", err)
			}

			return ValidateSweepExecutionEvent(&ev)
		},
	}
}

// ---- CLASS B: the four publication identities ---------------------------------------------
//
// These stay on the PREIMAGE path, because their exported preimage functions already hand back
// the transcript: the altered artifact is authored by patching the version field in the
// preimage and re-deriving the identifier, so nothing about the grammar is restated.
//
// Their boundary genuinely IS recomputation equality. Nothing DECODES a Nats-Msg-Id: a
// consumer recomputes the expected identifier from the record it holds and compares. That is
// the fallback the corpus is allowed to use where the equality is itself the check.

// versionAt patches the 8-byte big-endian version that follows a length-framed domain string,
// and returns the identifier the patched transcript yields.
func patchedIdentity(t *testing.T, preimage []byte, domain string, version uint64) string {
	t.Helper()

	// Layout: u64(len(domain)) || domain || u64(version) || ...
	off := 8 + len(domain)
	if len(preimage) < off+8 {
		t.Fatalf("preimage too short to carry a version at offset %d", off)
	}

	patched := append([]byte{}, preimage...)
	binary.BigEndian.PutUint64(patched[off:off+8], version)

	if binary.BigEndian.Uint64(preimage[off:off+8]) == version {
		t.Fatalf("the patched version equals the frozen one; the row would prove nothing")
	}

	sum := sha256.Sum256(patched)

	return b64url(sum[:])
}

func corpusEdgeSlot() EdgeSlot {
	return EdgeSlot{
		NetworkScopeID:       stableUUID(0xD0),
		AuthenticatedAgentID: []byte("agent-corpus"),
		SpoolID:              stableUUID(0xD1),
		Sequence:             7,
	}
}

func corpusServiceSlot() ServiceSlot {
	return ServiceSlot{
		NetworkScopeID:         stableUUID(0xD2),
		AuthenticatedServiceID: []byte("svc-corpus"),
		PublicationLaneID:      stableUUID(0xD3),
		PublicationSequence:    9,
	}
}

func pubIDVector(object, okFile, altFile string,
	compute func(t *testing.T) (id string, preimage []byte, domain string, frozen uint64),
) versionVector {
	return versionVector{
		object: object, class: "B",
		ok: okFile, alt: altFile,
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			id, pre, domain, frozen := compute(t)

			return []byte(id), []byte(patchedIdentity(t, pre, domain, frozen+1)), nil
		},
		verify: func(t *testing.T, artifact, _ []byte) error {
			t.Helper()
			id, _, _, _ := compute(t)
			if string(artifact) == id {
				return nil
			}

			return fmt.Errorf("%w: identifier does not match the recomputed one", ErrPublicationIdentity)
		},
	}
}

func natsMsgIDEdgeVector() versionVector {
	return pubIDVector("nats_msgid_edge", "version_nats_msgid_edge_ok.txt", "version_nats_msgid_edge_alt.txt",
		func(t *testing.T) (string, []byte, string, uint64) {
			t.Helper()
			slot, sed, rsha := corpusEdgeSlot(), d32(0xD4), d32(0xD5)

			id, err := NatsMsgID(slot, sed, rsha)
			if err != nil {
				t.Fatalf("nats msg id: %v", err)
			}

			pre, err := NatsMsgIDPreimage(slot, sed, rsha)
			if err != nil {
				t.Fatalf("nats msg id preimage: %v", err)
			}

			return id, pre, msgIDDomain, MsgIDVersion
		})
}

func natsMsgIDServiceVector() versionVector {
	return pubIDVector("nats_msgid_service", "version_nats_msgid_service_ok.txt", "version_nats_msgid_service_alt.txt",
		func(t *testing.T) (string, []byte, string, uint64) {
			t.Helper()
			slot, sed, rsha := corpusServiceSlot(), d32(0xD6), d32(0xD7)

			id, err := ServiceNatsMsgID(slot, sed, rsha)
			if err != nil {
				t.Fatalf("service nats msg id: %v", err)
			}

			pre, err := ServiceNatsMsgIDPreimage(slot, sed, rsha)
			if err != nil {
				t.Fatalf("service nats msg id preimage: %v", err)
			}

			return id, pre, msgIDServiceDomain, MsgIDVersion
		})
}

func deliveryIDEdgeVector() versionVector {
	return pubIDVector("delivery_id_edge", "version_delivery_id_edge_ok.txt", "version_delivery_id_edge_alt.txt",
		func(t *testing.T) (string, []byte, string, uint64) {
			t.Helper()
			slot := corpusEdgeSlot()

			id, err := DeliveryID(slot)
			if err != nil {
				t.Fatalf("delivery id: %v", err)
			}

			pre, err := DeliveryIDPreimage(slot)
			if err != nil {
				t.Fatalf("delivery id preimage: %v", err)
			}

			return id, pre, deliveryIDDomain, DeliveryIDVersion
		})
}

func deliveryIDServiceVector() versionVector {
	return pubIDVector("delivery_id_service", "version_delivery_id_service_ok.txt", "version_delivery_id_service_alt.txt",
		func(t *testing.T) (string, []byte, string, uint64) {
			t.Helper()
			slot := corpusServiceSlot()

			id, err := ServiceDeliveryID(slot)
			if err != nil {
				t.Fatalf("service delivery id: %v", err)
			}

			pre, err := ServiceDeliveryIDPreimage(slot)
			if err != nil {
				t.Fatalf("service delivery id preimage: %v", err)
			}

			return id, pre, deliveryIDServiceDomain, DeliveryIDVersion
		})
}

// ---- CLASS A: transport provenance, the nineteenth object ---------------------------------
//
// Its unsupported-version vector ALREADY EXISTS, as the `unknown-version` row of
// pubid_reject_vectors.txt. Re-authoring those bytes here would create a second source of
// truth for one artifact; omitting the object would leave the inventory inexhaustive and let
// 1.6-a be checked with a member unproven. So the row NAMES the existing artifact with a
// `file#row` reference and EXECUTES it through DecodeTransportProvenance -- the same decoder
// production uses -- rather than pointing at it.

// artifactRef resolves `file` or `file#row`, where a row is looked up by name in a
// tab-separated vector file.
func artifactRef(t *testing.T, ref string) []byte {
	t.Helper()

	file, row, hasRow := strings.Cut(ref, "#")

	raw, err := os.ReadFile(goldenPath(file))
	if err != nil {
		t.Fatalf("read %s: %v", file, err)
	}

	if !hasRow {
		return raw
	}

	for _, line := range strings.Split(string(raw), "\n") {
		name, value, ok := strings.Cut(line, "\t")
		if ok && name == row {
			return []byte(value)
		}
	}

	t.Fatalf("%s has no row named %q", file, row)

	return nil
}

func transportProvenanceVector() versionVector {
	return versionVector{
		object: "transport_provenance", class: "A", reuse: true,
		ok:  "transport_provenance.txt",
		alt: "pubid_reject_vectors.txt#unknown-version",
		build: func(t *testing.T) ([]byte, []byte, []byte) {
			t.Helper()
			return artifactRef(t, "transport_provenance.txt"),
				artifactRef(t, "pubid_reject_vectors.txt#unknown-version"),
				nil
		},
		verify: func(t *testing.T, artifact, _ []byte) error {
			t.Helper()
			_, err := DecodeTransportProvenance(string(artifact))

			return err
		},
	}
}

func versionVectors() []versionVector {
	return []versionVector{
		capabilityVersionVector(),
		semanticEnvelopeVector(),
		manifestPageVersionVector(),
		tombstoneVersionVector(),
		manifestRootVector(),
		planHeaderVersionVector(),
		planPageVersionVector(),
		planRootVector(),
		rangeDigestVector(),
		tombstoneScopeVector(),
		manifestPageScopeVector(),
		resolvedScopeVector(),
		compiledAssignmentVersionVector(),
		mtrCompletionVersionVector(),
		natsMsgIDEdgeVector(),
		natsMsgIDServiceVector(),
		deliveryIDEdgeVector(),
		deliveryIDServiceVector(),
		transportProvenanceVector(),
	}
}

// TestVersionSharedCorpus writes every inventory member's control and altered artifact and
// asserts Go's verdict on both.
//
// Regenerate with EDGE_GOLDEN_UPDATE=1.
func TestVersionSharedCorpus(t *testing.T) {
	vectors := versionVectors()
	lines := make([]string, 0, len(vectors))
	seen := map[string]bool{}

	for _, v := range vectors {
		if seen[v.object] {
			t.Fatalf("duplicate inventory member %s", v.object)
		}

		seen[v.object] = true

		okBytes, altBytes, peerBytes := v.build(t)

		if !v.reuse {
			goldenBytesLocal(t, v.ok, okBytes)
			goldenBytesLocal(t, v.alt, altBytes)
		}

		if v.peer != "" {
			goldenBytesLocal(t, v.peer, peerBytes)
		}

		// NO OVER-REFUSAL: the control must pass the same verifier. Without this a row would
		// still be green if the verifier refused everything.
		if err := v.verify(t, okBytes, peerBytes); err != nil {
			t.Fatalf("%s: the CONTROL must be accepted: %v", v.object, err)
		}

		if err := v.verify(t, altBytes, peerBytes); err == nil {
			t.Fatalf("%s: the ALTERED-VERSION artifact was ACCEPTED", v.object)
		}

		peer := v.peer
		if peer == "" {
			peer = "-"
		}

		runtimes := "both"
		if v.goOnly {
			runtimes = "go_only"
		}

		lines = append(lines, fmt.Sprintf("%s %s %s %s %s %s",
			v.object, v.class, v.ok, v.alt, peer, runtimes))
	}

	goldenBytesLocal(t, versionManifest, []byte(strings.Join(lines, "\n")+"\n"))
}

// expectedVersionInventory is the HAND-WRITTEN Appendix A object inventory: every versioned
// object, and the proof class it belongs to.
//
// It is deliberately NOT derived from versionVectors(). A generator that lost an object would
// regenerate a manifest without it, every count derived from that manifest would agree with
// itself, and "19 exhaustive objects" would quietly become 18 with nothing to notice. This
// table is the independent statement that makes exhaustiveness checkable, and the count below
// is derived from it only AFTER membership and class have been established.
//
//nolint:gochecknoglobals // frozen inventory, not state
var expectedVersionInventory = map[string]string{
	// CLASS A -- the object decodes a version from its input.
	"capability":           "A",
	"manifest_page":        "A",
	"tombstone":            "A",
	"plan_header":          "A",
	"plan_page":            "A",
	"compiled_assignment":  "A", // ONE version field governs Appendix A grammars 9 AND 10
	"mtr_completion":       "A",
	"transport_provenance": "A", // artifact owned by golden_test.go; executed here
	// CLASS B -- the version is a compile-time constant and the received value is a digest.
	"semantic_envelope":   "B",
	"manifest_root":       "B",
	"plan_root":           "B",
	"range_digest":        "B",
	"tombstone_scope":     "B",
	"manifest_page_scope": "B",
	"resolved_scope":      "B",
	"nats_msgid_edge":     "B",
	"nats_msgid_service":  "B",
	"delivery_id_edge":    "B",
	"delivery_id_service": "B",
}

// expectedGoOnlyObjects is the CLOSED set of inventory members no Elixir consumer enforces.
// ONE of nineteen today, which is why parent task 1.6 stays open: its rule is that BOTH
// runtimes prove every member, and eighteen do. The three recovery scope transcripts left this
// set when 1.6-d gave this peer a signed recovery-control boundary to run them through.
//
// Membership here is a CONTRACT statement, not bookkeeping. An object may only appear if the
// peer runtime has no production verifier that trusts the value -- never because writing one
// would be inconvenient, and never as a standing exemption.
//
//nolint:gochecknoglobals // frozen inventory, not state
var expectedGoOnlyObjects = map[string]bool{
	"mtr_completion": true, // task 1.6-c
}

type manifestRow struct {
	class, ok, alt, peer, runtimes string
}

func readVersionManifest(t *testing.T) map[string]manifestRow {
	t.Helper()

	raw, err := os.ReadFile(goldenPath(versionManifest))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	rows := map[string]manifestRow{}

	for i, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		f := strings.Fields(line)
		if len(f) != 6 {
			t.Fatalf("manifest line %d has %d columns, want 6: %q", i+1, len(f), line)
		}

		if _, dup := rows[f[0]]; dup {
			t.Fatalf("manifest lists %s twice", f[0])
		}

		rows[f[0]] = manifestRow{class: f[1], ok: f[2], alt: f[3], peer: f[4], runtimes: f[5]}
	}

	return rows
}

// TestVersionInventoryIsExhaustive is the gate that makes the word "exhaustive" mean something.
//
// It reads the COMMITTED manifest -- not the generator's in-memory table -- and holds it to the
// hand-written inventory in BOTH directions, checks each object's class, then resolves every
// artifact FROM DISK and RUNS the production verifier over it. A row that named an artifact
// nothing executes would pass a membership check and prove nothing.
func TestVersionInventoryIsExhaustive(t *testing.T) {
	rows := readVersionManifest(t)

	for object, class := range expectedVersionInventory {
		row, ok := rows[object]
		if !ok {
			t.Errorf("inventory object %q is ABSENT from the manifest", object)

			continue
		}

		if row.class != class {
			t.Errorf("%s: manifest says class %s, the inventory says %s", object, row.class, class)
		}
	}

	for object := range rows {
		if _, ok := expectedVersionInventory[object]; !ok {
			t.Errorf("manifest carries %q, which is not in the inventory", object)
		}
	}

	// The RUNTIME COVERAGE is asserted against a hand-written expectation for the same reason
	// the class is: a row silently flipping to go_only would otherwise shrink what the peer
	// suite runs, with nothing failing.
	for object, row := range rows {
		want := "both"
		if expectedGoOnlyObjects[object] {
			want = "go_only"
		}

		if row.runtimes != want {
			t.Errorf("%s: manifest says %s, expected %s", object, row.runtimes, want)
		}
	}

	if t.Failed() {
		t.Fatal("inventory membership failed; the derived count below would be meaningless")
	}

	// EXECUTION, from disk. The vectors supply the verifier; the bytes come from the committed
	// artifacts, so this is the path a consumer actually takes.
	byObject := map[string]versionVector{}
	for _, v := range versionVectors() {
		byObject[v.object] = v
	}

	for object, row := range rows {
		v, ok := byObject[object]
		if !ok {
			t.Errorf("%s: no vector supplies a verifier", object)

			continue
		}

		var peer []byte
		if row.peer != "-" {
			peer = artifactRef(t, row.peer)
		}

		if err := v.verify(t, artifactRef(t, row.ok), peer); err != nil {
			t.Errorf("%s: the committed CONTROL was refused: %v", object, err)
		}

		if err := v.verify(t, artifactRef(t, row.alt), peer); err == nil {
			t.Errorf("%s: the committed ALTERED artifact was ACCEPTED", object)
		}
	}

	// DERIVED, and informational only -- it runs last because a count is not evidence of
	// coverage. The membership check above is.
	classes := map[string]int{}
	for _, class := range expectedVersionInventory {
		classes[class]++
	}

	t.Logf("inventory: %d objects (%d Class A, %d Class B)", len(expectedVersionInventory),
		classes["A"], classes["B"])
}

// TestVersionScopeRowsIsolateTheClaim proves MECHANICALLY that the three scope rows differ in
// exactly one logical value.
//
// The claimed scope digest is carried TWICE -- inside the signed source claim and echoed on the
// outer authorization -- and changing it necessarily moves two derived values with it: the
// source capability's SIGNATURE and the record's semantic-envelope digest. Those four fields
// are therefore ONE logical change. Normalising all four and requiring everything else to be
// equal is what rules out a second, incidental difference silently doing the refusing.
//
// Without this, a future regeneration that also moved (say) a timestamp would still show
// "control accepted, altered refused" and the row would no longer be about versions at all.
func TestVersionScopeRowsIsolateTheClaim(t *testing.T) {
	rows := readVersionManifest(t)

	for _, object := range []string{"tombstone_scope", "manifest_page_scope", "resolved_scope"} {
		row, ok := rows[object]
		if !ok {
			t.Fatalf("%s: absent from the manifest", object)
		}

		okRec := normalizeScopeClaim(t, unmarshalRecord(t, artifactRef(t, row.ok)))
		altRec := normalizeScopeClaim(t, unmarshalRecord(t, artifactRef(t, row.alt)))

		if !proto.Equal(okRec, altRec) {
			t.Errorf("%s: the pair differs in more than the claimed scope; the row is not isolated",
				object)
		}
	}
}

// normalizeScopeClaim clears the claimed scope in BOTH positions it is carried, and the two
// values derived from it. What remains must be identical between the control and the altered
// record.
func normalizeScopeClaim(t *testing.T, r *edgev1.EdgeRecordV1) *edgev1.EdgeRecordV1 {
	t.Helper()

	c, ok := proto.Clone(r).(*edgev1.EdgeRecordV1)
	if !ok {
		t.Fatal("clone record")
	}

	sa := c.GetSourceAuthorization()
	if sa == nil || sa.GetCapability().GetSource() == nil {
		t.Fatal("a scope row must carry a signed source authorization")
	}

	sa.ScopeSha256 = nil                             // the outer echo
	sa.GetCapability().GetSource().ScopeSha256 = nil // the signed claim
	sa.GetCapability().Signature = nil               // derived: the claim is inside the signature
	c.SemanticEnvelopeSha256 = nil                   // derived: the envelope commits the claim

	return c
}

// TestVersionManifestMatchesDisk compares the manifest against the fixtures ON DISK, in both
// directions, so an orphaned artifact cannot be staged by Bazel and read by nobody.
func TestVersionManifestMatchesDisk(t *testing.T) {
	if os.Getenv("EDGE_GOLDEN_UPDATE") == "1" {
		t.Skip("regenerating")
	}

	raw, err := os.ReadFile(goldenPath(versionManifest))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	listed := map[string]bool{}

	for i, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 6 {
			t.Fatalf("manifest line %d has %d columns, want 6: %q", i+1, len(fields), line)
		}

		for _, f := range fields[2:5] {
			if f == "-" {
				continue
			}

			// A row may reference an artifact this corpus does not own, by `file#row`. Those are
			// required to EXIST and be readable; only the files this generator authors are held
			// to the both-directions membership rule below.
			file, _, _ := strings.Cut(f, "#")
			if !strings.HasPrefix(file, "version_") {
				if _, err := os.Stat(goldenPath(file)); err != nil {
					t.Errorf("manifest references %s, which is unreadable: %v", f, err)
				}

				continue
			}

			listed[file] = true
		}
	}

	dir := filepath.Dir(goldenPath(versionManifest))

	var matches []string

	// Both extensions: the scope rows' peer is a committed PUBLIC KEY, and globbing only
	// `.bin` would leave it unchecked in exactly the direction this guard exists for.
	// .txt as well: the publication-identity artifacts are identifiers, not messages. The
	// manifest itself is excluded below -- it is the index, not an indexed artifact.
	for _, pattern := range []string{"version_*.bin", "version_*.pub", "version_*.txt"} {
		found, err := filepath.Glob(filepath.Join(dir, pattern))
		if err != nil {
			t.Fatalf("glob fixtures: %v", err)
		}

		matches = append(matches, found...)
	}

	if len(matches) == 0 {
		t.Fatal("no version_* fixtures found on disk; the guard would pass vacuously")
	}

	onDisk := map[string]bool{}

	for _, m := range matches {
		if base := filepath.Base(m); base != versionManifest {
			onDisk[base] = true
		}
	}

	for name := range listed {
		if !onDisk[name] {
			t.Errorf("manifest names %s, which is not on disk", name)
		}
	}

	for name := range onDisk {
		if !listed[name] {
			t.Errorf("%s is on disk but absent from the manifest, so no runtime reads it", name)
		}
	}
}
