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

import (
	"errors"
	"fmt"
	"math"

	"google.golang.org/protobuf/reflect/protoreflect"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// LaneKey identifies a lane by the PLATFORM taxonomy: one (route profile,
// traffic class) pair.
//
// It deliberately carries nothing else. Payload family, sweep-vs-MTR, output
// contract, package, and plugin identity are all OUT: a package contract must not
// be able to allocate itself a lane or a traffic class, and a domain that gains a
// new record kind must not gain scheduler capacity with it. Sweep, MTR, inventory,
// and plugin traffic sharing one (profile, class) pair share exactly one lane.
type LaneKey struct {
	RouteProfile edgev1.EdgeRecordRouteProfile
	TrafficClass edgev1.EdgeRecordTrafficClass
}

func (k LaneKey) String() string {
	return fmt.Sprintf("%s/%s", k.RouteProfile, k.TrafficClass)
}

// declaredNonZero reports whether an enum value is a NON-ZERO member DECLARED by
// its generated descriptor.
//
// The check is generic over `protoreflect.Enum` rather than a switch, so a member
// added to the proto becomes acceptable through regeneration alone -- a scheduler
// switch would silently reject new ABI until someone remembered to extend it.
//
// Zero is excluded because UNSPECIFIED is the proto3 zero value: an unset field
// arrives looking like a legitimate enum, and treating it as a lane would pool
// unattested work with real traffic.
func declaredNonZero(e protoreflect.Enum) bool {
	if e.Number() == 0 {
		return false
	}

	return e.Descriptor().Values().ByNumber(e.Number()) != nil
}

// specified reports whether both halves of the key are declared, non-zero
// taxonomy values.
//
// Checking only `!= UNSPECIFIED` is insufficient: a Go enum is an int32, so an
// undeclared number such as RouteProfile(99) or TrafficClass(-1) is neither zero
// nor a real member. Admitting one would let a caller expand scheduler
// cardinality outside the finite ABI taxonomy, and -- when absent from the
// snapshot -- would misreport a malformed key as the RETRYABLE ErrLaneNotReady
// instead of the permanent ErrLaneInvalid.
func (k LaneKey) specified() bool {
	return declaredNonZero(k.RouteProfile) && declaredNonZero(k.TrafficClass)
}

// isRecoveryRoute reports whether the key uses the recovery-control route.
// Recovery is defined by ROUTE PROFILE, matching edgerecord.validateRecoveryLane;
// the traffic class is a deployment choice and is not fixed here.
func (k LaneKey) isRecoveryRoute() bool {
	return k.RouteProfile ==
		edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
}

// LanePolicy is the byte weight for one configured lane.
type LanePolicy struct {
	// Key is the (route profile, traffic class) pair this policy configures.
	Key LaneKey
	// WeightBytes is the number of BYTES the lane may emit per visit. It MUST be
	// positive and MUST NOT exceed math.MaxInt64: a zero or absent weight is a
	// configuration error, not a hint to invent a default, and the deficit
	// arithmetic is signed, so a weight above MaxInt64 wraps NEGATIVE when
	// credited and the lane can never satisfy `deficit > 0` -- Dequeue would spin
	// forever on a non-empty queue. The retired scheduler took a positive Go
	// `int`, which could not exceed MaxInt64; widening to uint64 introduced the
	// hazard, so the bound is enforced here.
	WeightBytes uint64
}

// LaneTaxonomy is an immutable snapshot of the lanes a deployment has ACTIVE or
// RETAINED, plus which one is the reserved recovery lane.
//
// It is supplied by the caller rather than derived here. The scheduler must not
// enumerate the Cartesian product of the protobuf enums: an ABI-known value is not
// necessarily deployment-active, and materializing every combination would create
// queues, weights, and ring slots for lanes no deployment routes. Equally it must
// not guess which pair is the recovery lane -- that mapping is a deployment fact,
// not something to infer from a traffic-class name.
//
// This slice owns the scheduler-facing abstraction only. Building a snapshot from
// a deployment route map is separate work; no platform taxonomy implementation
// exists yet.
type LaneTaxonomy struct {
	lanes    map[LaneKey]uint64
	order    []LaneKey
	recovery LaneKey
}

var (
	// ErrLaneInvalid marks a malformed or unspecified lane key. Permanent: the
	// caller's work is not attributable to any lane.
	ErrLaneInvalid = errors.New("fairsched: lane key is unspecified or malformed")
	// ErrLaneNotReady marks a well-formed lane absent from the active/retained
	// snapshot. NOT permanent: the pair may be valid ABI that this deployment has
	// not configured (or not configured yet), so the work is refused, never
	// dropped, aliased, or promoted into another lane.
	ErrLaneNotReady = errors.New("fairsched: lane is not in the active taxonomy")
	// ErrTaxonomyInvalid marks an unusable snapshot.
	ErrTaxonomyInvalid = errors.New("fairsched: invalid lane taxonomy")
)

// NewLaneTaxonomy builds an immutable snapshot from an explicit, finite lane list
// and the designated reserved recovery lane.
//
// Every lane needs an explicit positive weight, duplicates are rejected, and the
// recovery lane must itself be one of the configured lanes.
func NewLaneTaxonomy(policies []LanePolicy, recovery LaneKey) (*LaneTaxonomy, error) {
	if len(policies) == 0 {
		return nil, fmt.Errorf("%w: no lanes configured", ErrTaxonomyInvalid)
	}

	t := &LaneTaxonomy{
		lanes:    make(map[LaneKey]uint64, len(policies)),
		order:    make([]LaneKey, 0, len(policies)),
		recovery: recovery,
	}

	for _, p := range policies {
		if !p.Key.specified() {
			return nil, fmt.Errorf("%w: %s is unspecified", ErrTaxonomyInvalid, p.Key)
		}

		if p.WeightBytes == 0 {
			return nil, fmt.Errorf("%w: %s has no positive weight", ErrTaxonomyInvalid, p.Key)
		}

		if p.WeightBytes > math.MaxInt64 {
			return nil, fmt.Errorf("%w: %s weight %d exceeds MaxInt64 and would wrap the signed deficit",
				ErrTaxonomyInvalid, p.Key, p.WeightBytes)
		}

		if _, dup := t.lanes[p.Key]; dup {
			return nil, fmt.Errorf("%w: %s configured twice", ErrTaxonomyInvalid, p.Key)
		}

		t.lanes[p.Key] = p.WeightBytes
		t.order = append(t.order, p.Key)
	}

	if !recovery.specified() {
		return nil, fmt.Errorf("%w: recovery lane is unspecified", ErrTaxonomyInvalid)
	}

	// Recovery is defined by ROUTE PROFILE (edgerecord.validateRecoveryLane).
	// Designating a non-recovery route would leave the deployment with no usable
	// reserved recovery lane while appearing configured.
	if !recovery.isRecoveryRoute() {
		return nil, fmt.Errorf("%w: recovery lane %s must use RECOVERY_CONTROL_V1", ErrTaxonomyInvalid, recovery)
	}

	if _, ok := t.lanes[recovery]; !ok {
		return nil, fmt.Errorf("%w: recovery lane %s is not configured", ErrTaxonomyInvalid, recovery)
	}

	// Exactly ONE recovery lane. Two lanes on the recovery route with only one
	// designated would leave recovery traffic schedulable on an undesignated lane.
	for _, k := range t.order {
		if k.isRecoveryRoute() && k != recovery {
			return nil, fmt.Errorf("%w: %s also uses RECOVERY_CONTROL_V1; exactly one recovery lane is allowed",
				ErrTaxonomyInvalid, k)
		}
	}

	return t, nil
}

// Len reports how many lanes the snapshot configures.
func (t *LaneTaxonomy) Len() int { return len(t.order) }

// Lanes returns the configured lanes in configuration order.
func (t *LaneTaxonomy) Lanes() []LaneKey {
	out := make([]LaneKey, len(t.order))
	copy(out, t.order)

	return out
}

// RecoveryLane returns the designated reserved recovery lane.
func (t *LaneTaxonomy) RecoveryLane() LaneKey { return t.recovery }

// Scheduler interleaves work across the taxonomy's lanes with a byte-weighted
// deficit round-robin, so one large job cannot monopolize the result window: each
// lane accrues its weight in BYTES per visit and emits while its byte deficit
// stays positive. A lane of large (e.g. 512 KiB) frames is throttled to its byte
// share and cannot crowd out a lane of small interactive frames, which gives
// interactive and recovery lanes an unstarvable byte share even against an
// unbounded bulk backlog. Within a lane, a byte-fair DRR FairQueue shares the lane
// across scopes/agents/executions.
//
// Lane cardinality is fixed by the injected taxonomy at construction and can never
// grow from enqueue input. Not safe for concurrent use; wrap externally if shared.
type Scheduler struct {
	taxonomy *LaneTaxonomy
	lanes    map[LaneKey]*FairQueue
	weight   map[LaneKey]uint64
	deficit  map[LaneKey]int64
	inRing   map[LaneKey]bool
	ring     []LaneKey
	credited bool
}

// NewScheduler builds a scheduler over an immutable lane taxonomy. flowQuantum is
// the byte quantum of each lane's inner DRR queue.
func NewScheduler(taxonomy *LaneTaxonomy, flowQuantum uint64) (*Scheduler, error) {
	if taxonomy == nil || taxonomy.Len() == 0 {
		return nil, fmt.Errorf("%w: taxonomy is required", ErrTaxonomyInvalid)
	}

	s := &Scheduler{
		taxonomy: taxonomy,
		lanes:    make(map[LaneKey]*FairQueue, taxonomy.Len()),
		weight:   make(map[LaneKey]uint64, taxonomy.Len()),
		deficit:  make(map[LaneKey]int64, taxonomy.Len()),
		inRing:   make(map[LaneKey]bool, taxonomy.Len()),
	}

	for _, k := range taxonomy.order {
		s.lanes[k] = NewFairQueue(flowQuantum)
		s.weight[k] = taxonomy.lanes[k]
	}

	return s, nil
}

// Enqueue places an item on the lane identified by key.
//
// It returns ErrLaneInvalid for an unspecified or malformed key, and
// ErrLaneNotReady for a well-formed pair this deployment has not configured. It
// never silently drops the item, aliases it onto a neighbouring lane, or promotes
// it into a faster one: an unroutable item is REFUSED so the caller retains it.
func (s *Scheduler) Enqueue(key LaneKey, it Item) error {
	if !key.specified() {
		return fmt.Errorf("%w: %s", ErrLaneInvalid, key)
	}

	q, ok := s.lanes[key]
	if !ok {
		return fmt.Errorf("%w: %s", ErrLaneNotReady, key)
	}

	q.Enqueue(it)

	if !s.inRing[key] {
		s.ring = append(s.ring, key)
		s.inRing[key] = true
	}

	return nil
}

// Dequeue returns the next (lane, item) under byte-weighted lane deficit
// round-robin plus per-flow DRR within the chosen lane. A lane is credited its
// byte weight once per visit and emits while its deficit stays positive; emitting
// a large item drives the deficit negative, throttling that lane over the
// following visits so other lanes get their byte share. ok is false only when
// every lane is empty.
func (s *Scheduler) Dequeue() (LaneKey, Item, bool) {
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

	return LaneKey{}, Item{}, false
}

// Len reports total queued items across all lanes.
func (s *Scheduler) Len() int {
	n := 0
	for _, q := range s.lanes {
		n += q.Len()
	}

	return n
}

// LaneCount reports the scheduler's lane cardinality, which equals the injected
// taxonomy and never changes.
func (s *Scheduler) LaneCount() int { return len(s.lanes) }

// RecoveryLane returns the taxonomy's designated reserved recovery lane.
func (s *Scheduler) RecoveryLane() LaneKey { return s.taxonomy.RecoveryLane() }

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
