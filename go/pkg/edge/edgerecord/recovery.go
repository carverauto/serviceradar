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
	"sort"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// RecoveryDigestVersion is the canonical page/root digest algorithm version.
const RecoveryDigestVersion = 1

// Hard bounds so a manifest can never enumerate an outage-sized tail.
const (
	MaxManifestPages         = 1024
	MaxRangesPerPage         = 256
	MaxAffectedScopesPerPage = 256
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
	ErrManifestAffected      = errors.New("edgerecord: manifest affected scope invalid/uncovered")
	ErrManifestCoarsen       = errors.New("edgerecord: manifest coarsening inconsistent")
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
	d.present(p.GetCoarsened())
	d.u64(uint64(len(p.GetLostRanges())))
	for _, r := range p.GetLostRanges() {
		d.u64(r.GetFromSequence())
		d.u64(r.GetThroughSequence())
	}
	d.u64(uint64(len(p.GetAffected())))
	for _, a := range p.GetAffected() {
		// Field-by-field per #4710 Appendix A -- NOT proto.Marshal, so the digest
		// is byte-identical across protobuf-go and protobuf-elixir even if
		// EdgeAffectedScopeV1 later gains a oneof or a field Go reorders.
		d.u64(a.GetFromSequence())
		d.u64(a.GetThroughSequence())
		d.bytes(a.GetContractBundleSha256())
		d.bytes(a.GetProducerAssignmentId())
		d.bytes(a.GetRunId())
		d.u64(uint64(a.GetRunShard()))
		d.u64(a.GetAuthorityEpoch())
		d.bytes(a.GetScopeSha256())
		d.bytes(a.GetRangeSha256())
		d.present(a.GetCoarsened())
	}
	return d.finish()
}

// ManifestRoot composes the ordered root over a validated page chain:
// SHA-256(version || page_count || concat(page_sha256 in page order)).
func ManifestRoot(pages []*edgev1.EdgeLossManifestPageV1) []byte {
	d := newDigest()
	d.str(manifestRootDomain)
	d.u64(RecoveryDigestVersion)
	d.u64(uint64(len(pages)))
	for _, p := range pages {
		d.bytes(p.GetPageSha256())
	}
	return d.finish()
}

// ValidateManifestChain fail-closes a full manifest: bounds and total byte
// budget, per-page digest, index/count/terminal relations, predecessor chaining,
// one UUIDv7 recovery id shared by every page, GLOBALLY ordered non-overlapping
// lost ranges across page boundaries, validated affected scopes (each interval
// within a lost range, UUID/digest lengths, coverage), and (when a nonzero
// expectedRoot is given) the ordered root.
func ValidateManifestChain(pages []*edgev1.EdgeLossManifestPageV1, expectedRoot []byte) error {
	if len(pages) == 0 {
		return ErrManifestEmpty
	}
	// Appendix A requires unknown fields to be REJECTED in every grammar-covered position BEFORE
	// hashing: the field-framed digests walk declared fields only, so retained unknown bytes would be
	// invisible to the digest while still riding along on the wire. That is load-bearing for
	// immutable plan/recovery CONTENT ADDRESSING.
	for _, p := range pages {
		if hasUnknownFields(p) {
			return ErrUnknownFields
		}
	}
	if len(pages) > MaxManifestPages {
		return ErrManifestBounds
	}
	if err := validateUUIDv7Field(pages[0].GetRecoveryId()); err != nil {
		return ErrManifestRecoveryID
	}
	recoveryID := pages[0].GetRecoveryId()
	count := len(pages)
	totalBytes := 0
	var lost []*edgev1.EdgeLostRangeV1
	anyCoarsened := false
	var prevThrough uint64
	haveRange := false

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
		if len(p.GetLostRanges()) > MaxRangesPerPage || len(p.GetAffected()) > MaxAffectedScopesPerPage {
			return ErrManifestBounds
		}
		pb, _ := proto.MarshalOptions{Deterministic: true}.Marshal(p)
		totalBytes += len(pb)
		if totalBytes > MaxManifestBytes {
			return ErrManifestBounds
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
		// Globally ordered, non-overlapping, non-adjacent ranges across pages.
		for _, r := range p.GetLostRanges() {
			if r.GetFromSequence() == 0 { // lane sequences start at 1
				return ErrManifestRange
			}
			if r.GetThroughSequence() < r.GetFromSequence() {
				return ErrManifestRange
			}
			// Reject overlap AND adjacency (overflow-safe) so one contiguous loss set
			// cannot be split into multiple ranges yielding different roots.
			if haveRange && (prevThrough == ^uint64(0) || r.GetFromSequence() <= prevThrough+1) {
				return ErrManifestRange
			}
			prevThrough = r.GetThroughSequence()
			haveRange = true
			lost = append(lost, r)
		}
		if p.GetCoarsened() {
			anyCoarsened = true
		}
	}
	if !haveRange {
		return ErrManifestRange // a manifest must cover at least one lost range
	}
	if err := validateAffectedScopes(pages, lost, anyCoarsened); err != nil {
		return err
	}
	if len(expectedRoot) > 0 && !bytes.Equal(ManifestRoot(pages), expectedRoot) {
		return ErrManifestRoot
	}
	return nil
}

