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

package gwprefix

import (
	"errors"
	"math"
	"testing"
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// resolvingKinds returns the four kinds the frozen ABI marks as resolving.
func resolvingKinds() []Disposition {
	return []Disposition{
		DispositionAcceptedAuthoritative,
		DispositionAcceptedAuditOnly,
		DispositionAcceptedQuarantine,
		DispositionRejectedPermanent,
	}
}

func TestFreshTrackerResolvesNothing(t *testing.T) {
	tr := New(7)

	if got := tr.ResolvedThrough(); got != 6 {
		t.Fatalf("ResolvedThrough=%d, want 6", got)
	}

	if got := tr.ReclaimableThrough(); got != 6 {
		t.Fatalf("ReclaimableThrough=%d, want 6", got)
	}
}

func TestContiguousInOrderAdvances(t *testing.T) {
	tr := New(1)

	for seq := uint64(1); seq <= 4; seq++ {
		if err := tr.Record(seq, DispositionAcceptedAuthoritative); err != nil {
			t.Fatalf("Record(%d): %v", seq, err)
		}
	}

	if got := tr.ResolvedThrough(); got != 4 {
		t.Fatalf("ResolvedThrough=%d, want 4", got)
	}
}

func TestOutOfOrderHoldsAtGap(t *testing.T) {
	tr := New(1)

	if err := tr.Record(2, DispositionAcceptedAuthoritative); err != nil {
		t.Fatalf("Record(2): %v", err)
	}

	if got := tr.ResolvedThrough(); got != 0 {
		t.Fatalf("ResolvedThrough=%d with seq 1 missing, want 0", got)
	}

	if err := tr.Record(1, DispositionAcceptedAuthoritative); err != nil {
		t.Fatalf("Record(1): %v", err)
	}

	if got := tr.ResolvedThrough(); got != 2 {
		t.Fatalf("ResolvedThrough=%d after gap closed, want 2", got)
	}
}

// --- 2.16: all five frozen dispositions, retryable must NOT resolve -----------

func TestAllFourResolvingKindsAdvanceThePrefix(t *testing.T) {
	for _, kind := range resolvingKinds() {
		tr := New(1)

		if err := tr.Record(1, kind); err != nil {
			t.Fatalf("Record(%v): %v", kind, err)
		}

		if got := tr.ResolvedThrough(); got != 1 {
			t.Fatalf("%v: ResolvedThrough=%d, want 1", kind, got)
		}

		got, ok := tr.Disposition(1)
		if !ok || got != kind {
			t.Fatalf("%v: disposition = (%v,%v), want it retained distinctly", kind, got, ok)
		}
	}
}

// REJECTED_RETRYABLE is transient: the sequence may still be delivered, so it
// must cap the prefix exactly like a missing outcome. Treating it as resolved
// would eventually authorize reclaiming data that was never delivered.
func TestRetryableNeverResolves(t *testing.T) {
	tr := New(1)

	if err := tr.Record(1, DispositionRejectedRetryable); err != nil {
		t.Fatalf("Record: %v", err)
	}

	if got := tr.ResolvedThrough(); got != 0 {
		t.Fatalf("ResolvedThrough=%d on a RETRYABLE refusal, want 0", got)
	}

	if _, ok := tr.Disposition(1); ok {
		t.Fatal("a retryable sequence must not be inside the resolved prefix")
	}

	if d, ok := tr.PendingDisposition(1); !ok || d != DispositionRejectedRetryable {
		t.Fatalf("PendingDisposition = (%v,%v), want the retryable kind retained", d, ok)
	}

	// It must also cap a later contiguous run.
	if err := tr.Record(2, DispositionAcceptedAuthoritative); err != nil {
		t.Fatalf("Record(2): %v", err)
	}

	if got := tr.ResolvedThrough(); got != 0 {
		t.Fatalf("ResolvedThrough=%d; a retryable outcome must cap the prefix", got)
	}
}

// A retryable refusal is PROVISIONAL: the agent retransmits, the gateway resolves,
// and the prefix must advance -- including across sequences queued behind it.
// Treating the provisional value as immutable wedges the lane permanently.
func TestRetryableIsSupersededByASuccessfulRetry(t *testing.T) {
	tr := New(1)

	if err := tr.Record(1, DispositionRejectedRetryable); err != nil {
		t.Fatalf("Record(1, retryable): %v", err)
	}

	// Sequence 2 resolves out of order and waits behind the retryable sequence 1.
	if err := tr.Record(2, DispositionAcceptedAuthoritative); err != nil {
		t.Fatalf("Record(2): %v", err)
	}

	if got := tr.ResolvedThrough(); got != 0 {
		t.Fatalf("ResolvedThrough=%d while seq 1 is retryable, want 0", got)
	}

	// The agent retransmits seq 1; the gateway now accepts it.
	if err := tr.Record(1, DispositionAcceptedAuthoritative); err != nil {
		t.Fatalf("successful retry over a retryable outcome must be accepted, got %v", err)
	}

	if got := tr.ResolvedThrough(); got != 2 {
		t.Fatalf("ResolvedThrough=%d after the retry resolved, want 2 (through the queued sequence)", got)
	}

	if d, ok := tr.Disposition(1); !ok || d != DispositionAcceptedAuthoritative {
		t.Fatalf("seq 1 disposition = (%v,%v), want the resolving kind retained", d, ok)
	}
}

// Every resolving kind may supersede a retryable outcome, not just the first.
func TestRetryableSupersededByAnyResolvingKind(t *testing.T) {
	for _, kind := range resolvingKinds() {
		tr := New(1)

		if err := tr.Record(1, DispositionRejectedRetryable); err != nil {
			t.Fatalf("Record(retryable): %v", err)
		}

		if err := tr.Record(1, kind); err != nil {
			t.Fatalf("retryable -> %v must be accepted, got %v", kind, err)
		}

		if got := tr.ResolvedThrough(); got != 1 {
			t.Fatalf("%v: ResolvedThrough=%d after superseding retryable, want 1", kind, got)
		}
	}
}

// A resolving kind is terminal: it may not change to a different resolving kind,
// nor be downgraded back to retryable.
func TestResolvingKindsRemainImmutable(t *testing.T) {
	tr := New(1)

	if err := tr.Record(2, DispositionAcceptedAuthoritative); err != nil {
		t.Fatalf("Record: %v", err)
	}

	// Still pending behind the gap at seq 1.
	if err := tr.Record(2, DispositionRejectedPermanent); !errors.Is(err, ErrConflict) {
		t.Fatalf("resolving -> different resolving: err = %v, want ErrConflict", err)
	}

	if err := tr.Record(2, DispositionRejectedRetryable); !errors.Is(err, ErrConflict) {
		t.Fatalf("resolving -> retryable downgrade: err = %v, want ErrConflict", err)
	}
}

// Unspecified and undeclared numbers fail closed.
func TestUnknownDispositionsFailClosed(t *testing.T) {
	tr := New(1)

	for _, d := range []Disposition{
		DispositionUnspecified,
		edgev1.EdgeRecordDispositionKind(6),
		edgev1.EdgeRecordDispositionKind(99),
		edgev1.EdgeRecordDispositionKind(-1),
	} {
		if err := tr.Record(1, d); !errors.Is(err, ErrUnknownDisposition) {
			t.Fatalf("Record(%d) err = %v, want ErrUnknownDisposition", int32(d), err)
		}
	}

	if tr.ResolvedThrough() != 0 {
		t.Fatalf("ResolvedThrough=%d after only unknown kinds, want 0", tr.ResolvedThrough())
	}
}

// The five kinds must remain mutually distinguishable inside the prefix.
func TestFrozenKindsRemainDistinct(t *testing.T) {
	tr := New(1)

	for i, kind := range resolvingKinds() {
		if err := tr.Record(uint64(i+1), kind); err != nil {
			t.Fatalf("Record(%d,%v): %v", i+1, kind, err)
		}
	}

	seen := map[Disposition]bool{}

	for i, want := range resolvingKinds() {
		got, ok := tr.Disposition(uint64(i + 1))
		if !ok {
			t.Fatalf("seq %d: disposition lost inside the prefix", i+1)
		}

		if got != want {
			t.Fatalf("seq %d disposition = %v, want %v", i+1, got, want)
		}

		if seen[got] {
			t.Fatalf("%v aliased another kind", got)
		}

		seen[got] = true
	}

	if len(seen) != 4 {
		t.Fatalf("only %d distinct kinds retained, want 4", len(seen))
	}
}

// --- 2.16: remote resolution is not local reclaim -----------------------------

func TestResolvedPrefixDoesNotAuthorizeReclaim(t *testing.T) {
	tr := New(1)

	for seq := uint64(1); seq <= 5; seq++ {
		if err := tr.Record(seq, DispositionAcceptedAuthoritative); err != nil {
			t.Fatalf("Record(%d): %v", seq, err)
		}
	}

	if got := tr.ResolvedThrough(); got != 5 {
		t.Fatalf("ResolvedThrough=%d, want 5", got)
	}

	if got := tr.ReclaimableThrough(); got != 0 {
		t.Fatalf("ReclaimableThrough=%d after PubAcks alone, want 0", got)
	}
}

// One local terminal event must NOT vouch for earlier sequences.
func TestLocalReclaimAdvancesOnlyAcrossContiguousLocalOutcomes(t *testing.T) {
	tr := New(1)

	if err := tr.Record(1, DispositionRejectedPermanent); err != nil {
		t.Fatalf("Record(1): %v", err)
	}

	if err := tr.Record(2, DispositionAcceptedAuthoritative); err != nil {
		t.Fatalf("Record(2): %v", err)
	}

	// Sequence 1's local quarantine transaction is still pending; only 2 committed.
	if err := tr.RecordTerminalOutcome(2); err != nil {
		t.Fatalf("RecordTerminalOutcome(2): %v", err)
	}

	if got := tr.ReclaimableThrough(); got != 0 {
		t.Fatalf("ReclaimableThrough=%d after recording only seq 2, want 0", got)
	}

	if _, ok := tr.Disposition(1); !ok {
		t.Fatal("sequence 1's evidence was erased by a later sequence's terminal outcome")
	}

	// Once seq 1's own action commits, the run advances through 2.
	if err := tr.RecordTerminalOutcome(1); err != nil {
		t.Fatalf("RecordTerminalOutcome(1): %v", err)
	}

	if got := tr.ReclaimableThrough(); got != 2 {
		t.Fatalf("ReclaimableThrough=%d after seq 1 committed, want 2", got)
	}
}

func TestReclaimNeverExceedsResolved(t *testing.T) {
	tr := New(1)

	if err := tr.RecordTerminalOutcome(1); !errors.Is(err, ErrNotResolved) {
		t.Fatalf("terminal before resolution: err = %v, want ErrNotResolved", err)
	}

	if err := tr.Record(1, DispositionAcceptedAuthoritative); err != nil {
		t.Fatalf("Record: %v", err)
	}

	if err := tr.RecordTerminalOutcome(2); !errors.Is(err, ErrNotResolved) {
		t.Fatalf("terminal beyond resolved: err = %v, want ErrNotResolved", err)
	}

	if tr.ReclaimableThrough() > tr.ResolvedThrough() {
		t.Fatalf("reclaimable %d exceeds resolved %d", tr.ReclaimableThrough(), tr.ResolvedThrough())
	}
}

func TestRetainedDispositionsReleasedOnReclaim(t *testing.T) {
	tr := New(1)

	for seq := uint64(1); seq <= 10; seq++ {
		if err := tr.Record(seq, DispositionAcceptedAuthoritative); err != nil {
			t.Fatalf("Record(%d): %v", seq, err)
		}
	}

	if got := tr.RetainedDispositions(); got != 10 {
		t.Fatalf("RetainedDispositions=%d, want 10", got)
	}

	for seq := uint64(1); seq <= 10; seq++ {
		if err := tr.RecordTerminalOutcome(seq); err != nil {
			t.Fatalf("RecordTerminalOutcome(%d): %v", seq, err)
		}
	}

	if got := tr.RetainedDispositions(); got != 0 {
		t.Fatalf("RetainedDispositions=%d after full reclaim, want 0", got)
	}
}

func TestConflictDetectedInsideThePrefix(t *testing.T) {
	tr := New(1)

	if err := tr.Record(1, DispositionAcceptedAuthoritative); err != nil {
		t.Fatalf("Record: %v", err)
	}

	if err := tr.Record(1, DispositionRejectedPermanent); !errors.Is(err, ErrConflict) {
		t.Fatalf("conflicting re-record: err = %v, want ErrConflict", err)
	}

	if err := tr.Record(1, DispositionAcceptedAuthoritative); err != nil {
		t.Fatalf("agreeing re-record must be idempotent, got %v", err)
	}
}

func TestRecordValidatesRange(t *testing.T) {
	tr := New(5)

	if err := tr.Record(4, DispositionAcceptedAuthoritative); !errors.Is(err, ErrBelowBase) {
		t.Fatalf("err = %v, want ErrBelowBase", err)
	}
}

// --- 2.16: the final uint64 sequence must not hang ----------------------------

// Lanes never wrap, so MaxUint64 is a VALID final sequence. Incrementing past it
// wraps to zero and the reclaim loop would never terminate.
func TestReclaimTerminatesAtMaxUint64(t *testing.T) {
	tr := New(math.MaxUint64)

	if err := tr.Record(math.MaxUint64, DispositionAcceptedAuthoritative); err != nil {
		t.Fatalf("Record: %v", err)
	}

	done := make(chan struct{})

	go func() {
		defer close(done)

		if err := tr.RecordTerminalOutcome(math.MaxUint64); err != nil {
			t.Errorf("RecordTerminalOutcome: %v", err)
		}
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("RecordTerminalOutcome(MaxUint64) did not terminate")
	}

	if got := tr.ReclaimableThrough(); got != math.MaxUint64 {
		t.Fatalf("ReclaimableThrough=%d, want MaxUint64", got)
	}
}
