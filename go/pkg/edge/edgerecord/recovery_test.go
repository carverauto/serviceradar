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
	"crypto/sha256"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"testing"

	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// activeSpan builds an ATTRIBUTED_ACTIVE span with a complete, valid identity.
func activeSpan(t *testing.T, from, through uint64) *edgev1.EdgeClassificationSpanV1 {
	t.Helper()
	return &edgev1.EdgeClassificationSpanV1{
		FromSequence: from, ThroughSequence: through,
		Classification: &edgev1.EdgeClassificationSpanV1_AttributedActive{
			AttributedActive: &edgev1.EdgeAttributedActiveV1{
				Identity:    spanIdentity(t, nil),
				RangeSha256: d32(0x03),
			},
		},
	}
}

// passiveSpan builds an ATTRIBUTED_PASSIVE span. It still carries its lost DELIVERY
// interval: omitting it would leave a hole indistinguishable from undetected loss.
func passiveSpan(t *testing.T, from, through uint64) *edgev1.EdgeClassificationSpanV1 {
	t.Helper()
	return &edgev1.EdgeClassificationSpanV1{
		FromSequence: from, ThroughSequence: through,
		Classification: &edgev1.EdgeClassificationSpanV1_AttributedPassive{
			AttributedPassive: &edgev1.EdgeAttributedPassiveV1{Identity: spanIdentity(t, nil)},
		},
	}
}

func unattributableSpan(from, through uint64, r edgev1.EdgeUnattributableReason) *edgev1.EdgeClassificationSpanV1 {
	return &edgev1.EdgeClassificationSpanV1{
		FromSequence: from, ThroughSequence: through,
		Classification: &edgev1.EdgeClassificationSpanV1_Unattributable{
			Unattributable: &edgev1.EdgeUnattributableV1{Reason: r},
		},
	}
}

// spanIdentity builds a valid attributed identity. src is attached verbatim, so a
// test can pin the source-present and source-absent cases -- which must NOT collide.
func spanIdentity(t *testing.T, src *edgev1.EdgeSourceSpanIdentityV1) *edgev1.EdgeAttributedSpanIdentityV1 {
	t.Helper()
	return &edgev1.EdgeAttributedSpanIdentityV1{
		ProducerAssignmentId: mustUUID(t),
		RunId:                mustUUID(t),
		RunShard:             2,
		AuthorityEpoch:       5,
		ProductionScopeId:    mustUUID(t),
		ScopeSha256:          d32(0x02),
		ContractBundleSha256: d32(0x01),
		Source:               src,
	}
}

// buildManifest builds a valid single-recovery chained manifest with computed page
// digests and prev-hash links.
func buildManifest(t *testing.T, recoveryID []byte, pageSpans [][]*edgev1.EdgeClassificationSpanV1) []*edgev1.EdgeLossManifestPageV1 {
	t.Helper()
	count := len(pageSpans)
	pages := make([]*edgev1.EdgeLossManifestPageV1, count)
	var prev []byte
	for i, spans := range pageSpans {
		p := &edgev1.EdgeLossManifestPageV1{
			RecoveryId: recoveryID, PageIndex: uint32(i), PageCount: uint32(count),
			PrevPageSha256: prev, Terminal: i == count-1, DigestVersion: RecoveryDigestVersion,
			ClassificationSpans: spans,
		}
		p.PageSha256 = ManifestPageDigest(p)
		pages[i] = p
		prev = p.PageSha256
	}
	return pages
}

func TestManifestChainValid(t *testing.T) {
	rid := mustUUID(t)
	pages := buildManifest(t, rid, [][]*edgev1.EdgeClassificationSpanV1{
		{activeSpan(t, 10, 20), activeSpan(t, 30, 40)},
		{passiveSpan(t, 100, 110)},
	})
	if err := ValidateManifestChain(pages, ManifestRoot(pages)); err != nil {
		t.Fatalf("valid manifest: %v", err)
	}
	tomb := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: rid, PriorSpoolId: mustUUID(t), NewSpoolId: mustUUID(t),
		ManifestRootSha256: ManifestRoot(pages), ManifestPageCount: uint32(len(pages)), DigestVersion: RecoveryDigestVersion,
	}
	if err := ValidateTombstone(tomb, pages); err != nil {
		t.Fatalf("valid tombstone: %v", err)
	}
}

func TestManifestRejectsCrossRecoveryAndOverlap(t *testing.T) {
	// Different recovery IDs across pages.
	a := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeClassificationSpanV1{
		{activeSpan(t, 1, 2)}, {activeSpan(t, 3, 4)},
	})
	a[1].RecoveryId = mustUUID(t)
	a[1].PrevPageSha256 = a[0].PageSha256
	a[1].PageSha256 = ManifestPageDigest(a[1])
	if err := ValidateManifestChain(a, nil); !errors.Is(err, ErrManifestRecoveryID) {
		t.Fatalf("cross-recovery = %v, want ErrManifestRecoveryID", err)
	}

	// Spans overlapping across the page boundary.
	b := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeClassificationSpanV1{
		{activeSpan(t, 10, 20)}, {activeSpan(t, 15, 25)},
	})
	if err := ValidateManifestChain(b, nil); !errors.Is(err, ErrManifestSpan) {
		t.Fatalf("cross-page overlap = %v, want ErrManifestSpan", err)
	}

	// TOUCHING AT A POINT: the next span starts ON the previous span's last sequence.
	// The rule is `from <= prevThrough`, so this is the exact boundary separating it
	// from `from < prevThrough`; without this vector, weakening the comparison by one
	// goes unnoticed. Both within a page and across a page boundary.
	for _, tc := range []struct {
		name  string
		pages [][]*edgev1.EdgeClassificationSpanV1
	}{
		{"within a page", [][]*edgev1.EdgeClassificationSpanV1{{activeSpan(t, 1, 5), activeSpan(t, 5, 10)}}},
		{"across a page boundary", [][]*edgev1.EdgeClassificationSpanV1{{activeSpan(t, 1, 5)}, {activeSpan(t, 5, 10)}}},
	} {
		pages := buildManifest(t, mustUUID(t), tc.pages)
		if err := ValidateManifestChain(pages, nil); !errors.Is(err, ErrManifestSpan) {
			t.Fatalf("touching at a point (%s) = %v, want ErrManifestSpan", tc.name, err)
		}
	}

	// Lost sequence 0 (lane sequences start at 1) is rejected.
	c := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeClassificationSpanV1{{activeSpan(t, 0, 5)}})
	if err := ValidateManifestChain(c, nil); !errors.Is(err, ErrManifestSpan) {
		t.Fatalf("lost sequence 0 = %v, want ErrManifestSpan", err)
	}

	// Inverted interval: primitively invalid on its own, so ordering alone would
	// not have excluded it.
	d := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeClassificationSpanV1{{activeSpan(t, 9, 5)}})
	if err := ValidateManifestChain(d, nil); !errors.Is(err, ErrManifestSpan) {
		t.Fatalf("inverted interval = %v, want ErrManifestSpan", err)
	}
}

