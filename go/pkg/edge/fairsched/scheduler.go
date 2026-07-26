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

// Lane is a scheduler-attested traffic-class lane. An item's lane is fixed by
// the scheduler at enqueue from the attested class, so a caller cannot promote
// its own work into a faster lane.
type Lane uint8

const (
	// LaneSweepBulk carries large scheduled/sweep-profile sweep result traffic.
	LaneSweepBulk Lane = iota
	// LaneSweepInteractive carries ad-hoc/on-demand sweep traffic.
	LaneSweepInteractive
	// LaneMtrBulk carries scheduled/sweep-profile MTR trace traffic.
	LaneMtrBulk
	// LaneMtrInteractive carries ad-hoc/on-demand MTR trace traffic.
	LaneMtrInteractive
	// LaneRecovery carries loss-manifest/rollover/control traffic.
	LaneRecovery
	numLanes = iota
)

// Scheduler interleaves work across independent traffic-class lanes with a
// byte-weighted deficit round-robin so one large sweep or MTR job cannot
// monopolize the result window: each lane accrues its weight in BYTES per visit
// and emits items while its byte deficit remains positive, so a lane of large
// (e.g. 512 KiB) frames is throttled to its byte share and cannot crowd out a
// lane of small interactive frames. This gives interactive and recovery lanes an
// unstarvable byte share even against an unbounded bulk backlog. Within a lane, a
// byte-fair DRR FairQueue shares the lane fairly across scopes/agents/executions.
// Not safe for concurrent use; wrap externally if shared.
type Scheduler struct {
	lanes    [numLanes]*FairQueue
	weight   [numLanes]uint64 // byte quantum credited per visit
	deficit  [numLanes]int64  // signed byte deficit; may go negative after a large item
	ring     []Lane
	inRing   [numLanes]bool
	credited bool // whether the front lane has been credited this visit
}

// NewScheduler builds a scheduler. weights maps a lane to the number of BYTES it
// may emit per visit (its guaranteed byte share); any lane absent from weights
// defaults to 1. flowQuantum is the byte quantum of each lane's inner DRR queue.
func NewScheduler(weights map[Lane]int, flowQuantum uint64) *Scheduler {
	s := &Scheduler{}
	for l := Lane(0); l < numLanes; l++ {
		s.lanes[l] = NewFairQueue(flowQuantum)
		w := uint64(1)
		if wv, ok := weights[l]; ok && wv > 0 {
			w = uint64(wv)
		}
		s.weight[l] = w
	}
	return s
}

// Enqueue places an item on the attested lane's inner fair queue, activating the
// lane in the round-robin ring if it was idle.
func (s *Scheduler) Enqueue(lane Lane, it Item) {
	if lane >= numLanes {
		return
	}
	q := s.lanes[lane]
	q.Enqueue(it)
	if !s.inRing[lane] {
		s.ring = append(s.ring, lane)
		s.inRing[lane] = true
	}
}

// Dequeue returns the next (lane, item) under byte-weighted lane deficit
// round-robin plus per-flow DRR within the chosen lane. A lane is credited its
// byte weight once per visit and emits items while its deficit stays positive;
// emitting a large item drives the deficit negative, throttling that lane over
// the following visits so other lanes get their byte share. ok is false only
// when every lane is empty.
func (s *Scheduler) Dequeue() (Lane, Item, bool) {
	for len(s.ring) > 0 {
		lane := s.ring[0]
		q := s.lanes[lane]
		if q.Len() == 0 {
			s.dropFront()
			continue
		}
		if !s.credited {
			s.deficit[lane] += int64(s.weight[lane])
			s.credited = true
		}
		if s.deficit[lane] <= 0 {
			// Byte budget spent for this visit: yield to the next lane.
			s.rotate()
			s.credited = false
			continue
		}
		it, _ := q.Dequeue()
		s.deficit[lane] -= int64(it.Cost)
		if q.Len() == 0 {
			s.dropFront()
		}
		return lane, it, true
	}
	return 0, Item{}, false
}

// Len reports total queued items across all lanes.
func (s *Scheduler) Len() int {
	n := 0
	for l := Lane(0); l < numLanes; l++ {
		n += s.lanes[l].Len()
	}
	return n
}

func (s *Scheduler) dropFront() {
	lane := s.ring[0]
	s.ring = s.ring[1:]
	s.inRing[lane] = false
	s.deficit[lane] = 0 // a re-fed lane starts fresh, not penalized by an old deficit
	s.credited = false
}

func (s *Scheduler) rotate() {
	if len(s.ring) <= 1 {
		return
	}
	front := s.ring[0]
	s.ring = append(s.ring[1:], front)
}
