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
	"math/bits"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// RecoveryDigestVersion is the canonical page/root digest algorithm version.
const RecoveryDigestVersion = 1

// Hard bounds so a manifest can never enumerate an outage-sized tail.
const (
	MaxManifestPages = 1024
	// MaxRangesPerPage bounds a PLAN page's target ranges. Unrelated to recovery
	// spans despite the shared history; plan.go is its only consumer.
	MaxRangesPerPage = 256
	// MaxSpansPerPage replaces the retired recovery MaxRangesPerPage/
	// MaxAffectedScopesPerPage pair: one span now carries what an interval and its
	// scope carried separately, so the meaningful count is the interval count.
	MaxSpansPerPage = 256
)

// MaxManifestBytes bounds the total encoded size of a manifest's pages so a
// recovery can never smuggle an outage-sized tail.
const MaxManifestBytes = 256 * 1024

// MaxReasonBytes bounds a tombstone's free-text reason.
const MaxReasonBytes = 256

var (
	ErrManifestDigestVersion = errors.New("edgerecord: unsupported manifest digest version")
	ErrManifestPageDigest    = errors.New("edgerecord: manifest page digest mismatch")
	ErrManifestChain         = errors.New("edgerecord: manifest page chain broken")
	ErrManifestTerminal      = errors.New("edgerecord: manifest terminal flag inconsistent")
	ErrManifestRange         = errors.New("edgerecord: manifest range out of order/overlapping")
	ErrManifestRoot          = errors.New("edgerecord: manifest root mismatch")
	ErrManifestBounds        = errors.New("edgerecord: manifest exceeds hard bounds")
	ErrManifestEmpty         = errors.New("edgerecord: empty manifest")
	ErrManifestRecoveryID    = errors.New("edgerecord: manifest pages disagree on recovery id")
	ErrManifestSpan          = errors.New("edgerecord: classification span invalid")
	ErrManifestSpanBody      = errors.New("edgerecord: classification span body invalid")
	ErrTombstoneMismatch     = errors.New("edgerecord: tombstone disagrees with its manifest")
)

// Per-object domain tags: each recovery self-hash preimage leads with its own frozen
// string tag so a manifest-page digest can never equal a manifest-root (or any plan)
// digest by field-structure coincidence. Part of the frozen ABI (#4710 Appendix A),
// mirrored by ServiceRadar.Edge.HashGrammar. (The recovery-OPERATION SCOPE digests --
// TombstoneScopeDigest and the manifest-page/resolved scope digests -- carry their own
// RecoveryScopeDigestVersion + u64 body-kind discriminant and are a separate family.)
const (
	manifestPageDomain = "serviceradar.edge.recovery.manifest_page.v1"
	manifestRootDomain = "serviceradar.edge.recovery.manifest_root.v1"
)

// ManifestPageDigest computes the canonical digest over every EdgeLossManifestPageV1
// field EXCEPT page_sha256, so a contradictory page cannot masquerade as valid.
func ManifestPageDigest(p *edgev1.EdgeLossManifestPageV1) []byte {
	d := newDigest()
	d.str(manifestPageDomain)
	d.u64(uint64(p.GetDigestVersion()))
	d.bytes(p.GetRecoveryId())
	d.u64(uint64(p.GetPageIndex()))
	d.u64(uint64(p.GetPageCount()))
	d.bytes(p.GetPrevPageSha256())
	d.present(p.GetTerminal())
	d.u64(uint64(len(p.GetClassificationSpans())))
	for _, sp := range p.GetClassificationSpans() {
		// Field-by-field per Appendix A -- NOT proto.Marshal, so the digest is
		// byte-identical across protobuf-go and protobuf-elixir.
		d.u64(sp.GetFromSequence())
		d.u64(sp.GetThroughSequence())
		spanBodyDigest(d, sp)
	}
	return d.finish()
}

// Frozen oneof member field numbers. These ARE the transcript discriminant, so they
// are written out rather than derived: a renumbered oneof would silently change every
// page digest.
const (
	spanMemberActive         uint64 = 3
	spanMemberPassive        uint64 = 4
	spanMemberUnattributable uint64 = 5
)

