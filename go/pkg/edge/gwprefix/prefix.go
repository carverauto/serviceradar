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

// Package gwprefix is the gateway-side contiguous resolved-prefix tracker (task
// 3.5). Frames arrive and publish asynchronously and may earn their durable
// PubAck out of order; this tracker advances the resolved watermark reported back
// to the agent only across a CONTIGUOUS run whose members each have a durable
// outcome -- a primary-stream PubAck (accepted) or an audit/DLQ PubAck (rejected).
// A sequence with no durable outcome yet (NATS unavailable, stream refusal,
// publisher saturation) is simply never recorded, so the prefix stops there and
// the agent keeps the frame spooled. The tracker is stateless across restarts in
// the sense that it can be rebuilt from the durable stream/DLQ; it holds no I/O.
package gwprefix

import (
	"errors"
	"fmt"
)

// Status is a sequence's durable outcome.
type Status uint8

const (
	// StatusPending means no durable outcome yet; such a sequence must NOT be
	// recorded (the caller withholds by not calling Record).
	StatusPending Status = iota
	// StatusAccepted means the frame earned a primary-stream JetStream PubAck.
	StatusAccepted
	// StatusRejected means the frame was permanently rejected and earned an
	// audit/DLQ PubAck. It is resolved (the agent may drop it) but not ingested.
	StatusRejected
)

var (
	// ErrNotDurable is returned when Record is called with StatusPending.
	ErrNotDurable = errors.New("gwprefix: only a durable (accepted/rejected) outcome may be recorded")
	// ErrBelowBase is returned when a sequence precedes the tracker's base.
	ErrBelowBase = errors.New("gwprefix: sequence precedes lane base")
	// ErrConflict is returned when a sequence is re-recorded with a different
	// durable status.
	ErrConflict = errors.New("gwprefix: conflicting durable status for a sequence")
)

// Tracker follows one lane's durable outcomes and computes the contiguous
// resolved prefix. Not safe for concurrent use.
type Tracker struct {
	base     uint64            // first sequence this lane will carry
	resolved uint64            // contiguous resolved watermark (base-1 == nothing)
	durable  map[uint64]Status // resolved-but-not-yet-contiguous outcomes
}

// New creates a tracker whose lane begins at firstSequence (>= 1).
func New(firstSequence uint64) *Tracker {
	if firstSequence == 0 {
		firstSequence = 1
	}
	return &Tracker{
		base:     firstSequence,
		resolved: firstSequence - 1,
		durable:  make(map[uint64]Status),
	}
}

// Record marks a sequence's durable outcome and advances the contiguous prefix
// as far as the newly-contiguous durable outcomes allow. Recording a sequence at
// or below the current watermark is an idempotent no-op when the status agrees.
func (t *Tracker) Record(seq uint64, s Status) error {
	if s == StatusPending {
		return ErrNotDurable
	}
	if seq < t.base {
		return fmt.Errorf("%w: seq %d < base %d", ErrBelowBase, seq, t.base)
	}
	if seq <= t.resolved {
		return nil // already resolved; contiguous prefix implies it was durable
	}
	if prev, ok := t.durable[seq]; ok {
		if prev != s {
			return fmt.Errorf("%w: seq %d was %d now %d", ErrConflict, seq, prev, s)
		}
		return nil
	}
	t.durable[seq] = s
	for {
		next := t.resolved + 1
		if _, ok := t.durable[next]; !ok {
			break
		}
		delete(t.durable, next)
		t.resolved = next
	}
	return nil
}

// ResolvedThrough returns the contiguous resolved watermark. It never exceeds a
// sequence with an intervening non-durable gap, so a withheld frame holds the
// prefix at the gap.
func (t *Tracker) ResolvedThrough() uint64 { return t.resolved }

// PendingOutOfOrder reports how many durable outcomes are held waiting for an
// earlier gap to resolve.
func (t *Tracker) PendingOutOfOrder() int { return len(t.durable) }
