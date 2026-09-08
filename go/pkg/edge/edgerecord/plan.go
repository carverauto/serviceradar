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
	"strings"

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
	return rangeDigestWithVersion(r, PlanDigestVersion)
}

// rangeDigestWithVersion is RangeDigest with the grammar version supplied rather than
// baked in. The exported wrapper is the ONLY production caller and always passes the frozen
// constant, so no shipped behaviour is parameterised.
//
// It exists so the shared version corpus can author the artifact a peer running a DIFFERENT
// grammar version would emit -- and can do so WITHOUT a second copy of this transcript. A
// re-implemented grammar is the failure mode this avoids: it agrees on the day it is written
// and drifts silently afterwards, which is exactly what a version freeze must not rely on.
func rangeDigestWithVersion(r *edgev1.TargetRangeV1, version uint64) []byte {
	d := newDigest()
	d.str(planRangeDomain)
	d.u64(version)
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
	return planRootWithVersion(pages, PlanDigestVersion)
}

// planRootWithVersion is PlanRoot with the grammar version supplied rather than
// baked in. The exported wrapper is the ONLY production caller and always passes the frozen
// constant, so no shipped behaviour is parameterised.
//
// It exists so the shared version corpus can author the artifact a peer running a DIFFERENT
// grammar version would emit -- and can do so WITHOUT a second copy of this transcript. A
// re-implemented grammar is the failure mode this avoids: it agrees on the day it is written
// and drifts silently afterwards, which is exactly what a version freeze must not rely on.
func planRootWithVersion(pages []*edgev1.ScheduledPlanPageV1, version uint64) []byte {
	d := newDigest()
	d.str(planRootDomain)
	d.u64(version)
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

	// STRUCTURAL COUNTS BEFORE ANY RECURSIVE WALK. Both checks below are O(1) per page on an
	// already-decoded slice, and both bound the traversal that follows: hasUnknownFields
	// RECURSES into every range of every page, so counting afterwards did the work the ceiling
	// exists to prevent. Every count precedes every walk, rather than interleaving per page, so
	// the rule is statable in one sentence instead of depending on iteration order.
	//
	// PRECEDENCE, frozen: an oversize page list whose pages ALSO carry unknown fields is a
	// BOUNDS refusal. Both are refusals, so only a precedence assertion can hold this.
	if len(pages) == 0 || len(pages) > MaxManifestPages {
		return ErrPlanBounds
	}
	for _, p := range pages {
		if len(p.GetRanges()) == 0 || len(p.GetRanges()) > MaxRangesPerPage {
			return ErrPlanBounds
		}
	}

	for _, p := range pages {
		if hasUnknownFields(p) {
			return ErrUnknownFields
		}
	}

	if int(h.GetPageCount()) != len(pages) {
		return ErrPlanChain
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
		// The range count is bounded ABOVE, before the recursive walk. Re-checking it here
		// would be dead code that reads like the enforcement point.
		if !bytes.Equal(p.GetCheckSetSha256(), h.GetCheckSetSha256()) {
			return ErrPlanCheckSet
		}
		// NOTE: this measures a RE-MARSHAL of the decoded page, which is NOT the
		// physical ceiling the ABI defines. Duplicate known fields collapse on the round
		// trip, so a received page far over the limit can pass here. The authoritative
		// bound is on RECEIVED bytes -- see ValidatePlanFromRaw, which is what a
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
	checked, err := checkRangeStrings(r)
	if err != nil {
		return err
	}
	hasCidr := r.GetCidr() != ""
	hasSpan := r.GetFirstAddress() != "" || r.GetLastAddress() != ""
	if hasCidr == hasSpan {
		return fmt.Errorf("%w: cidr xor first/last", ErrPlanRange) // exactly one form
	}
	if r.GetTargetCount() == 0 {
		return fmt.Errorf("%w: zero target count", ErrPlanRange)
	}
	spanSize, err := rangeSpanSize(checked)
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
	// EQUALITY ONLY -- the length bound is CENTRALIZED at the header. `ValidatePlanHeader` bounds
	// the policy before any range is reached, and a range must equal that already-bounded value.
	// A second length arm here would be unreachable on its own AND would mask a missing header
	// bound, so the rule lives in exactly one place.
	if !bytes.Equal(r.GetAvailabilityPolicyId(), headerPolicy) {
		return fmt.Errorf("%w: range availability policy", ErrPlanRange)
	}
	return nil
}

// rangeSpanSize parses the range's canonical CIDR or first/last span and returns
// the number of addresses it spans (saturating to MaxUint64 for spans wider than
// 64 bits). It rejects a non-canonical CIDR (host bits set), an unparseable
// address, a family mismatch, or first > last.
// checkedRangeStrings holds a range's address strings AFTER the field preflight. It exists so
// the ORDER is hard to get wrong rather than remembered: rangeSpanSize takes this type and not
// a TargetRangeV1, so reaching a parser means having gone through the preflight -- the same
// reasoning that made the plan page-only path unexported.
//
// IT IS NOT UNFORGEABLE. This is an ordinary same-package struct, so anything in this package
// can construct one and bypass the preflight entirely. What catches that is the whole-validator
// zoned row in the corpus, not the type.
type checkedRangeStrings struct{ cidr, first, last string }

// checkRangeStrings is THE field preflight for a range's address strings: length bounds, then
// the IPv6-zone prohibition. It parses nothing.
//
// LENGTH FIRST, because an over-length value should not be scanned at all. Then the ZONE. A
// zone names an interface on the machine that WROTE the string; it has no meaning at the
// receiver, which cannot resolve it to the same thing the author meant, if at all.
//
// THE ZONE IS REFUSED, NEVER STRIPPED. These strings feed the range, page, plan-root, header
// and assignment digest chain, so rewriting one changes every digest above it and forks a
// plan's identity from the bytes its author signed. A plan carrying zoned addresses is
// regenerated by its author, not repaired by a consumer.
//
// WITHOUT THE ZONE RULE THE RUNTIMES DISAGREE, and neither reports a zone problem: netip
// accepts a scoped address and round-trips it canonically, so THIS runtime admits it -- at the
// ceiling, since a zone is arbitrary-length text. The Elixir parser accepts the text, DISCARDS
// the zone, and refuses the re-encoded form as a non-canonical SPELLING.
func checkRangeStrings(r *edgev1.TargetRangeV1) (checkedRangeStrings, error) {
	c := checkedRangeStrings{cidr: r.GetCidr(), first: r.GetFirstAddress(), last: r.GetLastAddress()}

	for _, v := range []string{c.cidr, c.first, c.last} {
		if len(v) > MaxRangeStrBytes {
			return checkedRangeStrings{}, fmt.Errorf("%w: address string too long", ErrPlanRange)
		}
	}
	for _, v := range []string{c.cidr, c.first, c.last} {
		if strings.ContainsRune(v, '%') {
			return checkedRangeStrings{}, fmt.Errorf("%w: address carries an IPv6 zone", ErrPlanRange)
		}
	}
	return c, nil
}

func rangeSpanSize(s checkedRangeStrings) (uint64, error) {
	if s.cidr != "" {
		p, err := netip.ParsePrefix(s.cidr)
		if err != nil {
			return 0, fmt.Errorf("%w: unparseable cidr", ErrPlanRange)
		}
		if p.Masked() != p {
			return 0, fmt.Errorf("%w: non-canonical cidr (host bits set)", ErrPlanRange)
		}
		// Reject non-canonical textual spellings (e.g. 2001:0DB8::/32) so one
		// network cannot have multiple content digests.
		if p.String() != s.cidr {
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
	first, err := netip.ParseAddr(s.first)
	if err != nil {
		return 0, fmt.Errorf("%w: unparseable first address", ErrPlanRange)
	}
	last, err := netip.ParseAddr(s.last)
	if err != nil {
		return 0, fmt.Errorf("%w: unparseable last address", ErrPlanRange)
	}
	if first.String() != s.first || last.String() != s.last {
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

// MaxPlanHeaderBytes bounds ONE encoded ScheduledPlanHeaderV1 on RECEIVED BYTES. It lives here,
// beside the page bound it partners, because it governs the general plan boundary below rather
// than any single consumer of it.
const MaxPlanHeaderBytes = 512 * 1024

// ErrPlanHeaderTooLarge is a PERMANENT rejection for an oversize raw plan header.
var ErrPlanHeaderTooLarge = errors.New("edgerecord: encoded plan header exceeds 512 KiB bound")

// ErrPlanPageTooLarge is a PERMANENT rejection for an oversize raw plan page. It WRAPS
// ErrPlanBounds so existing callers matching the general bound still match, while being
// distinguishable -- which is what makes the preflight ORDER observable: a malformed early page
// plus an oversize later one yields THIS error only if every size was checked before any decode.
var ErrPlanPageTooLarge = fmt.Errorf("edgerecord: encoded plan page exceeds 128 KiB bound: %w", ErrPlanBounds)

// ValidatePlanFromRaw is THE raw plan boundary, and the only exported one: it bounds the header
// AND every page on EXACT RECEIVED BYTES, then validates and returns the decoded plan.
//
// The page-only path is deliberately unexported. While it was public it was a header-ceiling
// BYPASS -- it takes an already-decoded header, so a duplicate-field header over the bound
// collapses on decode and passes. A bound that one caller remembers to apply is not a bound.
//
// PREFLIGHT ORDER MATTERS: every raw size is checked BEFORE anything is decoded, so oversize
// input is rejected without ever being parsed. Decoding first and bounding afterwards would do
// the work the bound exists to prevent.
//
// It returns the DECODED header AND pages so a caller uses exactly what was validated. Returning
// the header alone left callers re-decoding the raw slices, which is a check/use gap: the bytes
// validated and the bytes used were two separate decodes of storage the caller does not own.
func ValidatePlanFromRaw(
	rawHeader []byte,
	rawPages [][]byte,
) (*edgev1.ScheduledPlanHeaderV1, []*edgev1.ScheduledPlanPageV1, error) {
	if len(rawHeader) > MaxPlanHeaderBytes {
		return nil, nil, ErrPlanHeaderTooLarge
	}
	// STRUCTURAL and PHYSICAL bounds first, across the WHOLE input.
	if len(rawPages) == 0 || len(rawPages) > MaxManifestPages {
		return nil, nil, ErrPlanBounds
	}
	for _, raw := range rawPages {
		if len(raw) > MaxPlanPageBytes {
			return nil, nil, ErrPlanPageTooLarge
		}
	}
	var h edgev1.ScheduledPlanHeaderV1
	if err := proto.Unmarshal(rawHeader, &h); err != nil {
		return nil, nil, ErrPlanBounds
	}
	// THE HEADER IS VALIDATED IMMEDIATELY. Decoding every page first meant an unsupported header
	// version reported a page's malformedness instead: the cheaper, more authoritative failure was
	// masked by whichever page happened to break first. ValidatePlanPages re-checks the header
	// below; that is idempotent and cheap, and having the authoritative reason surface first is
	// worth it.
	if err := ValidatePlanHeader(&h); err != nil {
		return nil, nil, err
	}
	pages := make([]*edgev1.ScheduledPlanPageV1, 0, len(rawPages))
	for _, raw := range rawPages {
		var page edgev1.ScheduledPlanPageV1
		if err := proto.Unmarshal(raw, &page); err != nil {
			return nil, nil, ErrPlanBounds
		}
		pages = append(pages, &page)
	}
	if err := ValidatePlanPages(&h, pages); err != nil {
		return nil, nil, err
	}
	return &h, pages, nil
}