// spanBodyDigest frames one span's classification body.
//
// The identity marker is emitted even though an unset identity is REJECTED: omitting
// a marker for a field that "cannot" be absent is how two runtimes end up disagreeing
// about whether the byte is there. The SOURCE marker is load-bearing rather than
// merely structural -- absence is part of the span identity, so source-present and
// source-absent spans MUST produce different preimages, and framing an absent source
// as zero-valued fields would collapse them.
//
// Repeated entries carry no per-entry marker (the element count precedes them) and
// the oneof body carries none (the discriminant names it); every other nested message
// keeps its marker.
func spanBodyDigest(d *digestWriter, sp *edgev1.EdgeClassificationSpanV1) {
	switch b := sp.GetClassification().(type) {
	case *edgev1.EdgeClassificationSpanV1_AttributedActive:
		d.u64(spanMemberActive)
		identityDigest(d, b.AttributedActive.GetIdentity())
		d.bytes(b.AttributedActive.GetRangeSha256())
	case *edgev1.EdgeClassificationSpanV1_AttributedPassive:
		d.u64(spanMemberPassive)
		identityDigest(d, b.AttributedPassive.GetIdentity())
	case *edgev1.EdgeClassificationSpanV1_Unattributable:
		d.u64(spanMemberUnattributable)
		d.u64(uint64(b.Unattributable.GetReason()))
	}
}

func identityDigest(d *digestWriter, id *edgev1.EdgeAttributedSpanIdentityV1) {
	d.present(id != nil)
	if id == nil {
		return
	}
	d.bytes(id.GetProducerAssignmentId())
	d.bytes(id.GetRunId())
	d.u64(uint64(id.GetRunShard()))
	d.u64(id.GetAuthorityEpoch())
	d.bytes(id.GetProductionScopeId())
	d.bytes(id.GetScopeSha256())
	d.bytes(id.GetContractBundleSha256())

	src := id.GetSource()
	d.present(src != nil)
	if src == nil {
		return
	}
	d.u64(uint64(src.GetKind()))
	d.bytes(src.GetContextId())
	d.bytes(src.GetSourceScopeId())
	d.bytes(src.GetSourceScopeSha256())
}

// ManifestRoot composes the ordered root over a validated page chain:
// SHA-256(version || page_count || concat(page_sha256 in page order)).
func ManifestRoot(pages []*edgev1.EdgeLossManifestPageV1) []byte {
	return manifestRootWithVersion(pages, RecoveryDigestVersion)
}

// manifestRootWithVersion is ManifestRoot with the grammar version supplied rather than
// baked in. The exported wrapper is the ONLY production caller and always passes the frozen
// constant, so no shipped behaviour is parameterised.
//
// It exists so the shared version corpus can author the artifact a peer running a DIFFERENT
// grammar version would emit -- and can do so WITHOUT a second copy of this transcript. A
// re-implemented grammar is the failure mode this avoids: it agrees on the day it is written
// and drifts silently afterwards, which is exactly what a version freeze must not rely on.
func manifestRootWithVersion(pages []*edgev1.EdgeLossManifestPageV1, version uint64) []byte {
	d := newDigest()
	d.str(manifestRootDomain)
	d.u64(version)
	d.u64(uint64(len(pages)))
	for _, p := range pages {
		d.bytes(p.GetPageSha256())
	}
	return d.finish()
}

// ValidateManifestChainFromRaw is the RAW-BYTE entry point. It bounds each page on
// the bytes ACTUALLY RECEIVED, before any unmarshal, and sums those exact lengths.
//
// A per-page check is not sufficient on its own: MaxManifestBytes is an AGGREGATE
// budget, so two pages can each be under the cap in received bytes, exceed it
// together, and then collapse back under it when re-encoded. Summing re-encoded
// sizes -- which is what the pre-1.6a validator did -- therefore admits an
// over-budget manifest whose pages carry duplicate fields or non-minimal varints.
func ValidateManifestChainFromRaw(raw [][]byte, expectedRoot []byte) error {
	if len(raw) == 0 {
		return ErrManifestEmpty
	}
	if len(raw) > MaxManifestPages {
		return ErrManifestBounds
	}
	// BOUND FIRST, DECODE SECOND. The budget is checked over every page's received
	// length BEFORE any unmarshal -- interleaving the two would let a page that fails
	// to decode mask a later page's budget violation, and would decode bytes the
	// budget already rejects.
	var total uint64
	for _, b := range raw {
		if len(b) > MaxManifestBytes {
			return ErrManifestBounds
		}
		sum, carry := bits.Add64(total, uint64(len(b)), 0)
		if carry != 0 || sum > MaxManifestBytes {
			return ErrManifestBounds
		}
		total = sum
	}

	pages := make([]*edgev1.EdgeLossManifestPageV1, 0, len(raw))
	for _, b := range raw {
		var pg edgev1.EdgeLossManifestPageV1
		if err := proto.Unmarshal(b, &pg); err != nil {
			return ErrManifestChain
		}
		pages = append(pages, &pg)
	}
	return ValidateManifestChain(pages, expectedRoot)
}

