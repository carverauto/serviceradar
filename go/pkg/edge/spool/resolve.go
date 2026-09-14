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

package spool

import (
	"sort"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Outcome is the single restart outcome of one slot. Resolution is TOTAL: every
// slot present after restart resolves to exactly one of these.
type Outcome uint8

const (
	// OutcomeUnknown is the zero value; ResolveSlot never returns it.
	OutcomeUnknown Outcome = iota
	// OutcomeCommitted: intact commit evidence, valid bindings, intact bytes. The
	// receipt stands and the sender may expose the slot.
	OutcomeCommitted
	// OutcomeAttributedLoss: intact evidence, a binding that verifies for the slot,
	// a representable span, and missing or corrupt record bytes.
	OutcomeAttributedLoss
	// OutcomeUnattributable: intact evidence and a binding that verifies for the
	// slot, but a span the frozen identity cannot represent. Its coverage reason is
	// always DISCRIMINATOR_UNREPRESENTABLE.
	OutcomeUnattributable
	// OutcomeAmbiguousAllocated: the append may have been acknowledged but cannot be
	// proven committed. It enters rollover coverage and its sequence is never reused.
	OutcomeAmbiguousAllocated
	// OutcomeDiscardablePreparation: no evidence, no allocation, no complete record.
	// The append never became durable.
	OutcomeDiscardablePreparation
)

func (o Outcome) String() string {
	switch o {
	case OutcomeCommitted:
		return "COMMITTED"
	case OutcomeAttributedLoss:
		return "ATTRIBUTED_LOSS"
	case OutcomeUnattributable:
		return "UNATTRIBUTABLE"
	case OutcomeAmbiguousAllocated:
		return "AMBIGUOUS_ALLOCATED_SLOT"
	case OutcomeDiscardablePreparation:
		return "DISCARDABLE_PREPARATION"
	case OutcomeUnknown:
		return "UNKNOWN"
	default:
		return "UNKNOWN"
	}
}

// EvidenceState is what the redundant commit-evidence copies say about a slot once
// compared against each other.
type EvidenceState uint8

const (
	// EvidenceNone: no copy holds any entry, readable or not, for the slot.
	EvidenceNone EvidenceState = iota
	// EvidenceCommitted: at least one valid copy is COMMITTED and no valid copy
	// disagrees with it. This is the only INTACT state.
	EvidenceCommitted
	// EvidencePrepared: valid copies agree the slot was allocated, none shows a commit.
	EvidencePrepared
	// EvidenceUnreadable: entries exist but no copy yields a valid state.
	EvidenceUnreadable
	// EvidenceDisagree: two valid copies record different states or contents. The
	// higher generation is deliberately NOT taken as authoritative.
	EvidenceDisagree
)

// BytesState is the condition of a slot's record bytes, judged against intact
// commit evidence.
type BytesState uint8

const (
	// BytesMissing: absent or short (torn or truncated).
	BytesMissing BytesState = iota
	// BytesCorrupt: present but failing a header or body checksum.
	BytesCorrupt
	// BytesIntact: checksum-valid and matching the committed wrapper and record hash.
	BytesIntact
	// BytesContradict: checksum-valid but naming a different sequence, event, length,
	// or record hash than the commit evidence. The wrapper binding is unverifiable,
	// which is not the same as lost bytes.
	BytesContradict
)

// AttributionState is the attribution-binding layer's verdict for one slot, in the
// terms the frozen reason precedence is written in.
type AttributionState uint8

const (
	// AttributionAbsent: no binding record exists for the slot.
	AttributionAbsent AttributionState = iota
	// AttributionVersionUnsupported: binding_version is READABLE but unsupported.
	AttributionVersionUnsupported
	// AttributionNotVerifying: a binding exists but does not verify for this slot for
	// any other reason (unreadable, truncated, malformed, digest failure, relational
	// mismatch, or inconsistent with the commit evidence).
	AttributionNotVerifying
	// AttributionVerifies: binding_verifies_for_slot holds.
	AttributionVerifies
)

// AttributionVerdict is binding_verifies_for_slot and span_is_representable as two
// SEPARATE predicates. Representable is meaningful only when State is
// AttributionVerifies; collapsing the two would make the verified-but-unrepresentable
// case impossible to express.
type AttributionVerdict struct {
	State         AttributionState
	Representable bool
	// Digest is the binding digest the layer found. The spool compares it against the
	// digest the commit evidence names, so a verifying binding that is not the one
	// committed for this slot does not verify.
	Digest []byte
}

// ReceiptState is the producer idempotency/receipt binding layer's verdict for a slot.
type ReceiptState uint8

const (
	// ReceiptAbsent: no receipt binding exists for the slot.
	ReceiptAbsent ReceiptState = iota
	// ReceiptUnverifiable: a receipt binding exists but cannot be verified.
	ReceiptUnverifiable
	// ReceiptValid: the receipt binding verifies.
	ReceiptValid
)

// ReceiptVerdict carries the receipt binding verdict and the digest it verified.
type ReceiptVerdict struct {
	State  ReceiptState
	Digest []byte
}

// SlotEvidence is the surviving trusted evidence the spool hands a binding layer so
// it can evaluate its relation for the slot. EventID and RecordSHA256 are nil when no
// surviving evidence agrees on them.
type SlotEvidence struct {
	Sequence     uint64
	EventID      []byte
	RecordSHA256 []byte
}

// BindingInspector is implemented by the layers that own the producer
// idempotency/receipt binding and the attribution binding. The spool owns the commit
// evidence and the record bytes; it asks these layers only for their verdicts.
type BindingInspector interface {
	InspectAttribution(SlotEvidence) AttributionVerdict
	InspectReceipt(SlotEvidence) ReceiptVerdict
}

// SlotObservation is everything restart resolution considers for one slot.
type SlotObservation struct {
	Sequence uint64
	Evidence EvidenceState
	// Allocated: the sequence is at or below the durable sequence high-water.
	Allocated bool
	// CompleteRecord: a complete, checksum-valid record exists for the slot.
	CompleteRecord bool
	// InTornTail: the slot lies in the spool's torn tail -- its own record never fully
	// landed, so its declared extent runs past the segment end or past where a later
	// slot was placed. Fully present but damaged bytes are not a torn tail.
	InTornTail bool
	// Bytes is judged against the committed entry; meaningful for EvidenceCommitted.
	Bytes BytesState
	// ReceiptRequired / AttributionRequired: the committed entry declares the binding.
	ReceiptRequired     bool
	Receipt             ReceiptState
	AttributionRequired bool
	Attribution         AttributionVerdict
}

// Coverage is the rollover classification of a slot that enters coverage.
type Coverage struct {
	Attributed bool
	// Reason is set only when Attributed is false.
	Reason edgev1.EdgeUnattributableReason
}

// SlotResolution is the resolved outcome of one slot.
type SlotResolution struct {
	Sequence uint64
	Outcome  Outcome
	Evidence EvidenceState
	// Coverage is meaningful only when EntersCoverage reports true.
	Coverage Coverage
}

// EntersCoverage reports whether the slot must be accounted for by rollover coverage
// rather than delivered or discarded.
func (r SlotResolution) EntersCoverage() bool {
	switch r.Outcome {
	case OutcomeAttributedLoss, OutcomeUnattributable, OutcomeAmbiguousAllocated:
		return true
	case OutcomeUnknown, OutcomeCommitted, OutcomeDiscardablePreparation:
		return false
	default:
		return false
	}
}

// ResolveSlot resolves one slot to exactly one outcome. The rows are evaluated in
// the order the restart contract lists them, first match wins.
func ResolveSlot(o SlotObservation) SlotResolution {
	r := SlotResolution{Sequence: o.Sequence, Evidence: o.Evidence}
	verifies := o.Attribution.State == AttributionVerifies

	switch {
	case o.Evidence == EvidenceCommitted:
		// A declared binding must verify; an undeclared one must be absent, because a
		// binding the commit never named is not the commit's binding.
		attributionValid := o.Attribution.State == AttributionAbsent
		if o.AttributionRequired {
			attributionValid = verifies
		}
		receiptValid := o.Receipt == ReceiptAbsent
		if o.ReceiptRequired {
			receiptValid = o.Receipt == ReceiptValid
		}
		bytesLost := o.Bytes == BytesMissing || o.Bytes == BytesCorrupt

		switch {
		case attributionValid && receiptValid && o.Bytes == BytesIntact:
			r.Outcome = OutcomeCommitted
		case verifies && o.Attribution.Representable && bytesLost:
			r.Outcome = OutcomeAttributedLoss
			r.Coverage = Coverage{Attributed: true}
		case verifies && !o.Attribution.Representable:
			r.Outcome = OutcomeUnattributable
			r.Coverage = Coverage{
				Reason: edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_DISCRIMINATOR_UNREPRESENTABLE,
			}
		default:
			// Intact evidence with an attribution, wrapper, or receipt binding that is
			// missing or unverifiable.
			r.Outcome = OutcomeAmbiguousAllocated
			r.Coverage = rolloverCoverage(o)
		}

	case o.Evidence != EvidenceNone || o.Allocated || o.CompleteRecord:
		// Evidence missing, corrupt, prepared-only, or disagreeing where the append may
		// have been acknowledged -- including an allocated sequence with no marker and
		// a complete prepared record with no marker.
		r.Outcome = OutcomeAmbiguousAllocated
		r.Coverage = rolloverCoverage(o)

	default:
		r.Outcome = OutcomeDiscardablePreparation
	}
	return r
}

// rolloverCoverage classifies a slot entering coverage. ATTRIBUTED requires BOTH
// binding_verifies_for_slot AND span_is_representable; otherwise the frozen reason
// precedence applies, first match wins.
func rolloverCoverage(o SlotObservation) Coverage {
	a := o.Attribution
	if a.State == AttributionVerifies && a.Representable {
		return Coverage{Attributed: true}
	}

	var reason edgev1.EdgeUnattributableReason
	switch {
	// Row 1: a torn tail explains the absent binding, so it is not charged as a
	// missing binding.
	case o.InTornTail && a.State == AttributionAbsent:
		reason = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL
	// Row 2.
	case a.State == AttributionAbsent:
		reason = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING
	// Row 3: fail closed at the version, without trial hashing.
	case a.State == AttributionVersionUnsupported:
		reason = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_VERSION_UNSUPPORTED
	// Row 5: verified but not representable.
	case a.State == AttributionVerifies:
		reason = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_DISCRIMINATOR_UNREPRESENTABLE
	// Row 4 is the catch-all for a present binding that does not verify, including
	// a verdict value this reader does not know.
	default:
		reason = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT
	}
	return Coverage{Reason: reason}
}

// Resolution is the restart resolution of one spool.
type Resolution struct {
	// HighWater is the durable sequence high-water: every sequence in [1, HighWater]
	// is allocated and never reused.
	HighWater uint64
	// Slots lists, in sequence order, every allocated slot that did NOT resolve
	// COMMITTED. Every other sequence in [1, HighWater] is COMMITTED.
	Slots []SlotResolution
	// Discarded lists torn preparations found beyond the high-water. Sequence is 0
	// when the torn bytes did not preserve a readable header.
	Discarded []SlotResolution
}

// Slot returns the resolution of sequence seq, and false when seq is above the
// high-water (never allocated).
func (r Resolution) Slot(seq uint64) (SlotResolution, bool) {
	if seq == 0 || seq > r.HighWater {
		return SlotResolution{}, false
	}
	i := sort.Search(len(r.Slots), func(i int) bool { return r.Slots[i].Sequence >= seq })
	if i < len(r.Slots) && r.Slots[i].Sequence == seq {
		return r.Slots[i], true
	}
	return SlotResolution{Sequence: seq, Outcome: OutcomeCommitted, Evidence: EvidenceCommitted}, true
}