// GAPS ARE LEGAL and mean "not lost" -- within a page and at a page boundary alike.
// This replaces the retired "no gaps within coverage" rule, which existed only
// because coverage was DECLARED; with the extent derived there is nothing to
// contradict. ADJACENCY is legal too: two adjacent spans may differ in body.
func TestManifestAcceptsGapsAndAdjacency(t *testing.T) {
	cases := []struct {
		name  string
		pages [][]*edgev1.EdgeClassificationSpanV1
	}{
		{"gap within a page", [][]*edgev1.EdgeClassificationSpanV1{
			{activeSpan(t, 1, 1), activeSpan(t, 100, 100)}}},
		{"gap across a page boundary", [][]*edgev1.EdgeClassificationSpanV1{
			{activeSpan(t, 1, 1)}, {activeSpan(t, 100, 100)}}},
		{"adjacent spans", [][]*edgev1.EdgeClassificationSpanV1{
			{activeSpan(t, 1, 1), passiveSpan(t, 2, 2)}}},
		{"span bounded at MaxUint64", [][]*edgev1.EdgeClassificationSpanV1{
			{activeSpan(t, 1, ^uint64(0))}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pages := buildManifest(t, mustUUID(t), tc.pages)
			if err := ValidateManifestChain(pages, ManifestRoot(pages)); err != nil {
				t.Fatalf("%s should be accepted: %v", tc.name, err)
			}
		})
	}
}

// The oneof guarantees AT MOST ONE body; exactly-one and the field-level rules are
// enforced here, because proto3 still permits a set body with a nil identity, empty
// required bytes, or a wrong-width digest.
func TestSpanBodyStructuralRules(t *testing.T) {
	nilIdentityActive := &edgev1.EdgeClassificationSpanV1{
		FromSequence: 1, ThroughSequence: 1,
		Classification: &edgev1.EdgeClassificationSpanV1_AttributedActive{
			AttributedActive: &edgev1.EdgeAttributedActiveV1{RangeSha256: d32(3)},
		},
	}
	badID := spanIdentity(t, nil)
	badID.ProductionScopeId = []byte("not-a-uuid")
	shortDigest := spanIdentity(t, nil)
	shortDigest.ScopeSha256 = []byte{1, 2, 3}

	cases := []struct {
		name string
		span *edgev1.EdgeClassificationSpanV1
	}{
		{"unset oneof", &edgev1.EdgeClassificationSpanV1{FromSequence: 1, ThroughSequence: 1}},
		{"active with nil identity", nilIdentityActive},
		{"active missing range_sha256", &edgev1.EdgeClassificationSpanV1{
			FromSequence: 1, ThroughSequence: 1,
			Classification: &edgev1.EdgeClassificationSpanV1_AttributedActive{
				AttributedActive: &edgev1.EdgeAttributedActiveV1{Identity: spanIdentity(t, nil)},
			},
		}},
		{"non-canonical production scope id", &edgev1.EdgeClassificationSpanV1{
			FromSequence: 1, ThroughSequence: 1,
			Classification: &edgev1.EdgeClassificationSpanV1_AttributedPassive{
				AttributedPassive: &edgev1.EdgeAttributedPassiveV1{Identity: badID},
			},
		}},
		{"wrong-width scope digest", &edgev1.EdgeClassificationSpanV1{
			FromSequence: 1, ThroughSequence: 1,
			Classification: &edgev1.EdgeClassificationSpanV1_AttributedPassive{
				AttributedPassive: &edgev1.EdgeAttributedPassiveV1{Identity: shortDigest},
			},
		}},
		{"unattributable UNSPECIFIED", unattributableSpan(1, 1,
			edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_UNSPECIFIED)},
		// Closed accepted SET: a value outside 2,3,4,6,7 is rejected before it can be
		// hashed, including the reserved numbers 1 and 5 and anything a later proto
		// revision might declare.
		{"unattributable reserved 1", unattributableSpan(1, 1, edgev1.EdgeUnattributableReason(1))},
		{"unattributable reserved 5", unattributableSpan(1, 1, edgev1.EdgeUnattributableReason(5))},
		{"unattributable unknown 8", unattributableSpan(1, 1, edgev1.EdgeUnattributableReason(8))},
		{"unattributable 999", unattributableSpan(1, 1, edgev1.EdgeUnattributableReason(999))},
		{"unattributable negative", unattributableSpan(1, 1, edgev1.EdgeUnattributableReason(-1))},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pages := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeClassificationSpanV1{{tc.span}})
			if err := ValidateManifestChain(pages, nil); !errors.Is(err, ErrManifestSpanBody) {
				t.Fatalf("%s = %v, want ErrManifestSpanBody", tc.name, err)
			}
		})
	}

	// A partial source combination is rejected: all four members travel together.
	partial := spanIdentity(t, &edgev1.EdgeSourceSpanIdentityV1{
		Kind:      edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
		ContextId: mustUUID(t),
		// source_scope_id and source_scope_sha256 omitted
	})
	pages := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeClassificationSpanV1{{{
		FromSequence: 1, ThroughSequence: 1,
		Classification: &edgev1.EdgeClassificationSpanV1_AttributedPassive{
			AttributedPassive: &edgev1.EdgeAttributedPassiveV1{Identity: partial},
		},
	}}})
	if err := ValidateManifestChain(pages, nil); !errors.Is(err, ErrManifestSpanBody) {
		t.Fatalf("partial source = %v, want ErrManifestSpanBody", err)
	}
}

