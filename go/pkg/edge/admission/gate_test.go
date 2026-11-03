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
	"testing"
	"time"
)

func TestNewGateRejectsBadWatermarks(t *testing.T) {
	held := func() uint64 { return 0 }
	for name, build := range map[string]func() (*Gate, error){
		"low equals high": func() (*Gate, error) { return NewGate(100, 100, held) },
		"low above high":  func() (*Gate, error) { return NewGate(100, 200, held) },
		"no byte reading": func() (*Gate, error) { return NewGate(100, 50, nil) },
	} {
		if _, err := build(); !errors.Is(err, ErrInvalidGate) {
			t.Errorf("%s: err=%v, want ErrInvalidGate", name, err)
		}
	}
}

// The gate follows the bytes its owner reports: bulk pauses at the high water,
// stays paused while the bytes sit between the marks, resumes at the low water,
// and stays open between the marks until the high water is reached again.
func TestGateBulkHysteresisFollowsTheOwnersBytes(t *testing.T) {
	var held uint64
	g, err := NewGate(800, 400, func() uint64 { return held })
	if err != nil {
		t.Fatal(err)
	}
	for _, step := range []struct {
		held uint64
		want Decision
	}{
		{0, Admit},
		{799, Admit},
		{800, Defer},
		{401, Defer},
		{799, Defer},
		{400, Admit},
		{799, Admit},
		{900, Defer},
	} {
		held = step.held
		if got := g.Admit(ClassBulk); got != step.want {
			t.Fatalf("bulk at %d held = %v, want %v", step.held, got, step.want)
		}
		if g.BulkPaused() != (step.want == Defer) {
			t.Fatalf("BulkPaused at %d held disagrees with Admit", step.held)
		}
	}
}

// A gate first read between the marks starts paused: those bytes may belong to
// a pause the process never saw relieved. At or below the low water it starts
// open.
func TestGateStartsPausedAboveTheLowWater(t *testing.T) {
	for _, tc := range []struct {
		held uint64
		want Decision
	}{
		{400, Admit},
		{401, Defer},
		{799, Defer},
	} {
		g, err := NewGate(800, 400, func() uint64 { return tc.held })
		if err != nil {
			t.Fatal(err)
		}
		if got := g.Admit(ClassBulk); got != tc.want {
			t.Errorf("first read at %d held = %v, want %v", tc.held, got, tc.want)
		}
	}
}

// Only bulk pauses; the byte owner enforces the hard ceiling for every class.
func TestGatePausesOnlyBulk(t *testing.T) {
	g, err := NewGate(800, 400, func() uint64 { return 1000 })
	if err != nil {
		t.Fatal(err)
	}
	for class, want := range map[Class]Decision{
		ClassBulk: Defer, ClassInteractive: Admit, ClassRecovery: Admit, Class(99): Reject,
	} {
		if got := g.Admit(class); got != want {
			t.Errorf("class %d while paused = %v, want %v", class, got, want)
		}
	}
}

// fairSimFlow is one producer in the fair-share simulation: a FIFO of records
// of one size that it offers head first, retrying a deferred head unchanged.
type fairSimFlow struct {
	name      string
	size      uint64
	perTick   int // records generated each tick
	every     int // the flow asks every this many ticks
	next      int // sequence of the next record generated
	queue     []int
	admitted  []int
	generated int
}

func (f *fairSimFlow) generate() {
	for range f.perTick {
		f.next++
		f.queue = append(f.queue, f.next)
		f.generated++
	}
}

// offer appends head first until the gate defers, as a producer drains its
// retry queue in one push.
func (f *fairSimFlow) offer(g *Gate, held *uint64, now time.Time) {
	for len(f.queue) > 0 && g.AdmitFlow(f.name, f.size, now) == Admit {
		f.admitted = append(f.admitted, f.queue[0])
		f.queue = f.queue[1:]
		*held += f.size
	}
}

func (f *fairSimFlow) admittedBytes() uint64 { return uint64(len(f.admitted)) * f.size }

