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

package spool

// Segment rotation bounds (task 2.24 of
// openspec/changes/unify-sweep-results-proto).
//
// A segment is bounded on THREE axes and rotates on whichever binds first:
//
//  1. KEYS: at most MaxSegmentKeys distinct attribution binding digests. This
//     bounds the per-segment key index, not the recovery: alternating between
//     two keys stays within any distinct-key bound while still growing the
//     manifest, so a key bound alone cannot bound recovery (design.md, "Why
//     distinct-key bounds alone do not bound recovery").
//  2. RUNS: at most MaxSegmentRuns maximal runs of consecutive same-key
//     appends. Alternating keys A,B,A,B,... produce one run per record, so the
//     run count is what grows where the key count does not.
//  3. MANIFEST SIZE: the projected worst-case manifest for the segment -- one
//     worst-case span per RECORD plus page framing -- must stay within
//     edgerecord.MaxManifestBytes. Attributed records cost more per span than
//     unattributed ones, so a heavily attributed segment trips the byte bound
//     before the run bound, while a cheap (unattributed) segment trips the run
//     bound first.
//
// The KEY is the commit's declared attribution binding digest
// (Bindings.AttributionSHA256): equal digests name the same bound attribution
// and their records may merge into one manifest span, so a run of equal keys
// may project to one span. A nil digest declares no binding and NEVER continues
// a run, not even another nil: whether two unattributed records may share one
// UNATTRIBUTABLE span depends on their corruption reasons, which are unknowable
// at append time, so each unattributed append conservatively opens its own run.
//
// The MANIFEST projection charges each RECORD one worst-case span, not each
// run: a run of equal keys may still fragment into many spans at recovery time
// (each record's corruption reason can differ), and append-time accounting
// cannot see reasons. Charging per record makes the projection an
// OVERESTIMATE by construction -- every per-span and per-page constant in this
// file is at or above the largest encoding the recovery grammar accepts
// (proven by TestSegmentBoundConstantsCoverWorstCase in segments_test.go), and
// no record can contribute more than one span no matter how its run fragments
// -- so an admitted segment's real manifest is always within the grammar's
// page and byte ceilings. This is why rotation tightens to roughly
// MaxManifestBytes/maxAttributedSpanBytes (~817) attributed records per
// segment.
//
// A refused append wraps ErrRotationRequired (hence ErrRetryable, never
// ErrPermanent): the append was valid, the producer rotates the lane's
// generation (LaneSet.Rotate) and retries it unchanged. The refusal writes
// nothing and allocates no sequence.
//
// Bounds state is rebuilt from the commit evidence on every open (see
// absorbEvidence): a restart never resets the bounds, so a segment cannot slip
// past them by crashing. Slots whose evidence does not agree on one payload --
// disagreeing copies, unreadable copies, and markerless allocated gaps --
// count as runs of unknown key at attributed cost: their spans may be
// maximally sized, and an unknown key provably continues no run.
//
// What this does NOT bound: the segment's own on-disk byte count. The
// manifest bound now caps a segment at roughly 817 attributed records (one
// worst-case span each), but each record's segment bytes can dwarf its span
// bytes (a body can be far larger than maxAttributedSpanBytes), so a segment
// file can still grow without bound in bytes. Capping segment bytes is the
// multi-segment rotation work of task 2.4, not this one.

import (
	"fmt"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
)

// Frozen rotation limits. Changing any of them changes when lanes rotate; the
// ceiling proof in segments_test.go ties them to the recovery grammar, so a
// change that breaks that proof fails the build's tests, not just review.
const (
	// MaxSegmentKeys bounds the distinct attribution binding digests one
	// segment may carry. It caps the per-segment key index, not the manifest.
	MaxSegmentKeys = 256
	// MaxSegmentRuns bounds the maximal same-key runs one segment may carry.
	// Alternating keys A,B,A,B,... opens one run per record, so runs are what
	// grow where the key count does not; for the cheapest (unattributed) spans
	// the run bound trips before the byte bound does.
	MaxSegmentRuns = 4096
)

