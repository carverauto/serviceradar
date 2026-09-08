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

import (
	"bytes"
	"errors"
	"math"
	"testing"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func d32domain(tag byte) []byte {
	b := make([]byte, 32)
	for i := range b {
		b[i] = tag + byte(i)
	}
	return b
}

func validSweepBatch(t *testing.T) *edgev1.SweepObservationBatchV1 {
	t.Helper()
	return &edgev1.SweepObservationBatchV1{
		ExecutionId: mustUUID(t), ExecutionPlanId: mustUUID(t), TargetRangeId: mustUUID(t),
		ExecutionPlanSha256: d32domain(0x10), TargetRangeSha256: d32domain(0x20),
		AvailabilityPolicyId: []byte("policy-1"), BatchSequence: 1, ObservedAtUnixNano: 1,
		Source:             edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
		SourceRunId:        mustUUID(t), // REQUIRED on this row; distinct from execution_id
		ConfiguredModeBits: uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP) | uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR),
		TestedChecks: []*edgev1.SweepTestV1{
			{Mode: edgev1.SweepMode_SWEEP_MODE_ICMP, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
			{Mode: edgev1.SweepMode_SWEEP_MODE_MTR, Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP},
		},
		Hosts: []*edgev1.SweepHostObservationV1{{
			Address:        []byte{10, 0, 0, 1},
			ResultModeBits: uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP) | uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_MTR),
			Icmp:           &edgev1.SweepIcmpSummaryV1{Outcome: edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS, TargetReached: true, Sent: 1, Received: 1},
			Mtr:            &edgev1.SweepMtrSummaryV1{TraceId: mustUUID(t), Outcome: edgev1.MtrOutcome_MTR_OUTCOME_REACHED, TargetReached: true, TotalHops: 3},
		}},
	}
}

func TestValidateSweepObservationBatch(t *testing.T) {
	if err := ValidateSweepObservationBatch(validSweepBatch(t)); err != nil {
		t.Fatalf("valid sweep batch: %v", err)
	}

	// configured_mode_bits must equal the derived bitmask.
	b := validSweepBatch(t)
	b.ConfiguredModeBits = uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_ICMP)
	if err := ValidateSweepObservationBatch(b); !errors.Is(err, ErrSweepModeBits) {
		t.Fatalf("mode-bit mismatch = %v, want ErrSweepModeBits", err)
	}

	// Missing batch identity/plan/range/policy is rejected.
	b1 := validSweepBatch(t)
	b1.ExecutionPlanSha256 = nil
	if err := ValidateSweepObservationBatch(b1); !errors.Is(err, ErrSweepIdentity) {
		t.Fatalf("missing plan digest = %v, want ErrSweepIdentity", err)
	}

	// A named MTR result bit without an MTR summary is rejected.
	b2 := validSweepBatch(t)
	b2.Hosts[0].Mtr = nil
	if err := ValidateSweepObservationBatch(b2); !errors.Is(err, ErrSweepModeSummary) {
		t.Fatalf("MTR bit without summary = %v, want ErrSweepModeSummary", err)
	}

	// An out-of-range open-port check index is rejected.
	b3 := validSweepBatch(t)
	b3.Hosts[0].OpenPorts = []*edgev1.SweepOpenPortV1{{TestedCheckIndex: 99}}
	if err := ValidateSweepObservationBatch(b3); !errors.Is(err, ErrSweepCheckIndex) {
		t.Fatalf("bad check index = %v, want ErrSweepCheckIndex", err)
	}

	// ICMP mode paired with a UDP protocol / nonzero port is rejected.
	b4 := validSweepBatch(t)
	b4.TestedChecks[0].Protocol = edgev1.TransportProtocol_TRANSPORT_PROTOCOL_UDP
	b4.TestedChecks[0].Port = 99999
	if err := ValidateSweepObservationBatch(b4); !errors.Is(err, ErrSweepChecks) {
		t.Fatalf("icmp+udp/port = %v, want ErrSweepChecks", err)
	}

	// received > sent is rejected.
	b5 := validSweepBatch(t)
	b5.Hosts[0].Icmp.Received = 9
	if err := ValidateSweepObservationBatch(b5); !errors.Is(err, ErrSweepSummary) {
		t.Fatalf("received>sent = %v, want ErrSweepSummary", err)
	}

	// NaN loss is rejected.
	b6 := validSweepBatch(t)
	b6.Hosts[0].Icmp.PacketLossPct = proto.Float64(math.NaN())
	if err := ValidateSweepObservationBatch(b6); !errors.Is(err, ErrSweepSummary) {
		t.Fatalf("NaN loss = %v, want ErrSweepSummary", err)
	}

	// An unspecified outcome is rejected.
	b7 := validSweepBatch(t)
	b7.Hosts[0].Icmp.Outcome = edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_UNSPECIFIED
	if err := ValidateSweepObservationBatch(b7); !errors.Is(err, ErrSweepSummary) {
		t.Fatalf("unspecified outcome = %v, want ErrSweepSummary", err)
	}

	// A TCP summary present for a host that named no TCP mode is rejected.
	b8 := validSweepBatch(t)
	b8.Hosts[0].Tcp = &edgev1.SweepTcpSummaryV1{Outcome: edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS}
	if err := ValidateSweepObservationBatch(b8); !errors.Is(err, ErrSweepModeSummary) {
		t.Fatalf("extraneous tcp summary = %v, want ErrSweepModeSummary", err)
	}
}

