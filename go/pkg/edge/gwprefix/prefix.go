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
// 3.5). Frames publish asynchronously and may earn their durable outcome out of
// order; this tracker advances the resolved watermark across a CONTIGUOUS run of
// RESOLVING dispositions.
//
// # Dispositions are the frozen ABI, not a local approximation
//
// Outcomes are `edgev1.EdgeRecordDispositionKind` values, used DIRECTLY. There is
// no local two-valued accepted/rejected enum, because the frozen ABI distinguishes
// five kinds whose meanings are not interchangeable:
//
//	ACCEPTED_AUTHORITATIVE (1)  primary stream            resolves
//	ACCEPTED_AUDIT_ONLY    (2)  audit stream              resolves
//	ACCEPTED_QUARANTINE    (3)  quarantine DLQ            resolves
//	REJECTED_PERMANENT     (4)  reject-audit DLQ          resolves
//	REJECTED_RETRYABLE     (5)  transient                 NEVER resolves
//
// A local enum cannot carry those meanings, and collapsing them is actively
// dangerous: a REJECTED_RETRYABLE refusal is transient, so treating it as resolved
// would let the prefix advance past work the gateway has not accepted and would
// eventually authorize reclaiming customer data that was never delivered.
// Retryable therefore CAPS the prefix, exactly like a missing outcome.
//
// Unspecified and undeclared kinds fail closed.
//
// # Two watermarks, deliberately separate
//
// REMOTE RESOLUTION and LOCAL RECLAIM are distinct facts:
//
//   - ResolvedThrough is what the GATEWAY durably resolved. It says nothing about
//     local spool bytes.
//   - ReclaimableThrough is the contiguous run for which the AGENT has durably
//     recorded its own terminal action. Only this authorizes releasing bytes.
//
// A gateway PubAck does NOT by itself reclaim anything, and one local terminal
// event does not vouch for earlier sequences: each sequence advances the local
// watermark only after ITS OWN durability/quarantine action is recorded, so the
// local watermark is a contiguous prefix of locally-recorded outcomes.
//
// The tracker can be rebuilt from the durable stream/DLQ and holds no I/O. Not
// safe for concurrent use.
package gwprefix