// ValidateManifestChain fail-closes a decoded manifest: bounds, per-page digest,
// index/count/terminal relations, predecessor chaining, one UUIDv7 recovery id shared
// by every page, GLOBALLY ordered non-overlapping classification spans across page
// boundaries, structural span validity, and (when a nonzero expectedRoot is given)
// the ordered root.
//
// It does NOT enforce the received-byte budget, because it cannot: it is handed
// decoded messages. Callers that hold the wire bytes MUST use
// ValidateManifestChainFromRaw.
func ValidateManifestChain(pages []*edgev1.EdgeLossManifestPageV1, expectedRoot []byte) error {
	if len(pages) == 0 {
		return ErrManifestEmpty
	}
	// Appendix A requires unknown fields to be REJECTED in every grammar-covered position BEFORE
	// hashing: the field-framed digests walk declared fields only, so retained unknown bytes would be
	// invisible to the digest while still riding along on the wire. That is load-bearing for
	// immutable plan/recovery CONTENT ADDRESSING.
	// STRUCTURAL COUNTS BEFORE ANY RECURSIVE WALK -- see ValidatePlanPages for the full
	// reasoning. hasUnknownFields RECURSES into every classification span of every page, so
	// bounding the page list and each page's span count afterwards did the work the ceilings
	// exist to prevent. Both checks are O(1) per page on a decoded slice.
	//
	// PRECEDENCE, frozen: an oversize page list whose pages ALSO carry unknown fields is a
	// BOUNDS refusal. Both are refusals, so only a precedence assertion can hold this.
	if len(pages) > MaxManifestPages {
		return ErrManifestBounds
	}
	for _, p := range pages {
		if l := len(p.GetClassificationSpans()); l == 0 || l > MaxSpansPerPage {
			return ErrManifestBounds
		}
	}

	for _, p := range pages {
		if hasUnknownFields(p) {
			return ErrUnknownFields
		}
	}
	if err := validateUUIDv7Field(pages[0].GetRecoveryId()); err != nil {
		return ErrManifestRecoveryID
	}
	recoveryID := pages[0].GetRecoveryId()
	count := len(pages)

	var prevThrough uint64
	haveSpan := false

	for i, p := range pages {
		if p.GetDigestVersion() != RecoveryDigestVersion {
			return ErrManifestDigestVersion
		}
		if !bytes.Equal(p.GetRecoveryId(), recoveryID) {
			return ErrManifestRecoveryID
		}
		if int(p.GetPageCount()) != count || int(p.GetPageIndex()) != i {
			return ErrManifestChain
		}
		// At least one span per page (an empty page has no derivable extent, so it can be
		// neither validated nor chained) and at most MaxSpansPerPage -- both bounded ABOVE,
		// before the recursive walk. Re-checking here would be dead code that reads like the
		// enforcement point.
		spans := p.GetClassificationSpans()
		// REJECT BEFORE HASHING. Every span body is structurally validated -- including
		// the CLOSED enum sets -- before this page is hashed. Hashing first would make
		// the verdict for an invalid enum depend on the supplied page digest: with a
		// MATCHING digest the hash check passes and the body error surfaces, but with
		// a STALE digest the page is rejected as a digest mismatch and the invalid
		// value is never reported -- having already been hashed. The frozen rule is
		// that an unaccepted value never reaches the digest at all.
		for _, sp := range spans {
			if err := validateClassificationSpanBody(sp); err != nil {
				return err
			}
		}
		if !bytes.Equal(ManifestPageDigest(p), p.GetPageSha256()) {
			return ErrManifestPageDigest
		}
		if p.GetTerminal() != (i == count-1) {
			return ErrManifestTerminal
		}
		if i == 0 {
			if len(p.GetPrevPageSha256()) != 0 {
				return ErrManifestChain
			}
		} else if !bytes.Equal(p.GetPrevPageSha256(), pages[i-1].GetPageSha256()) {
			return ErrManifestChain
		}

		for _, sp := range spans {
			// Primitively valid on its own: a single span with a zero or inverted
			// interval violates no ordering rule, so ordering alone does not exclude it.
			if sp.GetFromSequence() == 0 { // lane sequences start at 1
				return ErrManifestSpan
			}
			if sp.GetThroughSequence() < sp.GetFromSequence() {
				return ErrManifestSpan
			}
			// Strictly ascending and non-overlapping across the WHOLE chain, not
			// merely within a page: a within-page rule lets two individually valid
			// pages describe overlapping loss and double-count the union.
			//
			// ADJACENCY IS PERMITTED, unlike the retired lost_ranges rule. Gaps are
			// legal and mean "not lost", so a producer may legitimately emit [1,1]
			// and [2,2] separately when their classification bodies differ.
			if haveSpan && sp.GetFromSequence() <= prevThrough {
				return ErrManifestSpan
			}
			prevThrough = sp.GetThroughSequence()
			haveSpan = true
		}
	}
	if !haveSpan {
		return ErrManifestSpan
	}
	if len(expectedRoot) > 0 && !bytes.Equal(ManifestRoot(pages), expectedRoot) {
		return ErrManifestRoot
	}
	return nil
}

