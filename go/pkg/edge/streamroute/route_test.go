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

package streamroute

import (
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func TestPartitionDeterministicAndInRange(t *testing.T) {
	key := []byte("network-scope-01")
	p := Partition(key)
	if p >= NumPartitions {
		t.Fatalf("partition %d out of range", p)
	}
	if p2 := Partition(key); p2 != p {
		t.Fatalf("partition not deterministic: %d != %d", p, p2)
	}
	if Partition(nil) != 0 {
		t.Fatal("empty key must map to partition 0")
	}
}

func TestPartitionSpreadsAcrossSpace(t *testing.T) {
	seen := map[uint32]int{}
	for i := 0; i < 10000; i++ {
		key := []byte{byte(i), byte(i >> 8), byte(i >> 16), 0x5a}
		seen[Partition(key)]++
	}
	// A healthy hash should touch a large share of the 64 partitions.
	if len(seen) < NumPartitions/2 {
		t.Fatalf("partition spread too narrow: only %d of %d partitions used", len(seen), NumPartitions)
	}
}

// The (lane, partition) -> data subject map must be complete over routable lanes
// and non-overlapping: no two distinct (lane, partition) pairs share a subject,
// and no data subject collides with a DLQ subject.
func TestSubjectMapCompleteAndNonOverlapping(t *testing.T) {
	seen := map[string]string{} // subject -> owner tag
	claim := func(subj, owner string) {
		if prev, ok := seen[subj]; ok {
			t.Fatalf("subject %q claimed by both %q and %q", subj, prev, owner)
		}
		seen[subj] = owner
	}
	for _, lane := range RoutableLanes() {
		for p := uint32(0); p < NumPartitions; p++ {
			ds, err := DataSubject(lane, p)
			if err != nil {
				t.Fatalf("data subject lane=%v p=%d: %v", lane, p, err)
			}
			claim(ds, "data")
			dl, err := DLQSubject(lane, p)
			if err != nil {
				t.Fatalf("dlq subject lane=%v p=%d: %v", lane, p, err)
			}
			claim(dl, "dlq")
		}
	}
	// 5 lanes * 64 partitions * 2 (data + dlq) = 640 distinct subjects.
	if len(seen) != len(RoutableLanes())*NumPartitions*2 {
		t.Fatalf("subject count = %d, want %d", len(seen), len(RoutableLanes())*NumPartitions*2)
	}
}

// Bulk and interactive lanes (and sweep vs MTR) must resolve to disjoint
// physical streams so they never share capacity, and DLQ streams are distinct
// from data streams.
func TestPhysicalStreamsDisjoint(t *testing.T) {
	streams := map[string]bool{}
	for _, lane := range RoutableLanes() {
		s, err := PhysicalStream(lane)
		if err != nil {
			t.Fatalf("stream lane=%v: %v", lane, err)
		}
		if streams[s] {
			t.Fatalf("physical stream %q shared by two lanes", s)
		}
		streams[s] = true
	}
	for _, lane := range RoutableLanes() {
		d, err := PhysicalDLQStream(lane)
		if err != nil {
			t.Fatalf("dlq stream lane=%v: %v", lane, err)
		}
		if streams[d] {
			t.Fatalf("DLQ stream %q collides with a data stream", d)
		}
		streams[d] = true
	}
	// Sweep-bulk and sweep-interactive must be different streams.
	sb, _ := PhysicalStream(edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_BULK)
	si, _ := PhysicalStream(edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_INTERACTIVE)
	if sb == si {
		t.Fatal("bulk and interactive must not share a physical stream")
	}
}

func TestUnroutableLaneRejected(t *testing.T) {
	if _, err := DataSubject(edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_UNSPECIFIED, 0); err != ErrUnroutableLane {
		t.Fatalf("unspecified lane = %v, want ErrUnroutableLane", err)
	}
	if _, err := DataSubject(edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_BULK, NumPartitions); err == nil {
		t.Fatal("out-of-range partition must error")
	}
}

func TestSubjectFormatStableAndVersioned(t *testing.T) {
	s, err := DataSubject(edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_BULK, 7)
	if err != nil {
		t.Fatalf("subject: %v", err)
	}
	if s != "sr.edge.v1.sweep.bulk.p07.v1" {
		t.Fatalf("unexpected subject %q", s)
	}
}