func TestValidateMtrTraceBatchCorrelation(t *testing.T) {
	mtrBatch := func(traces []*edgev1.MtrTraceEventV1) *edgev1.MtrTraceBatchV1 {
		return &edgev1.MtrTraceBatchV1{
			NetworkScopeId: mustUUID(t), AgentId: mustUUID(t), BatchSequence: 1,
			Source:      edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
			Correlation: &edgev1.MtrTraceBatchV1_ScheduledCheck{ScheduledCheck: &edgev1.MtrScheduledCheckContextV1{CheckId: mustUUID(t)}},
			Traces:      traces,
		}
	}
	goodTrace := func() *edgev1.MtrTraceEventV1 {
		return &edgev1.MtrTraceEventV1{
			TraceId: mustUUID(t), EventId: mustUUID(t), SweepHostAddress: []byte{10, 0, 0, 9},
			Outcome: edgev1.MtrOutcome_MTR_OUTCOME_REACHED, Target: "10.0.0.9", Attempted: true, TargetReached: true, TotalHops: 1,
			Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP, IpVersion: 4,
			Hops: []*edgev1.MtrTraceHopV1{{HopNumber: 1, Sent: 3, Received: 3}},
		}
	}
	good := mtrBatch([]*edgev1.MtrTraceEventV1{goodTrace()})
	if err := ValidateMtrTraceBatch(good); err != nil {
		t.Fatalf("valid mtr batch: %v", err)
	}

	// Duplicate hop number is rejected.
	dupHops := goodTrace()
	dupHops.TotalHops = 2
	dupHops.Hops = []*edgev1.MtrTraceHopV1{{HopNumber: 1, Sent: 1, Received: 1}, {HopNumber: 1, Sent: 1, Received: 1}}
	if err := ValidateMtrTraceBatch(mtrBatch([]*edgev1.MtrTraceEventV1{dupHops})); !errors.Is(err, ErrMtrHop) {
		t.Fatalf("duplicate hop number = %v, want ErrMtrHop", err)
	}
	// ip_version 99 is rejected.
	badIP := goodTrace()
	badIP.IpVersion = 99
	if err := ValidateMtrTraceBatch(mtrBatch([]*edgev1.MtrTraceEventV1{badIP})); !errors.Is(err, ErrMtrTrace) {
		t.Fatalf("ip_version 99 = %v, want ErrMtrTrace", err)
	}
	// A nil network scope is rejected.
	noScope := mtrBatch([]*edgev1.MtrTraceEventV1{goodTrace()})
	noScope.NetworkScopeId = nil
	if err := ValidateMtrTraceBatch(noScope); !errors.Is(err, ErrMtrTrace) {
		t.Fatalf("nil network scope = %v, want ErrMtrTrace", err)
	}

	// source=SCHEDULED_CHECK with a command correlation is rejected.
	bad := mtrBatch(nil)
	bad.Correlation = &edgev1.MtrTraceBatchV1_Command{Command: &edgev1.MtrCommandContextV1{CommandId: mustUUID(t)}}
	if err := ValidateMtrTraceBatch(bad); !errors.Is(err, ErrMtrCorrelation) {
		t.Fatalf("source/correlation mismatch = %v, want ErrMtrCorrelation", err)
	}

	// Missing correlation is rejected.
	missing := mtrBatch(nil)
	missing.Correlation = nil
	if err := ValidateMtrTraceBatch(missing); !errors.Is(err, ErrMtrCorrelation) {
		t.Fatalf("missing correlation = %v, want ErrMtrCorrelation", err)
	}

	// A non-terminal trace outcome is rejected.
	nonterminalTrace := goodTrace()
	nonterminalTrace.Outcome = edgev1.MtrOutcome_MTR_OUTCOME_UNSPECIFIED
	nonterminalTrace.TargetReached = false
	if err := ValidateMtrTraceBatch(mtrBatch([]*edgev1.MtrTraceEventV1{nonterminalTrace})); !errors.Is(err, ErrMtrTrace) {
		t.Fatalf("non-terminal outcome = %v, want ErrMtrTrace", err)
	}

	// A hop with received > sent is rejected.
	badhopTrace := goodTrace()
	badhopTrace.Hops = []*edgev1.MtrTraceHopV1{{HopNumber: 1, Sent: 1, Received: 9}}
	if err := ValidateMtrTraceBatch(mtrBatch([]*edgev1.MtrTraceEventV1{badhopTrace})); !errors.Is(err, ErrMtrHop) {
		t.Fatalf("hop received>sent = %v, want ErrMtrHop", err)
	}
}