// Worst-case encoding sizes for the manifest projection. Each is an
// OVERESTIMATE of the largest encoding the recovery grammar accepts --
// overestimating rotates early (safe); underestimating would admit a segment
// whose manifest can exceed a ceiling (unsound). The derivation of each:
//
//   - maxAttributedSpanBytes: an ACTIVE span with every varint maxed
//     (from/through 10 bytes each), a full identity (three 16-byte UUIDs,
//     two 32-byte digests, maxed shard/epoch varints, a full source identity)
//     and a 32-byte range digest, plus per-span field framing: ~280 bytes
//     true cost, 320 budgeted.
//   - maxUnattributableSpanBytes: interval varints plus a reason enum plus
//     framing: ~30 bytes true cost, 32 budgeted.
//   - manifestPageOverheadBytes: a page's fixed framing (16-byte recovery id,
//     index/count varints, two 32-byte digests, terminal flag, digest
//     version): ~106 bytes true cost, 128 budgeted.
//
// segments_test.go marshals the true maxima and asserts each constant covers
// them, so grammar growth that outgrows a constant fails loudly there.
const (
	maxAttributedSpanBytes     = 320
	maxUnattributableSpanBytes = 32
	manifestPageOverheadBytes  = 128
)

// segmentLimits are the three rotation bounds. Production always uses
// defaultSegmentLimits; tests shrink them through the in-package override on
// Spool/LaneSet to prove each bound binds independently without thousands of
// fsynced commits.
type segmentLimits struct {
	maxKeys          uint64
	maxRuns          uint64
	maxManifestBytes uint64
}

func defaultSegmentLimits() segmentLimits {
	return segmentLimits{
		maxKeys:          MaxSegmentKeys,
		maxRuns:          MaxSegmentRuns,
		maxManifestBytes: uint64(edgerecord.MaxManifestBytes),
	}
}

// segmentBounds is one segment's rotation accounting: the limits plus the
// folded state. The zero value is an empty segment under production limits;
// Open replaces it with defaultSegmentLimits.
type segmentBounds struct {
	limits segmentLimits

	keys      map[[32]byte]struct{}
	runs      uint64 // maximal same-key runs, for the runs bound
	spans     uint64 // worst-case span count: one span per record
	spanBytes uint64 // sum of worst-case span costs over every record so far

	// hasRun/curKey/curAttributed name the open run: the key the next append
	// must carry to continue it. Unattributed and unknown slots leave hasRun
	// false, so they never continue a run and no run continues past them.
	hasRun        bool
	curKey        [32]byte
	curAttributed bool
}

// runPages is the page count of a worst-case manifest with one span per span
// count: MaxSpansPerPage spans per page, at least one page once a span exists.
func runPages(spans uint64) uint64 {
	if spans == 0 {
		return 0
	}
	return (spans + uint64(edgerecord.MaxSpansPerPage) - 1) / uint64(edgerecord.MaxSpansPerPage)
}

// projectedBytes is the worst-case manifest size for spans spans costing
// spanBytes in span bytes plus page framing.
func projectedBytes(spans, spanBytes uint64) uint64 {
	return spanBytes + runPages(spans)*manifestPageOverheadBytes
}

// refusalFor reports which bound ("keys", "runs", or "manifest") the next
// append carrying key would exceed, or "" if it fits. A nil key declares no
// attribution binding. It is pure: it changes no state.
func (b *segmentBounds) refusalFor(key []byte) string {
	keys := uint64(len(b.keys))
	runs := b.runs
	spans := b.spans
	cost := b.spanBytes
	if len(key) == 0 {
		runs++
		spans++
		cost += maxUnattributableSpanBytes
	} else {
		var k [32]byte
		copy(k[:], key)
		if _, ok := b.keys[k]; !ok {
			keys++
		}
		if !b.hasRun || !b.curAttributed || b.curKey != k {
			runs++
		}
		spans++
		cost += maxAttributedSpanBytes
	}
	switch {
	case keys > b.limits.maxKeys:
		return "keys"
	case runs > b.limits.maxRuns:
		return "runs"
	case projectedBytes(spans, cost) > b.limits.maxManifestBytes:
		return "manifest"
	default:
		return ""
	}
}

