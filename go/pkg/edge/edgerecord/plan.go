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
	"math"
	"math/bits"
	"net/netip"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// PlanDigestVersion is the canonical plan page/root/header digest version.
const PlanDigestVersion = 1

// Hard encoded/string bounds so a "bounded" plan page cannot smuggle a huge
// policy id or an oversized page.
const (
	MaxPlanPageBytes = 128 * 1024
	MaxPolicyIDBytes = 128
	MaxRangeStrBytes = 64
)

// MaxPlanMtrOrdinals bounds the TOTAL admitted MTR ordinals across one plan, so that
// recomputing a commitment is bounded WORK. It is deliberately far below
// MaxMtrCompletionOrdinals (2^31): that constant bounds what the ordinal space can
// REPRESENT, this one bounds what a validator will COMPUTE. Without it a compact plan
// could declare a 2^31 window and cost billions of SHA-256 operations inside a
// validator -- denial of service reachable from a small message.
const MaxPlanMtrOrdinals = 1 << 20

var (
	ErrPlanDigestVersion = errors.New("edgerecord: unsupported plan digest version")
	ErrPlanHeaderDigest  = errors.New("edgerecord: plan header digest mismatch")
	ErrPlanPageDigest    = errors.New("edgerecord: plan page digest mismatch")
	ErrPlanChain         = errors.New("edgerecord: plan page chain broken")
	ErrPlanRoot          = errors.New("edgerecord: plan root mismatch")
	ErrPlanCheckSet      = errors.New("edgerecord: plan page check-set does not match header")
	ErrPlanBounds        = errors.New("edgerecord: plan exceeds hard bounds")
	ErrPlanPolicy        = errors.New("edgerecord: plan availability policy missing")
	ErrPlanRange         = errors.New("edgerecord: plan target range invalid")
	ErrPlanTotals        = errors.New("edgerecord: plan target-count total mismatch")
	// ErrPlanMtrCommitment fires when mtr_ordinal_range_commitment is not exactly 32
	// bytes. A zero-MTR plan carries 32 ZERO bytes, never empty bytes.
	ErrPlanMtrCommitment = errors.New("edgerecord: plan mtr ordinal-range commitment must be 32 bytes")
	// ErrPlanMtrWindow fires when a range's admitted MTR count exceeds its ceiling,
	// overflows the ordinal space, or the plan's windows are not well formed.
	ErrPlanMtrWindow = errors.New("edgerecord: plan mtr ordinal window invalid")
)

// Per-object domain tags: each plan-digest preimage leads with its own frozen
// string tag so a digest of one object type can never equal a digest of another
// (or of a recovery object). Without this, RangeDigest / PlanPageDigest / PlanRoot
// / PlanHeaderDigest all lead with the same PlanDigestVersion and are distinguished
// only by field structure. These tags are part of the frozen ABI (see #4710
// Appendix A) and mirrored by ServiceRadar.Edge.HashGrammar.
const (
	planRangeDomain  = "serviceradar.edge.plan.range.v1"
	planPageDomain   = "serviceradar.edge.plan.page.v1"
	planRootDomain   = "serviceradar.edge.plan.root.v1"
	planHeaderDomain = "serviceradar.edge.plan.header.v1"
)

// RangeDigest computes the canonical content digest of a target range over every
// field except range_sha256 itself.
func RangeDigest(r *edgev1.TargetRangeV1) []byte {
	d := newDigest()
	d.str(planRangeDomain)
	d.u64(PlanDigestVersion)
	d.bytes(r.GetRangeId())
	d.str(r.GetCidr())
	d.str(r.GetFirstAddress())
	d.str(r.GetLastAddress())
	d.u64(r.GetTargetCount())
	d.bytes(r.GetCheckSetSha256())
	d.bytes(r.GetAvailabilityPolicyId())
	d.u64(r.GetMtrAdmissionBudget())
	// The EXACT admitted MTR count is part of the range's content. An assignment binds
	// to `range_sha256`, so leaving the window width outside the digest would let two
	// ranges share an identity while admitting different numbers of ordinals.
	d.u64(r.GetMtrOrdinalCount())
	return d.finish()
}

