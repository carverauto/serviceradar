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

package obsbatch

import (
	"errors"
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func icmpChecks() []*edgev1.SweepTestV1 {
	return []*edgev1.SweepTestV1{{Mode: edgev1.SweepMode_SWEEP_MODE_ICMP, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP}}
}

func testCtx() Context {
	return Context{
		ExecutionID:  make([]byte, 16),
		Source:       edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
		TestedChecks: icmpChecks(),
	}
}

func host(hostname string, openPorts int) *edgev1.SweepHostObservationV1 {
	h := &edgev1.SweepHostObservationV1{
		Address:  []byte{10, 0, 0, 1},
		Hostname: hostname,
		Icmp:     &edgev1.SweepIcmpSummaryV1{Outcome: edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS, TargetReached: true},
	}
	for i := 0; i < openPorts; i++ {
		h.OpenPorts = append(h.OpenPorts, &edgev1.SweepOpenPortV1{TestedCheckIndex: 0, Service: "svc"})
	}
	return h
}

func TestBuilderFlushesNearByteTarget(t *testing.T) {
	b := NewBuilder(testCtx(), Limits{ByteTarget: 200, ByteHard: 4096})

	var flushed []*edgev1.SweepObservationBatchV1
	for i := 0; i < 20; i++ {
		out, err := b.Add(host("host-with-a-longish-name", 0))
		if err != nil {
			t.Fatalf("add: %v", err)
		}
		flushed = append(flushed, out...)
	}
	if final := b.Flush(); final != nil {
		flushed = append(flushed, final)
	}

	if len(flushed) < 2 {
		t.Fatalf("expected multiple flushed batches with a 200-byte target, got %d", len(flushed))
	}
	for i, batch := range flushed {
		if sz := proto.Size(batch); sz > 4096 {
			t.Fatalf("batch %d size %d exceeds hard limit", i, sz)
		}
		if len(batch.Hosts) == 0 {
			t.Fatalf("batch %d is empty", i)
		}
	}
}

func TestBuilderHostCountGuard(t *testing.T) {
	b := NewBuilder(testCtx(), Limits{ByteTarget: 1 << 20, ByteHard: 1 << 20, MaxHosts: 3})

	total := 0
	batches := 0
	for i := 0; i < 10; i++ {
		out, err := b.Add(host("h", 0))
		if err != nil {
			t.Fatalf("add: %v", err)
		}
		for _, batch := range out {
			batches++
			if len(batch.Hosts) > 3 {
				t.Fatalf("batch has %d hosts, exceeds MaxHosts 3", len(batch.Hosts))
			}
			total += len(batch.Hosts)
		}
	}
	if final := b.Flush(); final != nil {
		total += len(final.Hosts)
	}
	if total != 10 {
		t.Fatalf("lost hosts: got %d, want 10", total)
	}
	if batches == 0 {
		t.Fatal("expected host-count-driven flushes")
	}
}

func TestBuilderRowBudgetGuard(t *testing.T) {
	// Each host projects 1 + openPorts rows. With 4 ports/host = 5 rows, a
	// MaxSweepRows of 12 must flush before a 3rd host (15 rows) accumulates.
	b := NewBuilder(testCtx(), Limits{ByteTarget: 1 << 20, ByteHard: 1 << 20, MaxSweepRows: 12})

	out1, _ := b.Add(host("h1", 4))
	out2, _ := b.Add(host("h2", 4))
	out3, _ := b.Add(host("h3", 4))
	if len(out1) != 0 || len(out2) != 0 {
		t.Fatalf("did not expect early flush: %d %d", len(out1), len(out2))
	}
	if len(out3) != 1 {
		t.Fatalf("expected a row-budget flush before host 3, got %d", len(out3))
	}
	if len(out3[0].Hosts) != 2 {
		t.Fatalf("flushed batch = %d hosts, want 2", len(out3[0].Hosts))
	}
}

func TestBuilderHostTooLarge(t *testing.T) {
	b := NewBuilder(testCtx(), Limits{ByteTarget: 64, ByteHard: 128})
	_, err := b.Add(host(strings.Repeat("x", 512), 0))
	if !errors.Is(err, ErrHostTooLarge) {
		t.Fatalf("expected ErrHostTooLarge, got %v", err)
	}
	if b.PendingHosts() != 0 {
		t.Fatal("oversize host must not be buffered")
	}
}

func TestBuilderSequenceContiguousFromOne(t *testing.T) {
	b := NewBuilder(testCtx(), Limits{ByteTarget: 1 << 20, ByteHard: 1 << 20, MaxHosts: 1})

	var seqs []uint64
	for i := 0; i < 3; i++ {
		out, _ := b.Add(host("h", 0))
		for _, batch := range out {
			seqs = append(seqs, batch.BatchSequence)
		}
	}
	if final := b.Flush(); final != nil {
		seqs = append(seqs, final.BatchSequence)
	}
	want := []uint64{1, 2, 3}
	if len(seqs) != 3 || seqs[0] != want[0] || seqs[1] != want[1] || seqs[2] != want[2] {
		t.Fatalf("batch_sequence = %v, want %v", seqs, want)
	}
}

// Finding usp-03/P1: the hard byte cap must hold for the real flushed sequence,
// not the seq=0 base that proto3 omits.
func TestBuilderHardCapHoldsForRealSequence(t *testing.T) {
	// Drive many flushes so batch_sequence grows into multi-byte varints, and a
	// tight hard cap so any per-batch sequence-overhead slip would breach it.
	b := NewBuilder(testCtx(), Limits{ByteTarget: 300, ByteHard: 360})
	var flushed []*edgev1.SweepObservationBatchV1
	for i := 0; i < 5000; i++ {
		out, err := b.Add(host("host-with-a-longish-name", 1))
		if err != nil {
			t.Fatalf("add: %v", err)
		}
		flushed = append(flushed, out...)
	}
	if final := b.Flush(); final != nil {
		flushed = append(flushed, final)
	}
	if len(flushed) < 100 {
		t.Fatalf("expected many batches (large sequences), got %d", len(flushed))
	}
	for _, batch := range flushed {
		if sz := proto.Size(batch); sz > 360 {
			t.Fatalf("flushed batch seq %d size %d exceeds hard cap 360", batch.GetBatchSequence(), sz)
		}
	}
}

// Finding usp-03/P1: port_errors are projected rows and must count against the
// sweep-row budget.
func TestBuilderRowBudgetCountsPortErrors(t *testing.T) {
	b := NewBuilder(testCtx(), Limits{ByteTarget: 1 << 20, ByteHard: 1 << 20, MaxSweepRows: 5})
	h := &edgev1.SweepHostObservationV1{Address: []byte{10, 0, 0, 9}}
	for i := 0; i < 10; i++ {
		h.PortErrors = append(h.PortErrors, &edgev1.SweepPortErrorV1{TestedCheckIndex: 0, ErrorCode: "refused"})
	}
	// One host projects 1 (reachability) + 10 (errors) = 11 rows > the 5-row cap.
	// It must still be accepted alone (a single host cannot be split), but a
	// second identical host must force a flush rather than pack 22 rows.
	if _, err := b.Add(h); err != nil {
		t.Fatalf("add first: %v", err)
	}
	flushed, err := b.Add(h)
	if err != nil {
		t.Fatalf("add second: %v", err)
	}
	if len(flushed) != 1 {
		t.Fatalf("expected the row budget (incl. port_errors) to force a flush, got %d batches", len(flushed))
	}
}