// validateAffectedScopes checks every affected entry and requires conservative
// coverage. A manifest ALWAYS carries at least one affected scope and the union
// of affected intervals ALWAYS covers every lost range -- even coarsened, the
// consumer must be able to partialize/fence/reschedule the lost work, so
// coarsening trades identity DETAIL, never coverage. Coarsening is reconciled:
// when the manifest is not coarsened no entry may be coarsened; when it is, at
// least one entry MUST be coarsened.
func validateAffectedScopes(pages []*edgev1.EdgeLossManifestPageV1, lost []*edgev1.EdgeLostRangeV1, coarsened bool) error {
	var affected []*edgev1.EdgeAffectedScopeV1
	for _, p := range pages {
		affected = append(affected, p.GetAffected()...)
	}
	if len(affected) == 0 {
		return ErrManifestAffected // never discard all identity for lost work
	}
	anyEntryCoarsened := false
	for _, a := range affected {
		if a.GetThroughSequence() < a.GetFromSequence() || a.GetFromSequence() == 0 {
			return ErrManifestAffected
		}
		if !intervalWithinAny(a.GetFromSequence(), a.GetThroughSequence(), lost) {
			return ErrManifestAffected
		}
		if len(a.GetContractBundleSha256()) != sha256Len ||
			len(a.GetScopeSha256()) != sha256Len || len(a.GetRangeSha256()) != sha256Len {
			return ErrManifestAffected
		}
		// assignment/run are canonical UUIDs (scheduler/runtime allocate v4); only
		// event/trace identity-time ids are strict v7.
		if ValidateCanonicalUUID(a.GetProducerAssignmentId()) != nil || ValidateCanonicalUUID(a.GetRunId()) != nil {
			return ErrManifestAffected
		}
		if a.GetCoarsened() {
			anyEntryCoarsened = true
		}
	}
	if coarsened != anyEntryCoarsened {
		return ErrManifestCoarsen // page/tombstone coarsening MUST match entry flags
	}
	// Every lost range must be covered by the union of affected intervals, coarsened
	// or not.
	for _, r := range lost {
		if !rangeCoveredBy(r.GetFromSequence(), r.GetThroughSequence(), affected) {
			return ErrManifestAffected
		}
	}
	return nil
}

func intervalWithinAny(from, through uint64, lost []*edgev1.EdgeLostRangeV1) bool {
	for _, r := range lost {
		if from >= r.GetFromSequence() && through <= r.GetThroughSequence() {
			return true
		}
	}
	return false
}

// rangeCoveredBy reports whether [from,through] is fully covered by the union of
// affected intervals (which may be given in any order).
func rangeCoveredBy(from, through uint64, affected []*edgev1.EdgeAffectedScopeV1) bool {
	ivals := make([][2]uint64, 0, len(affected))
	for _, a := range affected {
		ivals = append(ivals, [2]uint64{a.GetFromSequence(), a.GetThroughSequence()})
	}
	sort.Slice(ivals, func(i, j int) bool { return ivals[i][0] < ivals[j][0] })
	cursor := from
	for _, iv := range ivals {
		if iv[0] > cursor {
			return false // gap
		}
		if iv[1] >= cursor {
			cursor = iv[1] + 1
		}
		if cursor > through {
			return true
		}
	}
	return cursor > through
}

