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

package admission

import (
	"errors"
	"sync"
)

// ErrInvalidGate is returned by NewGate when the watermarks are inconsistent
// or no byte reading is supplied.
var ErrInvalidGate = errors.New("admission: invalid gate")

// watermarks is the bulk hysteresis rule Controller and Gate share: bulk
// pauses once held bytes reach the high water and resumes only once they fall
// to the low water.
type watermarks struct {
	high uint64
	low  uint64
}

func (w watermarks) next(paused bool, held uint64) bool {
	if paused {
		return held > w.low
	}
	return held >= w.high
}

// initial is the pause state at startup. Bytes between the marks may belong
// to a pause the process never saw relieved, so only the low water starts
// unpaused (see Controller.restoreHysteresisLocked).
func (w watermarks) initial(held uint64) bool { return held > w.low }

// Gate applies the bulk high/low-water hysteresis to a byte count another
// component owns and releases, such as the spool allocator's ordinary usage.
//
// Controller charges bytes itself and frees them only through a
// ReclaimAuthorization, which nothing can mint until the coverage owner of task
// 2.28 exists, so a producer that committed through it would stay paused for
// good. The spool allocator already charges a record until its bytes are
// physically deleted, so its reading is the held count; Gate holds no
// accounting of its own, only the pause state.
//
// Gate pauses only ClassBulk. The hard ceiling for every class stays with the
// owner of the bytes, which refuses what does not fit.
type Gate struct {
	marks watermarks
	held  func() uint64

	mu       sync.Mutex
	observed bool
	paused   bool
}

// NewGate returns a gate that pauses bulk admission once held() reaches
// highWater and resumes it once held() falls to lowWater.
func NewGate(highWater, lowWater uint64, held func() uint64) (*Gate, error) {
	if held == nil || lowWater >= highWater {
		return nil, ErrInvalidGate
	}
	return &Gate{marks: watermarks{high: highWater, low: lowWater}, held: held}, nil
}

// Admit reports whether class may add bytes now: Defer for bulk while the
// gate is paused, Reject for an unknown class, and Admit otherwise. It reads
// held first. The first reading starts paused anywhere above the low water.
func (g *Gate) Admit(class Class) Decision {
	switch class {
	case ClassBulk:
		if g.BulkPaused() {
			return Defer
		}
		return Admit
	case ClassInteractive, ClassRecovery:
		return Admit
	default:
		return Reject
	}
}

// BulkPaused reads held, applies it to the pause state, and reports whether
// bulk admission is paused.
func (g *Gate) BulkPaused() bool {
	g.mu.Lock()
	defer g.mu.Unlock()

	held := g.held()
	if !g.observed {
		g.observed = true
		g.paused = g.marks.initial(held)
	} else {
		g.paused = g.marks.next(g.paused, held)
	}
	return g.paused
}