// Source presence is part of the span identity, so source-present and source-absent
// spans MUST NOT produce the same digest -- the collision the source identity was
// added to prevent.
//
// BOTH pages share ONE recovery id. An earlier version built them with separate ids;
// since recovery_id is itself hashed, the digests differed regardless of span
// framing, and the test passed with the source framing deleted entirely.
//
// SCOPE, stated precisely because the name invites over-reading: this proves the
// source MEMBERS reach the preimage. It does NOT prove the 1-byte presence MARKER is
// framed -- absent emits nothing while present emits >=32 bytes of members, so the
// digests differ either way. The marker's property is CROSS-LANGUAGE agreement (Go
// omitting a byte Elixir emits), which only the shared golden fixture can pin. See
// manifest_page.bin, which carries one source-present and one source-absent span.
func TestSourceMembersReachTheDigest(t *testing.T) {
	rid := mustUUID(t)
	id := spanIdentity(t, nil)

	absent := &edgev1.EdgeClassificationSpanV1{
		FromSequence: 1, ThroughSequence: 1,
		Classification: &edgev1.EdgeClassificationSpanV1_AttributedPassive{
			AttributedPassive: &edgev1.EdgeAttributedPassiveV1{Identity: id},
		},
	}
	withSrc := proto.Clone(absent).(*edgev1.EdgeClassificationSpanV1)
	withSrc.GetAttributedPassive().Identity.Source = &edgev1.EdgeSourceSpanIdentityV1{
		Kind:              edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
		ContextId:         mustUUID(t),
		SourceScopeId:     mustUUID(t),
		SourceScopeSha256: d32(0x44),
	}
	// A second source-present span differing ONLY in context_id. This is the case the
	// round-K review found missing from the schema: two records sharing every other
	// member while carrying DIFFERENT signed source contexts must not merge onto one
	// wire identity.
	otherCtx := proto.Clone(withSrc).(*edgev1.EdgeClassificationSpanV1)
	otherCtx.GetAttributedPassive().Identity.Source.ContextId = mustUUID(t)

	a := buildManifest(t, rid, [][]*edgev1.EdgeClassificationSpanV1{{absent}})
	b := buildManifest(t, rid, [][]*edgev1.EdgeClassificationSpanV1{{withSrc}})
	c := buildManifest(t, rid, [][]*edgev1.EdgeClassificationSpanV1{{otherCtx}})

	if !bytes.Equal(a[0].GetRecoveryId(), b[0].GetRecoveryId()) ||
		!bytes.Equal(b[0].GetRecoveryId(), c[0].GetRecoveryId()) {
		t.Fatal("pages must share one recovery id or this test is vacuous")
	}
	for _, pair := range []struct {
		name string
		x, y []*edgev1.EdgeLossManifestPageV1
	}{
		{"absent vs present", a, b},
		{"present vs different context_id", b, c},
	} {
		if bytes.Equal(pair.x[0].GetPageSha256(), pair.y[0].GetPageSha256()) {
			t.Fatalf("%s produced the SAME page digest; distinct source identities collide", pair.name)
		}
	}
	for _, pages := range [][]*edgev1.EdgeLossManifestPageV1{a, b, c} {
		if err := ValidateManifestChain(pages, ManifestRoot(pages)); err != nil {
			t.Fatalf("all three forms must be valid: %v", err)
		}
	}
}

// An unaccepted enum value must be REJECTED BEFORE the page is hashed, so the verdict
// cannot depend on the supplied digest.
//
// The ordering is only observable when the digest does NOT match: with a matching
// digest the hash check passes and the body error surfaces under either ordering.
// These vectors therefore install an out-of-set value AND leave a stale page_sha256,
// then assert the BODY error. Under hash-first they would report
// ErrManifestPageDigest instead.
//
// BOTH frozen enums are covered. An earlier version tested only
// EdgeUnattributableReason, which left the closed set on
// EdgeSourceSpanIdentityV1.kind free to be widened by a later proto revision without
// any regression noticing.
func TestInvalidEnumRejectedBeforeHashing(t *testing.T) {
	// reason: accepted set is 2,3,4,6,7 (1 and 5 reserved).
	reasonSpan := func(v int32) *edgev1.EdgeClassificationSpanV1 {
		return unattributableSpan(1, 1, edgev1.EdgeUnattributableReason(v))
	}
	// kind: accepted set is 1..7.
	kindSpan := func(t *testing.T, v int32) *edgev1.EdgeClassificationSpanV1 {
		t.Helper()
		return &edgev1.EdgeClassificationSpanV1{
			FromSequence: 1, ThroughSequence: 1,
			Classification: &edgev1.EdgeClassificationSpanV1_AttributedPassive{
				AttributedPassive: &edgev1.EdgeAttributedPassiveV1{
					Identity: spanIdentity(t, &edgev1.EdgeSourceSpanIdentityV1{
						Kind:              edgev1.EdgeSourceAuthorizationKind(v),
						ContextId:         mustUUID(t),
						SourceScopeId:     mustUUID(t),
						SourceScopeSha256: d32(0x44),
					}),
				},
			},
		}
	}

	reject := []struct {
		name string
		span *edgev1.EdgeClassificationSpanV1
	}{
		{"reason 0 (UNSPECIFIED)", reasonSpan(0)},
		{"reason -1", reasonSpan(-1)},
		{"reason 1 (reserved)", reasonSpan(1)},
		{"reason 5 (reserved)", reasonSpan(5)},
		{"reason 8 (next unknown)", reasonSpan(8)},
		{"reason 999", reasonSpan(999)},
		{"kind 0 (UNSPECIFIED)", kindSpan(t, 0)},
		{"kind -1", kindSpan(t, -1)},
		{"kind 8 (next unknown)", kindSpan(t, 8)},
		{"kind 999", kindSpan(t, 999)},
	}
	for _, tc := range reject {
		t.Run(tc.name, func(t *testing.T) {
			pages := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeClassificationSpanV1{{activeSpan(t, 1, 1)}})
			// Swap the span in WITHOUT recomputing page_sha256, so the digest is stale.
			pages[0].ClassificationSpans = []*edgev1.EdgeClassificationSpanV1{tc.span}
			if bytes.Equal(ManifestPageDigest(pages[0]), pages[0].GetPageSha256()) {
				t.Fatal("digest unexpectedly still matches; this vector cannot distinguish the orderings")
			}
			if err := ValidateManifestChain(pages, nil); !errors.Is(err, ErrManifestSpanBody) {
				t.Fatalf("%s = %v, want ErrManifestSpanBody (a digest error means the page "+
					"was hashed before the value was rejected)", tc.name, err)
			}
		})
	}

	// ACCEPTED CONTROLS. Without these the rejections above would also pass an
	// implementation that rejects every value, proving nothing about the SET.
	accept := []struct {
		name string
		span *edgev1.EdgeClassificationSpanV1
	}{
		{"reason 2", reasonSpan(2)}, {"reason 3", reasonSpan(3)}, {"reason 4", reasonSpan(4)},
		{"reason 6", reasonSpan(6)}, {"reason 7", reasonSpan(7)},
		{"kind 1", kindSpan(t, 1)}, {"kind 4", kindSpan(t, 4)}, {"kind 7", kindSpan(t, 7)},
	}
	for _, tc := range accept {
		t.Run("accepted/"+tc.name, func(t *testing.T) {
			pages := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeClassificationSpanV1{{tc.span}})
			if err := ValidateManifestChain(pages, ManifestRoot(pages)); err != nil {
				t.Fatalf("%s must be accepted: %v", tc.name, err)
			}
		})
	}
}

