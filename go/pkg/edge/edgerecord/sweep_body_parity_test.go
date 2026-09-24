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

package edgerecord

import (
	"errors"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// TestSweepModeBitTableIsExact pins modeBit's FOUR rows individually.
//
// The Elixir peer derives its numbers from the generated SweepModeBit and pins only the
// mode -> bit-NAME correspondence, so nothing on that side can catch Go's switch mapping a
// mode to the wrong generated constant. Swapping the TCP_SYN and TCP_CONNECT arms survived
// every other test in this package, because the fixtures exercise only ICMP and MTR.
func TestSweepModeBitTableIsExact(t *testing.T) {
	want := map[edgev1.SweepMode]edgev1.SweepModeBit{
		edgev1.SweepMode_SWEEP_MODE_ICMP:        edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP,
		edgev1.SweepMode_SWEEP_MODE_TCP_SYN:     edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_SYN,
		edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT: edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT,
		edgev1.SweepMode_SWEEP_MODE_MTR:         edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR,
	}

	for mode, bit := range want {
		if got := modeBit(mode); got != uint32(bit) {
			t.Fatalf("modeBit(%v) = %d, want %d (%v)", mode, got, uint32(bit), bit)
		}
	}

	// Every admitted mode has a row, and the rows are DISTINCT: a switch that mapped two
	// modes to the same bit would still satisfy a per-row lookup of one of them.
	seen := map[uint32]edgev1.SweepMode{}
	for mode := range want {
		b := modeBit(mode)
		if prior, dup := seen[b]; dup {
			t.Fatalf("modeBit(%v) and modeBit(%v) are both %d", mode, prior, b)
		}
		seen[b] = mode
	}

	// Anything outside the admitted set is 0, which is what makes an unknown mode a
	// rejection rather than a silently-zero contribution to the derived bitmask.
	for _, m := range []edgev1.SweepMode{
		edgev1.SweepMode_SWEEP_MODE_UNSPECIFIED,
		edgev1.SweepMode(9999),
		edgev1.SweepMode(-1),
	} {
		if got := modeBit(m); got != 0 {
			t.Fatalf("modeBit(%v) = %d, want 0", m, got)
		}
	}

	// EXACT membership, both directions: every row is an admitted mode, and every admitted
	// mode has a row. One direction alone lets an admitted mode carry no bit -- which
	// contributes 0 to the derived mask and is then invisible in the configured comparison.
	for mode := range want {
		if !knownSweepMode(mode) {
			t.Fatalf("%v has a mode bit but is not an admitted mode", mode)
		}
	}

	for _, mode := range allSweepModes() {
		if knownSweepMode(mode) == (modeBit(mode) == 0) {
			t.Fatalf("%v: admitted=%v but modeBit=%d -- the two sets disagree",
				mode, knownSweepMode(mode), modeBit(mode))
		}
		if _, ok := want[mode]; knownSweepMode(mode) && !ok {
			t.Fatalf("%v is admitted but has no row in this table", mode)
		}
	}
}

// allSweepModes is the generated SweepMode domain, so "every admitted mode" above is the
// descriptor's answer rather than a second hand-written list.
func allSweepModes() []edgev1.SweepMode {
	vals := edgev1.SweepMode(0).Descriptor().Values()
	out := make([]edgev1.SweepMode, 0, vals.Len())
	for i := 0; i < vals.Len(); i++ {
		out = append(out, edgev1.SweepMode(vals.Get(i).Number()))
	}
	return out
}

// sweepFamilyVector is one Elixir reason FAMILY and the Go sentinel it claims to correspond
// to, plus an input that actually produces it.
type sweepFamilyVector struct {
	family   string // the Elixir reason family, verbatim
	sentinel error
	mutate   func(*testing.T, *edgev1.SweepObservationBatchV1)
}

// TestSweepBodyFamilySentinelsAreBehavioural gives the Elixir family -> Go sentinel mapping
// BEHAVIOURAL evidence.
//
// The Elixir side pins the mapping as DATA. It no longer checks that each sentinel NAME is
// declared here: that check read Go source from an Elixir test, which Bazel does not stage
// for the Elixir shard, and it was strictly weaker than this file -- every sentinel below is
// referenced as an IDENTIFIER, so a name that does not exist fails to COMPILE.
//
// What neither the data mapping nor a name check would notice is a Go branch changed to
// return a DIFFERENT existing sentinel -- the host-bound branch returning ErrSweepChecks,
// say -- because the name still exists and the mapping still says what it always said.
// These vectors pin the BRANCH.
//
// SCOPE: ONE REPRESENTATIVE PER FAMILY, deliberately. This is not an exhaustive branch
// matrix -- Go's sentinels are distinct values, so a single input per family is what the
// mapping claim needs. Enumerating every branch that can reach a family belongs to the
// correctness suite, not here.
//
// The family strings are duplicated across the two runtimes, and the sweep-join corpus does
// NOT remove that: it carries CORRELATION labels, not the body-family -> Go-sentinel
// mapping, which is a different vocabulary answering a different question. Removing this
// duplication needs a body-family corpus of its own; until one exists, this proves Go's side
// of each pair and the Elixir suite proves its own.
func TestSweepBodyFamilySentinelsAreBehavioural(t *testing.T) {
	vectors := []sweepFamilyVector{
		{
			family:   "source",
			sentinel: ErrSweepSource,
			mutate: func(_ *testing.T, b *edgev1.SweepObservationBatchV1) {
				b.Source = edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_UNSPECIFIED
			},
		},
		{
			family:   "source_run_id",
			sentinel: ErrSweepSourceRunID,
			mutate: func(_ *testing.T, b *edgev1.SweepObservationBatchV1) {
				// SCHEDULED_CHECK REQUIRES one.
				b.SourceRunId = nil
			},
		},
		{
			family:   "identity",
			sentinel: ErrSweepIdentity,
			mutate: func(_ *testing.T, b *edgev1.SweepObservationBatchV1) {
				b.ExecutionPlanSha256 = nil
			},
		},
		{
			family:   "checks",
			sentinel: ErrSweepChecks,
			mutate: func(_ *testing.T, b *edgev1.SweepObservationBatchV1) {
				b.TestedChecks = nil
			},
		},
		{
			family:   "bounds",
			sentinel: ErrSweepBounds,
			mutate: func(_ *testing.T, b *edgev1.SweepObservationBatchV1) {
				// NIL hosts: the bound is checked before the host loop, so these are never
				// dereferenced. That is also the Go-side proof of bound-before-host-work.
				b.Hosts = make([]*edgev1.SweepHostObservationV1, MaxSweepHostsPerBatch+1)
			},
		},
		{
			family:   "mode_bits",
			sentinel: ErrSweepModeBits,
			mutate: func(_ *testing.T, b *edgev1.SweepObservationBatchV1) {
				b.ConfiguredModeBits = uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP)
			},
		},
		{
			family:   "mode_summary",
			sentinel: ErrSweepModeSummary,
			mutate: func(_ *testing.T, b *edgev1.SweepObservationBatchV1) {
				b.Hosts[0].Mtr = nil
			},
		},
		{
			family:   "address",
			sentinel: ErrSweepAddress,
			mutate: func(_ *testing.T, b *edgev1.SweepObservationBatchV1) {
				b.Hosts[0].Address = []byte{1}
			},
		},
		{
			family:   "check_index",
			sentinel: ErrSweepCheckIndex,
			mutate: func(_ *testing.T, b *edgev1.SweepObservationBatchV1) {
				b.Hosts[0].OpenPorts = []*edgev1.SweepOpenPortV1{{TestedCheckIndex: 99}}
			},
		},
		{
			family:   "summary",
			sentinel: ErrSweepSummary,
			mutate: func(_ *testing.T, b *edgev1.SweepObservationBatchV1) {
				b.Hosts[0].Icmp.Received = b.Hosts[0].Icmp.GetSent() + 1
			},
		},
	}

	// Every family the Elixir map gives a Go peer appears here exactly once. `shape` and
	// `width` are deliberately absent: Go's generated struct makes those unrepresentable.
	wantFamilies := map[string]bool{
		"source": true, "source_run_id": true, "identity": true, "checks": true,
		"bounds": true, "mode_bits": true, "mode_summary": true, "address": true,
		"check_index": true, "summary": true,
	}

	seen := map[string]bool{}
	for _, v := range vectors {
		if seen[v.family] {
			t.Fatalf("family %q has two vectors", v.family)
		}
		seen[v.family] = true

		if !wantFamilies[v.family] {
			t.Fatalf("family %q is not one of the families with a Go peer", v.family)
		}

		b := validSweepBatch(t)
		v.mutate(t, b)

		err := ValidateSweepObservationBatch(b)
		if !errors.Is(err, v.sentinel) {
			t.Fatalf("family %q: got %v, want %v", v.family, err, v.sentinel)
		}
	}

	if len(seen) != len(wantFamilies) {
		t.Fatalf("covered %d families, want %d", len(seen), len(wantFamilies))
	}

	// The control: unmutated, the fixture is valid, so every rejection above is one axis
	// off a passing input rather than a batch that was broken to begin with.
	if err := ValidateSweepObservationBatch(validSweepBatch(t)); err != nil {
		t.Fatalf("the unmutated fixture is invalid: %v", err)
	}
}
