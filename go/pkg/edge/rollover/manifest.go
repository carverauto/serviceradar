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

// Package rollover builds the bounded loss manifest and drives the crash-safe
// phase journal for spool loss-manifest / new-spool rollover. When a spool tail
// is lost (corruption, ENOSPC forcing a new spool), the agent records which
// semantic sequence ranges are lost without ever enumerating an outage-sized
// tail: an overlarge manifest coarsens to a single conservative uncertain scope.
// The phase journal makes the rollover resumable across restart. This is the
// pure decision core of task 2.4's rollover half; segment copy I/O lives above.
package rollover

import (
	"crypto/sha256"
	"encoding/binary"
	"math"
	"sort"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// LostRange is one contiguous run of lost spool sequences, inclusive.
type LostRange struct {
	From    uint64
	Through uint64
}

// Manifest accumulates lost sequence ranges under a hard entry bound. Adding
// past the bound collapses the whole manifest to one conservative [min,max]
// range and marks it coarsened, so the manifest can never grow with the size of
// the lost tail. Not safe for concurrent use.
type Manifest struct {
	maxEntries int
	ranges     []LostRange
	coarsened  bool
	min        uint64
	max        uint64
	haveBounds bool
}

// NewManifest returns a manifest that holds at most maxEntries discrete ranges
// before coarsening. maxEntries < 1 is promoted to 1.
func NewManifest(maxEntries int) *Manifest {
	if maxEntries < 1 {
		maxEntries = 1
	}
	return &Manifest{maxEntries: maxEntries}
}

// Add records that [from, through] is lost. Ranges are normalized (sorted and
// overlap/adjacency-merged) so equivalent loss sets -- e.g. [1,5] versus
// [1,3]+[4,5] -- collapse to the same canonical ranges and hash identically, and
// duplicate/overlapping reports do not consume the entry cap. Once the merged set
// would exceed the entry bound (or is already coarsened) the manifest folds into
// the running conservative [min,max] scope instead of storing discretely.
func (m *Manifest) Add(from, through uint64) {
	if through < from {
		from, through = through, from
	}
	m.extendBounds(from, through)

	if m.coarsened {
		return
	}
	m.ranges = normalize(append(m.ranges, LostRange{From: from, Through: through}))
	if len(m.ranges) > m.maxEntries {
		m.coarsen()
	}
}

// normalize sorts ranges and merges any that overlap or are adjacent (touching
// at consecutive integers), yielding a canonical minimal set.
func normalize(rs []LostRange) []LostRange {
	if len(rs) == 0 {
		return nil
	}
	sort.Slice(rs, func(i, j int) bool {
		if rs[i].From != rs[j].From {
			return rs[i].From < rs[j].From
		}
		return rs[i].Through < rs[j].Through
	})
	out := []LostRange{rs[0]}
	for _, r := range rs[1:] {
		last := &out[len(out)-1]
		// Merge on overlap or adjacency (r starts within, at, or just past last).
		adjacent := r.From <= last.Through || (last.Through < math.MaxUint64 && r.From <= last.Through+1)
		if adjacent {
			if r.Through > last.Through {
				last.Through = r.Through
			}
			continue
		}
		out = append(out, r)
	}
	return out
}

// Coarsened reports whether the manifest collapsed to a conservative scope.
func (m *Manifest) Coarsened() bool { return m.coarsened }

// Ranges returns the discrete lost ranges, or the single conservative range when
// coarsened. Ranges are sorted by From.
func (m *Manifest) Ranges() []LostRange {
	if m.coarsened {
		if !m.haveBounds {
			return nil
		}
		return []LostRange{{From: m.min, Through: m.max}}
	}
	out := make([]LostRange, len(m.ranges))
	copy(out, m.ranges)
	sort.Slice(out, func(i, j int) bool { return out[i].From < out[j].From })
	return out
}

// Bounds returns the lowest and highest lost sequence across everything added,
// and whether any range has been recorded.
func (m *Manifest) Bounds() (lo, hi uint64, ok bool) {
	return m.min, m.max, m.haveBounds
}

// Digest is the canonical content digest over the manifest's effective ranges
// (sorted), plus a coarsened flag byte, so identical loss sets hash identically
// and a coarsened manifest never collides with a discrete one of the same span.
func (m *Manifest) Digest() []byte {
	h := sha256.New()
	if m.coarsened {
		_, _ = h.Write([]byte{1})
	} else {
		_, _ = h.Write([]byte{0})
	}
	var buf [16]byte
	for _, r := range m.Ranges() {
		binary.BigEndian.PutUint64(buf[0:8], r.From)
		binary.BigEndian.PutUint64(buf[8:16], r.Through)
		_, _ = h.Write(buf[:])
	}
	return h.Sum(nil)
}

// Tombstone builds the SpoolLossTombstoneV1 that immutably binds this rollover:
// the recovery id, prior/new spool ids, the lost [from,through] span, the
// manifest digest, the coarsened flag, and detection time.
func (m *Manifest) Tombstone(recoveryID, priorSpoolID, newSpoolID []byte, detectedAtUnixNano int64) *edgev1.SpoolLossTombstoneV1 {
	lo, hi, _ := m.Bounds()
	return &edgev1.SpoolLossTombstoneV1{
		RecoveryId:          recoveryID,
		PriorSpoolId:        priorSpoolID,
		LostFromSequence:    lo,
		LostThroughSequence: hi,
		NewSpoolId:          newSpoolID,
		ManifestSha256:      m.Digest(),
		Coarsened:           m.coarsened,
		DetectedAtUnixNano:  detectedAtUnixNano,
	}
}

func (m *Manifest) extendBounds(from, through uint64) {
	if !m.haveBounds {
		m.min, m.max, m.haveBounds = from, through, true
		return
	}
	if from < m.min {
		m.min = from
	}
	if through > m.max {
		m.max = through
	}
}

func (m *Manifest) coarsen() {
	m.coarsened = true
	m.ranges = nil
}
