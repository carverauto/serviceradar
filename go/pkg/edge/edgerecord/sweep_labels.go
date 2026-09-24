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

import "errors"

// SweepJoinLabel is the PORTABLE semantic reason a sweep record was refused. Most
// of these come from the CORRELATION, but not all: the disposition label is
// BODY-owned, decided from the batch alone with no signed authority consulted.
// Labels and gates are orthogonal, so a label does not name the gate that emits it.
//
// It exists because a formatted error suffix is not comparable across runtimes:
// Elixir has no access to Go's message text, so "exact reason parity" between the
// two implementations was undefined rather than merely unproven.
//
// The FIFTEEN NAMES below are FROZEN by the sweep correlation requirements in
// `openspec/changes/freeze-edge-record-v1-abi`.
//
// WHAT IS FROZEN TODAY IS THE NAME SET, NOT ITS ORDER AND NOT ITS EMISSION.
//   - The SET is pinned in both runtimes by an inventory test.
//   - The ORDER is not frozen: the shared vector manifest that would give an order
//     its authority does not exist yet. The inventories therefore compare an
//     unordered set, and any list here is presentation only.
//   - EMISSION: Go emits all fifteen. Elixir's SweepCorrelate emits the correlation
//     labels and the disposition; it has no full body validator yet (task 1.2-c), so
//     it names one as a precondition rather than enforcing it.
//   - The (label, gate) PAIR is pinned for TEN of the fifteen in both runtimes -- the
//     nine correlation labels and the disposition. The FIVE TIME labels are asserted
//     for their label only, with no vector pinning a gate; task 1.3-f owns that.
//
// LABELS AND GATES ARE ORTHOGONAL. Most of these are emitted by the correlation,
// but SweepLabelSourceRunIDDisposition is emitted by the BODY VALIDATOR, because
// that rule is decidable from the batch alone. A label does not imply a gate.
//
// Two rejections this matrix deliberately leaves UNLABELLED are the enum
// admission of an unknown sweep source and the reserved recovery lane. Both are
// pre-existing gates with per-runtime typed reasons, and demanding an exact label
// from them would be unsatisfiable against this contract.
type SweepJoinLabel string

const (
	// SweepLabelSourceAuthorityAbsent: the record carries no source
	// authorization. The field is OPTIONAL at the record level, so no structural
	// gate can require it -- the sweep correlation is the first thing that asks.
	SweepLabelSourceAuthorityAbsent SweepJoinLabel = "source_authority_absent"

	// SweepLabelSourceKind: the signed authorization kind is not the one this
	// body's source maps to.
	SweepLabelSourceKind SweepJoinLabel = "source_kind"

	// SweepLabelSourceRunIDDisposition: source_run_id is present where its row
	// forbids it, absent where required, or not a canonical UUID where required.
	// Emitted by the BODY validator, not the correlation.
	SweepLabelSourceRunIDDisposition SweepJoinLabel = "source_run_id_disposition"

	// SweepLabelContextID: the signed context does not equal the ONE operand this
	// source selects.
	SweepLabelContextID SweepJoinLabel = "context_id"

	// SweepLabelRangeID: the signed scope id is not the body's target range id.
	SweepLabelRangeID SweepJoinLabel = "range_id"

	// SweepLabelScopeDigest: the signed scope digest is not the body's target
	// range digest. SEPARATE from SweepLabelTargetRangeDigest because the signed
	// claim carries BOTH, and one label covering both would let either predicate
	// be deleted with the manifest still matching.
	SweepLabelScopeDigest SweepJoinLabel = "scope_digest"

	// SweepLabelTargetRangeDigest: the signed target-range digest is not the
	// body's.
	SweepLabelTargetRangeDigest SweepJoinLabel = "target_range_digest"

	// SweepLabelPlanDigest: the signed execution-plan digest is not the body's.
	SweepLabelPlanDigest SweepJoinLabel = "plan_digest"

	// SweepLabelExecutionShard: the body's shard is not the attested producer's.
	SweepLabelExecutionShard SweepJoinLabel = "execution_shard"

	// SweepLabelAssignmentEpoch: the body's epoch is not the attested authority
	// epoch.
	SweepLabelAssignmentEpoch SweepJoinLabel = "assignment_epoch"

	// SweepLabelBatchTimeWindow: the batch observation time is outside the signed
	// collection window.
	SweepLabelBatchTimeWindow SweepJoinLabel = "batch_time_window"

	// SweepLabelHostTimeWindow: a per-host absolute time is outside the window,
	// with no overflow involved.
	SweepLabelHostTimeWindow SweepJoinLabel = "host_time_window"

	// SweepLabelHostTimeOverflow: batch time plus the per-host delta OVERFLOWS
	// int64. Distinct from the window label because a wrapped sum can land INSIDE
	// the window, so the two are independently removable predicates.
	SweepLabelHostTimeOverflow SweepJoinLabel = "host_time_overflow"

	// SweepLabelTraceTimeWindow: an MTR trace identity time is outside the window.
	SweepLabelTraceTimeWindow SweepJoinLabel = "trace_time_window"

	// SweepLabelTraceTimeOverflow: an MTR trace identity's UUIDv7 millisecond
	// timestamp does not convert to int64 nanoseconds. Distinct from the window
	// label for the same reason as the host pair.
	SweepLabelTraceTimeOverflow SweepJoinLabel = "trace_time_overflow"
)