// PlanPageDigest computes the canonical digest over every ScheduledPlanPageV1
// field EXCEPT page_sha256 (each range covered by its range identity + digest).
func PlanPageDigest(p *edgev1.ScheduledPlanPageV1) []byte {
	d := newDigest()
	d.str(planPageDomain)
	d.u64(uint64(p.GetDigestVersion()))
	d.bytes(p.GetExecutionPlanId())
	d.u64(uint64(p.GetPageIndex()))
	d.u64(uint64(p.GetPageCount()))
	d.bytes(p.GetPrevPageSha256())
	d.bytes(p.GetCheckSetSha256())
	d.u64(uint64(len(p.GetRanges())))
	for _, r := range p.GetRanges() {
		d.bytes(r.GetRangeId())
		d.bytes(r.GetRangeSha256())
		d.str(r.GetCidr())
		d.str(r.GetFirstAddress())
		d.str(r.GetLastAddress())
		d.u64(r.GetTargetCount())
		d.bytes(r.GetCheckSetSha256())
		d.bytes(r.GetAvailabilityPolicyId())
		d.u64(r.GetMtrAdmissionBudget())
		d.u64(r.GetMtrOrdinalCount())
	}
	return d.finish()
}

// PlanRoot composes the constant-size ordered root over a validated plan page
// chain: SHA-256(version || page_count || concat(page_sha256 in page order)).
func PlanRoot(pages []*edgev1.ScheduledPlanPageV1) []byte {
	d := newDigest()
	d.str(planRootDomain)
	d.u64(PlanDigestVersion)
	d.u64(uint64(len(pages)))
	for _, p := range pages {
		d.bytes(p.GetPageSha256())
	}
	return d.finish()
}

// PlanHeaderDigest computes the canonical digest over every ScheduledPlanHeaderV1
// field EXCEPT execution_plan_sha256 itself.
func PlanHeaderDigest(h *edgev1.ScheduledPlanHeaderV1) []byte {
	d := newDigest()
	d.str(planHeaderDomain)
	d.u64(uint64(h.GetDigestVersion()))
	d.bytes(h.GetExecutionPlanId())
	d.u64(uint64(h.GetPageCount()))
	d.u64(h.GetTotalTargetCount())
	d.bytes(h.GetPlanRootSha256())
	d.bytes(h.GetCheckSetSha256())
	d.bytes(h.GetAvailabilityPolicyId())
	// tag 9 (assignment_epoch) RETIRED: an immutable plan must not commit a value that
	// reassignment advances without changing the plan.
	d.bytes(h.GetNetworkScopeId())
	d.bytes(h.GetMtrOrdinalRangeCommitment())
	return d.finish()
}

// ValidatePlanHeader fail-closes a constant-size plan header: a valid plan id,
// the supported digest version, a bound check-set/availability-policy, a 32-byte
// plan root, and a self-consistent header digest (excluding the digest field).
func ValidatePlanHeader(h *edgev1.ScheduledPlanHeaderV1) error {
	if h == nil {
		return ErrNilRecord
	}
	// Appendix A requires unknown fields to be REJECTED in every grammar-covered position BEFORE
	// hashing: the field-framed digests walk declared fields only, so retained unknown bytes would be
	// invisible to the digest while still riding along on the wire. That is load-bearing for
	// immutable plan/recovery CONTENT ADDRESSING.
	if hasUnknownFields(h) {
		return ErrUnknownFields
	}
	if err := ValidateUUIDv7(h.GetExecutionPlanId()); err != nil {
		return ErrIdentity
	}
	if h.GetDigestVersion() != PlanDigestVersion {
		return ErrPlanDigestVersion
	}
	if len(h.GetPlanRootSha256()) != sha256Len {
		return ErrPlanRoot
	}
	if len(h.GetCheckSetSha256()) != sha256Len {
		return ErrPlanCheckSet
	}
	if ValidateCanonicalUUID(h.GetNetworkScopeId()) != nil {
		return ErrNetworkScope
	}
	if l := len(h.GetAvailabilityPolicyId()); l == 0 || l > MaxPolicyIDBytes {
		return ErrPlanPolicy
	}
	if h.GetPageCount() == 0 {
		return ErrPlanBounds
	}
	// The commitment is ALWAYS 32 bytes. A plan that admits no MTR targets carries
	// the empty-set multiset hash -- 32 ZERO bytes -- never empty bytes: the zero-MTR
	// completion proof compares its (zero) member accumulator against this field, and
	// empty bytes would be a second, unverifiable spelling of "no MTR" that the
	// comparison could not distinguish from an omitted commitment.
	if len(h.GetMtrOrdinalRangeCommitment()) != sha256Len {
		return ErrPlanMtrCommitment
	}
	if len(h.GetExecutionPlanSha256()) != sha256Len ||
		!bytes.Equal(PlanHeaderDigest(h), h.GetExecutionPlanSha256()) {
		return ErrPlanHeaderDigest
	}
	return nil
}