func TestMtrCompletionRootOrderIndependentAndValidated(t *testing.T) {
	trace := mustUUID(t)
	planRoot := d32domain(0x90)
	rng := d32domain(0x91)
	leaves := []MtrCompletionLeaf{
		{Ordinal: 2, Disposition: MtrDispositionNotAdmitted, RangeSha256: rng},
		{Ordinal: 1, Disposition: MtrDispositionTraceAllocated, TraceID: trace, RangeSha256: rng},
	}
	comm := MtrOrdinalRangeCommitment(leaves)
	root := MtrCompletionRoot
	a, err := root(leaves, 0, 2, planRoot, comm)
	if err != nil {
		t.Fatalf("valid completion: %v", err)
	}
	// Order-independent: shuffling input leaves yields the same root.
	b, err := root([]MtrCompletionLeaf{leaves[1], leaves[0]}, 0, 2, planRoot, comm)
	if err != nil || string(a) != string(b) {
		t.Fatalf("completion root must be order-independent: %v", err)
	}
	// A different disposition changes the root but keeps membership.
	changed, err := root([]MtrCompletionLeaf{
		{Ordinal: 1, Disposition: MtrDispositionProbeFailed, RangeSha256: rng},
		{Ordinal: 2, Disposition: MtrDispositionNotAdmitted, RangeSha256: rng},
	}, 0, 2, planRoot, comm)
	if err != nil || string(a) == string(changed) {
		t.Fatalf("completion root must change when a disposition changes: %v", err)
	}
	// A different plan root changes the root.
	other, _ := root(leaves, 0, 2, d32domain(0x33), comm)
	if string(a) == string(other) {
		t.Fatal("completion root must bind the plan root")
	}

	// Reviewer P0 repro: {2,2,2}/3 and {1,1,4,4}/4 are rejected by the coverage proof.
	if _, err := root([]MtrCompletionLeaf{
		{Ordinal: 2, Disposition: MtrDispositionNotAdmitted, RangeSha256: rng},
		{Ordinal: 2, Disposition: MtrDispositionNotAdmitted, RangeSha256: rng},
		{Ordinal: 2, Disposition: MtrDispositionNotAdmitted, RangeSha256: rng},
	}, 0, 3, planRoot, comm); !errors.Is(err, ErrMtrCompletion) {
		t.Fatalf("{2,2,2} for expected 3 = %v, want ErrMtrCompletion", err)
	}
	// Reviewer P0 repro: {1,1,4,4}/4.
	if _, err := root([]MtrCompletionLeaf{
		{Ordinal: 1, Disposition: MtrDispositionNotAdmitted, RangeSha256: rng},
		{Ordinal: 1, Disposition: MtrDispositionNotAdmitted, RangeSha256: rng},
		{Ordinal: 4, Disposition: MtrDispositionNotAdmitted, RangeSha256: rng},
		{Ordinal: 4, Disposition: MtrDispositionNotAdmitted, RangeSha256: rng},
	}, 0, 4, planRoot, comm); !errors.Is(err, ErrMtrCompletion) {
		t.Fatalf("{1,1,4,4} for expected 4 = %v, want ErrMtrCompletion", err)
	}
	// Reviewer P1 repro (r5-07): a leaf claiming an ordinal belongs to a range the
	// plan never assigned it (0xFE) is rejected by the membership proof.
	if _, err := root([]MtrCompletionLeaf{
		{Ordinal: 1, Disposition: MtrDispositionTraceAllocated, TraceID: trace, RangeSha256: d32domain(0xFE)},
		{Ordinal: 2, Disposition: MtrDispositionNotAdmitted, RangeSha256: d32domain(0xFE)},
	}, 0, 2, planRoot, comm); !errors.Is(err, ErrMtrCompletion) {
		t.Fatalf("wrong ordinal->range = %v, want ErrMtrCompletion", err)
	}
	// Ordinal zero, unspecified disposition, trace-on-non-allocated, and incomplete
	// coverage are all rejected.
	for _, bad := range [][]MtrCompletionLeaf{
		{{Ordinal: 0, Disposition: MtrDispositionNotAdmitted, RangeSha256: rng}},
		{{Ordinal: 1, Disposition: MtrDispositionUnspecified, RangeSha256: rng}},
		{{Ordinal: 1, Disposition: MtrDispositionNotAdmitted, TraceID: trace, RangeSha256: rng}},
	} {
		if _, err := root(bad, 0, 1, planRoot, MtrOrdinalRangeCommitment(bad)); !errors.Is(err, ErrMtrCompletion) {
			t.Fatalf("bad leaf %+v = %v, want ErrMtrCompletion", bad, err)
		}
	}
	if _, err := root([]MtrCompletionLeaf{{Ordinal: 1, Disposition: MtrDispositionNotAdmitted, RangeSha256: rng}}, 0, 2, planRoot, comm); !errors.Is(err, ErrMtrCompletion) {
		t.Fatalf("incomplete coverage = %v, want ErrMtrCompletion", err)
	}
}