// validateClassificationSpanBody enforces what the oneof cannot. The oneof guarantees
// AT MOST ONE body; exactly-one is enforced here, because a proto3 oneof can
// legitimately be unset. Likewise proto3 still permits a set body with a nil identity,
// empty required bytes, or a wrong-width digest.
func validateClassificationSpanBody(sp *edgev1.EdgeClassificationSpanV1) error {
	switch b := sp.GetClassification().(type) {
	case *edgev1.EdgeClassificationSpanV1_AttributedActive:
		if err := validateSpanIdentity(b.AttributedActive.GetIdentity()); err != nil {
			return err
		}
		// range_sha256 is REQUIRED on ACTIVE and absent on PASSIVE.
		if len(b.AttributedActive.GetRangeSha256()) != sha256Len {
			return ErrManifestSpanBody
		}
		return nil

	case *edgev1.EdgeClassificationSpanV1_AttributedPassive:
		return validateSpanIdentity(b.AttributedPassive.GetIdentity())

	case *edgev1.EdgeClassificationSpanV1_Unattributable:
		if !knownUnattributableReason(b.Unattributable.GetReason()) {
			return ErrManifestSpanBody
		}
		return nil

	default:
		// Unset oneof: an interval with no classification, which no consumer can act on.
		return ErrManifestSpanBody
	}
}

// knownUnattributableReason is the frozen v1 accepted SET, not "any declared member".
// A member added by a later proto revision must NOT begin hashing under an unchanged
// RecoveryDigestVersion; admitting one is a deliberate grammar version change. The
// reserved numbers 1 and 5 fall through to the default arm like any other.
//
// TWO GATES COVER THIS PREDICATE, and neither covers the other's case. The enum-policy
// manifest proves Go and Elixir police the same DECLARED members -- but it enumerates
// the descriptor, so widening this to accept a RESERVED or unknown number is invisible
// to it (a reserved number has no descriptor entry to export). That case is covered by
// the explicit reject vectors for 0, -1, 1, 5, 8 and 999 in recovery_test.go and
// recovery_validate_test.exs. Removing either gate leaves a real hole.
func knownUnattributableReason(v edgev1.EdgeUnattributableReason) bool {
	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted value
	switch v {
	case edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING,
		edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT,
		edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL,
		edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_VERSION_UNSUPPORTED,
		edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_DISCRIMINATOR_UNREPRESENTABLE:
		return true
	default:
		return false
	}
}

func validateSpanIdentity(id *edgev1.EdgeAttributedSpanIdentityV1) error {
	if id == nil {
		return ErrManifestSpanBody
	}
	// Canonical UUIDs, not merely non-empty: the accepted-record validators already
	// require canonical UUIDs for these, and a weaker manifest rule would admit
	// attributed identities no valid record could have produced.
	for _, u := range [][]byte{id.GetProducerAssignmentId(), id.GetRunId(), id.GetProductionScopeId()} {
		if ValidateCanonicalUUID(u) != nil {
			return ErrManifestSpanBody
		}
	}
	if len(id.GetScopeSha256()) != sha256Len || len(id.GetContractBundleSha256()) != sha256Len {
		return ErrManifestSpanBody
	}

	src := id.GetSource()
	if src == nil {
		// Absent source is legal -- and is NOT the same as PASSIVE. Source presence
		// and attribution classification are independent axes.
		return nil
	}
	// All four members travel together; a partial combination is rejected.
	//
	// The accepted set is knownSourceAuthKind -- the SAME production predicate the
	// record's own source_authorization uses, not a copy. An earlier revision restated
	// the seven members inline here, which is a second source of truth for one frozen
	// set and would drift silently from the enum-policy manifest.
	if !knownSourceAuthKind(src.GetKind()) {
		return ErrManifestSpanBody
	}
	if ValidateCanonicalUUID(src.GetContextId()) != nil || ValidateCanonicalUUID(src.GetSourceScopeId()) != nil {
		return ErrManifestSpanBody
	}
	if len(src.GetSourceScopeSha256()) != sha256Len {
		return ErrManifestSpanBody
	}
	return nil
}