// observe folds a successfully committed append into the bounds. It must run
// exactly once per committed sequence, under the spool mutex.
func (b *segmentBounds) observe(key []byte) {
	if len(key) == 0 {
		b.foldUnattributed()
		return
	}
	var k [32]byte
	copy(k[:], key)
	if b.keys == nil {
		b.keys = make(map[[32]byte]struct{})
	}
	b.keys[k] = struct{}{}
	if b.hasRun && b.curAttributed && b.curKey == k {
		b.spans++
		b.spanBytes += maxAttributedSpanBytes
		return
	}
	b.runs++
	b.spans++
	b.spanBytes += maxAttributedSpanBytes
	b.curKey = k
	b.curAttributed = true
	b.hasRun = true
}

// foldUnattributed folds one append carrying no attribution binding: always a
// new run, always the cheap span cost, and never continuable.
func (b *segmentBounds) foldUnattributed() {
	b.runs++
	b.spans++
	b.spanBytes += maxUnattributableSpanBytes
	b.hasRun = false
}

// foldUnknown folds one slot whose evidence does not agree on one payload. Its
// span may be maximally sized (attributed cost) and its key continues nothing.
func (b *segmentBounds) foldUnknown() {
	b.runs++
	b.spans++
	b.spanBytes += maxAttributedSpanBytes
	b.hasRun = false
}

// absorbEvidence folds one slot's commit-evidence views into the bounds during
// open and resync. Slots with agreeing valid entries fold their declared
// binding; every other allocated slot folds unknown. It never refuses: bounds
// describe what is on disk, and a segment that already exceeds a limit simply
// refuses every further append until it rotates.
func (b *segmentBounds) absorbEvidence(views [evidenceCopies]copyView) {
	if b.keys == nil {
		b.keys = make(map[[32]byte]struct{})
	}
	state, valid := combineViews(views)
	if (state == EvidenceCommitted || state == EvidencePrepared) && len(valid) > 0 {
		e := valid[0]
		if e.flags&flagAttributionBinding != 0 {
			b.keys[e.attributionSHA256] = struct{}{}
			if b.hasRun && b.curAttributed && b.curKey == e.attributionSHA256 {
				b.spans++
				b.spanBytes += maxAttributedSpanBytes
				return
			}
			b.runs++
			b.spans++
			b.spanBytes += maxAttributedSpanBytes
			b.curKey = e.attributionSHA256
			b.curAttributed = true
			b.hasRun = true
			return
		}
		b.foldUnattributed()
		return
	}
	b.foldUnknown()
}

// segmentBoundsStats is a read-only snapshot of one segment's rotation
// accounting, for tests.
type segmentBoundsStats struct {
	Keys           uint64
	Runs           uint64
	ProjectedBytes uint64
	ProjectedPages uint64
	MaxKeys        uint64
	MaxRuns        uint64
	MaxBytes       uint64
}

// stats snapshots the bounds. The caller holds at least a read view of the
// spool mutex.
func (b *segmentBounds) stats() segmentBoundsStats {
	return segmentBoundsStats{
		Keys:           uint64(len(b.keys)),
		Runs:           b.runs,
		ProjectedBytes: projectedBytes(b.spans, b.spanBytes),
		ProjectedPages: runPages(b.spans),
		MaxKeys:        b.limits.maxKeys,
		MaxRuns:        b.limits.maxRuns,
		MaxBytes:       b.limits.maxManifestBytes,
	}
}

// rotationRefusal formats the retryable refusal for the bound an append would
// exceed. It wraps ErrRotationRequired (hence ErrRetryable): the append was
// valid and the producer rotates and retries it unchanged.
func rotationRefusal(bound string, s segmentBoundsStats) error {
	return fmt.Errorf("%w: segment %s bound reached (keys=%d runs=%d projected=%dB in %d pages)",
		ErrRotationRequired, bound, s.Keys, s.Runs, s.ProjectedBytes, s.ProjectedPages)
}
