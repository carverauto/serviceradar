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

// Package admission applies bulk pressure and fair sharing to the spool
// allocator's measured usage. The allocator owns capacity and durable release;
// this package owns no byte reservations or reclamation authority.
package admission

import (
	"errors"
	"sync"
	"time"
)

// ErrInvalidGate is returned by NewGate when the watermarks are inconsistent
// or no byte reading is supplied.
var ErrInvalidGate = errors.New("admission: invalid gate")

// Class identifies the traffic whose admission is being considered.
type Class uint8

const (
	ClassBulk Class = iota
	ClassInteractive
	ClassRecovery
)

// Decision describes gate admission; the allocator still enforces capacity.
type Decision uint8

const (
	Admit Decision = iota
	Defer
	Reject
)

// watermarks pauses bulk once held bytes reach the high water and resumes only
// once they fall to the low water.
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
// unpaused.
func (w watermarks) initial(held uint64) bool { return held > w.low }

// Fair-share bounds for Gate.AdmitFlow.
const (
	// fairQuantum is how far, in bytes, a flow may get ahead of the least-served
	// flow while the room is contended: about one full record, the 256 KiB flush
	// target of a batch builder.
	fairQuantum uint64 = 256 << 10
	// fairFlowTTL is how long a flow keeps its share without asking again. It
	// outlasts the agent's 30 second push interval, the slowest retry of any
	// producer, so only a flow that stopped producing is forgotten.
	fairFlowTTL = 2 * time.Minute
	// maxFairFlows bounds the flows Gate tracks. Past it the flow seen longest
	// ago is forgotten first.
	maxFairFlows = 1024
)

// Gate applies the bulk high/low-water hysteresis to a byte count another
// component owns and releases, such as the spool allocator's ordinary usage,
// and shares the room between the marks byte-fairly across producer flows.
//
// The spool allocator charges retained record bytes until physical reclamation,
// so its reading is the held count. Gate holds no accounting of its own, only
// the pause state and the bytes each flow was admitted.
//
// Gate pauses only ClassBulk. The hard ceiling for every class stays with the
// owner of the bytes, which refuses what does not fit.
type Gate struct {
	marks watermarks
	held  func() uint64

	mu            sync.Mutex
	observed      bool
	paused        bool
	budgetBlocked bool
	flows         map[string]*fairFlow
	// lead is the most bytes any flow has been admitted.
	lead uint64
}

// fairFlow is one producer flow's admitted bytes and when it last asked.
type fairFlow struct {
	attained uint64
	seen     time.Time
}

// NewGate returns a gate that pauses bulk admission once held() reaches
// highWater and resumes it once held() falls to lowWater.
func NewGate(highWater, lowWater uint64, held func() uint64) (*Gate, error) {
	if held == nil || lowWater >= highWater {
		return nil, ErrInvalidGate
	}
	return &Gate{marks: watermarks{high: highWater, low: lowWater}, held: held, flows: make(map[string]*fairFlow)}, nil
}

// SetWatermarks moves the bulk hysteresis marks, as NewGate validates them. The
// pause state follows the new marks from the next reading of held.
func (g *Gate) SetWatermarks(highWater, lowWater uint64) error {
	if lowWater >= highWater {
		return ErrInvalidGate
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.marks = watermarks{high: highWater, low: lowWater}
	return nil
}

// SetBudgetBlocked pauses producer admission while a configured budget cannot
// be applied. Recovery and interactive traffic retain their reserved capacity.
// Clearing it preserves the ordinary high/low-water hysteresis.
func (g *Gate) SetBudgetBlocked(blocked bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.budgetBlocked = blocked
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

	g.observeLocked(g.held())
	return g.budgetBlocked || g.paused
}

func (g *Gate) observeLocked(held uint64) {
	if !g.observed {
		g.observed = true
		g.paused = g.marks.initial(held)
	} else {
		g.paused = g.marks.next(g.paused, held)
	}
}

// AdmitFlow decides one bulk record of cost bytes from flow (a producer's
// network scope, origin, assignment, run and contract) at now. It returns
// Admit or Defer; a deferred record is retried unchanged, so a flow's records
// enter in the order it offers them and none is dropped here.
//
// While the gate is paused every flow defers. At or below the low water there
// is room for everyone and every flow is admitted. Between the marks the room
// left before the pause is contended, and a flow is admitted only while it has
// been admitted less than fairQuantum bytes more than the least-served flow
// that asked within fairFlowTTL. The least-served flow is always admitted, so
// no flow is shut out, and a flow that retries constantly cannot spend the
// room a flow that retries once a push interval is owed: it waits for that
// flow to catch up, or for the spool to drain to the low water.
//
// A flow's count trails the lead by at most the distance between the marks,
// so a flow that was idle, or is new, can claim at most that much catch-up
// before it shares the room again.
func (g *Gate) AdmitFlow(flow string, cost uint64, now time.Time) Decision {
	g.mu.Lock()
	defer g.mu.Unlock()

	held := g.held()
	g.observeLocked(held)
	g.expireFlowsLocked(now)
	f := g.flowLocked(flow, now)
	if g.budgetBlocked || g.paused || (held > g.marks.low && !g.withinShareLocked(f)) {
		return Defer
	}
	f.attained = g.attainedLocked(f) + cost
	g.lead = max(g.lead, f.attained)
	return Admit
}

// withinShareLocked reports whether f is less than fairQuantum ahead of every
// other tracked flow.
func (g *Gate) withinShareLocked(f *fairFlow) bool {
	mine := g.attainedLocked(f)
	for _, other := range g.flows {
		if other != f && mine >= g.attainedLocked(other)+fairQuantum {
			return false
		}
	}
	return true
}

// attainedLocked is f's admitted bytes, raised to trail the lead by no more
// than the distance between the marks.
func (g *Gate) attainedLocked(f *fairFlow) uint64 {
	if lag := g.marks.high - g.marks.low; g.lead > lag {
		return max(f.attained, g.lead-lag)
	}
	return f.attained
}

// flowLocked returns flow's state, tracking it if new, and marks it seen.
func (g *Gate) flowLocked(flow string, now time.Time) *fairFlow {
	f, ok := g.flows[flow]
	if !ok {
		if len(g.flows) >= maxFairFlows {
			g.forgetStalestLocked()
		}
		f = &fairFlow{}
		g.flows[flow] = f
	}
	f.seen = now
	return f
}

func (g *Gate) expireFlowsLocked(now time.Time) {
	for key, f := range g.flows {
		if now.Sub(f.seen) > fairFlowTTL {
			delete(g.flows, key)
		}
	}
}

func (g *Gate) forgetStalestLocked() {
	var stalest string
	var seen time.Time
	for key, f := range g.flows {
		if seen.IsZero() || f.seen.Before(seen) {
			stalest, seen = key, f.seen
		}
	}
	delete(g.flows, stalest)
}
