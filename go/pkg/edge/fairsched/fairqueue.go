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

// Package fairsched provides byte-fair interleaving across competing flows
// (network/site scopes, agents, executions) and across scheduler-attested
// traffic-class lanes. Its FairQueue is a deficit round-robin (DRR) queue so a
// single large sweep or MTR execution cannot monopolize the shared result
// window; its Scheduler layers weighted lanes with an unborrowable interactive
// share on top, and fixes an item's lane at enqueue so a caller cannot promote
// its own work. This is the decision core of task 2.7; it holds no I/O.
package fairsched

// Item is one unit of work competing for the result window.
type Item struct {
	// Flow identifies the fairness bucket -- typically a scope|agent|execution
	// key. Items with the same Flow share one FIFO sub-queue and one deficit.
	Flow string
	// Cost is the bytes (or sender credits) this item consumes; DRR shares Cost
	// fairly across flows.
	Cost uint64
	// Value is the opaque payload handed back on dequeue.
	Value any
}

type flowState struct {
	deficit uint64
	items   []Item
}

// FairQueue is a deficit round-robin queue: every active flow accrues one
// quantum of deficit per service turn and may dequeue head items whose cost fits
// its accumulated deficit. Flows with large items are throttled to their fair
// share rather than blocking small items behind them. Not safe for concurrent
// use; wrap externally if shared.
type FairQueue struct {
	quantum uint64
	flows   map[string]*flowState
	ring    []string // active flows in round-robin order
	length  int
	// frontCredited records that the current front flow has already been credited
	// one quantum for this visit, so a flow drains multiple affordable head items
	// in one visit (byte-fair) instead of one item per full ring cycle.
	frontCredited bool
}

// NewFairQueue creates a queue whose per-turn quantum is the given byte budget.
// A quantum near the typical item cost keeps latency low while preserving
// fairness; a zero quantum is promoted to 1 so progress is always possible.
func NewFairQueue(quantum uint64) *FairQueue {
	if quantum == 0 {
		quantum = 1
	}
	return &FairQueue{quantum: quantum, flows: make(map[string]*flowState)}
}

// Len reports the number of queued items across all flows.
func (q *FairQueue) Len() int { return q.length }

// Enqueue appends an item to its flow's FIFO sub-queue, registering the flow in
// the round-robin ring if it is newly active.
func (q *FairQueue) Enqueue(it Item) {
	fs, ok := q.flows[it.Flow]
	if !ok {
		fs = &flowState{}
		q.flows[it.Flow] = fs
		q.ring = append(q.ring, it.Flow)
	}
	fs.items = append(fs.items, it)
	q.length++
}

// Dequeue returns the next item under DRR fairness. It advances the ring,
// crediting each visited flow one quantum, until a flow's head item fits its
// deficit. Returns ok=false only when the queue is empty.
func (q *FairQueue) Dequeue() (Item, bool) {
	if q.length == 0 {
		return Item{}, false
	}
	for {
		flow := q.ring[0]
		fs := q.flows[flow]
		if len(fs.items) == 0 {
			// Flow drained: drop it (and its residual deficit) from the ring.
			q.ring = q.ring[1:]
			delete(q.flows, flow)
			q.frontCredited = false
			continue
		}
		if !q.frontCredited {
			fs.deficit += q.quantum
			q.frontCredited = true
		}
		head := fs.items[0]
		if head.Cost <= fs.deficit {
			fs.deficit -= head.Cost
			fs.items = fs.items[1:]
			q.length--
			if len(fs.items) == 0 {
				// Emptied: remove now so its residual deficit does not persist.
				q.ring = q.ring[1:]
				delete(q.flows, flow)
				q.frontCredited = false
			}
			// Otherwise stay on this flow so it can spend the rest of its deficit
			// on subsequent affordable head items within the same visit.
			return head, true
		}
		// Head too large for this visit's deficit: carry the deficit forward and
		// rotate so other flows make progress. The deficit accrues each time this
		// flow returns to the front until it can afford the large item.
		q.rotate()
		q.frontCredited = false
	}
}

// rotate moves the front flow to the back of the ring.
func (q *FairQueue) rotate() {
	if len(q.ring) <= 1 {
		return
	}
	front := q.ring[0]
	q.ring = append(q.ring[1:], front)
}
