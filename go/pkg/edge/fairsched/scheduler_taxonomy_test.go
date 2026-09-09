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
	"math"
	"strings"
	"testing"
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const (
	profileDurable    = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1
	profileContinuous = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1
	profileRecovery   = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
	profileUnset      = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_UNSPECIFIED

	classBulk        = edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK
	classInteractive = edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE
	classUnset       = edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED
)

func lane(p edgev1.EdgeRecordRouteProfile, c edgev1.EdgeRecordTrafficClass) LaneKey {
	return LaneKey{RouteProfile: p, TrafficClass: c}
}

// mustTaxonomy builds a snapshot resembling a plausible deployment: durable
// records in both classes, plus the reserved recovery lane.
func mustTaxonomy(t *testing.T, extra ...LanePolicy) *LaneTaxonomy {
	t.Helper()

	recovery := lane(profileRecovery, classInteractive)
	policies := append([]LanePolicy{
		{Key: lane(profileDurable, classBulk), WeightBytes: 4},
		{Key: lane(profileDurable, classInteractive), WeightBytes: 1},
		{Key: recovery, WeightBytes: 8},
	}, extra...)

	tax, err := NewLaneTaxonomy(policies, recovery)
	if err != nil {
		t.Fatalf("NewLaneTaxonomy: %v", err)
	}

	return tax
}

func mustScheduler(t *testing.T, tax *LaneTaxonomy, flowQuantum uint64) *Scheduler {
	t.Helper()

	s, err := NewScheduler(tax, flowQuantum)
	if err != nil {
		t.Fatalf("NewScheduler: %v", err)
	}

	return s
}

func mustEnqueue(t *testing.T, s *Scheduler, k LaneKey, it Item) {
	t.Helper()

	if err := s.Enqueue(k, it); err != nil {
		t.Fatalf("Enqueue(%s): %v", k, err)
	}
}

// A lane the OLD scheduler had no enum for must schedule normally once the
// deployment configures it. This is the whole point of the correction: capacity
// comes from the taxonomy, not from a hardcoded list of five semantic lanes.
func TestTaxonomyAcceptsLaneUnknownToTheOldScheduler(t *testing.T) {
	continuousBulk := lane(profileContinuous, classBulk)
	tax := mustTaxonomy(t, LanePolicy{Key: continuousBulk, WeightBytes: 4})
	s := mustScheduler(t, tax, 1<<10)

	for range 10 {
		mustEnqueue(t, s, continuousBulk, Item{Flow: "continuous", Cost: 1})
	}

	got := 0

	for range 10 {
		k, _, ok := s.Dequeue()
		if !ok {
			break
		}

		if k == continuousBulk {
			got++
		}
	}

	if got != 10 {
		t.Fatalf("CONTINUOUS_V/BULK scheduled %d/10; a taxonomy lane must schedule unchanged", got)
	}
}

// An ABI-valid pair the deployment has NOT configured is refused as not-ready --
// never dropped, aliased onto a neighbour, or promoted.
func TestUnconfiguredLaneIsNotReadyAndDoesNotQueue(t *testing.T) {
	s := mustScheduler(t, mustTaxonomy(t), 1<<10)
	before := s.Len()

	err := s.Enqueue(lane(profileContinuous, classBulk), Item{Flow: "f", Cost: 1})
	if !errors.Is(err, ErrLaneNotReady) {
		t.Fatalf("err = %v, want ErrLaneNotReady", err)
	}

	if s.Len() != before {
		t.Fatalf("queue length changed from %d to %d on a refused enqueue", before, s.Len())
	}

	if _, _, ok := s.Dequeue(); ok {
		t.Fatal("a refused item must not become schedulable")
	}
}