// inflate pads an encoded page to exactly `target` bytes with DECODABLE filler:
// repeated copies of the singular `digest_version` field (tag 8, varint), which
// protobuf resolves last-one-wins to the same value it already had. One non-minimal
// varint covers an odd byte count.
//
// Trailing zero bytes do NOT work: protobuf-Go rejects tag 0 rather than ignoring it,
// so a zero-padded page fails to decode and never reaches the budget check.
func inflate(t *testing.T, b []byte, target int) []byte {
	t.Helper()
	need := target - len(b)
	if need < 0 {
		t.Fatalf("page already %d bytes, over target %d", len(b), target)
	}
	out := append([]byte{}, b...)
	if need%2 == 1 {
		if need < 3 {
			t.Fatalf("cannot pad %d bytes", need)
		}
		out = append(out, 0x40, 0x81, 0x00) // digest_version = 1, non-minimal varint
		need -= 3
	}
	for ; need > 0; need -= 2 {
		out = append(out, 0x40, 0x01) // digest_version = 1
	}
	return out
}

// The aggregate received-byte budget cannot be enforced from decoded messages: two
// pages can each be under the cap in received bytes, exceed it together, and collapse
// back under it when re-encoded. This is the exact bypass the pre-1.6a validator had,
// which summed re-encoded sizes.
func TestAggregateReceivedByteBound(t *testing.T) {
	rid := mustUUID(t)
	pages := buildManifest(t, rid, [][]*edgev1.EdgeClassificationSpanV1{
		{activeSpan(t, 1, 1)}, {activeSpan(t, 3, 3)},
	})
	raw := make([][]byte, len(pages))
	for i, p := range pages {
		b, err := proto.Marshal(p)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		raw[i] = b
	}
	if err := ValidateManifestChainFromRaw(raw, ManifestRoot(pages)); err != nil {
		t.Fatalf("in-budget manifest rejected: %v", err)
	}

	// Aggregate exactly MaxManifestBytes+1 while each page stays under the cap.
	half := MaxManifestBytes / 2
	fat := [][]byte{inflate(t, raw[0], half), inflate(t, raw[1], half+1)}
	if got := len(fat[0]) + len(fat[1]); got != MaxManifestBytes+1 {
		t.Fatalf("aggregate = %d, want exactly %d", got, MaxManifestBytes+1)
	}
	for i, b := range fat {
		if len(b) > MaxManifestBytes {
			t.Fatalf("page %d individually over cap; test does not isolate the aggregate", i)
		}
		// Each padded page must DECODE, and to the same page it started as -- so the
		// only thing rejecting the manifest can be the aggregate received size.
		var pg edgev1.EdgeLossManifestPageV1
		if err := proto.Unmarshal(b, &pg); err != nil {
			t.Fatalf("padded page %d does not decode: %v", i, err)
		}
		if !proto.Equal(&pg, pages[i]) {
			t.Fatalf("padded page %d decoded to a different message; padding is not inert", i)
		}
		if re, err := proto.Marshal(&pg); err != nil || len(re) >= MaxManifestBytes/2 {
			t.Fatalf("re-encoded page %d is %d bytes; it must collapse far below the cap "+
				"so an implementation summing re-encoded sizes would accept this input",
				i, len(re))
		}
	}
	if err := ValidateManifestChainFromRaw(fat, nil); !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("aggregate over budget = %v, want ErrManifestBounds", err)
	}
}

// The aggregate bound is checked BEFORE any decode.
//
// A malformed page followed by one that pushes the AGGREGATE over the cap: if the
// implementation interleaved bounding and decoding, the malformed page would fail to
// unmarshal first and report ErrManifestChain, masking the budget violation. Bounding
// first makes ErrManifestBounds the only possible verdict.
//
// The interleaving bug was real and was found during development, but nothing in the
// committed suite pinned it until now -- so this regression exists to keep the
// ordering, not merely to have observed it once.
func TestAggregateBoundPrecedesDecode(t *testing.T) {
	malformed := []byte{0xFF, 0xFF, 0xFF}
	big := bytes.Repeat([]byte{0x40, 0x01}, (MaxManifestBytes+1-len(malformed))/2)

	if len(malformed)+len(big) <= MaxManifestBytes {
		t.Fatalf("inputs total %d, must exceed %d for this test to isolate the ordering",
			len(malformed)+len(big), MaxManifestBytes)
	}
	// The malformed page must genuinely be undecodable, or the test proves nothing.
	var probe edgev1.EdgeLossManifestPageV1
	if err := proto.Unmarshal(malformed, &probe); err == nil {
		t.Fatal("the malformed page decoded; it cannot demonstrate decode-before-bound")
	}

	if err := ValidateManifestChainFromRaw([][]byte{malformed, big}, nil); !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("aggregate over budget with a malformed first page = %v, want ErrManifestBounds "+
			"(a chain error means decoding ran before the budget was checked)", err)
	}
}

