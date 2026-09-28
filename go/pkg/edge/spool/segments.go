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
//     worst-case span per run plus page framing -- must stay within
//     edgerecord.MaxManifestBytes. Attributed runs cost more per span than
//     unattributed ones, so a heavily attributed segment trips the byte bound
//     before the run bound, while a cheap (unattributed) segment trips the run
//     bound first.
//
// The KEY is the commit's declared attribution binding digest
// (Bindings.AttributionSHA256): equal digests name the same bound attribution
// and their records may merge into one manifest span, so a run of equal keys
// projects to one span. A nil digest declares no binding and NEVER continues a
// run, not even another nil: whether two unattributed records may share one
// UNATTRIBUTABLE span depends on their corruption reasons, which are unknowable
// at append time, so each unattributed append conservatively opens its own run.
//
// A refused append wraps ErrRotationRequired (hence ErrRetryable, never
// ErrPermanent): the append was valid, the producer rotates the lane's
// generation (LaneSet.Rotate) and retries it unchanged. The refusal writes
// nothing and allocates no sequence.
//
// The projection is an OVERESTIMATE by construction: every per-span and
// per-page constant in this file is at or above the largest encoding the
// recovery grammar accepts (proven by TestSegmentBoundConstantsCoverWorstCase
// in segments_test.go), and one span per run assumes no cross-run merging.
// An admitted segment's real manifest is therefore always within the
// grammar's page and byte ceilings; the coordinator's split-across-manifests
// rule (design.md) remains the escape hatch for per-reason fragmentation
// inside a run, which append-time accounting cannot see.
//
// Bounds state is rebuilt from the commit evidence on every open (see
// absorbEvidence): a restart never resets the bounds, so a segment cannot slip
// past them by crashing. Slots whose evidence does not agree on one payload --
// disagreeing copies, unreadable copies, and markerless allocated gaps --
// count as unattributed-cost runs of unknown key: their spans may be
// maximally sized, and an unknown key provably continues no run.
//
// What this does NOT bound: the segment's own byte/record count. A single-key,
// single-run segment admits records indefinitely while its worst-case manifest
// stays one span. Capping segment bytes and record counts is the multi-segment
// rotation work of task 2.4, not this one.

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
	// Runs are the span-count driver of the worst-case manifest: at most one
	// span per run, and MaxSegmentRuns runs need at most
	// ceil(MaxSegmentRuns/MaxSpansPerPage) pages, far below MaxManifestPages.
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
	runs      uint64
	spanBytes uint64 // sum of worst-case span costs over every run so far

	// hasRun/curKey/curAttributed name the open run: the key the next append
	// must carry to continue it. Unattributed and unknown slots leave hasRun
	// false, so they never continue a run and no run continues past them.
	hasRun        bool
	curKey        [32]byte
	curAttributed bool
}

// runPages is the page count of a worst-case manifest with one span per run:
// MaxSpansPerPage spans per page, at least one page once a run exists.
func runPages(runs uint64) uint64 {
	if runs == 0 {
		return 0
	}
	return (runs + uint64(edgerecord.MaxSpansPerPage) - 1) / uint64(edgerecord.MaxSpansPerPage)
}

// projectedBytes is the worst-case manifest size for runs runs costing
// spanBytes in spans plus page framing.
func projectedBytes(runs, spanBytes uint64) uint64 {
	return spanBytes + runPages(runs)*manifestPageOverheadBytes
}

// refusalFor reports which bound ("keys", "runs", or "manifest") the next
// append carrying key would exceed, or "" if it fits. A nil key declares no
// attribution binding. It is pure: it changes no state.
func (b *segmentBounds) refusalFor(key []byte) string {
	keys := uint64(len(b.keys))
	runs := b.runs
	cost := b.spanBytes
	if len(key) == 0 {
		runs++
		cost += maxUnattributableSpanBytes
	} else {
		var k [32]byte
		copy(k[:], key)
		if _, ok := b.keys[k]; !ok {
			keys++
		}
		if !b.hasRun || !b.curAttributed || b.curKey != k {
			runs++
			cost += maxAttributedSpanBytes
		}
	}
	switch {
	case keys > b.limits.maxKeys:
		return "keys"
	case runs > b.limits.maxRuns:
		return "runs"
	case projectedBytes(runs, cost) > b.limits.maxManifestBytes:
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
		return
	}
	b.runs++
	b.spanBytes += maxAttributedSpanBytes
	b.curKey = k
	b.curAttributed = true
	b.hasRun = true
}

// foldUnattributed folds one append carrying no attribution binding: always a
// new run, always the cheap span cost, and never continuable.
func (b *segmentBounds) foldUnattributed() {
	b.runs++
	b.spanBytes += maxUnattributableSpanBytes
	b.hasRun = false
}

// foldUnknown folds one slot whose evidence does not agree on one payload. Its
// span may be maximally sized (attributed cost) and its key continues nothing.
func (b *segmentBounds) foldUnknown() {
	b.runs++
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
				return
			}
			b.runs++
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

// SegmentBoundsStats returns a read-only snapshot of the open segment's
// rotation accounting, for tests and operator introspection.
func (s *Spool) SegmentBoundsStats() SegmentBoundsStats {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.segBounds.stats()
}

// SegmentBoundsStats is a read-only snapshot of one segment's rotation
// accounting, for tests and operator introspection.
type SegmentBoundsStats struct {
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
func (b *segmentBounds) stats() SegmentBoundsStats {
	return SegmentBoundsStats{
		Keys:           uint64(len(b.keys)),
		Runs:           b.runs,
		ProjectedBytes: projectedBytes(b.runs, b.spanBytes),
		ProjectedPages: runPages(b.runs),
		MaxKeys:        b.limits.maxKeys,
		MaxRuns:        b.limits.maxRuns,
		MaxBytes:       b.limits.maxManifestBytes,
	}
}

// rotationRefusal formats the retryable refusal for the bound an append would
// exceed. It wraps ErrRotationRequired (hence ErrRetryable): the append was
// valid and the producer rotates and retries it unchanged.
func rotationRefusal(bound string, s SegmentBoundsStats) error {
	return fmt.Errorf("%w: segment %s bound reached (keys=%d runs=%d projected=%dB in %d pages)",
		ErrRotationRequired, bound, s.Keys, s.Runs, s.ProjectedBytes, s.ProjectedPages)
}