// UNSPECIFIED is the proto3 zero value, so an unset field must not be mistaken
// for a real lane.
func TestUnspecifiedLaneIsInvalid(t *testing.T) {
	s := mustScheduler(t, mustTaxonomy(t), 1<<10)

	for _, k := range []LaneKey{
		lane(profileUnset, classBulk),
		lane(profileDurable, classUnset),
		lane(profileUnset, classUnset),
		{},
	} {
		err := s.Enqueue(k, Item{Flow: "f", Cost: 1})
		if !errors.Is(err, ErrLaneInvalid) {
			t.Fatalf("Enqueue(%s) err = %v, want ErrLaneInvalid", k, err)
		}
	}

	if s.Len() != 0 {
		t.Fatalf("invalid enqueues queued %d items", s.Len())
	}
}

func TestTaxonomyRejectsBadConfiguration(t *testing.T) {
	recovery := lane(profileRecovery, classInteractive)
	good := LanePolicy{Key: recovery, WeightBytes: 8}

	cases := map[string]struct {
		policies []LanePolicy
		recovery LaneKey
	}{
		"no lanes":            {nil, recovery},
		"zero weight":         {[]LanePolicy{{Key: recovery, WeightBytes: 0}}, recovery},
		"unspecified lane":    {[]LanePolicy{{Key: lane(profileUnset, classBulk), WeightBytes: 1}}, recovery},
		"duplicate lane":      {[]LanePolicy{good, good}, recovery},
		"unspecified recover": {[]LanePolicy{good}, LaneKey{}},
		"recovery not configured": {
			[]LanePolicy{{Key: lane(profileDurable, classBulk), WeightBytes: 1}},
			recovery,
		},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := NewLaneTaxonomy(tc.policies, tc.recovery); !errors.Is(err, ErrTaxonomyInvalid) {
				t.Fatalf("err = %v, want ErrTaxonomyInvalid", err)
			}
		})
	}
}

// Sweep, MTR, inventory, and plugin traffic sharing one (profile, class) pair
// share exactly ONE lane. Domain identity is not part of the lane key, so a new
// record kind cannot mint scheduler capacity.
func TestDomainsShareOneLaneAndCreateNone(t *testing.T) {
	tax := mustTaxonomy(t)
	s := mustScheduler(t, tax, 1<<10)
	bulk := lane(profileDurable, classBulk)

	for _, flow := range []string{"sweep", "mtr", "inventory", "plugin"} {
		mustEnqueue(t, s, bulk, Item{Flow: flow, Cost: 1})
	}

	if s.LaneCount() != tax.Len() {
		t.Fatalf("LaneCount=%d, want %d: enqueue must not create lanes", s.LaneCount(), tax.Len())
	}

	seen := 0

	for range 4 {
		k, _, ok := s.Dequeue()
		if !ok {
			break
		}

		if k != bulk {
			t.Fatalf("item emitted on %s, want the single shared lane %s", k, bulk)
		}

		seen++
	}

	if seen != 4 {
		t.Fatalf("drained %d/4 from the shared lane", seen)
	}
}

// The two halves of the key are independent: same profile with a different class,
// and same class with a different profile, are distinct lanes.
func TestLaneKeyHalvesAreIndependent(t *testing.T) {
	sameProfile := mustTaxonomy(t)
	if sameProfile.Len() != 3 {
		t.Fatalf("taxonomy Len=%d, want 3", sameProfile.Len())
	}

	a := lane(profileDurable, classBulk)
	b := lane(profileDurable, classInteractive) // same profile, different class
	c := lane(profileContinuous, classBulk)     // same class, different profile

	if a == b || a == c || b == c {
		t.Fatal("lane keys collapsed; both halves must contribute to identity")
	}

	// The designated recovery lane must use RECOVERY_CONTROL_V1, so it is added
	// alongside rather than borrowing one of the three keys under test.
	recovery := lane(profileRecovery, classInteractive)

	tax, err := NewLaneTaxonomy([]LanePolicy{
		{Key: a, WeightBytes: 1},
		{Key: b, WeightBytes: 1},
		{Key: c, WeightBytes: 1},
		{Key: recovery, WeightBytes: 1},
	}, recovery)
	if err != nil {
		t.Fatalf("NewLaneTaxonomy: %v", err)
	}

	if tax.Len() != 4 {
		t.Fatalf("Len=%d, want 4 distinct lanes", tax.Len())
	}
}