// The SHARED over-budget pair, from the committed corpus rather than built here.
//
// TestAggregateReceivedByteBound builds its own padded pages, which proves this
// implementation is self-consistent but not that Go and Elixir agree on where the
// ceiling falls. These are the same bytes the Elixir suite reads.
func TestSharedOverBudgetPairIsRejected(t *testing.T) {
	read := func(name string) []byte {
		t.Helper()
		raw, err := os.ReadFile(goldenPath(name))
		if err != nil {
			t.Fatalf("read shared vector %s: %v", name, err)
		}
		return raw
	}
	a := read("manifest_page_overbudget_a.bin")
	b := read("manifest_page_overbudget_b.bin")

	// (1) THE DECODED PAIR IS A VALID CHAIN. Without this the bounds rejection proves
	// nothing: an earlier version padded two copies of the same page 0/1 terminal, so
	// the pair was a BROKEN chain and a re-encode-summing implementation would still
	// have rejected it -- just later, for an unrelated reason. The bypass was never
	// isolated.
	pages := make([]*edgev1.EdgeLossManifestPageV1, 0, 2)
	for i, raw := range [][]byte{a, b} {
		var pg edgev1.EdgeLossManifestPageV1
		if err := proto.Unmarshal(raw, &pg); err != nil {
			t.Fatalf("shared page %d must decode: %v", i, err)
		}
		pages = append(pages, &pg)
	}
	if err := ValidateManifestChain(pages, ManifestRoot(pages)); err != nil {
		t.Fatalf("the decoded pair must be a VALID chain, or the bounds rejection is "+
			"not attributable to byte accounting: %v", err)
	}

	// (2) ITS RE-ENCODED AGGREGATE IS BELOW THE CAP, so an implementation summing
	// re-encoded sizes would ADMIT this pair. That is the bypass under test.
	reencoded := 0
	for _, pg := range pages {
		enc, err := proto.Marshal(pg)
		if err != nil {
			t.Fatalf("re-marshal: %v", err)
		}
		reencoded += len(enc)
	}
	if reencoded >= MaxManifestBytes {
		t.Fatalf("re-encoded aggregate is %d; it must be BELOW %d or a re-encode-summing "+
			"implementation would reject the pair anyway", reencoded, MaxManifestBytes)
	}

	// (3) THE RAW PAIR IS EXACTLY ONE BYTE OVER, with each page individually under.
	if len(a) > MaxManifestBytes || len(b) > MaxManifestBytes {
		t.Fatalf("each page must be individually UNDER the cap (%d, %d vs %d)",
			len(a), len(b), MaxManifestBytes)
	}
	if len(a)+len(b) != MaxManifestBytes+1 {
		t.Fatalf("raw pair totals %d, want exactly %d", len(a)+len(b), MaxManifestBytes+1)
	}

	// (4) THE RAW BOUNDARY REJECTS, and each page alone does not -- so the verdict is
	// the AGGREGATE bound and nothing else.
	if err := ValidateManifestChainFromRaw([][]byte{a, b}, nil); !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("shared over-budget pair = %v, want ErrManifestBounds", err)
	}
	for i, one := range [][]byte{a, b} {
		if err := ValidateManifestChainFromRaw([][]byte{one}, nil); errors.Is(err, ErrManifestBounds) {
			t.Fatalf("page %d alone was rejected on bounds; it must be in budget", i)
		}
	}
}

func TestTombstoneMustReconcile(t *testing.T) {
	rid := mustUUID(t)
	pages := buildManifest(t, rid, [][]*edgev1.EdgeClassificationSpanV1{{activeSpan(t, 10, 20)}})
	// Tombstone recovery id differs from the manifest's.
	tomb := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: mustUUID(t), PriorSpoolId: mustUUID(t), NewSpoolId: mustUUID(t),
		ManifestRootSha256: ManifestRoot(pages), ManifestPageCount: 1, DigestVersion: RecoveryDigestVersion,
	}
	if err := ValidateTombstone(tomb, pages); !errors.Is(err, ErrManifestRecoveryID) && !errors.Is(err, ErrTombstoneMismatch) {
		t.Fatalf("cross-recovery tombstone = %v, want reconciliation error", err)
	}
	// Wrong manifest root.
	tomb2 := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: rid, PriorSpoolId: mustUUID(t), NewSpoolId: mustUUID(t),
		ManifestRootSha256: d32(0x77), ManifestPageCount: 1, DigestVersion: RecoveryDigestVersion,
	}
	if err := ValidateTombstone(tomb2, pages); !errors.Is(err, ErrManifestRoot) {
		t.Fatalf("wrong manifest root = %v, want ErrManifestRoot", err)
	}
	// prior_spool_id == new_spool_id is rejected.
	spool := mustUUID(t)
	tomb3 := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: rid, PriorSpoolId: spool, NewSpoolId: spool,
		ManifestRootSha256: ManifestRoot(pages), ManifestPageCount: 1, DigestVersion: RecoveryDigestVersion,
	}
	if err := ValidateTombstone(tomb3, pages); !errors.Is(err, ErrTombstoneMismatch) {
		t.Fatalf("prior==new spool = %v, want ErrTombstoneMismatch", err)
	}
}

// A manifest whose spans are [1,1] and [100,100] says 2..99 were NOT lost. The
// retired tombstone interval would have declared [1,100] lost -- and because the
// tombstone scope is SIGNED, that would have been an AUTHENTICATED second source of
// truth. The tombstone now carries no interval at all.
func TestTombstoneCarriesNoLossInterval(t *testing.T) {
	rid := mustUUID(t)
	pages := buildManifest(t, rid, [][]*edgev1.EdgeClassificationSpanV1{
		{activeSpan(t, 1, 1), activeSpan(t, 100, 100)},
	})
	tomb := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: rid, PriorSpoolId: mustUUID(t), NewSpoolId: mustUUID(t),
		ManifestRootSha256: ManifestRoot(pages), ManifestPageCount: 1, DigestVersion: RecoveryDigestVersion,
	}
	if err := ValidateTombstone(tomb, pages); err != nil {
		t.Fatalf("gapped manifest must validate: %v", err)
	}
	if d := TombstoneScopeDigest(tomb); len(d) != sha256Len {
		t.Fatalf("tombstone scope digest = %d bytes, want %d", len(d), sha256Len)
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
// set, a scope-covered member is changed AFTER the scope was signed (the r5-05
// substitution repro). It mutates `manifest_page_count` -- the retired loss interval
// this used to mutate is gone, but the property under test is unchanged: any member
// inside the signed scope must not be swappable after signing.
func recoveryControlRecord(t *testing.T, sourceCtxID, bodyRecoveryID []byte, mutateBody bool) (*edgev1.EdgeRecordV1, AuthorizationPolicy) {
	t.Helper()
	tomb := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: bodyRecoveryID, PriorSpoolId: mustUUID(t), NewSpoolId: mustUUID(t),
		ManifestRootSha256: d32(0x11),
		ManifestPageCount:  1, DigestVersion: RecoveryDigestVersion, DetectedAtUnixNano: 1, Reason: "torn-tail",
	}
	scopeDigest := TombstoneScopeDigest(tomb)
	if mutateBody {
		tomb.ManifestPageCount = 99
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
			// REQUIRED PRESENCE: these plans admit no MTR, stated explicitly. An absent
			// count is rejected, so a fixture cannot rely on the proto default.
			r.MtrOrdinalCount = proto.Uint64(0)
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
		// RECOMPUTED from the committed pages, never a carried constant.
		MtrOrdinalRangeCommitment: mustPlanCommitment(t, pages),
	}
	h.ExecutionPlanSha256 = PlanHeaderDigest(h)
	return h, pages
}