// TestZeroMtrCompletionIsMandatoryAndCanonical pins the zero-MTR decision: a plan
// admitting no MTR targets has exactly ONE valid completion proof, and it is a
// proof rather than an absence.
func TestZeroMtrCompletionIsMandatoryAndCanonical(t *testing.T) {
	planRoot := d32domain(0x90)
	zero32 := make([]byte, 32)

	root, err := ZeroMtrCompletionRoot(0, planRoot, zero32)
	if err != nil {
		t.Fatalf("zero-MTR completion must be constructible: %v", err)
	}
	if len(root) != sha256Len {
		t.Fatalf("zero-MTR root is %d bytes, want %d", len(root), sha256Len)
	}

	// The empty-set commitment IS 32 zero bytes -- the same value a producer gets
	// from folding no assignments, so the plan header and the proof agree by
	// construction rather than by convention.
	if got := MtrOrdinalRangeCommitment(nil); !bytes.Equal(got, zero32) {
		t.Fatalf("empty-set commitment = %x, want 32 zero bytes", got)
	}

	// It is bound to the plan root like any other proof: a different plan root is a
	// different completion, so a zero-MTR proof cannot be replayed across plans.
	other, err := ZeroMtrCompletionRoot(0, d32domain(0x33), zero32)
	if err != nil || bytes.Equal(root, other) {
		t.Fatalf("zero-MTR root must bind the plan root: %v", err)
	}

	// EMPTY commitment bytes are NOT the zero-MTR commitment. This is the whole
	// reason the field is always 32 bytes: empty would be a second spelling of
	// "no MTR" that no comparison could distinguish from an omitted commitment.
	if _, err := ZeroMtrCompletionRoot(0, planRoot, nil); !errors.Is(err, ErrMtrCompletion) {
		t.Fatalf("empty commitment = %v, want ErrMtrCompletion", err)
	}

	// A leaf at expected 0 is evidence of work the plan never admitted.
	leaf := MtrCompletionLeaf{Ordinal: 1, Disposition: MtrDispositionNotAdmitted, RangeSha256: d32domain(0x91)}
	if _, err := MtrCompletionRoot([]MtrCompletionLeaf{leaf}, 0, 0, planRoot, zero32); !errors.Is(err, ErrMtrCompletion) {
		t.Fatalf("leaf at expected 0 = %v, want ErrMtrCompletion", err)
	}

	// A non-zero commitment with no leaves fails the membership proof: the plan
	// committed ordinal->range assignments the completion never covered.
	if _, err := MtrCompletionRoot(nil, 0, 0, planRoot, d32domain(0x91)); !errors.Is(err, ErrMtrCompletion) {
		t.Fatalf("zero leaves against a non-empty commitment = %v, want ErrMtrCompletion", err)
	}
}