// ValidateTombstone fail-closes a spool-loss tombstone against its manifest pages:
// matching recovery id, digest version, page count, UUIDv7 prior/new spool ids, and
// the ordered manifest root. It no longer compares a loss interval or a coarsening
// flag -- 1.6a removes both from the tombstone.
func ValidateTombstone(t *edgev1.SpoolLossTombstoneV1, pages []*edgev1.EdgeLossManifestPageV1) error {
	if t == nil {
		return ErrNilRecord
	}
	// Appendix A requires unknown fields to be REJECTED in every grammar-covered position BEFORE
	// hashing: the field-framed digests walk declared fields only, so retained unknown bytes would be
	// invisible to the digest while still riding along on the wire. That is load-bearing for
	// immutable plan/recovery CONTENT ADDRESSING.
	if hasUnknownFields(t) {
		return ErrUnknownFields
	}
	if err := validateUUIDv7Field(t.GetRecoveryId()); err != nil {
		return ErrIdentity
	}
	if validateUUIDv7Field(t.GetPriorSpoolId()) != nil || validateUUIDv7Field(t.GetNewSpoolId()) != nil {
		return fmt.Errorf("%w: spool ids", ErrTombstoneMismatch)
	}
	if bytes.Equal(t.GetPriorSpoolId(), t.GetNewSpoolId()) {
		return fmt.Errorf("%w: prior and new spool must differ", ErrTombstoneMismatch)
	}
	if t.GetDigestVersion() != RecoveryDigestVersion {
		return ErrManifestDigestVersion
	}
	// BOUNDS BEFORE THE RELATION. The declared count is compared only once the supplied list
	// is known to be within the ceiling: an over-ceiling manifest is a BOUNDS fault whatever
	// the tombstone declares, and reporting it as a chain mismatch describes the wrong
	// problem. It also matters for parity -- a peer whose count is not O(1) cannot compare a
	// declared count first without walking past the ceiling to do it, so relation-first is
	// not a shape both runtimes can implement.
	if len(pages) > MaxManifestPages {
		return ErrManifestBounds
	}
	if int(t.GetManifestPageCount()) != len(pages) {
		return ErrManifestChain
	}
	if err := ValidateManifestChain(pages, t.GetManifestRootSha256()); err != nil {
		return err
	}
	if !bytes.Equal(t.GetRecoveryId(), pages[0].GetRecoveryId()) {
		return ErrTombstoneMismatch
	}
	if !bytes.Equal(ManifestRoot(pages), t.GetManifestRootSha256()) {
		return ErrManifestRoot
	}
	// The tombstone carries NO loss interval. With gaps legal the manifest's global
	// min/max is not the loss -- for spans [1,1] and [100,100] the pages say 2..99
	// were NOT lost while a min/max interval would declare [1,100] lost -- and
	// because the tombstone scope is SIGNED, that would be an AUTHENTICATED second
	// source of truth. The manifest root is the loss commitment.
	return nil
}

// ValidateRecoveryControl composes envelope-to-domain recovery validation by
// DECODING the record's actual payload. The record MUST be a valid recovery-lane
// record whose canonical payload is an EdgeRecoveryControlPayloadV1; the carried
// body's recovery_id MUST equal the record's signed recovery source context -- so
// a record authorized for recovery context A cannot ship a body (tombstone,
// manifest page, or resolved) for context B, and the body cannot be an unrelated
// object left beside a stale sweep payload.
func ValidateRecoveryControl(r *edgev1.EdgeRecordV1, expected *edgev1.EdgeOutputContractRef, policy AuthorizationPolicy) error {
	if err := ValidateRecordSigned(r, policy); err != nil {
		return err
	}
	if err := dispatchContract(r, expected); err != nil {
		return err
	}
	if r.GetPayloadFamily() != edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1 {
		return ErrRecoveryLane
	}
	sa := r.GetSourceAuthorization()
	if sa == nil || sa.GetKind() != edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL {
		return ErrRecoveryLane
	}
	inner, err := innerPayload(r)
	if err != nil {
		return err
	}
	var pl edgev1.EdgeRecoveryControlPayloadV1
	if err := unmarshalPayload(inner, &pl); err != nil {
		return err
	}
	rid, scope, err := recoveryControlBody(&pl)
	if err != nil {
		return err
	}
	// The signed recovery source scope MUST fix the exact recovery operation: its
	// scope_id is the recovery id and its scope_sha256 is the canonical digest over
	// the body's spool pair, manifest root, and page count. Reusing a signature for a
	// different spool pair or manifest root therefore fails.
	claims := sa.GetCapability().GetSource()
	if !bytes.Equal(sa.GetContextId(), rid) || !bytes.Equal(claims.GetScopeId(), rid) {
		return fmt.Errorf("%w: record recovery context != body recovery id", ErrTombstoneMismatch)
	}
	if !bytes.Equal(claims.GetScopeSha256(), scope) {
		return fmt.Errorf("%w: signed scope does not fix the recovery operation", ErrTombstoneMismatch)
	}
	return nil
}

