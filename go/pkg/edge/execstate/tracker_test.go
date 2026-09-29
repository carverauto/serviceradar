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

package execstate

import (
	"errors"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func newTracker() *Tracker {
	return New(Identity{ExecutionID: make([]byte, 16), ExecutionShard: 2, AssignmentEpoch: 9}, nil)
}

func TestStartProgressComplete(t *testing.T) {
	tr := newTracker()
	tr.SetExpectedMTR(2)

	if k := tr.Start().Kind; k != edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_START {
		t.Fatalf("start kind = %v", k)
	}

	if err := tr.RecordBatch(1, 100, 60, 1); err != nil {
		t.Fatal(err)
	}
	if err := tr.RecordBatch(2, 50, 20, 1); err != nil {
		t.Fatal(err)
	}
	if err := tr.SetDurableThrough(1); err != nil {
		t.Fatal(err)
	}

	prog, err := tr.Progress()
	if err != nil {
		t.Fatal(err)
	}
	if prog.DurableThroughBatchSequence != 1 {
		t.Fatalf("progress watermark = %d, want 1", prog.DurableThroughBatchSequence)
	}
	if prog.HostsObserved != 150 || prog.HostsAvailable != 80 {
		t.Fatalf("progress counts = %d/%d, want 150/80", prog.HostsObserved, prog.HostsAvailable)
	}
	if prog.ExpectedMtrTraces != 2 || prog.EmittedMtrTraces != 2 {
		t.Fatalf("mtr counts = %d/%d, want 2/2", prog.ExpectedMtrTraces, prog.EmittedMtrTraces)
	}

	if err := tr.SetDurableThrough(2); err != nil {
		t.Fatal(err)
	}
	done, err := tr.Complete()
	if err != nil {
		t.Fatal(err)
	}
	if done.Kind != edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED {
		t.Fatalf("completed kind = %v", done.Kind)
	}
	if done.TerminalBatchSequence != 2 {
		t.Fatalf("terminal_batch_sequence = %d, want 2", done.TerminalBatchSequence)
	}
	if done.DurableThroughBatchSequence != 2 {
		t.Fatalf("terminal watermark = %d, want 2", done.DurableThroughBatchSequence)
	}
}

func TestDurableWatermarkCannotExceedObserved(t *testing.T) {
	tr := newTracker()
	_ = tr.RecordBatch(1, 1, 1, 0)
	if err := tr.SetDurableThrough(5); err == nil {
		t.Fatal("watermark beyond observed sequence must error")
	}
	if err := tr.SetDurableThrough(1); err != nil {
		t.Fatal(err)
	}
	// Only advances.
	_ = tr.SetDurableThrough(0)
	prog, _ := tr.Progress()
	if prog.DurableThroughBatchSequence != 1 {
		t.Fatal("watermark must not move backwards")
	}
}

// Finding usp-06/P1: the interval is contiguous with no empty slots, so the
// first batch must be 1, duplicates are rejected, and interior gaps are rejected
// (a terminal [1,N] claim is only sound if every slot was recorded).
func TestBatchSequenceMustBeContiguous(t *testing.T) {
	tr := newTracker()
	// A non-1 first sequence is rejected.
	if err := tr.RecordBatch(2, 1, 1, 0); err == nil {
		t.Fatal("first batch_sequence must be exactly 1")
	}
	if err := tr.RecordBatch(1, 1, 1, 0); err != nil {
		t.Fatalf("first batch 1: %v", err)
	}
	// A duplicate is rejected.
	if err := tr.RecordBatch(1, 1, 1, 0); err == nil {
		t.Fatal("duplicate batch_sequence must error")
	}
	// An interior gap (skip 2) is rejected.
	if err := tr.RecordBatch(3, 1, 1, 0); err == nil {
		t.Fatal("interior gap must error; the interval must be contiguous")
	}
	// The exact next sequence is accepted.
	if err := tr.RecordBatch(2, 1, 1, 0); err != nil {
		t.Fatalf("contiguous next (2): %v", err)
	}
}

func TestTerminalGuards(t *testing.T) {
	tr := newTracker()
	_ = tr.RecordBatch(1, 1, 1, 0)
	if _, err := tr.Complete(); err != nil {
		t.Fatal(err)
	}
	if _, err := tr.Progress(); !errors.Is(err, ErrTerminal) {
		t.Fatal("progress after terminal must return ErrTerminal")
	}
	if _, err := tr.Complete(); !errors.Is(err, ErrTerminal) {
		t.Fatal("second complete must return ErrTerminal")
	}
	if err := tr.RecordBatch(2, 1, 1, 0); !errors.Is(err, ErrTerminal) {
		t.Fatal("record after terminal must return ErrTerminal")
	}
}

func TestAbortCarriesReason(t *testing.T) {
	tr := newTracker()
	_ = tr.RecordBatch(1, 10, 5, 0)
	ev, err := tr.Abort("scheduler_lease_lost")
	if err != nil {
		t.Fatal(err)
	}
	if ev.Kind != edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_ABORTED {
		t.Fatalf("kind = %v", ev.Kind)
	}
	if ev.AbortReason != "scheduler_lease_lost" {
		t.Fatalf("abort_reason = %q", ev.AbortReason)
	}
	if ev.TerminalBatchSequence != 1 {
		t.Fatalf("terminal seq = %d, want 1", ev.TerminalBatchSequence)
	}
}