// ValidatePlanPages fail-closes the plan page chain against the header: bounds,
// per-page digest, plan/index/count relations, predecessor chaining, matching
// check-set identity, and the header's plan root.
func ValidatePlanPages(h *edgev1.ScheduledPlanHeaderV1, pages []*edgev1.ScheduledPlanPageV1) error {
	// Appendix A requires unknown fields to be REJECTED in every grammar-covered position BEFORE
	// hashing: the field-framed digests walk declared fields only, so retained unknown bytes would be
	// invisible to the digest while still riding along on the wire. That is load-bearing for
	// immutable plan/recovery CONTENT ADDRESSING.
	// The HEADER is consumed here too (page_count, digests, plan id), so its grammar-covered
	// position must be clean before any of its declared fields are trusted -- otherwise a tainted
	// header that ValidatePlanHeader rejects still drives this chain check.
	if err := ValidatePlanHeader(h); err != nil {
		return err
	}

	for _, p := range pages {
		if hasUnknownFields(p) {
			return ErrUnknownFields
		}
	}

	if int(h.GetPageCount()) != len(pages) {
		return ErrPlanChain
	}
	if len(pages) == 0 || len(pages) > MaxManifestPages {
		return ErrPlanBounds
	}
	var total uint64
	rangeIDs := map[string]bool{}
	for i, p := range pages {
		if p.GetDigestVersion() != PlanDigestVersion {
			return ErrPlanDigestVersion
		}
		if !bytes.Equal(p.GetExecutionPlanId(), h.GetExecutionPlanId()) {
			return ErrPlanChain
		}
		if int(p.GetPageIndex()) != i || int(p.GetPageCount()) != len(pages) {
			return ErrPlanChain
		}
		if len(p.GetRanges()) == 0 || len(p.GetRanges()) > MaxRangesPerPage {
			return ErrPlanBounds
		}
		if !bytes.Equal(p.GetCheckSetSha256(), h.GetCheckSetSha256()) {
			return ErrPlanCheckSet
		}
		// NOTE: this measures a RE-MARSHAL of the decoded page, which is NOT the
		// physical ceiling the ABI defines. Duplicate known fields collapse on the round
		// trip, so a received page far over the limit can pass here. The authoritative
		// bound is on RECEIVED bytes -- see ValidatePlanPagesFromRaw, which is what a
		// caller holding wire bytes must use. This check remains only as a coarse guard
		// for callers that legitimately hold decoded structs.
		pb, err := proto.MarshalOptions{Deterministic: true}.Marshal(p)
		if err != nil || len(pb) > MaxPlanPageBytes {
			return ErrPlanBounds
		}
		for _, r := range p.GetRanges() {
			if err := validateTargetRange(r, p.GetCheckSetSha256(), h.GetAvailabilityPolicyId()); err != nil {
				return err
			}
			var carry uint64
			total, carry = bits.Add64(total, r.GetTargetCount(), 0)
			if carry != 0 {
				return fmt.Errorf("%w: target-count overflow", ErrPlanTotals)
			}
			if id := string(r.GetRangeId()); rangeIDs[id] {
				return fmt.Errorf("%w: duplicate range id", ErrPlanRange)
			} else {
				rangeIDs[id] = true
			}
		}
		if !bytes.Equal(PlanPageDigest(p), p.GetPageSha256()) {
			return ErrPlanPageDigest
		}
		if i == 0 {
			if len(p.GetPrevPageSha256()) != 0 {
				return ErrPlanChain
			}
		} else if !bytes.Equal(p.GetPrevPageSha256(), pages[i-1].GetPageSha256()) {
			return ErrPlanChain
		}
	}
	if total != h.GetTotalTargetCount() {
		return ErrPlanTotals
	}
	if !bytes.Equal(PlanRoot(pages), h.GetPlanRootSha256()) {
		return ErrPlanRoot
	}
	// The header's plan-wide MTR commitment is RECOMPUTED from the committed pages,
	// never trusted: it is the additive sum of every range's window commitment. A
	// carried 32-byte value that nothing derives is verifiable only for length, which
	// is the defect this change spent three rounds removing elsewhere.
	wantCommitment, err := PlanMtrOrdinalRangeCommitment(pages)
	if err != nil {
		return err
	}
	if !bytes.Equal(wantCommitment, h.GetMtrOrdinalRangeCommitment()) {
		return ErrPlanMtrCommitment
	}
	return nil
}