// RecoveryScopeDigestVersion is the frozen recovery-operation scope grammar.
const RecoveryScopeDigestVersion = 1

// TombstoneScopeDigest is the canonical digest over a tombstone's recovery
// operation: recovery id, prior/new spool, manifest root, and page count. The
// signed recovery source scope_sha256 MUST equal it, so the grant fixes the exact
// spool pair and manifest root it authorizes. The loss interval and coarsening
// flag it used to cover are retired -- the manifest root is the loss commitment.
func TombstoneScopeDigest(t *edgev1.SpoolLossTombstoneV1) []byte {
	return tombstoneScopeDigestWithVersion(t, RecoveryScopeDigestVersion)
}

// tombstoneScopeDigestWithVersion is TombstoneScopeDigest with the grammar version supplied rather than
// baked in. The exported wrapper is the ONLY production caller and always passes the frozen
// constant, so no shipped behaviour is parameterised.
//
// It exists so the shared version corpus can author the artifact a peer running a DIFFERENT
// grammar version would emit -- and can do so WITHOUT a second copy of this transcript. A
// re-implemented grammar is the failure mode this avoids: it agrees on the day it is written
// and drifts silently afterwards, which is exactly what a version freeze must not rely on.
func tombstoneScopeDigestWithVersion(t *edgev1.SpoolLossTombstoneV1, version uint64) []byte {
	d := newDigest()
	d.u64(version)
	d.u64(0) // body kind: tombstone
	d.bytes(t.GetRecoveryId())
	d.bytes(t.GetPriorSpoolId())
	d.bytes(t.GetNewSpoolId())
	d.bytes(t.GetManifestRootSha256())
	d.u64(uint64(t.GetManifestPageCount()))
	return d.finish()
}

// ManifestPageScopeDigest is the recovery-operation scope digest for a manifest-page
// control body: RecoveryScopeDigestVersion || u64(1) [body kind: manifest page] ||
// recovery_id || page_sha256. The u64 body-kind discriminant keeps it distinct from
// the tombstone (0) and resolved (2) scope digests.
func ManifestPageScopeDigest(p *edgev1.EdgeLossManifestPageV1) []byte {
	return manifestPageScopeDigestWithVersion(p, RecoveryScopeDigestVersion)
}

// manifestPageScopeDigestWithVersion is ManifestPageScopeDigest with the grammar version supplied rather than
// baked in. The exported wrapper is the ONLY production caller and always passes the frozen
// constant, so no shipped behaviour is parameterised.
//
// It exists so the shared version corpus can author the artifact a peer running a DIFFERENT
// grammar version would emit -- and can do so WITHOUT a second copy of this transcript. A
// re-implemented grammar is the failure mode this avoids: it agrees on the day it is written
// and drifts silently afterwards, which is exactly what a version freeze must not rely on.
func manifestPageScopeDigestWithVersion(p *edgev1.EdgeLossManifestPageV1, version uint64) []byte {
	d := newDigest()
	d.u64(version)
	d.u64(1)
	d.bytes(p.GetRecoveryId())
	d.bytes(p.GetPageSha256())
	return d.finish()
}

// ResolvedScopeDigest is the recovery-operation scope digest for a resolved control
// body: RecoveryScopeDigestVersion || u64(2) [body kind: resolved] || recovery_id ||
// manifest_root_sha256 || applied_through_sequence.
func ResolvedScopeDigest(rv *edgev1.RecoveryResolvedV1) []byte {
	return resolvedScopeDigestWithVersion(rv, RecoveryScopeDigestVersion)
}