// ValidateTombstone fail-closes a spool-loss tombstone against its manifest
// pages: matching recovery id, digest version, page count, the tombstone loss
// interval equal to the manifest's global min/max lost sequence, UUIDv7 prior/new
// spool ids, coarsening consistency, and the ordered manifest root.
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
	// The tombstone loss interval must equal the manifest's global min/max.
	minSeq, maxSeq, coarsened := manifestSpan(pages)
	if t.GetLostFromSequence() != minSeq || t.GetLostThroughSequence() != maxSeq {
		return ErrTombstoneMismatch
	}
	if t.GetCoarsened() != coarsened {
		return ErrManifestCoarsen
	}
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
	// the body's spool/loss/root/scope. Reusing a signature for a different spool
	// pair, loss interval, or manifest root therefore fails.
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
// operation (recovery id, prior/new spool, loss interval, manifest root, page
// count, coarsening). The signed recovery source scope_sha256 MUST equal it, so
// the grant fixes the exact spool pair / loss set / root it authorizes.
func TombstoneScopeDigest(t *edgev1.SpoolLossTombstoneV1) []byte {
	d := newDigest()
	d.u64(RecoveryScopeDigestVersion)
	d.u64(0) // body kind: tombstone
	d.bytes(t.GetRecoveryId())
	d.bytes(t.GetPriorSpoolId())
	d.bytes(t.GetNewSpoolId())
	d.u64(t.GetLostFromSequence())
	d.u64(t.GetLostThroughSequence())
	d.bytes(t.GetManifestRootSha256())
	d.u64(uint64(t.GetManifestPageCount()))
	d.present(t.GetCoarsened())
	return d.finish()
}

// ManifestPageScopeDigest is the recovery-operation scope digest for a manifest-page
// control body: RecoveryScopeDigestVersion || u64(1) [body kind: manifest page] ||
// recovery_id || page_sha256. The u64 body-kind discriminant keeps it distinct from
// the tombstone (0) and resolved (2) scope digests.
func ManifestPageScopeDigest(p *edgev1.EdgeLossManifestPageV1) []byte {
	d := newDigest()
	d.u64(RecoveryScopeDigestVersion)
	d.u64(1)
	d.bytes(p.GetRecoveryId())
	d.bytes(p.GetPageSha256())
	return d.finish()
}

// ResolvedScopeDigest is the recovery-operation scope digest for a resolved control
// body: RecoveryScopeDigestVersion || u64(2) [body kind: resolved] || recovery_id ||
// manifest_root_sha256 || applied_through_sequence.
func ResolvedScopeDigest(rv *edgev1.RecoveryResolvedV1) []byte {
	d := newDigest()
	d.u64(RecoveryScopeDigestVersion)
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
		if t.GetLostFromSequence() == 0 || t.GetLostThroughSequence() < t.GetLostFromSequence() {
			return nil, nil, fmt.Errorf("%w: tombstone loss interval", ErrTombstoneMismatch)
		}
		if t.GetManifestPageCount() == 0 || t.GetDetectedAtUnixNano() <= 0 {
			return nil, nil, fmt.Errorf("%w: tombstone page-count/time", ErrTombstoneMismatch)
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
// length, per-page bounds, ordered non-adjacent lost ranges (from >= 1), a
// nonempty affected scope covering them, and a matching self-hash.
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
	if len(p.GetLostRanges()) > MaxRangesPerPage || len(p.GetAffected()) > MaxAffectedScopesPerPage {
		return ErrManifestBounds
	}
	var lost []*edgev1.EdgeLostRangeV1
	var prevThrough uint64
	have := false
	for _, rg := range p.GetLostRanges() {
		if rg.GetFromSequence() == 0 || rg.GetThroughSequence() < rg.GetFromSequence() {
			return ErrManifestRange
		}
		if have && rg.GetFromSequence() <= prevThrough+1 { // reject overlap AND adjacency
			return ErrManifestRange
		}
		prevThrough = rg.GetThroughSequence()
		have = true
		lost = append(lost, rg)
	}
	if !have {
		return ErrManifestRange
	}
	if err := validateAffectedScopes([]*edgev1.EdgeLossManifestPageV1{p}, lost, p.GetCoarsened()); err != nil {
		return err
	}
	if !bytes.Equal(ManifestPageDigest(p), p.GetPageSha256()) {
		return ErrManifestPageDigest
	}
	return nil
}

func manifestSpan(pages []*edgev1.EdgeLossManifestPageV1) (minSeq, maxSeq uint64, coarsened bool) {
	first := true
	for _, p := range pages {
		if p.GetCoarsened() {
			coarsened = true
		}
		for _, r := range p.GetLostRanges() {
			if first || r.GetFromSequence() < minSeq {
				minSeq = r.GetFromSequence()
			}
			if first || r.GetThroughSequence() > maxSeq {
				maxSeq = r.GetThroughSequence()
			}
			first = false
		}
	}
	return minSeq, maxSeq, coarsened
}