// TestPlanHeaderRejectsNon32ByteMtrCommitment pins the length rule. Without it the
// suite stays green with the check deleted: every other test builds a header with a
// correct 32-byte commitment, so nothing exercises the boundary. Empty is the case
// that matters most -- it was the PREVIOUS spelling of "no MTR", and the zero-leaf
// completion proof cannot distinguish it from an omitted commitment.
func mustPlanCommitment(t *testing.T, pages []*edgev1.ScheduledPlanPageV1) []byte {
	t.Helper()
	c, err := PlanMtrOrdinalRangeCommitment(pages)
	if err != nil {
		t.Fatalf("plan mtr commitment: %v", err)
	}
	return c
}

func TestPlanHeaderRejectsNon32ByteMtrCommitment(t *testing.T) {
	for _, tc := range []struct {
		name       string
		commitment []byte
	}{
		{"empty", []byte{}},
		{"nil", nil},
		{"31 bytes", make([]byte, 31)},
		{"33 bytes", make([]byte, 33)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, _ := buildPlan(t, mustUUID(t), d32(0x77), [][]uint64{{256}})
			h.MtrOrdinalRangeCommitment = tc.commitment
			// Re-seal the header so the ONLY reason it can fail is the length rule --
			// otherwise a stale self-hash would mask a deleted check.
			h.ExecutionPlanSha256 = PlanHeaderDigest(h)
			if err := ValidatePlanHeader(h); !errors.Is(err, ErrPlanMtrCommitment) {
				t.Fatalf("commitment %s = %v, want ErrPlanMtrCommitment", tc.name, err)
			}
		})
	}

	// Control: the 32-zero commitment a zero-MTR plan carries IS accepted.
	h, _ := buildPlan(t, mustUUID(t), d32(0x77), [][]uint64{{256}})
	if err := ValidatePlanHeader(h); err != nil {
		t.Fatalf("32-zero commitment must be accepted: %v", err)
	}
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

// appliedPrefixVector is one COMPLETE input set for AppliedThroughSequence. The
// frozen rule needs all four inputs -- a bare span pair pins nothing, because the
// same union yields different answers depending on what was allocated and applied.
type appliedPrefixVector struct {
	name      string
	prior     uint64
	highWater uint64
	applied   []uint64
	lost      [][2]uint64
	expected  uint64
}

func appliedPrefixVectors() []appliedPrefixVector {
	return []appliedPrefixVector{
		{
			// THE GAPPED VECTOR. Lost [1,1] and [100,100] over an allocated space of
			// 1..100, with only sequence 1 applied. The three candidate meanings all
			// differ here, which is the whole point: max span end = 100, allocated
			// high-water = 100, correct contiguous applied prefix = 99.
			name:  "gapped union, tail lost and unapplied",
			prior: 0, highWater: 100, applied: []uint64{1},
			lost: [][2]uint64{{1, 1}, {100, 100}}, expected: 99,
		},
		{
			// Same union, tail now applied: the prefix reaches the high-water.
			name:  "gapped union, tail applied",
			prior: 0, highWater: 100, applied: []uint64{1, 100},
			lost: [][2]uint64{{1, 1}, {100, 100}}, expected: 100,
		},
		{
			// Sequence 1 is lost and unapplied, so nothing advances at all.
			name:  "head lost and unapplied blocks everything",
			prior: 0, highWater: 100, applied: nil,
			lost: [][2]uint64{{1, 1}, {100, 100}}, expected: 0,
		},
		{
			// No loss at all: every sequence is absent from the union, so the prefix
			// runs to the high-water without anything being applied.
			name:  "empty union advances to the high-water",
			prior: 0, highWater: 50, applied: nil,
			lost: nil, expected: 50,
		},
		{
			// The result never retreats below the prior watermark.
			name:  "prior watermark is never retreated",
			prior: 40, highWater: 100, applied: nil,
			lost: [][2]uint64{{41, 41}}, expected: 40,
		},
		{
			// A LOST-BUT-APPLIED sequence still advances: applied satisfies the rule
			// independently of loss. This is the disjunction, not a conjunction.
			name:  "lost but durably applied still advances",
			prior: 0, highWater: 5, applied: []uint64{1, 2, 3, 4, 5},
			lost: [][2]uint64{{1, 5}}, expected: 5,
		},
		{
			// A TRILLION-WIDE legal gap. Gaps are legal and unbounded, so an
			// implementation that enumerates sequences HANGS here rather than failing --
			// a liveness bug on VALID input, which is why this is a vector and not a
			// benchmark. Must terminate immediately, clearing the gap wholesale.
			name:  "trillion-wide gap is skipped wholesale",
			prior: 0, highWater: 2_000_000_000_000, applied: []uint64{1},
			lost:     [][2]uint64{{1, 1}, {2_000_000_000_000, 2_000_000_000_000}},
			expected: 1_999_999_999_999,
		},
		{
			// prior AT MaxUint64: `prior+1` wraps to 0, and an implementation starting
			// its walk there RETREATS the watermark to 0, releasing a journal over
			// everything. Must return prior untouched.
			name:  "prior at MaxUint64 does not wrap or retreat",
			prior: ^uint64(0), highWater: 0, applied: nil, lost: nil,
			expected: ^uint64(0),
		},
		{
			// high-water AT MaxUint64 with the final sequence lost and unapplied. The
			// increment at the top of the range wraps, which is how the earlier version
			// looped forever.
			name:  "high-water at MaxUint64, tail lost and unapplied",
			prior: ^uint64(0) - 2, highWater: ^uint64(0), applied: nil,
			lost:     [][2]uint64{{^uint64(0), ^uint64(0)}},
			expected: ^uint64(0) - 1,
		},
		{
			// The same boundary with the final sequence APPLIED: the prefix must reach
			// MaxUint64 and stop, not wrap past it.
			name:      "high-water at MaxUint64, tail applied",
			prior:     ^uint64(0) - 2,
			highWater: ^uint64(0),
			applied:   []uint64{^uint64(0) - 1, ^uint64(0)},
			lost:      [][2]uint64{{^uint64(0) - 1, ^uint64(0)}},
			expected:  ^uint64(0),
		},
	}
}

