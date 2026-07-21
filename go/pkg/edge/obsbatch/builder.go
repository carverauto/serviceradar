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

// Package obsbatch assembles byte-bounded SweepObservationBatchV1 frames from a
// stream of per-host observations. It is the agent-side batch builder for the
// edge observation data plane (unify-sweep-results-proto, task 2.2): completed
// host windows are fed in continuously and the builder flushes independently
// decodable batches near a byte target, never exceeding a hard byte limit, and
// enforcing secondary host-count and projected-row budgets.
//
// Grouping rule: every host in one batch MUST share the exact attempted-check
// dictionary. Callers with mixed dictionaries use the Router, which keeps one
// open Builder per distinct dictionary.
//
// The builder is deliberately free of disk and transport concerns; the spool
// (task 2.4) and gRPC sender (task 2.5) consume the flushed batches.
package obsbatch

import (
	"errors"
	"fmt"
	"math"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const (
	// DefaultByteTarget is the soft flush threshold; a batch is flushed before
	// it would grow past this.
	DefaultByteTarget = 256 * 1024
	// DefaultByteHard is the hard ceiling; an encoded batch must never exceed it,
	// so a single host whose contribution alone would breach it is rejected.
	DefaultByteHard = 512 * 1024
	// DefaultMaxHosts is the secondary host-count guard per batch.
	DefaultMaxHosts = 2000
	// DefaultMaxSweepRows caps the projected database rows a single batch may
	// produce, independent of byte size.
	DefaultMaxSweepRows = 10000
	// DefaultMaxActiveDicts bounds how many distinct attempted-check dictionaries
	// the Router keeps open at once, so a plan of many one-host dictionaries
	// cannot accrete execution-wide retained state.
	DefaultMaxActiveDicts = 256
)

// sequencer allocates the contiguous batch-sequence space for one
// execution/shard/epoch attempt. A single sequencer is shared by every Builder
// the Router creates, so batches across different dictionaries never collide on
// a sequence and a terminal can prove one contiguous [1,N] interval. Sequences
// are allocated only when a batch is actually flushed. Not safe for concurrent
// use; drive the owning Router/Builder from a single goroutine.
type sequencer struct{ n uint64 }

func (s *sequencer) next() uint64 {
	s.n++
	return s.n
}

// ErrHostTooLarge is returned when a single host observation is so large that no
// batch could carry it under the hard byte limit. The caller quarantines it.
var ErrHostTooLarge = errors.New("obsbatch: single host observation exceeds hard byte limit")

// Limits configures the flush thresholds. Zero fields fall back to defaults.
type Limits struct {
	ByteTarget     int
	ByteHard       int
	MaxHosts       int
	MaxSweepRows   int
	MaxActiveDicts int
}

func (l Limits) withDefaults() Limits {
	if l.ByteTarget <= 0 {
		l.ByteTarget = DefaultByteTarget
	}
	if l.ByteHard <= 0 {
		l.ByteHard = DefaultByteHard
	}
	if l.MaxHosts <= 0 {
		l.MaxHosts = DefaultMaxHosts
	}
	if l.MaxSweepRows <= 0 {
		l.MaxSweepRows = DefaultMaxSweepRows
	}
	if l.MaxActiveDicts <= 0 {
		l.MaxActiveDicts = DefaultMaxActiveDicts
	}
	return l
}

// Context holds the immutable batch-level fields shared by every host in a
// batch. TestedChecks is the exact attempted-check dictionary for the batch.
type Context struct {
	ExecutionID         []byte
	SweepGroupID        []byte
	ExecutionShard      uint32
	AssignmentEpoch     uint64
	ObservedAtUnixNano  int64
	ExecutionPlanID     []byte
	ExecutionPlanSHA256 []byte
	TargetRangeID       []byte
	TargetRangeSHA256   []byte
	TestedChecks        []*edgev1.SweepTestV1
	ConfiguredModeBits  uint32
	AvailabilityPolicy  []byte
	Source              edgev1.SweepExecutionSource
	SourceRunID         []byte
}

func (c Context) newBatch(sequence uint64) *edgev1.SweepObservationBatchV1 {
	return &edgev1.SweepObservationBatchV1{
		ExecutionId:          c.ExecutionID,
		SweepGroupId:         c.SweepGroupID,
		ExecutionShard:       c.ExecutionShard,
		AssignmentEpoch:      c.AssignmentEpoch,
		BatchSequence:        sequence,
		ObservedAtUnixNano:   c.ObservedAtUnixNano,
		ExecutionPlanId:      c.ExecutionPlanID,
		ExecutionPlanSha256:  c.ExecutionPlanSHA256,
		TargetRangeId:        c.TargetRangeID,
		TargetRangeSha256:    c.TargetRangeSHA256,
		TestedChecks:         c.TestedChecks,
		ConfiguredModeBits:   c.ConfiguredModeBits,
		AvailabilityPolicyId: c.AvailabilityPolicy,
		Source:               c.Source,
		SourceRunId:          c.SourceRunID,
	}
}

// Builder assembles batches for one fixed Context/dictionary. It is not safe for
// concurrent use; drive it from a single goroutine.
type Builder struct {
	ctx    Context
	limits Limits
	seq    *sequencer // shared across a Router's builders; sole owner when standalone

	baseBytes int // conservative encoded size of an empty batch (incl. max seq overhead)
	seqBytes  int // reserved worst-case batch_sequence field overhead

	hosts    []*edgev1.SweepHostObservationV1
	estBytes int // running estimate of the current batch's encoded size
	rows     int // projected database rows in the current batch
}

// NewBuilder creates a standalone Builder for the given context with its own
// batch-sequence space allocated contiguously from 1 as batches are flushed.
func NewBuilder(ctx Context, limits Limits) *Builder {
	return newBuilder(ctx, limits.withDefaults(), &sequencer{})
}

// newBuilder creates a Builder that draws batch sequences from the supplied
// shared sequencer, so every dictionary in one attempt shares one contiguous
// sequence space.
func newBuilder(ctx Context, limits Limits, seq *sequencer) *Builder {
	b := &Builder{
		ctx:    ctx,
		limits: limits,
		seq:    seq,
	}
	// The batch_sequence is allocated only at flush from the shared sequencer, so
	// its exact value is unknown while accumulating. Reserve the worst-case
	// varint overhead of that field so the hard byte cap holds for any sequence.
	base0 := proto.Size(ctx.newBatch(0))
	b.seqBytes = proto.Size(ctx.newBatch(math.MaxUint64)) - base0
	b.baseBytes = base0 + b.seqBytes
	b.reset()
	return b
}

func (b *Builder) reset() {
	b.hosts = nil
	b.estBytes = b.baseBytes
	b.rows = 0
}

// hostCost returns the incremental encoded bytes a host adds to the batch (its
// encoded size plus the repeated-field tag + length prefix) and its projected
// database-row count.
func hostCost(h *edgev1.SweepHostObservationV1) (bytesCost, rows int) {
	sz := proto.Size(h)
	// field 16 (hosts) tag = 2 bytes; length prefix is a varint of sz.
	bytesCost = 2 + varintLen(uint64(sz)) + sz

	rows = 1 // the host reachability row
	rows += len(h.GetOpenPorts())
	rows += len(h.GetPortErrors()) // each per-check error projects a row
	if h.GetMtr() != nil {
		rows++ // the MTR summary row
	}
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

// Add appends a host to the current batch, flushing the current batch first if
// the host would breach any bound. It returns any batches completed by this
// call (usually zero or one). ErrHostTooLarge means the host cannot fit any
// batch and was not added.
func (b *Builder) Add(host *edgev1.SweepHostObservationV1) ([]*edgev1.SweepObservationBatchV1, error) {
	cost, rows := hostCost(host)

	if b.baseBytes+cost > b.limits.ByteHard {
		return nil, fmt.Errorf("%w: host encodes to %d bytes, base %d, hard %d",
			ErrHostTooLarge, cost, b.baseBytes, b.limits.ByteHard)
	}

	var flushed []*edgev1.SweepObservationBatchV1

	if len(b.hosts) > 0 && b.wouldExceed(cost, rows) {
		flushed = append(flushed, b.flushLocked())
	}

	b.hosts = append(b.hosts, host)
	b.estBytes += cost
	b.rows += rows
	return flushed, nil
}

// wouldExceed reports whether adding a host of the given cost/rows to the
// current non-empty batch would breach the target byte, host-count, or
// projected-row bounds.
func (b *Builder) wouldExceed(cost, rows int) bool {
	if b.estBytes+cost > b.limits.ByteTarget {
		return true
	}
	if len(b.hosts)+1 > b.limits.MaxHosts {
		return true
	}
	if b.rows+rows > b.limits.MaxSweepRows {
		return true
	}
	return false
}

// Flush returns the current batch if it is non-empty, otherwise nil.
func (b *Builder) Flush() *edgev1.SweepObservationBatchV1 {
	if len(b.hosts) == 0 {
		return nil
	}
	return b.flushLocked()
}

func (b *Builder) flushLocked() *edgev1.SweepObservationBatchV1 {
	batch := b.ctx.newBatch(b.seq.next())
	batch.Hosts = b.hosts
	b.reset()
	return batch
}

// PendingHosts reports how many hosts are buffered in the current unflushed
// batch.
func (b *Builder) PendingHosts() int { return len(b.hosts) }