// sweepJoinError carries a frozen portable label AND the typed outcome of the
// gate that emitted it. The two are separate fields because labels and gates are
// ORTHOGONAL: the disposition label comes from the body validator and keeps
// ErrSweepSourceRunID, while the correlation labels keep ErrSweepJoin. Folding
// every label under one sentinel would silently reclassify a body rejection as a
// correlation one.
//
// THE TYPE IS UNEXPORTED, AND THAT IS THE POINT. While it was exported with an
// exported Label field, external code could construct one directly and bypass the
// registry entirely -- SweepLabelOf returned an unregistered label as though it
// were frozen, and Error() panicked on the nil gate. Callers observe labels
// through SweepLabelOf and gates through errors.Is; neither needs the concrete
// type, and neither can now forge one.
type sweepJoinError struct {
	label SweepJoinLabel
	// gate is the pre-existing sentinel callers match with errors.Is.
	gate error
}

func (e *sweepJoinError) Error() string {
	return e.gate.Error() + ": " + string(e.label)
}

// Unwrap keeps errors.Is against the OWNING gate's typed outcome true.
func (e *sweepJoinError) Unwrap() error { return e.gate }

// sweepLabelRegistry is the CANONICAL set of labels this runtime may emit, and
// the single source the inventory compares against.
//
// It exists because a test that hand-builds both sides of the comparison proves
// nothing about the implementation: adding a sixteenth constant left the old
// inventory green. Emission is validated against THIS map, so a label that is not
// registered cannot reach the wire at all -- a stray constant is inert rather than
// silently live.
//
//nolint:gochecknoglobals // immutable registry; it is the emission gate, see above
var sweepLabelRegistry = map[SweepJoinLabel]struct{}{
	SweepLabelSourceAuthorityAbsent:  {},
	SweepLabelSourceKind:             {},
	SweepLabelSourceRunIDDisposition: {},
	SweepLabelContextID:              {},
	SweepLabelRangeID:                {},
	SweepLabelScopeDigest:            {},
	SweepLabelTargetRangeDigest:      {},
	SweepLabelPlanDigest:             {},
	SweepLabelExecutionShard:         {},
	SweepLabelAssignmentEpoch:        {},
	SweepLabelBatchTimeWindow:        {},
	SweepLabelHostTimeWindow:         {},
	SweepLabelHostTimeOverflow:       {},
	SweepLabelTraceTimeWindow:        {},
	SweepLabelTraceTimeOverflow:      {},
}

// SweepLabels returns the canonical label set. Order is UNSPECIFIED and callers
// SHALL NOT depend on it: no shared manifest exists yet to give an order
// authority, so the set is what is frozen.
func SweepLabels() []SweepJoinLabel {
	out := make([]SweepJoinLabel, 0, len(sweepLabelRegistry))
	for l := range sweepLabelRegistry {
		out = append(out, l)
	}
	return out
}

// newSweepError builds a labelled rejection, refusing any label outside the
// canonical registry. The panic is deliberate and is a PROGRAMMING-ERROR guard,
// not input validation: labels are compile-time constants, so an unregistered one
// is a bug in this package rather than anything a record can cause.
func newSweepError(l SweepJoinLabel, gate error) error {
	if _, ok := sweepLabelRegistry[l]; !ok {
		panic("edgerecord: " + string(l) + " is not a registered sweep label")
	}
	if gate == nil {
		panic("edgerecord: a labelled sweep rejection must carry its owning gate")
	}
	return &sweepJoinError{label: l, gate: gate}
}

// sweepJoinErr builds a labelled CORRELATION rejection.
func sweepJoinErr(l SweepJoinLabel) error { return newSweepError(l, ErrSweepJoin) }

// sweepBodyErr builds a labelled BODY-VALIDATION rejection.
func sweepBodyErr(l SweepJoinLabel, gate error) error { return newSweepError(l, gate) }

// SweepLabelOf recovers the portable label from a rejection, if it carries one.
//
// A FALSE RESULT MEANS ONLY "not a labelled sweep rejection". It does NOT identify the
// rejection as one of the deliberately unlabelled gates: an unrelated failure,
// including a bug, returns false the same way. A caller that needs to know WHICH
// gate refused MUST assert that gate separately with errors.Is -- this function
// cannot tell an intentional absence from an unexpected one.
func SweepLabelOf(err error) (SweepJoinLabel, bool) {
	var e *sweepJoinError
	if !errors.As(err, &e) {
		return "", false
	}
	// A TYPED NIL satisfies errors.As -- it sets e to nil and reports true -- so
	// reading e.label without this check panics. A caller passing a nil-valued
	// *sweepJoinError is asking a question, not causing an error, and must get an
	// answer rather than a crash.
	if e == nil {
		return "", false
	}
	// Defence in depth: only a REGISTERED label is ever reported as frozen. The
	// constructors already enforce this, so an unregistered one here would mean the
	// invariant was broken some other way.
	if _, ok := sweepLabelRegistry[e.label]; !ok {
		return "", false
	}
	return e.label, true
}