func (v appliedPrefixVector) spans(t *testing.T) []*edgev1.EdgeClassificationSpanV1 {
	t.Helper()
	out := make([]*edgev1.EdgeClassificationSpanV1, 0, len(v.lost))
	for _, r := range v.lost {
		out = append(out, activeSpan(t, r[0], r[1]))
	}
	return out
}

func (v appliedPrefixVector) appliedSet() map[uint64]bool {
	m := map[uint64]bool{}
	for _, s := range v.applied {
		m[s] = true
	}
	return m
}

func TestAppliedThroughSequence(t *testing.T) {
	for _, v := range appliedPrefixVectors() {
		t.Run(v.name, func(t *testing.T) {
			got := AppliedThroughSequence(v.prior, v.highWater, v.appliedSet(), v.spans(t))
			if got != v.expected {
				t.Fatalf("AppliedThroughSequence = %d, want %d", got, v.expected)
			}
		})
	}
}

// TestGoldenAppliedPrefixVectors exports the vectors so Elixir computes the SAME
// value from the SAME complete inputs. Without a shared corpus each runtime would
// only be self-consistent, which is exactly how the three candidate meanings could
// diverge unnoticed.
func TestGoldenAppliedPrefixVectors(t *testing.T) {
	var b bytes.Buffer
	for _, v := range appliedPrefixVectors() {
		lost := make([]string, 0, len(v.lost))
		for _, r := range v.lost {
			lost = append(lost, fmt.Sprintf("%d-%d", r[0], r[1]))
		}
		applied := make([]string, 0, len(v.applied))
		for _, s := range v.applied {
			applied = append(applied, strconv.FormatUint(s, 10))
		}
		fmt.Fprintf(&b, "%s\t%d\t%d\t%s\t%s\t%d\n",
			v.name, v.prior, v.highWater,
			strings.Join(applied, ","), strings.Join(lost, ","), v.expected)
	}
	goldenBytesLocal(t, "applied_prefix_vectors.txt", b.Bytes())
}

// retiredTagVector is ONE retired tag carried on otherwise-valid bytes.
//
// SIX INDEPENDENT FIXTURES, deliberately not bundled. A decoder that rejects the
// retired REPEATED fields while silently accepting a stale BOOLEAN passes a combined
// fixture and still admits a page whose digest cannot be reproduced -- so each tag
// needs its own vector or a surviving acceptance hides behind a sibling.
type retiredTagVector struct {
	name    string
	message string
	tag     int
	// wire is the retired field's ORIGINAL wire type. Proving the tag number alone is
	// not enough: a tag-9 VARINT would satisfy a number-only check even though
	// lost_ranges was length-delimited, so a vector could advertise a retired repeated
	// field while carrying bytes that field could never have produced.
	wire  protowire.Type
	field string
	raw   []byte
}

// varintField encodes one protobuf varint field: tag<<3|0, then the value.
func varintField(tag int, v uint64) []byte {
	out := protowire.AppendTag(nil, protowire.Number(tag), protowire.VarintType)
	return protowire.AppendVarint(out, v)
}

// fixedUUIDv7 builds a DETERMINISTIC canonical UUIDv7 from a seed byte. The golden
// vectors below are committed, so they must be byte-stable across runs: mustUUID is
// random per call and would rewrite the fixtures on every regeneration, turning a
// drift guard into noise.
func fixedUUIDv7(seed byte) []byte {
	b := bytes.Repeat([]byte{seed}, 16)
	b[6] = 0x70 | (seed & 0x0F) // version 7
	b[8] = 0x80 | (seed & 0x3F) // RFC variant
	return b
}

// fixedActiveSpan is activeSpan with DETERMINISTIC identity bytes, for the committed
// golden vectors. Random identities would rewrite them on every regeneration.
func fixedActiveSpan(from, through uint64) *edgev1.EdgeClassificationSpanV1 {
	return &edgev1.EdgeClassificationSpanV1{
		FromSequence: from, ThroughSequence: through,
		Classification: &edgev1.EdgeClassificationSpanV1_AttributedActive{
			AttributedActive: &edgev1.EdgeAttributedActiveV1{
				Identity: &edgev1.EdgeAttributedSpanIdentityV1{
					ProducerAssignmentId: fixedUUIDv7(0x61),
					RunId:                fixedUUIDv7(0x62),
					RunShard:             2,
					AuthorityEpoch:       5,
					ProductionScopeId:    fixedUUIDv7(0x63),
					ScopeSha256:          d32(0x64),
					ContractBundleSha256: d32(0x65),
				},
				RangeSha256: d32(0x66),
			},
		},
	}
}