import (
	"errors"
	"fmt"

	"google.golang.org/protobuf/reflect/protoreflect"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Disposition is the frozen gateway outcome kind. Aliasing the generated type
// rather than redefining it keeps this package incapable of drifting from the ABI.
type Disposition = edgev1.EdgeRecordDispositionKind

const (
	// DispositionUnspecified is the proto3 zero value: not a durable outcome.
	DispositionUnspecified = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_UNSPECIFIED
	// DispositionAcceptedAuthoritative resolves: the record is in the primary stream.
	DispositionAcceptedAuthoritative = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
	// DispositionAcceptedAuditOnly resolves: the record is in the audit stream only.
	DispositionAcceptedAuditOnly = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY
	// DispositionAcceptedQuarantine resolves: the record is in the quarantine DLQ.
	DispositionAcceptedQuarantine = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE
	// DispositionRejectedPermanent resolves: permanently refused to the reject-audit DLQ.
	DispositionRejectedPermanent = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
	// DispositionRejectedRetryable NEVER resolves: the refusal is transient, so the
	// sequence may still be delivered and the prefix must stop here.
	DispositionRejectedRetryable = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE
)

var (
	// ErrUnknownDisposition is returned for an unspecified or undeclared kind.
	// Fail closed: an unrecognised outcome must never advance anything.
	ErrUnknownDisposition = errors.New("gwprefix: unspecified or undeclared disposition kind")
	// ErrBelowBase is returned when a sequence precedes the tracker's base.
	ErrBelowBase = errors.New("gwprefix: sequence precedes lane base")
	// ErrConflict is returned when a sequence is re-recorded with a different kind.
	ErrConflict = errors.New("gwprefix: conflicting disposition for a sequence")
	// ErrNotResolved is returned when a local terminal outcome is recorded for a
	// sequence the gateway has not resolved.
	ErrNotResolved = errors.New("gwprefix: sequence is not within the resolved prefix")
)

// resolves reports whether a disposition RESOLVES the sequence. Only the four
// resolving kinds do; REJECTED_RETRYABLE is transient and must cap the prefix.
func resolves(d Disposition) bool {
	switch d {
	case DispositionAcceptedAuthoritative,
		DispositionAcceptedAuditOnly,
		DispositionAcceptedQuarantine,
		DispositionRejectedPermanent:
		return true
	case DispositionUnspecified, DispositionRejectedRetryable:
		return false
	default:
		return false
	}
}

// declared reports whether the kind is a non-zero member of the generated
// descriptor. Checked generically so a kind added to the proto is recognised
// through regeneration, and an undeclared number can never be mistaken for one.
func declared(d Disposition) bool {
	var e protoreflect.Enum = d

	if e.Number() == 0 {
		return false
	}

	return e.Descriptor().Values().ByNumber(e.Number()) != nil
}

// Tracker follows one lane's dispositions, computes the contiguous REMOTE
// resolved prefix, and separately tracks the contiguous LOCAL prefix for which
// the agent has durably recorded its own terminal action. Not safe for concurrent
// use.
type Tracker struct {
	base uint64

	resolved    uint64 // remote contiguous resolved watermark (base-1 == nothing)
	reclaimable uint64 // local contiguous terminal-recorded watermark

	// pending holds dispositions not yet inside the remote prefix, including
	// retryable ones (which are retained but never resolve).
	pending map[uint64]Disposition
	// disposition retains the outcome of every RESOLVED-but-not-yet-reclaimed
	// sequence, so all five kinds stay distinguishable inside the prefix.
	disposition map[uint64]Disposition
	// localTerminal records which sequences the AGENT has durably acted on. The
	// reclaim watermark advances only across a contiguous run of these, so one
	// late event can never vouch for an earlier sequence.
	localTerminal map[uint64]struct{}
}

// New creates a tracker whose lane begins at firstSequence (>= 1).
func New(firstSequence uint64) *Tracker {
	if firstSequence == 0 {
		firstSequence = 1
	}

	return &Tracker{
		base:          firstSequence,
		resolved:      firstSequence - 1,
		reclaimable:   firstSequence - 1,
		pending:       make(map[uint64]Disposition),
		disposition:   make(map[uint64]Disposition),
		localTerminal: make(map[uint64]struct{}),
	}
}

// Record marks a sequence's gateway disposition and advances the contiguous
// REMOTE prefix across newly-contiguous RESOLVING outcomes.
//
// A REJECTED_RETRYABLE disposition is retained but never resolves, so it caps the
// prefix exactly like a missing outcome. Recording does not advance reclamation.
func (t *Tracker) Record(seq uint64, d Disposition) error {
	if !declared(d) {
		return fmt.Errorf("%w: %v(%d)", ErrUnknownDisposition, d, int32(d))
	}

	if seq < t.base {
		return fmt.Errorf("%w: seq %d < base %d", ErrBelowBase, seq, t.base)
	}

	if seq <= t.resolved {
		if prev, ok := t.disposition[seq]; ok && prev != d {
			return fmt.Errorf("%w: seq %d was %v now %v", ErrConflict, seq, prev, d)
		}

		return nil
	}

	if prev, ok := t.pending[seq]; ok {
		if prev == d {
			return nil
		}

		// A RETRYABLE outcome is PROVISIONAL, not a verdict: it explicitly leaves
		// the sequence eligible for redelivery. When the agent retransmits and the
		// gateway resolves it, that resolving kind SUPERSEDES the provisional one
		// and the prefix advances -- including across sequences queued behind it.
		// Treating the retryable value as immutable would wedge the lane forever:
		// the retry can never be recorded, so the prefix can never move again.
		if prev == DispositionRejectedRetryable && resolves(d) {
			t.pending[seq] = d
			t.advanceResolved()

			return nil
		}

		// Anything else is a genuine contradiction: a RESOLVING kind is terminal,
		// so it may not change to a different resolving kind nor be downgraded
		// back to retryable.
		return fmt.Errorf("%w: seq %d was %v now %v", ErrConflict, seq, prev, d)
	}

	t.pending[seq] = d
	t.advanceResolved()

	return nil
}

// advanceResolved walks the contiguous run of RESOLVING dispositions. It stops at
// the first gap or retryable outcome.
func (t *Tracker) advanceResolved() {
	for {
		next := t.resolved + 1

		d, ok := t.pending[next]
		if !ok || !resolves(d) {
			return
		}

		delete(t.pending, next)
		// Retain the kind: the prefix advancing must not erase WHAT happened.
		t.disposition[next] = d
		t.resolved = next
	}
}

// RecordTerminalOutcome marks that the AGENT has durably recorded ITS OWN
// terminal action for exactly this sequence, then advances the local reclaim
// watermark across the contiguous run of such sequences.
//
// It records ONE sequence. Recording sequence 2 does not vouch for sequence 1: if
// sequence 1's local quarantine transaction is still pending, the watermark stays
// below it and sequence 1's evidence is retained. Rejected for a sequence the
// gateway has not resolved.
func (t *Tracker) RecordTerminalOutcome(seq uint64) error {
	if seq < t.base {
		return fmt.Errorf("%w: seq %d < base %d", ErrBelowBase, seq, t.base)
	}

	if seq > t.resolved {
		return fmt.Errorf("%w: seq %d > resolved %d", ErrNotResolved, seq, t.resolved)
	}

	if seq <= t.reclaimable {
		return nil // idempotent
	}

	t.localTerminal[seq] = struct{}{}
	t.advanceReclaimable()

	return nil
}

// advanceReclaimable walks the contiguous run of locally-recorded terminal
// outcomes, releasing each sequence's retained evidence as it passes.
//
// Overflow-safe by construction: termination is decided by MAP MEMBERSHIP, not by
// a `s <= seq` counter. MaxUint64 is a valid final sequence (lanes never wrap), and
// after processing it `next` wraps to 0 -- which can never be a member, because
// base is at least 1 and RecordTerminalOutcome refuses anything below base. The
// retired counting loop hung here precisely because `s++` wrapped while `s <= seq`
// stayed true forever.
func (t *Tracker) advanceReclaimable() {
	for {
		next := t.reclaimable + 1

		if _, ok := t.localTerminal[next]; !ok {
			return
		}

		delete(t.localTerminal, next)
		delete(t.disposition, next)
		t.reclaimable = next
	}
}

// ResolvedThrough returns the REMOTE contiguous resolved watermark. It stops at a
// gap OR at a REJECTED_RETRYABLE outcome.
//
// This is NOT a reclaim signal. See ReclaimableThrough.
func (t *Tracker) ResolvedThrough() uint64 { return t.resolved }

// ReclaimableThrough returns the LOCAL watermark: the contiguous run for which the
// agent has durably recorded its own terminal action, and therefore how far spool
// bytes may be released. It never exceeds ResolvedThrough.
func (t *Tracker) ReclaimableThrough() uint64 { return t.reclaimable }

// Disposition reports the frozen outcome kind of a resolved sequence, and whether
// it is still retained. All five kinds stay distinguishable; retained from
// resolution until reclamation.
func (t *Tracker) Disposition(seq uint64) (Disposition, bool) {
	d, ok := t.disposition[seq]

	return d, ok
}

// PendingDisposition reports a recorded-but-unresolved outcome, such as a
// retryable refusal capping the prefix.
func (t *Tracker) PendingDisposition(seq uint64) (Disposition, bool) {
	d, ok := t.pending[seq]

	return d, ok
}

// PendingOutOfOrder reports how many recorded outcomes are held outside the
// remote prefix, whether waiting on an earlier gap or non-resolving.
func (t *Tracker) PendingOutOfOrder() int { return len(t.pending) }

// RetainedDispositions reports how many resolved-but-unreclaimed dispositions are
// held -- the evidence that must survive until the agent records terminal
// outcomes. Bounded by the reclaim lag.
func (t *Tracker) RetainedDispositions() int { return len(t.disposition) }