// validateTargetRange fail-closes one range: canonical-UUID range id, matching
// content digest, CIDR-xor-(first,last) exclusivity, a CANONICAL and PARSEABLE
// address span, a target count in [1, span size] (a range can never claim more
// hosts than its address space holds), and a per-range check set that reconciles
// with its page/header check set. range_id is a canonical UUID (scheduler v4), not
// strict v7 -- identity time is not normative for a range.
func validateTargetRange(r *edgev1.TargetRangeV1, pageCheckSet, headerPolicy []byte) error {
	if err := ValidateCanonicalUUID(r.GetRangeId()); err != nil {
		return fmt.Errorf("%w: range id", ErrPlanRange)
	}
	if len(r.GetRangeSha256()) != sha256Len || !bytes.Equal(RangeDigest(r), r.GetRangeSha256()) {
		return fmt.Errorf("%w: range digest", ErrPlanRange)
	}
	if len(r.GetCidr()) > MaxRangeStrBytes || len(r.GetFirstAddress()) > MaxRangeStrBytes || len(r.GetLastAddress()) > MaxRangeStrBytes {
		return fmt.Errorf("%w: address string too long", ErrPlanRange)
	}
	hasCidr := r.GetCidr() != ""
	hasSpan := r.GetFirstAddress() != "" || r.GetLastAddress() != ""
	if hasCidr == hasSpan {
		return fmt.Errorf("%w: cidr xor first/last", ErrPlanRange) // exactly one form
	}
	if r.GetTargetCount() == 0 {
		return fmt.Errorf("%w: zero target count", ErrPlanRange)
	}
	spanSize, err := rangeSpanSize(r)
	if err != nil {
		return err
	}
	// The range expands to EXACTLY its address span -- target_count must equal the
	// span, so the covered work set is deterministic (no ambiguity about which host
	// a "/24 with target_count 1" selected).
	if r.GetTargetCount() != spanSize {
		return fmt.Errorf("%w: target count %d != address span %d", ErrPlanRange, r.GetTargetCount(), spanSize)
	}
	if len(r.GetCheckSetSha256()) != sha256Len {
		return fmt.Errorf("%w: range check set", ErrPlanRange)
	}
	// Reconcile: a range's check set MUST equal its page/header check set, so a
	// rehashed range cannot smuggle a different check set below the header.
	if len(pageCheckSet) != 0 && !bytes.Equal(r.GetCheckSetSha256(), pageCheckSet) {
		return ErrPlanCheckSet
	}
	// Reconcile the range availability policy with the header's, and bound it.
	if len(r.GetAvailabilityPolicyId()) > MaxPolicyIDBytes || !bytes.Equal(r.GetAvailabilityPolicyId(), headerPolicy) {
		return fmt.Errorf("%w: range availability policy", ErrPlanRange)
	}
	return nil
}