// resolvedScopeDigestWithVersion is ResolvedScopeDigest with the grammar version supplied rather than
// baked in. The exported wrapper is the ONLY production caller and always passes the frozen
// constant, so no shipped behaviour is parameterised.
//
// It exists so the shared version corpus can author the artifact a peer running a DIFFERENT
// grammar version would emit -- and can do so WITHOUT a second copy of this transcript. A
// re-implemented grammar is the failure mode this avoids: it agrees on the day it is written
// and drifts silently afterwards, which is exactly what a version freeze must not rely on.
func resolvedScopeDigestWithVersion(rv *edgev1.RecoveryResolvedV1, version uint64) []byte {
	d := newDigest()
	d.u64(version)
	d.u64(2)
	d.bytes(rv.GetRecoveryId())
	d.bytes(rv.GetManifestRootSha256())
	d.u64(rv.GetAppliedThroughSequence())
	return d.finish()
}

// recoveryControlBody validates every invariant knowable from ONE body before
// durable admission and returns (recovery_id, canonical scope digest). Full
// relational manifest-chain validation still runs after assembly.
func recoveryControlBody(pl *edgev1.EdgeRecoveryControlPayloadV1) (rid, scope []byte, err error) {
	switch b := pl.GetBody().(type) {
	case *edgev1.EdgeRecoveryControlPayloadV1_Tombstone:
		t := b.Tombstone
		if validateUUIDv7Field(t.GetRecoveryId()) != nil {
			return nil, nil, fmt.Errorf("%w: tombstone recovery id", ErrTombstoneMismatch)
		}
		if validateUUIDv7Field(t.GetPriorSpoolId()) != nil || validateUUIDv7Field(t.GetNewSpoolId()) != nil ||
			bytes.Equal(t.GetPriorSpoolId(), t.GetNewSpoolId()) {
			return nil, nil, fmt.Errorf("%w: tombstone spools", ErrTombstoneMismatch)
		}
		if t.GetDigestVersion() != RecoveryDigestVersion || len(t.GetManifestRootSha256()) != sha256Len {
			return nil, nil, fmt.Errorf("%w: tombstone digest", ErrTombstoneMismatch)
		}
		// BOUNDED 1..MaxManifestPages, not merely non-zero. This path receives NO page list --
		// `ValidateTombstone` is what reconciles a declaration against supplied pages -- so the
		// declaration is committed by the scope digest exactly as signed. An unbounded count
		// therefore travels signed and is only questioned, if ever, at assembly.
		if c := t.GetManifestPageCount(); c == 0 || c > MaxManifestPages {
			return nil, nil, fmt.Errorf("%w: tombstone page count", ErrTombstoneMismatch)
		}

		if t.GetDetectedAtUnixNano() <= 0 {
			return nil, nil, fmt.Errorf("%w: tombstone detected-at", ErrTombstoneMismatch)
		}
		if l := len(t.GetReason()); l == 0 || l > MaxReasonBytes {
			return nil, nil, fmt.Errorf("%w: tombstone reason", ErrTombstoneMismatch)
		}
		return t.GetRecoveryId(), TombstoneScopeDigest(t), nil
	case *edgev1.EdgeRecoveryControlPayloadV1_ManifestPage:
		p := b.ManifestPage
		if err := validateSingleManifestPage(p); err != nil {
			return nil, nil, err
		}
		return p.GetRecoveryId(), ManifestPageScopeDigest(p), nil
	case *edgev1.EdgeRecoveryControlPayloadV1_Resolved:
		rv := b.Resolved
		if validateUUIDv7Field(rv.GetRecoveryId()) != nil || len(rv.GetManifestRootSha256()) != sha256Len ||
			rv.GetAppliedThroughSequence() == 0 {
			return nil, nil, fmt.Errorf("%w: resolved recovery id/root/applied", ErrTombstoneMismatch)
		}
		return rv.GetRecoveryId(), ResolvedScopeDigest(rv), nil
	default:
		return nil, nil, fmt.Errorf("%w: empty recovery control body", ErrTombstoneMismatch)
	}
}