// Lane cardinality is fixed by the taxonomy and cannot grow from enqueue input,
// including refused input.
func TestLaneCardinalityIsFixedByTaxonomy(t *testing.T) {
	tax := mustTaxonomy(t)
	s := mustScheduler(t, tax, 1<<10)

	_ = s.Enqueue(lane(profileContinuous, classInteractive), Item{Flow: "f", Cost: 1})
	_ = s.Enqueue(lane(profileUnset, classUnset), Item{Flow: "f", Cost: 1})
	mustEnqueue(t, s, lane(profileDurable, classBulk), Item{Flow: "f", Cost: 1})

	if s.LaneCount() != tax.Len() {
		t.Fatalf("LaneCount=%d after mixed enqueues, want %d", s.LaneCount(), tax.Len())
	}
}

// The reserved recovery lane is DESIGNATED by the deployment, not inferred from a
// traffic-class name.
func TestRecoveryLaneIsExplicitlyDesignated(t *testing.T) {
	tax := mustTaxonomy(t)
	s := mustScheduler(t, tax, 1<<10)

	want := lane(profileRecovery, classInteractive)
	if s.RecoveryLane() != want {
		t.Fatalf("RecoveryLane=%s, want %s", s.RecoveryLane(), want)
	}
}

// Interactive AND the explicit recovery lane both keep progressing against an
// unbounded bulk backlog.
func TestInteractiveAndRecoveryProgressUnderBulkBacklog(t *testing.T) {
	tax := mustTaxonomy(t)
	s := mustScheduler(t, tax, 1<<10)

	bulk := lane(profileDurable, classBulk)
	interactive := lane(profileDurable, classInteractive)
	recovery := tax.RecoveryLane()

	for range 1000 {
		mustEnqueue(t, s, bulk, Item{Flow: "huge-sweep", Cost: 1})
	}

	for range 50 {
		mustEnqueue(t, s, interactive, Item{Flow: "adhoc", Cost: 1})
	}

	for range 16 {
		mustEnqueue(t, s, recovery, Item{Flow: "loss-manifest", Cost: 1})
	}

	var gotInteractive, gotRecovery int

	for range 100 {
		k, _, ok := s.Dequeue()
		if !ok {
			break
		}

		switch k {
		case interactive:
			gotInteractive++
		case recovery:
			gotRecovery++
		}
	}

	if gotInteractive < 10 {
		t.Fatalf("interactive served %d/100 under bulk backlog, want an unstarved share", gotInteractive)
	}

	if gotRecovery < 16 {
		t.Fatalf("recovery drained %d/16 in the first 100 dequeues, want all promptly", gotRecovery)
	}
}

func TestSchedulerDrainsEveryConfiguredLane(t *testing.T) {
	tax := mustTaxonomy(t, LanePolicy{Key: lane(profileContinuous, classBulk), WeightBytes: 2})
	s := mustScheduler(t, tax, 1<<10)

	want := 0

	for _, k := range tax.Lanes() {
		for range 10 {
			mustEnqueue(t, s, k, Item{Flow: "f", Cost: 1})

			want++
		}
	}

	got := 0

	for {
		if _, _, ok := s.Dequeue(); !ok {
			break
		}

		got++
	}

	if got != want {
		t.Fatalf("drained %d, want %d", got, want)
	}
}

