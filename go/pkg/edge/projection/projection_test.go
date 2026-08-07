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

package projection

import (
	"bytes"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func TestCanonicalMicrosFloors(t *testing.T) {
	cases := []struct {
		ns   int64
		want int64
	}{
		{0, 0},
		{999, 0},
		{1000, 1},
		{1999, 1},
		{1_720_000_000_123_456, 1_720_000_000_123},
		{-1, -1},    // floor(-0.001us) = -1
		{-1000, -1}, // exactly -1us
		{-1500, -2}, // floor
	}
	for _, c := range cases {
		if got := CanonicalMicros(c.ns); got != c.want {
			t.Fatalf("CanonicalMicros(%d) = %d, want %d", c.ns, got, c.want)
		}
	}
}

// Two timestamps in the same microsecond must canonicalize to the same PROJECTION-DOMAIN
// coordinate. That collapse is deliberate and applies only there: CONTRACT identity and the two
// contract hashes keep the raw nanoseconds and must still tell these two instants apart.
func TestCanonicalMicrosStableWithinMicrosecond(t *testing.T) {
	base := int64(1_720_000_000_000_000)
	if CanonicalMicros(base) != CanonicalMicros(base+999) {
		t.Fatal("timestamps within one microsecond must canonicalize equally")
	}
	if CanonicalMicros(base) == CanonicalMicros(base+1000) {
		t.Fatal("timestamps one microsecond apart must differ")
	}
}

func TestSweepRowsCountsEveryProjection(t *testing.T) {
	h := &edgev1.SweepHostObservationV1{
		OpenPorts:  []*edgev1.SweepOpenPortV1{{}, {}, {}},
		PortErrors: []*edgev1.SweepPortErrorV1{{}, {}},
		Mtr:        &edgev1.SweepMtrSummaryV1{},
	}
	// 1 reachability + 3 open ports + 2 port errors + 1 mtr summary = 7.
	if got := SweepHostRows(h); got != 7 {
		t.Fatalf("SweepHostRows = %d, want 7", got)
	}
	batch := &edgev1.SweepObservationBatchV1{Hosts: []*edgev1.SweepHostObservationV1{
		h,
		{}, // a bare host = 1 reachability row
	}}
	if got := SweepRows(batch); got != 8 {
		t.Fatalf("SweepRows = %d, want 8", got)
	}
}

func TestMtrRowsCountsTraceAndHops(t *testing.T) {
	tr := &edgev1.MtrTraceEventV1{Hops: []*edgev1.MtrTraceHopV1{{}, {}, {}, {}}}
	if got := MtrTraceRows(tr); got != 5 { // 1 trace + 4 hops
		t.Fatalf("MtrTraceRows = %d, want 5", got)
	}
	batch := &edgev1.MtrTraceBatchV1{Traces: []*edgev1.MtrTraceEventV1{tr, {}}}
	if got := MtrRows(batch); got != 6 { // 5 + (1 trace + 0 hops)
		t.Fatalf("MtrRows = %d, want 6", got)
	}
}

func TestRowKeyStableAndDistinct(t *testing.T) {
	digest := []byte("semantic-digest-32-bytes-example")
	a := RowKey(digest, 0)
	if !bytes.Equal(a, RowKey(digest, 0)) {
		t.Fatal("row key must be stable for the same (digest, ordinal)")
	}
	if bytes.Equal(a, RowKey(digest, 1)) {
		t.Fatal("row key must differ across ordinals")
	}
	other := []byte("different-digest-32-bytes-exampl")
	if bytes.Equal(a, RowKey(other, 0)) {
		t.Fatal("row key must differ across frames")
	}
}