// validateSingleManifestPage enforces every invariant knowable from one page in
// isolation: known digest version, index < count, terminal relation, predecessor
// length, per-page bounds, at least one span, ordered non-overlapping spans
// (from >= 1; ADJACENCY is permitted since gaps are legal), structurally valid
// span bodies, and a matching self-hash.
func validateSingleManifestPage(p *edgev1.EdgeLossManifestPageV1) error {
	if validateUUIDv7Field(p.GetRecoveryId()) != nil {
		return fmt.Errorf("%w: page recovery id", ErrManifestRecoveryID)
	}
	if p.GetDigestVersion() != RecoveryDigestVersion {
		return ErrManifestDigestVersion
	}
	if p.GetPageCount() == 0 || p.GetPageIndex() >= p.GetPageCount() {
		return ErrManifestChain
	}
	if p.GetTerminal() != (p.GetPageIndex() == p.GetPageCount()-1) {
		return ErrManifestTerminal
	}
	wantPrev := 0
	if p.GetPageIndex() != 0 {
		wantPrev = sha256Len
	}
	if len(p.GetPrevPageSha256()) != wantPrev {
		return ErrManifestChain
	}
	spans := p.GetClassificationSpans()
	if len(spans) == 0 || len(spans) > MaxSpansPerPage {
		return ErrManifestBounds
	}
	var prevThrough uint64
	have := false
	for _, sp := range spans {
		if sp.GetFromSequence() == 0 || sp.GetThroughSequence() < sp.GetFromSequence() {
			return ErrManifestSpan
		}
		// Overlap is rejected; ADJACENCY is permitted, since gaps are legal and two
		// adjacent spans may legitimately differ in classification body.
		if have && sp.GetFromSequence() <= prevThrough {
			return ErrManifestSpan
		}
		if err := validateClassificationSpanBody(sp); err != nil {
			return err
		}
		prevThrough = sp.GetThroughSequence()
		have = true
	}
	if !have {
		return ErrManifestSpan
	}
	if !bytes.Equal(ManifestPageDigest(p), p.GetPageSha256()) {
		return ErrManifestPageDigest
	}
	return nil
}

// AppliedThroughSequence computes the frozen meaning of
// RecoveryResolvedV1.applied_through_sequence: the consumer's DURABLY APPLIED
// CONTIGUOUS PREFIX over the ALLOCATED sequence space.
//
// It is the highest S such that EVERY allocated sequence at or below S is either
// durably applied by the consumer transaction, or ABSENT from a VALIDATED COMPLETE
// span union. The union is the LOST set, so only ABSENCE from a complete union
// establishes not-lost -- the inverse reading releases a journal over sequences the
// consumer never processed.
//
// It is NOT the maximum span end and NOT the allocated high-water. For lost spans
// [1,1] and [100,100] over an allocated space of 1..100 with only sequence 1 applied,
// all three candidates differ: max span end and high-water are both 100, while the
// correct value is 99 -- sequence 100 is lost and unapplied, so the prefix stops
// short of it. This value GATES durable local journal release, so picking the wrong
// candidate discards data the consumer still owes.
//
// prior is the previously published watermark; the result never retreats below it.
//
// TOTAL AND BOUNDED. An earlier version walked seq := prior+1 to the high-water one
// sequence at a time, which was neither: prior+1 WRAPS at MaxUint64 (so
// prior=MaxUint64 retreated to 0, and prior=MaxUint64-1 looped forever), and a legal
// gap of a trillion sequences cost a trillion iterations. Gaps are legal and can be
// arbitrarily wide, so enumerating them is not an optimisation problem -- it is a
// liveness bug on valid input.
//
// This walks the ORDERED loss spans instead and skips gaps wholesale. Work is
// O(#spans + |appliedDurably|): a gap costs one step regardless of width, and inside
// a lost span the prefix can only advance while consecutive sequences are applied, so
// that region is bounded by the applied set, not by the span.
//
// lost MUST be the validated, ordered, non-overlapping union. Passing an unordered or
// partial union yields a value that looks plausible and is wrong.
func AppliedThroughSequence(prior, allocatedHighWater uint64, appliedDurably map[uint64]bool, lost []*edgev1.EdgeClassificationSpanV1) uint64 {
	if prior >= allocatedHighWater {
		return prior
	}
	s := prior

	for _, sp := range lost {
		from, through := sp.GetFromSequence(), sp.GetThroughSequence()
		if through <= s {
			continue // already behind the prefix
		}
		// Everything strictly below this span's start is absent from the union, hence
		// NOT LOST, so the prefix clears it in one step however wide the gap is.
		if from > 0 && from-1 > s {
			s = min64(from-1, allocatedHighWater)
			if s >= allocatedHighWater {
				return s
			}
		}
		// Inside the span every sequence must be individually applied.
		for seq := max64(s+1, from); seq <= through && seq <= allocatedHighWater; seq++ {
			if !appliedDurably[seq] {
				return s
			}
			s = seq
			if seq == ^uint64(0) {
				return s // MaxUint64 reached: seq++ would wrap
			}
		}
		if s < through && s < allocatedHighWater {
			return s
		}
	}
	// Past the last span everything is absent from the union.
	return allocatedHighWater
}

func min64(a, b uint64) uint64 {
	if a < b {
		return a
	}
	return b
}

func max64(a, b uint64) uint64 {
	if a > b {
		return a
	}
	return b
}