// Preserved from the retired scheduler (finding usp-12/P1): lane scheduling must
// be byte-weighted, not item-count. With large bulk frames and small interactive
// frames at EQUAL byte weight, both lanes must receive a comparable BYTE share --
// an item-count scheduler would let 512 KiB frames dominate the window.
func TestSchedulerByteFairAcrossFrameSizes(t *testing.T) {
	const (
		bulkFrame        = 512 * 1024
		interactiveFrame = 1024
	)

	bulk := lane(profileDurable, classBulk)
	interactive := lane(profileDurable, classInteractive)
	recovery := lane(profileRecovery, classInteractive)

	tax, err := NewLaneTaxonomy([]LanePolicy{
		{Key: bulk, WeightBytes: bulkFrame}, // equal byte weight
		{Key: interactive, WeightBytes: bulkFrame},
		{Key: recovery, WeightBytes: bulkFrame},
	}, recovery)
	if err != nil {
		t.Fatalf("NewLaneTaxonomy: %v", err)
	}

	s := mustScheduler(t, tax, 1<<20)

	// Deep backlogs on both lanes so neither empties during the measurement.
	for range 100000 {
		mustEnqueue(t, s, bulk, Item{Flow: "sweep", Cost: bulkFrame})
		mustEnqueue(t, s, interactive, Item{Flow: "adhoc", Cost: interactiveFrame})
	}

	var bulkBytes, interactiveBytes uint64

	for range 4000 {
		k, it, ok := s.Dequeue()
		if !ok {
			break
		}

		switch k {
		case bulk:
			bulkBytes += it.Cost
		case interactive:
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

// --- review fixes for #4735 -------------------------------------------------

// A Go enum is an int32, so an UNDECLARED number is neither zero nor a real
// member. It must be permanently invalid at BOTH construction and enqueue, and
// must never expand scheduler cardinality.
func TestUndeclaredEnumNumbersAreInvalid(t *testing.T) {
	undeclared := []LaneKey{
		{RouteProfile: edgev1.EdgeRecordRouteProfile(99), TrafficClass: classBulk},
		{RouteProfile: profileDurable, TrafficClass: edgev1.EdgeRecordTrafficClass(99)},
		{RouteProfile: edgev1.EdgeRecordRouteProfile(-1), TrafficClass: classBulk},
		{RouteProfile: profileDurable, TrafficClass: edgev1.EdgeRecordTrafficClass(-1)},
		{RouteProfile: edgev1.EdgeRecordRouteProfile(99), TrafficClass: edgev1.EdgeRecordTrafficClass(-1)},
	}

	recovery := lane(profileRecovery, classInteractive)
	recoveryPolicy := LanePolicy{Key: recovery, WeightBytes: 1}

	// CONTROL: the surrounding configuration must be VALID on its own, so a
	// rejection below can only be caused by the undeclared key. Without this the
	// assertions pass vacuously -- an unconfigured recovery lane is itself
	// ErrTaxonomyInvalid, which would mask an undeclared key being accepted.
	if _, err := NewLaneTaxonomy([]LanePolicy{recoveryPolicy}, recovery); err != nil {
		t.Fatalf("control taxonomy must be valid, got %v", err)
	}

	for _, k := range undeclared {
		_, err := NewLaneTaxonomy([]LanePolicy{recoveryPolicy, {Key: k, WeightBytes: 1}}, recovery)
		if !errors.Is(err, ErrTaxonomyInvalid) {
			t.Fatalf("NewLaneTaxonomy(valid recovery + %s) err = %v, want ErrTaxonomyInvalid", k, err)
		}

		// The rejection must name the undeclared key, not some unrelated defect.
		if !strings.Contains(err.Error(), k.String()) {
			t.Fatalf("rejection for %s did not name it: %v", k, err)
		}
	}

	tax := mustTaxonomy(t)
	s := mustScheduler(t, tax, 1<<10)

	for _, k := range undeclared {
		// Permanent ErrLaneInvalid, NOT the retryable ErrLaneNotReady: a malformed
		// key can never become routable by configuring the deployment.
		if err := s.Enqueue(k, Item{Flow: "f", Cost: 1}); !errors.Is(err, ErrLaneInvalid) {
			t.Fatalf("Enqueue(%s) err = %v, want ErrLaneInvalid", k, err)
		}
	}

	if s.LaneCount() != tax.Len() || s.Len() != 0 {
		t.Fatalf("undeclared keys altered the scheduler: lanes=%d items=%d", s.LaneCount(), s.Len())
	}
}

// A DECLARED but unconfigured pair stays retryable -- the distinction the
// previous implementation collapsed.
func TestDeclaredButUnconfiguredStaysNotReady(t *testing.T) {
	s := mustScheduler(t, mustTaxonomy(t), 1<<10)

	err := s.Enqueue(lane(profileContinuous, classBulk), Item{Flow: "f", Cost: 1})
	if !errors.Is(err, ErrLaneNotReady) {
		t.Fatalf("CONTINUOUS_V1/BULK err = %v, want ErrLaneNotReady", err)
	}
}

// Recovery is defined by ROUTE PROFILE, matching edgerecord.validateRecoveryLane.
func TestRecoveryLaneMustUseRecoveryRoute(t *testing.T) {
	notRecovery := lane(profileDurable, classBulk)

	_, err := NewLaneTaxonomy([]LanePolicy{{Key: notRecovery, WeightBytes: 1}}, notRecovery)
	if !errors.Is(err, ErrTaxonomyInvalid) {
		t.Fatalf("designating DURABLE_RECORDS_V1/BULK as recovery: err = %v, want ErrTaxonomyInvalid", err)
	}
}

// Exactly one lane may use the recovery route; two would leave recovery traffic
// schedulable on an undesignated lane.
func TestOnlyOneRecoveryRouteLaneAllowed(t *testing.T) {
	bulkRecovery := lane(profileRecovery, classBulk)
	interactiveRecovery := lane(profileRecovery, classInteractive)

	_, err := NewLaneTaxonomy([]LanePolicy{
		{Key: bulkRecovery, WeightBytes: 1},
		{Key: interactiveRecovery, WeightBytes: 1},
	}, interactiveRecovery)
	if !errors.Is(err, ErrTaxonomyInvalid) {
		t.Fatalf("two RECOVERY_CONTROL_V1 lanes: err = %v, want ErrTaxonomyInvalid", err)
	}
}

// The traffic class of the recovery lane stays a deployment choice.
func TestRecoveryTrafficClassRemainsInjected(t *testing.T) {
	for _, class := range []edgev1.EdgeRecordTrafficClass{classBulk, classInteractive} {
		recovery := lane(profileRecovery, class)

		tax, err := NewLaneTaxonomy([]LanePolicy{{Key: recovery, WeightBytes: 1}}, recovery)
		if err != nil {
			t.Fatalf("recovery with class %s rejected: %v", class, err)
		}

		if tax.RecoveryLane() != recovery {
			t.Fatalf("RecoveryLane=%s, want %s", tax.RecoveryLane(), recovery)
		}
	}
}

// The deficit is signed, so a weight above MaxInt64 wraps negative when credited
// and the lane can never satisfy `deficit > 0`.
func TestWeightAboveMaxInt64IsRejected(t *testing.T) {
	recovery := lane(profileRecovery, classInteractive)

	if _, err := NewLaneTaxonomy([]LanePolicy{{Key: recovery, WeightBytes: math.MaxInt64}}, recovery); err != nil {
		t.Fatalf("MaxInt64 weight must be accepted: %v", err)
	}

	for _, w := range []uint64{uint64(math.MaxInt64) + 1, 1 << 63, math.MaxUint64} {
		if _, err := NewLaneTaxonomy([]LanePolicy{{Key: recovery, WeightBytes: w}}, recovery); !errors.Is(err, ErrTaxonomyInvalid) {
			t.Fatalf("weight %d: err = %v, want ErrTaxonomyInvalid", w, err)
		}
	}
}

// Bounded progress: with the maximum ACCEPTED weight, Dequeue must still return.
func TestDequeueTerminatesAtMaximumWeight(t *testing.T) {
	recovery := lane(profileRecovery, classInteractive)

	tax, err := NewLaneTaxonomy([]LanePolicy{{Key: recovery, WeightBytes: math.MaxInt64}}, recovery)
	if err != nil {
		t.Fatalf("NewLaneTaxonomy: %v", err)
	}

	s := mustScheduler(t, tax, 1<<10)
	mustEnqueue(t, s, recovery, Item{Flow: "f", Cost: 1})

	done := make(chan struct{})

	go func() {
		defer close(done)

		if _, _, ok := s.Dequeue(); !ok {
			t.Error("Dequeue reported empty with one item queued")
		}
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Dequeue did not terminate at the maximum accepted weight")
	}
}
