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

// Package mtrbatch assembles byte-bounded MtrTraceBatchV1 frames from a stream
// of complete MTR traces. It is the MTR analogue of obsbatch (task 1.4/2.8):
// full per-hop traces are carried in their own typed events, never embedded in
// sweep observations or flattened into generic metrics.
//
// Every trace in one batch MUST share the batch's authenticated context: network
// scope, agent, source, AND the source-specific authorization/correlation key
// (sweep_execution_id, check_id, command_id, or scan_run_id). The outer delivery
// capability authorizes exactly one such context, so a trace whose source or
// correlation key differs is rejected — a mixed-context batch, which the consumer
// treats as poison at projection, can never be produced.
package mtrbatch

import (
	"bytes"
	"errors"
	"fmt"
	"math"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const (
	// DefaultByteTarget is the soft flush threshold.
	DefaultByteTarget = 256 * 1024
	// DefaultByteHard is the hard ceiling an encoded batch must never exceed.
	DefaultByteHard = 512 * 1024
	// DefaultMaxTraces is the secondary trace-count guard per batch.
	DefaultMaxTraces = 128
	// DefaultMaxMTRRows caps the projected mtr_traces + mtr_hops rows per batch.
	DefaultMaxMTRRows = 5000
)

// ErrTraceTooLarge is returned when a single trace is too large for any batch
// under the hard byte limit; the caller quarantines it.
var ErrTraceTooLarge = errors.New("mtrbatch: single trace exceeds hard byte limit")

// ErrContextMismatch is returned when a trace's source or source-specific
// authorization/correlation key does not match the builder's batch context;
// contexts must never be mixed in one batch.
var ErrContextMismatch = errors.New("mtrbatch: trace context does not match batch context")

// Limits configures flush thresholds. Zero fields fall back to defaults.
type Limits struct {
	ByteTarget int
	ByteHard   int
	MaxTraces  int
	MaxMTRRows int
}

func (l Limits) withDefaults() Limits {
	if l.ByteTarget <= 0 {
		l.ByteTarget = DefaultByteTarget
	}
	if l.ByteHard <= 0 {
		l.ByteHard = DefaultByteHard
	}
	if l.MaxTraces <= 0 {
		l.MaxTraces = DefaultMaxTraces
	}
	if l.MaxMTRRows <= 0 {
		l.MaxMTRRows = DefaultMaxMTRRows
	}
	return l
}

// Context is the immutable, authenticated batch context every trace shares.
// CorrelationID is the source-specific authorization/correlation key the outer
// delivery capability authorizes: sweep_execution_id (sweep), check_id
// (scheduled_check), command_id (on_demand), or scan_run_id (ad_hoc). Every
// trace in the batch must carry the matching key for its source.
type Context struct {
	NetworkScopeID []byte
	AgentID        []byte
	Source         edgev1.SweepExecutionSource
	CorrelationID  []byte
}

func (c Context) newBatch(sequence uint64) *edgev1.MtrTraceBatchV1 {
	return &edgev1.MtrTraceBatchV1{
		NetworkScopeId: c.NetworkScopeID,
		AgentId:        c.AgentID,
		Source:         c.Source,
		BatchSequence:  sequence,
	}
}

// traceCorrelationID extracts the source-specific authorization/correlation key
// that must be homogeneous across a batch.
func traceCorrelationID(t *edgev1.MtrTraceEventV1) []byte {
	switch t.GetSource() {
	case edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK:
		return t.GetCheckId()
	case edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_ON_DEMAND:
		return t.GetCommandId()
	case edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC:
		return t.GetScanRunId()
	default:
		// Sweep-originated (scheduled sweep / sweep profile) traces correlate on
		// the sweep execution id.
		return t.GetSweepExecutionId()
	}
}

// Builder accumulates traces for one fixed context. Not safe for concurrent use.
type Builder struct {
	ctx    Context
	limits Limits

	baseBytes int // conservative empty-batch size, including max seq overhead
	nextSeq   uint64

	traces   []*edgev1.MtrTraceEventV1
	estBytes int
	rows     int
}

// NewBuilder creates a Builder for the given context.
func NewBuilder(ctx Context, limits Limits) *Builder {
	b := &Builder{ctx: ctx, limits: limits.withDefaults(), nextSeq: 1}
	// batch_sequence is nonzero on every flush but proto3 omits it at 0, so a
	// base measured at 0 underestimates. Reserve the field's worst-case varint
	// overhead so the hard byte cap holds for any flushed sequence.
	base0 := proto.Size(ctx.newBatch(0))
	seqBytes := proto.Size(ctx.newBatch(math.MaxUint64)) - base0
	b.baseBytes = base0 + seqBytes
	b.reset()
	return b
}

func (b *Builder) reset() {
	b.traces = nil
	b.estBytes = b.baseBytes
	b.rows = 0
}

func traceCost(t *edgev1.MtrTraceEventV1) (bytesCost, rows int) {
	sz := proto.Size(t)
	bytesCost = 2 + varintLen(uint64(sz)) + sz
	rows = 1 + len(t.GetHops()) // one trace row + one row per hop
	return bytesCost, rows
}

func varintLen(v uint64) int {
	n := 1
	for v >= 0x80 {
		v >>= 7
		n++
	}
	return n
}

// Add appends a trace, flushing first if it would breach a bound. The trace's
// Source must equal the builder's context source. Returns any completed batches.
func (b *Builder) Add(trace *edgev1.MtrTraceEventV1) ([]*edgev1.MtrTraceBatchV1, error) {
	if trace.GetSource() != b.ctx.Source {
		return nil, fmt.Errorf("%w: trace source %v, batch source %v", ErrContextMismatch, trace.GetSource(), b.ctx.Source)
	}
	if !bytes.Equal(traceCorrelationID(trace), b.ctx.CorrelationID) {
		return nil, fmt.Errorf("%w: trace correlation key does not match the batch's authorized context", ErrContextMismatch)
	}

	cost, rows := traceCost(trace)
	if b.baseBytes+cost > b.limits.ByteHard {
		return nil, fmt.Errorf("%w: trace encodes to %d bytes, hard %d", ErrTraceTooLarge, cost, b.limits.ByteHard)
	}

	var flushed []*edgev1.MtrTraceBatchV1
	if len(b.traces) > 0 && b.wouldExceed(cost, rows) {
		flushed = append(flushed, b.flushLocked())
	}
	b.traces = append(b.traces, trace)
	b.estBytes += cost
	b.rows += rows
	return flushed, nil
}

func (b *Builder) wouldExceed(cost, rows int) bool {
	if b.estBytes+cost > b.limits.ByteTarget {
		return true
	}
	if len(b.traces)+1 > b.limits.MaxTraces {
		return true
	}
	if b.rows+rows > b.limits.MaxMTRRows {
		return true
	}
	return false
}

// Flush returns the current batch if non-empty, otherwise nil.
func (b *Builder) Flush() *edgev1.MtrTraceBatchV1 {
	if len(b.traces) == 0 {
		return nil
	}
	return b.flushLocked()
}

func (b *Builder) flushLocked() *edgev1.MtrTraceBatchV1 {
	batch := b.ctx.newBatch(b.nextSeq)
	batch.Traces = b.traces
	b.nextSeq++
	b.reset()
	return batch
}

// PendingTraces reports how many traces are buffered in the current batch.
func (b *Builder) PendingTraces() int { return len(b.traces) }
