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

package fairsched

import "testing"

func TestFairQueueEmpty(t *testing.T) {
	q := NewFairQueue(10)
	if _, ok := q.Dequeue(); ok {
		t.Fatal("empty queue must return ok=false")
	}
}

// A large-item flow must not block a small-item flow's progress: the small flow
// should interleave rather than wait behind the big one.
func TestFairQueueLargeItemDoesNotBlockSmall(t *testing.T) {
	q := NewFairQueue(10)
	q.Enqueue(Item{Flow: "big", Cost: 1000, Value: "B"})
	for i := 0; i < 5; i++ {
		q.Enqueue(Item{Flow: "small", Cost: 5, Value: "s"})
	}
	// The first several dequeues must all be small items, since "big" cannot
	// afford its 1000-cost item until its deficit accrues over many visits.
	first, _ := q.Dequeue()
	if first.Flow != "small" {
		t.Fatalf("first dequeue = %q, want small (big must not head-of-line block)", first.Flow)
	}
	got := 1
	for {
		it, ok := q.Dequeue()
		if !ok {
			break
		}
		if it.Flow == "small" {
			got++
		}
	}
	if got != 5 {
		t.Fatalf("recovered %d small items, want 5", got)
	}
}

// Two backlogged small-item flows should share bytes roughly equally (DRR), not
// drain one entirely before the other (FIFO).
func TestFairQueueByteFairBetweenFlows(t *testing.T) {
	q := NewFairQueue(10)
	for i := 0; i < 20; i++ {
		q.Enqueue(Item{Flow: "a", Cost: 10})
		q.Enqueue(Item{Flow: "b", Cost: 10})
	}
	// Over the first 10 dequeues, each flow should appear ~5 times, never 10/0.
	counts := map[string]int{}
	for i := 0; i < 10; i++ {
		it, ok := q.Dequeue()
		if !ok {
			t.Fatalf("unexpected empty at %d", i)
		}
		counts[it.Flow]++
	}
	if counts["a"] < 4 || counts["b"] < 4 {
		t.Fatalf("unfair share in first 10: a=%d b=%d", counts["a"], counts["b"])
	}
}

func TestFairQueueDrainsEverything(t *testing.T) {
	q := NewFairQueue(7)
	total := 0
	for _, f := range []string{"x", "y", "z"} {
		for i := 0; i < 13; i++ {
			q.Enqueue(Item{Flow: f, Cost: uint64(1 + i%9)})
			total++
		}
	}
	seen := 0
	for {
		_, ok := q.Dequeue()
		if !ok {
			break
		}
		seen++
	}
	if seen != total {
		t.Fatalf("drained %d items, enqueued %d", seen, total)
	}
	if q.Len() != 0 {
		t.Fatalf("Len=%d after drain, want 0", q.Len())
	}
}

// An interactive lane must keep making progress even when a bulk lane holds an
// unbounded backlog -- the weighted round-robin gives it an unstarvable share.
func TestSchedulerInteractiveNotStarvedByBulk(t *testing.T) {
	s := NewScheduler(map[Lane]int{
		LaneSweepBulk:        4,
		LaneSweepInteractive: 1,
		LaneRecovery:         8,
	}, 1<<10)

	for i := 0; i < 1000; i++ {
		s.Enqueue(LaneSweepBulk, Item{Flow: "huge-sweep", Cost: 1})
	}
	for i := 0; i < 50; i++ {
		s.Enqueue(LaneSweepInteractive, Item{Flow: "adhoc", Cost: 1})
	}

	interactive := 0
	for i := 0; i < 100; i++ { // a bounded prefix of the drain
		lane, _, ok := s.Dequeue()
		if !ok {
			break
		}
		if lane == LaneSweepInteractive {
			interactive++
		}
	}
	// With weights 4:1, interactive should get ~1/5 of a 100-item prefix (~20),
	// certainly well above zero -- it is never starved by the 1000-item bulk lane.
	if interactive < 10 {
		t.Fatalf("interactive served %d/100 while bulk backlogged, want an unstarved share", interactive)
	}
}

// A caller cannot promote its own work: the lane is chosen by the enqueuer, and
// recovery's high weight makes it drain promptly ahead of a bulk flood.
func TestSchedulerRecoveryDrainsPromptly(t *testing.T) {
	s := NewScheduler(map[Lane]int{
		LaneSweepBulk: 2,
		LaneRecovery:  16,
	}, 1<<10)
	for i := 0; i < 500; i++ {
		s.Enqueue(LaneSweepBulk, Item{Flow: "bulk", Cost: 1})
	}
	for i := 0; i < 16; i++ {
		s.Enqueue(LaneRecovery, Item{Flow: "loss-manifest", Cost: 1})
	}
	recovery := 0
	for i := 0; i < 40; i++ {
		lane, _, ok := s.Dequeue()
		if !ok {
			break
		}
		if lane == LaneRecovery {
			recovery++
		}
	}
	if recovery < 16 {
		t.Fatalf("recovery drained %d/16 in first 40 dequeues, want all 16 promptly", recovery)
	}
}

func TestSchedulerDrainsAllLanes(t *testing.T) {
	s := NewScheduler(nil, 1<<10)
	want := 0
	for _, l := range []Lane{LaneSweepBulk, LaneSweepInteractive, LaneMtrBulk, LaneMtrInteractive, LaneRecovery} {
		for i := 0; i < 10; i++ {
			s.Enqueue(l, Item{Flow: "f", Cost: 1})
			want++
		}
	}
	got := 0
	for {
		_, _, ok := s.Dequeue()
		if !ok {
			break
		}
		got++
	}
	if got != want {
		t.Fatalf("drained %d, want %d", got, want)
	}
}

// Finding usp-12/P1: lane scheduling must be byte-weighted, not item-count. With
// large bulk frames and small interactive frames at equal byte weight, the two
// lanes must receive a comparable BYTE share -- an item-count scheduler would let
// the 512 KiB bulk frames dominate the window.
func TestSchedulerByteFairAcrossFrameSizes(t *testing.T) {
	const bulkFrame = 512 * 1024
	const interactiveFrame = 1024
	s := NewScheduler(map[Lane]int{
		LaneSweepBulk:        bulkFrame, // equal byte weight
		LaneSweepInteractive: bulkFrame,
	}, 1<<20)

	// Deep backlogs on both lanes so neither empties during the measurement.
	for i := 0; i < 100000; i++ {
		s.Enqueue(LaneSweepBulk, Item{Flow: "sweep", Cost: bulkFrame})
		s.Enqueue(LaneSweepInteractive, Item{Flow: "adhoc", Cost: interactiveFrame})
	}

	var bulkBytes, interactiveBytes uint64
	for i := 0; i < 4000; i++ {
		lane, it, ok := s.Dequeue()
		if !ok {
			break
		}
		switch lane {
		case LaneSweepBulk:
			bulkBytes += it.Cost
		case LaneSweepInteractive:
			interactiveBytes += it.Cost
		}
	}
	if interactiveBytes == 0 || bulkBytes == 0 {
		t.Fatalf("a lane was starved: bulk=%d interactive=%d bytes", bulkBytes, interactiveBytes)
	}
	// Equal byte weight => comparable byte throughput (within 2x). An item-count
	// scheduler would give bulk ~512x the bytes.
	if bulkBytes > 2*interactiveBytes || interactiveBytes > 2*bulkBytes {
		t.Fatalf("byte share not fair: bulk=%d interactive=%d bytes", bulkBytes, interactiveBytes)
	}
}