// A burst flow that offers more than the spool drains, and retries in a tight
// loop, cannot hold a steady flow that asks once a push interval below its fair
// share of the contended room. The steady flow wants a quarter of the drain, so
// all of it is its fair share; the burst still gets the rest. Every record of
// both flows is admitted once production stops, in the order each flow offered
// them.
func TestAdmitFlowBurstCannotStarveASteadyFlow(t *testing.T) {
	const (
		mib       = 1 << 20
		drain     = 256 << 10 // bytes reclaimed per tick (one second)
		producing = 900       // ticks of production
	)
	var held uint64
	g, err := NewGate(8*mib, 4*mib, func() uint64 { return held })
	if err != nil {
		t.Fatal(err)
	}
	burst := &fairSimFlow{name: "burst", size: 256 << 10, perTick: 4, every: 1}
	steady := &fairSimFlow{name: "steady", size: 64 << 10, perTick: 1, every: 30}
	start := time.Unix(1_700_000_000, 0)

	tick := 0
	run := func(produce bool) {
		now := start.Add(time.Duration(tick) * time.Second)
		held -= min(held, drain)
		for _, f := range []*fairSimFlow{burst, steady} {
			if produce {
				f.generate()
			}
			if tick%f.every == 0 {
				f.offer(g, &held, now)
			}
		}
		tick++
	}
	for tick < producing {
		run(true)
	}
	if len(steady.queue) > steady.every {
		t.Fatalf("steady flow has %d records waiting after its last push, want at most one push interval (%d): got %d of %d bytes admitted",
			len(steady.queue), steady.every, steady.admittedBytes(), uint64(steady.generated)*steady.size)
	}
	if burstShare := float64(burst.admittedBytes()) / float64(uint64(producing)*drain); burstShare < 0.6 {
		t.Fatalf("burst flow got %.2f of the drained bytes, want at least 0.6 (all the steady flow left)", burstShare)
	}

	for len(burst.queue)+len(steady.queue) > 0 {
		if tick > 100*producing {
			t.Fatalf("records still waiting after production stopped: burst %d, steady %d", len(burst.queue), len(steady.queue))
		}
		run(false)
	}
	for _, f := range []*fairSimFlow{burst, steady} {
		if len(f.admitted) != f.generated {
			t.Fatalf("%s: %d of %d records admitted", f.name, len(f.admitted), f.generated)
		}
		for i, seq := range f.admitted {
			if seq != i+1 {
				t.Fatalf("%s: record %d admitted at position %d, want offer order", f.name, seq, i+1)
			}
		}
	}
}

// A flow that stops asking keeps its share for fairFlowTTL and is then
// forgotten, so it holds the others back no longer than that.
func TestAdmitFlowForgetsAFlowThatStoppedAsking(t *testing.T) {
	var held uint64
	g, err := NewGate(8<<20, 4<<20, func() uint64 { return held })
	if err != nil {
		t.Fatal(err)
	}
	start := time.Unix(1_700_000_000, 0)
	const record = 256 << 10
	if g.AdmitFlow("quiet", record, start) != Admit {
		t.Fatal("first record below the low water was deferred")
	}
	for range 2 {
		if g.AdmitFlow("busy", record, start) != Admit {
			t.Fatal("record below the low water was deferred")
		}
	}

	held = 5 << 20
	if got := g.AdmitFlow("busy", record, start.Add(fairFlowTTL)); got != Defer {
		t.Fatalf("busy flow a quantum ahead of a flow seen within the TTL = %v, want Defer", got)
	}
	if got := g.AdmitFlow("busy", record, start.Add(fairFlowTTL+time.Second)); got != Admit {
		t.Fatalf("busy flow after the quiet flow's TTL = %v, want Admit", got)
	}
}

// A flow that arrives far behind the lead may catch up by at most the distance
// between the marks before the leader is admitted again; it cannot replay the
// leader's whole history.
func TestAdmitFlowBoundsTheCatchUpOfANewFlow(t *testing.T) {
	var held uint64
	g, err := NewGate(8<<20, 4<<20, func() uint64 { return held })
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_700_000_000, 0)
	const record = 256 << 10
	for range 400 { // 100 MiB through an uncontended spool
		if g.AdmitFlow("leader", record, now) != Admit {
			t.Fatal("record below the low water was deferred")
		}
	}

	held = 5 << 20
	caughtUp := 0
	for {
		if g.AdmitFlow("newcomer", record, now) != Admit {
			t.Fatal("the least-served flow was deferred")
		}
		caughtUp++
		if g.AdmitFlow("leader", record, now) == Admit {
			break
		}
		if caughtUp > 100 {
			t.Fatal("newcomer replayed the leader's history")
		}
	}
	if caughtUp < 2 {
		t.Fatal("leader was admitted while a quantum ahead of the newcomer")
	}
	if limit := int((4<<20+fairQuantum)/record) + 1; caughtUp > limit {
		t.Fatalf("newcomer caught up %d records before the leader resumed, want at most %d", caughtUp, limit)
	}
}
