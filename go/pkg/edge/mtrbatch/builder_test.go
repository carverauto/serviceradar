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

package mtrbatch

import (
	"errors"
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func corrID() []byte { return []byte("mtr-correlation1") } // 16 bytes

// setCorrelation stamps the source-specific correlation key on a trace.
func setCorrelation(t *edgev1.MtrTraceEventV1, id []byte) {
	switch t.GetSource() {
	case edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK:
		t.CheckId = id
	case edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_ON_DEMAND:
		t.CommandId = id
	case edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC:
		t.ScanRunId = id
	default:
		t.SweepExecutionId = id
	}
}

func ctx(src edgev1.SweepExecutionSource) Context {
	return Context{NetworkScopeID: make([]byte, 16), AgentID: make([]byte, 16), Source: src, CorrelationID: corrID()}
}

func trace(src edgev1.SweepExecutionSource, target string, hops int) *edgev1.MtrTraceEventV1 {
	t := &edgev1.MtrTraceEventV1{
		TraceId: make([]byte, 16),
		Source:  src,
		Target:  target,
		Outcome: edgev1.MtrOutcome_MTR_OUTCOME_REACHED,
	}
	setCorrelation(t, corrID())
	for i := 0; i < hops; i++ {
		t.Hops = append(t.Hops, &edgev1.MtrTraceHopV1{HopNumber: uint32(i + 1), Address: []byte{10, 0, 0, byte(i)}})
	}
	return t
}

func TestBuilderFlushesNearByteTarget(t *testing.T) {
	b := NewBuilder(ctx(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK), Limits{ByteTarget: 400, ByteHard: 1 << 16})

	var flushed []*edgev1.MtrTraceBatchV1
	for i := 0; i < 20; i++ {
		out, err := b.Add(trace(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK, "target.example", 4))
		if err != nil {
			t.Fatalf("add: %v", err)
		}
		flushed = append(flushed, out...)
	}
	if final := b.Flush(); final != nil {
		flushed = append(flushed, final)
	}
	if len(flushed) < 2 {
		t.Fatalf("expected multiple batches, got %d", len(flushed))
	}
	for i, batch := range flushed {
		if proto.Size(batch) > 1<<16 {
			t.Fatalf("batch %d exceeds hard limit", i)
		}
		if len(batch.Traces) == 0 {
			t.Fatalf("batch %d empty", i)
		}
	}
}

func TestBuilderTraceCountGuard(t *testing.T) {
	b := NewBuilder(ctx(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC), Limits{ByteTarget: 1 << 20, ByteHard: 1 << 20, MaxTraces: 2})

	total, batches := 0, 0
	for i := 0; i < 5; i++ {
		out, _ := b.Add(trace(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC, "t", 1))
		for _, batch := range out {
			batches++
			if len(batch.Traces) > 2 {
				t.Fatalf("batch has %d traces, exceeds MaxTraces 2", len(batch.Traces))
			}
			total += len(batch.Traces)
		}
	}
	if final := b.Flush(); final != nil {
		total += len(final.Traces)
	}
	if total != 5 {
		t.Fatalf("lost traces: got %d, want 5", total)
	}
	if batches == 0 {
		t.Fatal("expected trace-count flushes")
	}
}

func TestBuilderMTRRowBudget(t *testing.T) {
	// Each trace = 1 + hops rows. 3 hops => 4 rows. MaxMTRRows 10 must flush
	// before a 3rd trace (12 rows) accumulates.
	b := NewBuilder(ctx(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_ON_DEMAND), Limits{ByteTarget: 1 << 20, ByteHard: 1 << 20, MaxMTRRows: 10})

	_, _ = b.Add(trace(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_ON_DEMAND, "t1", 3))
	_, _ = b.Add(trace(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_ON_DEMAND, "t2", 3))
	out3, _ := b.Add(trace(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_ON_DEMAND, "t3", 3))
	if len(out3) != 1 {
		t.Fatalf("expected a row-budget flush before trace 3, got %d", len(out3))
	}
	if len(out3[0].Traces) != 2 {
		t.Fatalf("flushed batch = %d traces, want 2", len(out3[0].Traces))
	}
}

func TestBuilderRejectsMixedContext(t *testing.T) {
	b := NewBuilder(ctx(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK), Limits{})
	_, err := b.Add(trace(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC, "t", 1))
	if !errors.Is(err, ErrContextMismatch) {
		t.Fatalf("expected ErrContextMismatch, got %v", err)
	}
	if b.PendingTraces() != 0 {
		t.Fatal("mismatched trace must not be buffered")
	}
}

func TestBuilderRejectsOversizeTrace(t *testing.T) {
	b := NewBuilder(ctx(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC), Limits{ByteTarget: 64, ByteHard: 128})
	big := trace(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC, strings.Repeat("y", 512), 0)
	_, err := b.Add(big)
	if !errors.Is(err, ErrTraceTooLarge) {
		t.Fatalf("expected ErrTraceTooLarge, got %v", err)
	}
}

// Finding usp-07/P1: two traces with the same source but different source-
// specific correlation keys must not batch together (the outer capability
// authorizes exactly one context).
func TestBuilderRejectsMixedCorrelation(t *testing.T) {
	b := NewBuilder(ctx(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK),
		Limits{ByteTarget: 1 << 16, ByteHard: 1 << 16})

	ok := trace(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK, "10.0.0.1", 1)
	if _, err := b.Add(ok); err != nil {
		t.Fatalf("first trace: %v", err)
	}
	other := trace(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK, "10.0.0.2", 1)
	other.CheckId = []byte("different-check1") // same source, different check_id
	if _, err := b.Add(other); !errors.Is(err, ErrContextMismatch) {
		t.Fatalf("mixed correlation key = %v, want ErrContextMismatch", err)
	}
}

// Finding usp-07/P1: a trace admitted at the hard boundary must serialize within
// the hard cap for its real (nonzero) batch_sequence.
func TestBuilderHardCapHoldsForRealSequence(t *testing.T) {
	b := NewBuilder(ctx(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK),
		Limits{ByteTarget: 300, ByteHard: 380})
	var flushed []*edgev1.MtrTraceBatchV1
	for i := 0; i < 3000; i++ {
		out, err := b.Add(trace(edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK, "10.0.0.9", 1))
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
		if sz := proto.Size(batch); sz > 380 {
			t.Fatalf("batch seq %d size %d exceeds hard cap 380", batch.GetBatchSequence(), sz)
		}
	}
}