// TestVerifyCompletionAgainstPlanState exercises the comparison PRIMITIVE. It does
// NOT demonstrate plan-aware verification, and cannot: this test supplies the
// authoritative values itself, exactly as any caller does, which IS the limitation.
// What it pins is that GIVEN correct plan state the comparison accepts only the
// matching proof -- so the primitive is ready for a real carrier (task 1.3) to drive.
func TestVerifyCompletionAgainstPlanState(t *testing.T) {
	planRoot := d32domain(0x90)
	zero32 := make([]byte, 32)
	root, err := ZeroMtrCompletionRoot(0, planRoot, zero32)
	if err != nil {
		t.Fatalf("zero root: %v", err)
	}

	ev := func() *edgev1.SweepExecutionEventV1 {
		return &edgev1.SweepExecutionEventV1{
			ExecutionId: mustUUID(t), ExecutionPlanId: mustUUID(t), TargetRangeId: mustUUID(t),
			ExecutionPlanSha256: d32domain(0x10),
			Kind:                edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_COMPLETED,
			EmittedAtUnixNano:   1, TerminalBatchSequence: 1,
			MtrCompletionDigestVersion: MtrCompletionDigestVersion,
			MtrCompletionDigest:        root,
			PlanRootSha256:             planRoot,
		}
	}

	if err := VerifyCompletionAgainstPlanState(ev(), 0, 0, planRoot, zero32, nil); err != nil {
		t.Fatalf("canonical zero-MTR completion must verify: %v", err)
	}

	// The comparison ignores the event's own counters: with the CALLER passing an
	// expected count of 2, the zero-leaf proof is rejected even though the event's
	// self-reported counters agree with it. That is a property of the primitive, not
	// evidence that anything in production sources the 2 from real plan state.
	bad := ev()
	bad.ExpectedMtrTraces, bad.EmittedMtrTraces = 0, 0
	trace := mustUUID(t)
	rng := d32domain(0x91)
	leaves := []MtrCompletionLeaf{
		{Ordinal: 1, Disposition: MtrDispositionTraceAllocated, TraceID: trace, RangeSha256: rng},
		{Ordinal: 2, Disposition: MtrDispositionNotAdmitted, RangeSha256: rng},
	}
	comm := MtrOrdinalRangeCommitment(leaves)
	if err := VerifyCompletionAgainstPlanState(bad, 0, 2, planRoot, comm, leaves); !errors.Is(err, ErrMtrCompletion) {
		t.Fatalf("self-reported zero against a 2-ordinal plan = %v, want ErrMtrCompletion", err)
	}

	// A proof for a different plan root is rejected even when internally valid.
	wrongPlan := ev()
	wrongPlan.PlanRootSha256 = d32domain(0x33)
	if err := VerifyCompletionAgainstPlanState(wrongPlan, 0, 0, planRoot, zero32, nil); !errors.Is(err, ErrMtrCompletion) {
		t.Fatalf("mismatched plan root = %v, want ErrMtrCompletion", err)
	}

	// An omitted proof is a lifecycle failure, not a permitted zero-MTR shape.
	omitted := ev()
	omitted.MtrCompletionDigest = nil
	if err := VerifyCompletionAgainstPlanState(omitted, 0, 0, planRoot, zero32, nil); !errors.Is(err, ErrLifecycle) {
		t.Fatalf("omitted proof = %v, want ErrLifecycle", err)
	}

	// A wrong digest version is rejected before the digest is compared.
	badVersion := ev()
	badVersion.MtrCompletionDigestVersion = MtrCompletionDigestVersion + 1
	if err := VerifyCompletionAgainstPlanState(badVersion, 0, 0, planRoot, zero32, nil); !errors.Is(err, ErrLifecycle) {
		t.Fatalf("wrong digest version = %v, want ErrLifecycle", err)
	}
}