// rangeSpanSize parses the range's canonical CIDR or first/last span and returns
// the number of addresses it spans (saturating to MaxUint64 for spans wider than
// 64 bits). It rejects a non-canonical CIDR (host bits set), an unparseable
// address, a family mismatch, or first > last.
func rangeSpanSize(r *edgev1.TargetRangeV1) (uint64, error) {
	if r.GetCidr() != "" {
		p, err := netip.ParsePrefix(r.GetCidr())
		if err != nil {
			return 0, fmt.Errorf("%w: unparseable cidr", ErrPlanRange)
		}
		if p.Masked() != p {
			return 0, fmt.Errorf("%w: non-canonical cidr (host bits set)", ErrPlanRange)
		}
		// Reject non-canonical textual spellings (e.g. 2001:0DB8::/32) so one
		// network cannot have multiple content digests.
		if p.String() != r.GetCidr() {
			return 0, fmt.Errorf("%w: non-canonical cidr spelling", ErrPlanRange)
		}
		hostBits := p.Addr().BitLen() - p.Bits()
		// A span whose exact host count cannot be represented in uint64 (an IPv6
		// prefix wider than /64) MUST be split into narrower ranges; saturation is
		// not an exact count.
		if hostBits >= 64 {
			return 0, fmt.Errorf("%w: span exceeds uint64 (split to /65 or narrower)", ErrPlanRange)
		}
		return uint64(1) << uint(hostBits), nil
	}
	first, err := netip.ParseAddr(r.GetFirstAddress())
	if err != nil {
		return 0, fmt.Errorf("%w: unparseable first address", ErrPlanRange)
	}
	last, err := netip.ParseAddr(r.GetLastAddress())
	if err != nil {
		return 0, fmt.Errorf("%w: unparseable last address", ErrPlanRange)
	}
	if first.String() != r.GetFirstAddress() || last.String() != r.GetLastAddress() {
		return 0, fmt.Errorf("%w: non-canonical address spelling", ErrPlanRange)
	}
	if first.BitLen() != last.BitLen() || first.Is4() != last.Is4() {
		return 0, fmt.Errorf("%w: span family mismatch", ErrPlanRange)
	}
	if last.Less(first) {
		return 0, fmt.Errorf("%w: first > last", ErrPlanRange)
	}
	span, ok := addrSpan(first, last)
	if !ok {
		return 0, fmt.Errorf("%w: span exceeds uint64 (split into narrower ranges)", ErrPlanRange)
	}
	return span, nil
}

// addrSpan returns (last-first+1, true), or (0, false) when the exact span cannot
// be represented in uint64.
func addrSpan(first, last netip.Addr) (uint64, bool) {
	fb := first.As16()
	lb := last.As16()
	var borrow uint64
	loF := binaryBE64(fb[8:])
	loL := binaryBE64(lb[8:])
	lo, borrow := bits.Sub64(loL, loF, 0)
	hiF := binaryBE64(fb[:8])
	hiL := binaryBE64(lb[:8])
	hi, _ := bits.Sub64(hiL, hiF, borrow)
	if hi != 0 || lo == math.MaxUint64 { // difference >= 2^64, or +1 overflows
		return 0, false
	}
	return lo + 1, true
}

func binaryBE64(b []byte) uint64 {
	var v uint64
	for _, x := range b {
		v = v<<8 | uint64(x)
	}
	return v
}

// PlanMtrWindows walks the committed plan in page order and assigns each range its
// CONTIGUOUS plan-global ordinal window, returning the offset keyed by range id.
//
// Order is the plan's own: pages by index, ranges within a page as committed. The
// window is therefore a fact of the plan, recomputable by any consumer, rather than
// something an assignment asserts about itself.
func PlanMtrWindows(pages []*edgev1.ScheduledPlanPageV1) (map[string]uint64, uint64, error) {
	windows := make(map[string]uint64)
	var next uint64
	for _, p := range pages {
		for _, r := range p.GetRanges() {
			// REQUIRED PRESENCE. An absent count is NOT zero: it is a plan that never
			// stated its window, and accepting it would hash identically to an explicit
			// zero -- the exact collapse that makes "required presence" decorative.
			if r.MtrOrdinalCount == nil {
				return nil, 0, ErrPlanMtrWindow
			}
			// A range's admitted count may never exceed its ceiling. The count is
			// CARRIED, not derived from the budget -- but it is still bounded by it.
			if r.GetMtrOrdinalCount() > r.GetMtrAdmissionBudget() {
				return nil, 0, ErrPlanMtrWindow
			}
			if r.GetMtrOrdinalCount() > MaxMtrCompletionOrdinals ||
				next > MaxMtrCompletionOrdinals-r.GetMtrOrdinalCount() {
				return nil, 0, ErrPlanMtrWindow
			}
			if _, dup := windows[string(r.GetRangeId())]; dup {
				return nil, 0, ErrPlanMtrWindow
			}
			windows[string(r.GetRangeId())] = next
			next += r.GetMtrOrdinalCount()
			// VALIDATION-COST CEILING. Recomputing a commitment is O(ordinals), so a
			// compact plan declaring a 2^31 window would cost billions of SHA-256 ops
			// inside a validator -- a denial of service reachable from a small message.
			// The ordinal SPACE bound (MaxMtrCompletionOrdinals) bounds correctness;
			// this bounds work.
			if next > MaxPlanMtrOrdinals {
				return nil, 0, ErrPlanMtrWindow
			}
		}
	}
	return windows, next, nil
}

