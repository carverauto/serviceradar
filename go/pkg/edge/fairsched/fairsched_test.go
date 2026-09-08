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