// TestMtrCompletionDispositionSymbolNumbers pins each SYMBOL to its exact NUMBER,
// and pins the membership to exactly six values. The closed-set test below proves
// only which NUMBERS are accepted, so swapping two valid members -- QUARANTINED=4
// and SCHEDULER_LOST=5 -- would leave it green while changing which meaning is
// hashed at those numbers, and the completion root for a quarantined ordinal would
// silently become the root for a scheduler-lost one. The number is part of the
// digest grammar, so the symbol->number pair is what has to be frozen, not the set.
func TestMtrCompletionDispositionSymbolNumbers(t *testing.T) {
	want := map[int32]string{
		0: "MTR_COMPLETION_DISPOSITION_UNSPECIFIED",
		1: "MTR_COMPLETION_DISPOSITION_TRACE_ALLOCATED",
		2: "MTR_COMPLETION_DISPOSITION_NOT_ADMITTED",
		3: "MTR_COMPLETION_DISPOSITION_PROBE_FAILED",
		4: "MTR_COMPLETION_DISPOSITION_QUARANTINED",
		5: "MTR_COMPLETION_DISPOSITION_SCHEDULER_LOST",
	}
	got := edgev1.MtrCompletionDisposition_name
	if len(got) != len(want) {
		t.Fatalf("membership drift: generated enum has %d numbers, want %d (%v)", len(got), len(want), got)
	}
	// _name is keyed by NUMBER, so it collapses same-number aliases and would not
	// notice a second symbol declared at an existing number. _value is keyed by
	// SYMBOL, so its cardinality is what catches that.
	if n := len(edgev1.MtrCompletionDisposition_value); n != len(want) {
		t.Fatalf("membership drift: generated enum has %d symbols, want %d (%v)",
			n, len(want), edgev1.MtrCompletionDisposition_value)
	}
	for number, symbol := range want {
		if got[number] != symbol {
			t.Errorf("number %d maps to %q, want %q", number, got[number], symbol)
		}
		// Comma-ok, not a bare index: a MISSING entry reads back as 0, which is the
		// expected value for UNSPECIFIED, so a bare lookup would prove nothing for it.
		n, ok := edgev1.MtrCompletionDisposition_value[symbol]
		if !ok {
			t.Errorf("symbol %q is absent from the generated value map", symbol)
		} else if n != number {
			t.Errorf("symbol %q maps to %d, want %d", symbol, n, number)
		}
	}

	// The Go-side aliases must carry the same numbers, so a constant repointed at a
	// different generated member is caught here rather than in a proof mismatch.
	for _, tc := range []struct {
		disp MtrTerminalDisposition
		want int32
	}{
		{MtrDispositionUnspecified, 0},
		{MtrDispositionTraceAllocated, 1},
		{MtrDispositionNotAdmitted, 2},
		{MtrDispositionProbeFailed, 3},
		{MtrDispositionQuarantined, 4},
		{MtrDispositionSchedulerLost, 5},
	} {
		if int32(tc.disp) != tc.want {
			t.Errorf("alias %v = %d, want %d", tc.disp, int32(tc.disp), tc.want)
		}
	}
}

// TestMtrCompletionDispositionIsAClosedSet pins the leaf disposition to the
// generated enum's declared members. 6 is the next UNALLOCATED number -- the one a
// later proto revision could declare -- and it must stay rejected until the
// completion grammar version itself changes, because the leaf grammar is frozen.
// -1 is only expressible at all because the disposition IS the generated int32
// enum; the previous local uint32 declaration could not represent it.
func TestMtrCompletionDispositionIsAClosedSet(t *testing.T) {
	planRoot := d32domain(0x90)
	rng := d32domain(0x91)

	for _, disp := range []MtrTerminalDisposition{0, -1, 6, 999} {
		bad := []MtrCompletionLeaf{{Ordinal: 1, Disposition: disp, RangeSha256: rng}}
		if _, err := MtrCompletionRoot(bad, 0, 1, planRoot, MtrOrdinalRangeCommitment(bad)); !errors.Is(err, ErrMtrCompletion) {
			t.Fatalf("disposition %d = %v, want ErrMtrCompletion", disp, err)
		}
	}

	trace := mustUUID(t)
	for _, tc := range []struct {
		disp  MtrTerminalDisposition
		trace []byte
	}{
		{MtrDispositionTraceAllocated, trace},
		{MtrDispositionNotAdmitted, nil},
		{MtrDispositionProbeFailed, nil},
		{MtrDispositionQuarantined, nil},
		{MtrDispositionSchedulerLost, nil},
	} {
		good := []MtrCompletionLeaf{{Ordinal: 1, Disposition: tc.disp, TraceID: tc.trace, RangeSha256: rng}}
		if _, err := MtrCompletionRoot(good, 0, 1, planRoot, MtrOrdinalRangeCommitment(good)); err != nil {
			t.Fatalf("declared member %d rejected: %v", tc.disp, err)
		}
	}
}