// MtrWindowCommitment folds the additive multiset commitment for ONE range's window:
// the members `(offset + i, rangeSha256)` for i in 1..count. It is the value an
// assignment's expectation MUST carry, recomputed rather than trusted.
func MtrWindowCommitment(offset, count uint64, rangeSha256 []byte) ([]byte, error) {
	// The WORK ceiling applies here too, not only in PlanMtrWindows: this function is
	// exported and folds one hash per ordinal, so bounding only the caller would leave
	// the expensive loop reachable directly.
	//
	// The bound is on where the window ENDS, not merely on its WIDTH. Capping width
	// alone admits (offset = MaxPlanMtrOrdinals, count = 1): a one-ordinal window that
	// begins past the plan ceiling and therefore names an ordinal no plan can contain.
	if len(rangeSha256) != sha256Len || count > MaxPlanMtrOrdinals ||
		offset > MaxPlanMtrOrdinals-count {
		return nil, ErrPlanMtrWindow
	}
	var acc [32]byte
	for i := uint64(1); i <= count; i++ {
		add256(&acc, mtrMemberHash(offset+i, rangeSha256))
	}
	return acc[:], nil
}

// PlanMtrOrdinalRangeCommitment recomputes the PLAN-WIDE commitment as the additive
// sum of every range's window commitment. Because the multiset hash is additive, the
// plan-wide value is exactly the sum of the per-assignment values -- which is what
// makes a split plan verifiable without renumbering any attempt's local ordinals.
func PlanMtrOrdinalRangeCommitment(pages []*edgev1.ScheduledPlanPageV1) ([]byte, error) {
	// PlanMtrWindows enforces every bound BEFORE a single hash is computed, so an
	// over-budget plan costs a walk rather than a fold.
	windows, _, err := PlanMtrWindows(pages)
	if err != nil {
		return nil, err
	}
	var acc [32]byte
	for _, p := range pages {
		for _, r := range p.GetRanges() {
			c, err := MtrWindowCommitment(windows[string(r.GetRangeId())], r.GetMtrOrdinalCount(), r.GetRangeSha256())
			if err != nil {
				return nil, err
			}
			var w [32]byte
			copy(w[:], c)
			add256(&acc, w)
		}
	}
	return acc[:], nil
}

// ValidatePlanPagesFromRaw is the RAW plan boundary: it bounds each page against
// MaxPlanPageBytes on the EXACT RECEIVED BYTES before decoding, then validates the
// decoded chain.
//
// This exists because ValidatePlanPages measures a RE-MARSHAL, and the two are not the
// same number: a page padded with duplicate known fields to 131,074 received bytes
// collapses to a few hundred on the round trip, so the struct path accepted what the
// physical ceiling forbids -- and what the Elixir peer, which bounds received bytes,
// rejected. The ceiling exists to bound what a receiver must hold and forward, which
// is the received size.
func ValidatePlanPagesFromRaw(h *edgev1.ScheduledPlanHeaderV1, rawPages [][]byte) error {
	if len(rawPages) == 0 || len(rawPages) > MaxManifestPages {
		return ErrPlanBounds
	}
	pages := make([]*edgev1.ScheduledPlanPageV1, 0, len(rawPages))
	for _, raw := range rawPages {
		if len(raw) > MaxPlanPageBytes {
			return ErrPlanBounds
		}
		var p edgev1.ScheduledPlanPageV1
		if err := proto.Unmarshal(raw, &p); err != nil {
			return ErrPlanBounds
		}
		pages = append(pages, &p)
	}
	return ValidatePlanPages(h, pages)
}