func retiredTagVectors(t *testing.T) []retiredTagVector {
	t.Helper()

	page := buildManifest(t, fixedUUIDv7(0x51), [][]*edgev1.EdgeClassificationSpanV1{{fixedActiveSpan(1, 5)}})[0]
	pageBytes, err := proto.Marshal(page)
	if err != nil {
		t.Fatalf("marshal page: %v", err)
	}

	tomb := &edgev1.SpoolLossTombstoneV1{
		RecoveryId: page.GetRecoveryId(), PriorSpoolId: fixedUUIDv7(0x52), NewSpoolId: fixedUUIDv7(0x53),
		ManifestRootSha256: ManifestRoot([]*edgev1.EdgeLossManifestPageV1{page}),
		ManifestPageCount:  1, DigestVersion: RecoveryDigestVersion,
		DetectedAtUnixNano: 1, Reason: "torn-tail",
	}
	tombBytes, err := proto.Marshal(tomb)
	if err != nil {
		t.Fatalf("marshal tombstone: %v", err)
	}

	// Retired PAGE tags: 7 coarsened (bool), 9 lost_ranges, 10 affected.
	// Retired TOMBSTONE tags: 3/4 the loss interval (varints), 8 coarsened (bool).
	// The repeated fields are encoded as empty length-delimited submessages, which is
	// what a stale candidate encoder would have emitted.
	lenField := func(tag int) []byte {
		out := protowire.AppendTag(nil, protowire.Number(tag), protowire.BytesType)
		return protowire.AppendBytes(out, nil)
	}

	// Wire types are the RETIRED fields' own: bool/uint64 were varints, the two
	// repeated message fields were length-delimited.
	return []retiredTagVector{
		{"page_tag7_coarsened", "EdgeLossManifestPageV1", 7, protowire.VarintType, "coarsened",
			append(append([]byte{}, pageBytes...), varintField(7, 1)...)},
		{"page_tag9_lost_ranges", "EdgeLossManifestPageV1", 9, protowire.BytesType, "lost_ranges",
			append(append([]byte{}, pageBytes...), lenField(9)...)},
		{"page_tag10_affected", "EdgeLossManifestPageV1", 10, protowire.BytesType, "affected",
			append(append([]byte{}, pageBytes...), lenField(10)...)},
		{"tombstone_tag3_lost_from", "SpoolLossTombstoneV1", 3, protowire.VarintType, "lost_from_sequence",
			append(append([]byte{}, tombBytes...), varintField(3, 10)...)},
		{"tombstone_tag4_lost_through", "SpoolLossTombstoneV1", 4, protowire.VarintType, "lost_through_sequence",
			append(append([]byte{}, tombBytes...), varintField(4, 20)...)},
		{"tombstone_tag8_coarsened", "SpoolLossTombstoneV1", 8, protowire.VarintType, "coarsened",
			append(append([]byte{}, tombBytes...), varintField(8, 1)...)},
	}
}

// Each retired tag must be rejected INDEPENDENTLY. Tag reservation prevents SOURCE
// reuse; it does not by itself prove old bytes are refused at runtime, and the
// grammar deliberately keeps version 1 -- so a same-version atomic rewrite could
// otherwise admit stale candidate bytes.
func TestRetiredTagsAreRejectedIndependently(t *testing.T) {
	for _, v := range retiredTagVectors(t) {
		t.Run(v.name, func(t *testing.T) {
			// GUARD THE GUARD: the vector must actually carry the tag it advertises.
			// Without this, a vector built with the WRONG tag -- or none -- would still
			// be rejected for some unrelated reason and the subtest would pass while
			// proving nothing about the tag in its own name.
			assertCarriesTag(t, v)
			switch v.message {
			case "EdgeLossManifestPageV1":
				if err := ValidateManifestChainFromRaw([][]byte{v.raw}, nil); err == nil {
					t.Fatalf("page carrying retired tag %d (%s) was ACCEPTED", v.tag, v.field)
				}
			case "SpoolLossTombstoneV1":
				var tomb edgev1.SpoolLossTombstoneV1
				if err := proto.Unmarshal(v.raw, &tomb); err != nil {
					t.Fatalf("vector must decode to reach the validator: %v", err)
				}
				pages := buildManifest(t, tomb.GetRecoveryId(),
					[][]*edgev1.EdgeClassificationSpanV1{{fixedActiveSpan(1, 5)}})
				if err := ValidateTombstone(&tomb, pages); !errors.Is(err, ErrUnknownFields) {
					t.Fatalf("tombstone carrying retired tag %d (%s) = %v, want ErrUnknownFields",
						v.tag, v.field, err)
				}
			}
		})
	}
}

// assertCarriesTag decodes the vector and requires its advertised retired tag to be
// present among the RETAINED unknown fields. A retired tag is reserved, so protobuf
// keeps it as unknown rather than mapping it to a field -- which is exactly the
// property the rejection depends on.
func assertCarriesTag(t *testing.T, v retiredTagVector) {
	t.Helper()

	var unknown []byte
	switch v.message {
	case "EdgeLossManifestPageV1":
		var m edgev1.EdgeLossManifestPageV1
		if err := proto.Unmarshal(v.raw, &m); err != nil {
			t.Fatalf("%s must decode to be a meaningful vector: %v", v.name, err)
		}
		unknown = m.ProtoReflect().GetUnknown()
	case "SpoolLossTombstoneV1":
		var m edgev1.SpoolLossTombstoneV1
		if err := proto.Unmarshal(v.raw, &m); err != nil {
			t.Fatalf("%s must decode to be a meaningful vector: %v", v.name, err)
		}
		unknown = m.ProtoReflect().GetUnknown()
	}
	if len(unknown) == 0 {
		t.Fatalf("%s retained no unknown field; the vector is inert", v.name)
	}

	type retained struct {
		num protowire.Number
		typ protowire.Type
	}
	var got []retained
	for b := unknown; len(b) > 0; {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			t.Fatalf("%s: malformed retained bytes", v.name)
		}
		got = append(got, retained{num, typ})
		b = b[n:]
		n = protowire.ConsumeFieldValue(num, typ, b)
		if n < 0 {
			t.Fatalf("%s: malformed retained value", v.name)
		}
		b = b[n:]
	}
	// TAG AND WIRE TYPE. The number alone would accept a tag-9 varint even though
	// lost_ranges was length-delimited -- bytes that retired field could never have
	// produced, advertised as if it had.
	for _, r := range got {
		if int(r.num) == v.tag && r.typ == v.wire {
			return
		}
	}
	t.Fatalf("%s advertises tag %d wire %v (%s) but retained %v",
		v.name, v.tag, v.wire, v.field, got)
}

// TestGoldenRetiredTagVectors exports the six raw byte vectors so Elixir refuses the
// SAME bytes. A Go-only proof would leave the Elixir decoder free to accept them.
func TestGoldenRetiredTagVectors(t *testing.T) {
	for _, v := range retiredTagVectors(t) {
		goldenBytesLocal(t, "retired_"+v.name+".bin", v.raw)
	}
}
