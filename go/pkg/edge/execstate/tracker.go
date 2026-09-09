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

// Package execstate tracks one sweep execution attempt on the agent and emits
// SweepExecutionEventV1 evidence: a START event, bounded PROGRESS events
// carrying the durable-prefix watermark, and one terminal COMPLETED or ABORTED
// event. The terminal event closes the batch-sequence interval [1, terminal]
// and reports cumulative counts plus expected/emitted MTR-trace totals so the
// consumer can reconcile the streamed batches against the immutable plan without
// materializing the whole execution.
//
// It is pure bookkeeping: batch flushes and durable watermarks are fed in, and
// it produces the evidence messages. The caller frames and spools them.
package execstate

import (
	"errors"
	"fmt"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// ErrTerminal is returned when evidence is requested after the attempt has
// already produced a terminal (COMPLETED/ABORTED) event.
var ErrTerminal = errors.New("execstate: attempt already terminal")

// ErrBatchSequenceGap is returned when a batch is recorded out of order. The
// interval is one contiguous sequence space, so a terminal [1,N] claim is only
// sound if every slot in between was recorded.
var ErrBatchSequenceGap = errors.New("execstate: batch_sequence must be contiguous")

// ErrDurableBeyondObserved is returned when the durable-prefix watermark is
// advanced past the highest observed batch sequence -- a claim that data was
// durable before it was ever produced.
var ErrDurableBeyondObserved = errors.New("execstate: durable watermark cannot exceed observed batch sequence")

// Identity is the immutable identity of one execution attempt.
type Identity struct {
	ExecutionID         []byte
	ExecutionShard      uint32
	AssignmentEpoch     uint64
	ExecutionPlanID     []byte
	ExecutionPlanSHA256 []byte
	TargetRangeID       []byte
}

// Tracker accumulates progress for one attempt. Not safe for concurrent use.
type Tracker struct {
	id Identity

	nowNano func() int64

	lastBatchSeq   uint64 // highest batch_sequence made durable/observed
	durableThrough uint64 // contiguous durable-prefix watermark
	hostsObserved  uint64
	hostsAvailable uint64
	expectedMTR    uint64
	emittedMTR     uint64

	terminal bool
}

// New creates a Tracker. nowNano supplies the event timestamp; pass nil to omit
// timestamps (they default to 0), which keeps the tracker deterministic in
// tests.
func New(id Identity, nowNano func() int64) *Tracker {
	if nowNano == nil {
		nowNano = func() int64 { return 0 }
	}
	return &Tracker{id: id, nowNano: nowNano}
}

// SetExpectedMTR records how many MTR traces the plan expects for this attempt.
func (t *Tracker) SetExpectedMTR(n uint64) { t.expectedMTR = n }

// RecordBatch advances the observed batch sequence and adds the batch's host
// and available counts and its emitted MTR-summary count. batchSeq must be
// exactly lastBatchSeq+1: the interval is one contiguous sequence space with no
// empty slots, so the first batch must be 1 and no interior slot may be skipped.
// A terminal [1,N] claim is only sound if every slot in between was recorded.
func (t *Tracker) RecordBatch(batchSeq, hosts, available, emittedMTR uint64) error {
	if t.terminal {
		return ErrTerminal
	}
	if batchSeq != t.lastBatchSeq+1 {
		return fmt.Errorf("%w: got %d, want %d", ErrBatchSequenceGap, batchSeq, t.lastBatchSeq+1)
	}
	t.lastBatchSeq = batchSeq
	t.hostsObserved += hosts
	t.hostsAvailable += available
	t.emittedMTR += emittedMTR
	return nil
}

// SetDurableThrough advances the durable-prefix watermark. It must never exceed
// the highest observed batch sequence and only advances.
func (t *Tracker) SetDurableThrough(seq uint64) error {
	if seq > t.lastBatchSeq {
		return ErrDurableBeyondObserved
	}
	if seq > t.durableThrough {
		t.durableThrough = seq
	}
	return nil
}

// Start returns the START evidence event.
func (t *Tracker) Start() *edgev1.SweepExecutionEventV1 {
	e := t.base(edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_START)
	return e
}

// Progress returns a PROGRESS event carrying the current durable-prefix
// watermark and cumulative counts.
func (t *Tracker) Progress() (*edgev1.SweepExecutionEventV1, error) {
	if t.terminal {
		return nil, ErrTerminal
	}
	e := t.base(edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_PROGRESS)
	e.DurableThroughBatchSequence = t.durableThrough
	e.HostsObserved = t.hostsObserved
	e.HostsAvailable = t.hostsAvailable
	e.ExpectedMtrTraces = t.expectedMTR
	e.EmittedMtrTraces = t.emittedMTR
	return e, nil
}

// Complete returns the terminal COMPLETED event closing [1, terminal] and
// reporting final counts. After it the tracker is terminal.
func (t *Tracker) Complete() (*edgev1.SweepExecutionEventV1, error) {
	if t.terminal {
		return nil, ErrTerminal
	}
	t.terminal = true
	e := t.base(edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED)
	e.TerminalBatchSequence = t.lastBatchSeq
	e.DurableThroughBatchSequence = t.durableThrough
	e.HostsObserved = t.hostsObserved
	e.HostsAvailable = t.hostsAvailable
	e.ExpectedMtrTraces = t.expectedMTR
	e.EmittedMtrTraces = t.emittedMTR
	return e, nil
}

// Abort returns the terminal ABORTED event with a reason.
func (t *Tracker) Abort(reason string) (*edgev1.SweepExecutionEventV1, error) {
	if t.terminal {
		return nil, ErrTerminal
	}
	t.terminal = true
	e := t.base(edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_ABORTED)
	e.TerminalBatchSequence = t.lastBatchSeq
	e.DurableThroughBatchSequence = t.durableThrough
	e.HostsObserved = t.hostsObserved
	e.HostsAvailable = t.hostsAvailable
	e.AbortReason = reason
	return e, nil
}

func (t *Tracker) base(kind edgev1.SweepExecutionEventKind) *edgev1.SweepExecutionEventV1 {
	return &edgev1.SweepExecutionEventV1{
		ExecutionId:         t.id.ExecutionID,
		ExecutionShard:      t.id.ExecutionShard,
		AssignmentEpoch:     t.id.AssignmentEpoch,
		ExecutionPlanId:     t.id.ExecutionPlanID,
		ExecutionPlanSha256: t.id.ExecutionPlanSHA256,
		TargetRangeId:       t.id.TargetRangeID,
		Kind:                kind,
		EmittedAtUnixNano:   t.nowNano(),
	}
}
