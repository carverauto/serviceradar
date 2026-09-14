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
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"sync"
	"testing"
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

const (
	reasonTornTail        = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL
	reasonMissing         = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING
	reasonCorrupt         = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT
	reasonUnsupported     = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_VERSION_UNSUPPORTED
	reasonUnrepresentable = edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_DISCRIMINATOR_UNREPRESENTABLE
)

var allBarriers = []barrier{ //nolint:gochecknoglobals // test table
	barrierEvidenceDirA, barrierEvidenceDirB, barrierPrepareA, barrierPrepareB,
	barrierRecord, barrierCommitA, barrierCommitB,
}

func barrierName(b barrier) string {
	return [...]string{"evidence-dir-A", "evidence-dir-B", "prepare-A", "prepare-B", "record", "commit-A", "commit-B"}[b]
}

func isDirBarrier(b barrier) bool { return b == barrierEvidenceDirA || b == barrierEvidenceDirB }

// crashError stands in for the process dying immediately before a barrier.
type crashError struct{ at barrier }

func (e crashError) Error() string { return "injected crash before " + barrierName(e.at) }

func crashBefore(target barrier) func(barrier) error {
	return func(b barrier) error {
		if b == target {
			return crashError{at: b}
		}
		return nil
	}
}

type fakeBindings struct {
	attribution map[uint64]AttributionVerdict
	receipt     map[uint64]ReceiptVerdict
}

func (f fakeBindings) InspectAttribution(e SlotEvidence) AttributionVerdict {
	return f.attribution[e.Sequence]
}

func (f fakeBindings) InspectReceipt(e SlotEvidence) ReceiptVerdict { return f.receipt[e.Sequence] }

func attributionAt(seq uint64, v AttributionVerdict) fakeBindings {
	return fakeBindings{attribution: map[uint64]AttributionVerdict{seq: v}}
}

func digestOf(b byte) []byte { return bytes.Repeat([]byte{b}, 32) }

func openWith(t *testing.T, dir string, b BindingInspector) *Spool {
	t.Helper()
	s, err := Open(dir, WithBindings(b))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func visibleSeqs(t *testing.T, s *Spool) []uint64 {
	t.Helper()
	recs, err := s.Unresolved()
	if err != nil {
		t.Fatalf("unresolved: %v", err)
	}
	out := make([]uint64, 0, len(recs))
	for _, r := range recs {
		out = append(out, r.Sequence)
	}
	return out
}

func slotOf(t *testing.T, s *Spool, seq uint64) SlotResolution {
	t.Helper()
	r, ok := s.RestartResolution().Slot(seq)
	if !ok {
		t.Fatalf("sequence %d is not allocated after restart (high-water %d)", seq, s.RestartResolution().HighWater)
	}
	return r
}

func assertAmbiguous(t *testing.T, got SlotResolution, evidence EvidenceState, want Coverage) {
	t.Helper()
	if got.Outcome != OutcomeAmbiguousAllocated || got.Evidence != evidence || !got.EntersCoverage() {
		t.Fatalf("slot %d = %s evidence %d, want AMBIGUOUS_ALLOCATED_SLOT evidence %d in coverage",
			got.Sequence, got.Outcome, got.Evidence, evidence)
	}
	if got.Coverage != want {
		t.Fatalf("slot %d coverage = %+v, want %+v", got.Sequence, got.Coverage, want)
	}
}

func assertNoReceipt(t *testing.T, r CommitReceipt) {
	t.Helper()
	if r.Sequence != 0 || r.EventID != nil || r.RecordSHA256 != nil || r.EvidenceGeneration != 0 {
		t.Fatalf("receipt observable: %+v", r)
	}
}

func evidenceFilePath(dir string, c int) string {
	return filepath.Join(dir, evidenceDirName(c), evidenceFile)
}

func mutate(t *testing.T, path string, off int64, n int, fn func([]byte)) {
	t.Helper()
	buf, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	fn(buf[off : off+int64(n)])
	if err := os.WriteFile(path, buf, filePerm); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func corruptEntry(t *testing.T, dir string, c int, seq uint64, state byte) {
	t.Helper()
	mutate(t, evidenceFilePath(dir, c), evidencePosition(seq, state)+40, 1, func(b []byte) { b[0] ^= 0xFF })
}

func zeroEntry(t *testing.T, dir string, c int, seq uint64, state byte) {
	t.Helper()
	mutate(t, evidenceFilePath(dir, c), evidencePosition(seq, state), evidenceEntryLen, func(b []byte) { clear(b) })
}

func entryStatusAt(t *testing.T, dir string, c int, seq uint64, state byte) entryStatus {
	t.Helper()
	buf, err := os.ReadFile(evidenceFilePath(dir, c))
	if err != nil {
		t.Fatalf("read evidence: %v", err)
	}
	pos := evidencePosition(seq, state)
	end := min(pos+evidenceEntryLen, int64(len(buf)))
	if pos > int64(len(buf)) {
		end = pos
	}
	_, status := decodeEvidence(buf[pos:end], c, seq, state)
	return status
}

// corruptBody flips a byte inside the body of the record at offset.
func corruptBody(t *testing.T, dir string, offset int64) {
	t.Helper()
	mutate(t, filepath.Join(dir, segmentFile), offset+headerLen+headerCRC, 1, func(b []byte) { b[0] ^= 0xFF })
}

func TestResolveSlotOutcomeTable(t *testing.T) {
	verified := AttributionVerdict{State: AttributionVerifies, Representable: true}
	unrepresentable := AttributionVerdict{State: AttributionVerifies}
	committed := func(o SlotObservation) SlotObservation {
		o.Sequence, o.Evidence, o.Allocated, o.CompleteRecord = 1, EvidenceCommitted, true, true
		return o
	}

	cases := []struct {
		name string
		obs  SlotObservation
		want Outcome
		cov  Coverage
	}{
		{"intact, no bindings declared", committed(SlotObservation{Bytes: BytesIntact}), OutcomeCommitted, Coverage{}},
		{"intact, declared bindings valid", committed(SlotObservation{
			Bytes: BytesIntact, AttributionRequired: true, Attribution: verified, ReceiptRequired: true, Receipt: ReceiptValid,
		}), OutcomeCommitted, Coverage{}},
		{"verifies, representable, bytes corrupt", committed(SlotObservation{
			Bytes: BytesCorrupt, AttributionRequired: true, Attribution: verified,
		}), OutcomeAttributedLoss, Coverage{Attributed: true}},
		{"verifies, representable, bytes missing", committed(SlotObservation{
			Bytes: BytesMissing, AttributionRequired: true, Attribution: verified,
		}), OutcomeAttributedLoss, Coverage{Attributed: true}},
		{"verifies, not representable, bytes corrupt", committed(SlotObservation{
			Bytes: BytesCorrupt, AttributionRequired: true, Attribution: unrepresentable,
		}), OutcomeUnattributable, Coverage{Reason: reasonUnrepresentable}},
		{"declared attribution missing", committed(SlotObservation{
			Bytes: BytesIntact, AttributionRequired: true,
		}), OutcomeAmbiguousAllocated, Coverage{Reason: reasonMissing}},
		{"declared receipt unverifiable", committed(SlotObservation{
			Bytes: BytesIntact, AttributionRequired: true, Attribution: verified, ReceiptRequired: true, Receipt: ReceiptUnverifiable,
		}), OutcomeAmbiguousAllocated, Coverage{Attributed: true}},
		{"wrapper contradicts evidence", committed(SlotObservation{
			Bytes: BytesContradict, AttributionRequired: true, Attribution: verified,
		}), OutcomeAmbiguousAllocated, Coverage{Attributed: true}},
		{"bytes lost, no attribution declared", committed(SlotObservation{Bytes: BytesCorrupt}),
			OutcomeAmbiguousAllocated, Coverage{Reason: reasonMissing}},
		{"copies disagree", SlotObservation{Sequence: 1, Evidence: EvidenceDisagree, Allocated: true, CompleteRecord: true},
			OutcomeAmbiguousAllocated, Coverage{Reason: reasonMissing}},
		{"prepared only", SlotObservation{Sequence: 1, Evidence: EvidencePrepared, Allocated: true},
			OutcomeAmbiguousAllocated, Coverage{Reason: reasonMissing}},
		{"evidence unreadable", SlotObservation{Sequence: 1, Evidence: EvidenceUnreadable, Allocated: true},
			OutcomeAmbiguousAllocated, Coverage{Reason: reasonMissing}},
		{"high-water allocated, no marker", SlotObservation{Sequence: 1, Allocated: true},
			OutcomeAmbiguousAllocated, Coverage{Reason: reasonMissing}},
		{"complete record, no marker", SlotObservation{Sequence: 1, CompleteRecord: true},
			OutcomeAmbiguousAllocated, Coverage{Reason: reasonMissing}},
		{"no evidence, allocation, or record", SlotObservation{Sequence: 1}, OutcomeDiscardablePreparation, Coverage{}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveSlot(tc.obs)
			if got.Outcome != tc.want || got.Coverage != tc.cov {
				t.Fatalf("ResolveSlot = %s %+v, want %s %+v", got.Outcome, got.Coverage, tc.want, tc.cov)
			}
			wantCoverage := tc.want != OutcomeCommitted && tc.want != OutcomeDiscardablePreparation
			if got.EntersCoverage() != wantCoverage {
				t.Fatalf("EntersCoverage = %v, want %v", got.EntersCoverage(), wantCoverage)
			}
		})
	}
}

// ATTRIBUTED requires BOTH predicates; otherwise the frozen precedence picks exactly
// one reason, first match wins.
func TestRolloverCoverageFrozenPrecedence(t *testing.T) {
	cases := []struct {
		name     string
		tornTail bool
		verdict  AttributionVerdict
		want     Coverage
	}{
		{"verifies and representable", false, AttributionVerdict{State: AttributionVerifies, Representable: true}, Coverage{Attributed: true}},
		{"verifies and representable in the torn tail", true, AttributionVerdict{State: AttributionVerifies, Representable: true}, Coverage{Attributed: true}},
		{"torn tail with no binding is TORN_TAIL, not BINDING_MISSING", true, AttributionVerdict{}, Coverage{Reason: reasonTornTail}},
		{"no binding", false, AttributionVerdict{}, Coverage{Reason: reasonMissing}},
		{"readable unsupported version", false, AttributionVerdict{State: AttributionVersionUnsupported}, Coverage{Reason: reasonUnsupported}},
		{"torn tail does not mask a present binding", true, AttributionVerdict{State: AttributionVersionUnsupported}, Coverage{Reason: reasonUnsupported}},
		{"does not verify", false, AttributionVerdict{State: AttributionNotVerifying, Representable: true}, Coverage{Reason: reasonCorrupt}},
		{"verifies but not representable", false, AttributionVerdict{State: AttributionVerifies}, Coverage{Reason: reasonUnrepresentable}},
		{"unknown verdict fails closed", false, AttributionVerdict{State: 99, Representable: true}, Coverage{Reason: reasonCorrupt}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveSlot(SlotObservation{Sequence: 7, Allocated: true, InTornTail: tc.tornTail, Attribution: tc.verdict})
			if got.Outcome != OutcomeAmbiguousAllocated || got.Coverage != tc.want {
				t.Fatalf("got %s %+v, want AMBIGUOUS_ALLOCATED_SLOT %+v", got.Outcome, got.Coverage, tc.want)
			}
		})
	}
}

func TestCrashInjectionAtEveryBarrier(t *testing.T) {
	cases := []struct {
		at        barrier
		allocated bool
		evidence  EvidenceState
		reason    edgev1.EdgeUnattributableReason
	}{
		// Nothing allocated yet: the append never became durable.
		{at: barrierEvidenceDirA},
		{at: barrierEvidenceDirB},
		{at: barrierPrepareA},
		// One PREPARED copy allocates the sequence; no record was written.
		{at: barrierPrepareB, allocated: true, evidence: EvidencePrepared, reason: reasonTornTail},
		{at: barrierRecord, allocated: true, evidence: EvidencePrepared, reason: reasonTornTail},
		// A complete prepared record with no commit marker.
		{at: barrierCommitA, allocated: true, evidence: EvidencePrepared, reason: reasonMissing},
		// Split write: copy A COMMITTED, copy B still PREPARED.
		{at: barrierCommitB, allocated: true, evidence: EvidenceDisagree, reason: reasonMissing},
	}
	for _, tc := range cases {
		t.Run(barrierName(tc.at), func(t *testing.T) {
			dir := t.TempDir()
			s, err := Open(dir)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			wantVisible := []uint64{}
			if !isDirBarrier(tc.at) {
				wantVisible = append(wantVisible, mustAppend(t, s, 1, "prior"))
			}
			inFlight := uint64(len(wantVisible)) + 1

			s.beforeBarrier = crashBefore(tc.at)
			r, err := s.Commit(evid(2), []byte("in flight"), Bindings{})
			var crash crashError
			if !errors.As(err, &crash) {
				t.Fatalf("commit = %v, want injected crash", err)
			}
			assertNoReceipt(t, r)
			_ = s.Close()

			s2 := openWith(t, dir, nil)
			res := s2.RestartResolution()
			got, allocated := res.Slot(inFlight)
			if allocated != tc.allocated {
				t.Fatalf("sequence %d allocated = %v, want %v", inFlight, allocated, tc.allocated)
			}
			if tc.allocated {
				assertAmbiguous(t, got, tc.evidence, Coverage{Reason: tc.reason})
			}
			if len(res.Discarded) != 0 {
				t.Fatalf("discarded = %+v, want none", res.Discarded)
			}
			if v := visibleSeqs(t, s2); !slices.Equal(v, wantVisible) {
				t.Fatalf("sender-visible = %v, want %v", v, wantVisible)
			}

			wantNext := inFlight
			if tc.allocated {
				wantNext++ // an ambiguous sequence is never reused
			}
			if got := mustAppend(t, s2, 3, "after restart"); got != wantNext {
				t.Fatalf("append after restart = %d, want %d", got, wantNext)
			}
			_ = s2.Close()

			// The later commit is placed where the interrupted append left the segment
			// end; it must not change how the interrupted slot resolves.
			s3 := openWith(t, dir, nil)
			if again, ok := s3.RestartResolution().Slot(inFlight); tc.allocated && (!ok || again != got) {
				t.Fatalf("sequence %d after a later commit = %+v (allocated %v), want %+v", inFlight, again, ok, got)
			}
			if d := s3.RestartResolution().Discarded; len(d) != 0 {
				t.Fatalf("discarded after a later commit = %+v, want none", d)
			}
			if v := visibleSeqs(t, s3); !slices.Equal(v, append(wantVisible, wantNext)) {
				t.Fatalf("sender-visible after a later commit = %v, want %v", v, append(wantVisible, wantNext))
			}
		})
	}
}

// crashDuringRecordBody leaves sequence 2 as power loss while its record body was
// being written leaves it: both PREPARED entries durable, and only the record header
// and the first 100 of its 1000 body bytes in the segment, which then ends at 183.
func crashDuringRecordBody(t *testing.T, dir string, s *Spool) {
	t.Helper()
	s.beforeBarrier = crashBefore(barrierCommitA)
	if _, err := s.Commit(evid(2), bytes.Repeat([]byte{'x'}, 1000), Bindings{}); err == nil {
		t.Fatal("commit succeeded through an injected crash")
	}
	_ = s.Close()
	truncateSegment(t, dir, int64(minRecordLen+len("one")+headerLen+headerCRC+100))
}

func truncateSegment(t *testing.T, dir string, size int64) {
	t.Helper()
	if err := os.Truncate(filepath.Join(dir, segmentFile), size); err != nil {
		t.Fatal(err)
	}
}

// A slot's restart resolution is a function of durable facts about that slot. Commits
// appended after a restart land at the segment end the torn slot left, inside the
// extent its evidence declares, and must not move it out of the torn tail or change
// its outcome.
func TestTornSlotResolutionIsStableAcrossLaterCommits(t *testing.T) {
	torn := SlotResolution{
		Sequence: 2, Outcome: OutcomeAmbiguousAllocated, Evidence: EvidencePrepared,
		Coverage: Coverage{Reason: reasonTornTail},
	}
	cases := []struct {
		name     string
		later    int
		bindings BindingInspector
		crash    func(t *testing.T, dir string, s *Spool)
		want     SlotResolution
	}{
		{name: "record body torn, one later commit", later: 1, crash: crashDuringRecordBody, want: torn},
		{name: "record body torn, later commits cover its declared extent", later: 25, crash: crashDuringRecordBody, want: torn},
		{
			name:  "only preparation unreadable and no record",
			later: 1,
			crash: func(t *testing.T, dir string, s *Spool) {
				t.Helper()
				s.beforeBarrier = crashBefore(barrierPrepareB)
				if _, err := s.Commit(evid(2), []byte("two"), Bindings{}); err == nil {
					t.Fatal("commit succeeded through an injected crash")
				}
				_ = s.Close()
				corruptEntry(t, dir, copyA, 2, statePrepared)
			},
			want: SlotResolution{
				Sequence: 2, Outcome: OutcomeAmbiguousAllocated, Evidence: EvidenceUnreadable,
				Coverage: Coverage{Reason: reasonTornTail},
			},
		},
		{
			name:     "committed record lost, later commit placed at its offset",
			later:    1,
			bindings: attributionAt(2, AttributionVerdict{State: AttributionVerifies, Representable: true, Digest: digestOf(7)}),
			crash: func(t *testing.T, dir string, s *Spool) {
				t.Helper()
				if _, err := s.Commit(evid(2), []byte("two"), Bindings{AttributionSHA256: digestOf(7)}); err != nil {
					t.Fatalf("commit: %v", err)
				}
				_ = s.Close()
				truncateSegment(t, dir, int64(minRecordLen+len("one")))
			},
			want: SlotResolution{
				Sequence: 2, Outcome: OutcomeAttributedLoss, Evidence: EvidenceCommitted,
				Coverage: Coverage{Attributed: true},
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			s, err := Open(dir)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			mustAppend(t, s, 1, "one")
			tc.crash(t, dir, s)

			assertTornSlot := func(t *testing.T, s *Spool, when string) {
				t.Helper()
				if got := slotOf(t, s, 2); got != tc.want {
					t.Fatalf("%s: slot 2 = %+v, want %+v", when, got, tc.want)
				}
				if d := s.RestartResolution().Discarded; len(d) != 0 {
					t.Fatalf("%s: discarded = %+v, want none", when, d)
				}
			}

			s1 := openWith(t, dir, tc.bindings)
			assertTornSlot(t, s1, "first restart")
			later := make([]uint64, 0, tc.later)
			for i := range tc.later {
				later = append(later, mustAppend(t, s1, byte(3+i), "0123456789"))
			}
			_ = s1.Close()

			s2 := openWith(t, dir, tc.bindings)
			assertTornSlot(t, s2, "restart after later commits")
			for _, seq := range later {
				if got := slotOf(t, s2, seq); got.Outcome != OutcomeCommitted {
					t.Fatalf("later slot %d = %s, want COMMITTED", seq, got.Outcome)
				}
			}
			if v, want := visibleSeqs(t, s2), append([]uint64{1}, later...); !slices.Equal(v, want) {
				t.Fatalf("sender-visible = %v, want %v", v, want)
			}
			if got, want := s2.NextSequence(), uint64(3+tc.later); got != want {
				t.Fatalf("next sequence = %d, want %d", got, want)
			}
		})
	}
}

// A torn record's header declares a length that runs through records committed after
// the restart. Trusting it would skip them: the walk would stop inside a committed
// record, report a discardable preparation there, and -- with the evidence copies
// gone -- lose their sequences from the high-water so they would be reused.
func TestTornRecordLengthDoesNotHideLaterRecords(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustAppend(t, s, 1, "one")
	crashDuringRecordBody(t, dir, s)

	s1 := openWith(t, dir, nil)
	for id := byte(3); id <= 27; id++ {
		mustAppend(t, s1, id, "0123456789")
	}
	_ = s1.Close()

	s2 := openWith(t, dir, nil)
	if d := s2.RestartResolution().Discarded; len(d) != 0 {
		t.Fatalf("discarded = %+v, want none", d)
	}
	_ = s2.Close()

	for _, c := range []int{copyA, copyB} {
		if err := os.RemoveAll(filepath.Join(dir, evidenceDirName(c))); err != nil {
			t.Fatal(err)
		}
	}
	s3 := openWith(t, dir, nil)
	res := s3.RestartResolution()
	if res.HighWater != 27 || len(res.Discarded) != 0 {
		t.Fatalf("high-water %d discarded %+v, want 27 and none", res.HighWater, res.Discarded)
	}
	assertAmbiguous(t, slotOf(t, s3, 2), EvidenceNone, Coverage{Reason: reasonTornTail})
	for seq := uint64(3); seq <= 27; seq++ {
		assertAmbiguous(t, slotOf(t, s3, seq), EvidenceNone, Coverage{Reason: reasonMissing})
	}
	if got := mustAppend(t, s3, 28, "after"); got != 28 {
		t.Fatalf("append = %d, want 28 (sequences 3..27 must not be reused)", got)
	}
}

// A commit write can tear on the second copy after the first copy committed, leaving
// that copy's preparation valid beneath a commit entry that does not verify. No
// receipt was issued, so the copies disagree: never COMMITTED, never discarded.
func TestTornSecondCommitEntryIsAmbiguousInBothOrderings(t *testing.T) {
	for _, order := range [][evidenceCopies]int{{copyA, copyB}, {copyB, copyA}} {
		written, torn := order[0], order[1]
		t.Run(fmt.Sprintf("%c committed, %c commit torn", copyTag(written), copyTag(torn)), func(t *testing.T) {
			dir := t.TempDir()
			s, err := Open(dir)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			s.copyOrder = order
			mustAppend(t, s, 1, "prior")
			s.beforeBarrier = crashBefore(commitBarrier(torn))
			r, err := s.Commit(evid(2), []byte("torn"), Bindings{})
			if err == nil {
				t.Fatal("commit succeeded through an injected crash")
			}
			assertNoReceipt(t, r)
			_ = s.Close()

			// The first half of the commit entry lands; the rest reads back as zeros.
			pos := evidencePosition(2, stateCommitted)
			landed, err := os.ReadFile(evidenceFilePath(dir, written))
			if err != nil {
				t.Fatal(err)
			}
			entry := make([]byte, evidenceEntryLen)
			copy(entry[:evidenceEntryLen/2], landed[pos:])
			entry[5] = copyTag(torn)
			f, err := os.OpenFile(evidenceFilePath(dir, torn), os.O_WRONLY, filePerm)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := f.WriteAt(entry, pos); err != nil {
				t.Fatal(err)
			}
			_ = f.Close()
			if st := entryStatusAt(t, dir, torn, 2, stateCommitted); st != entryCorrupt {
				t.Fatalf("copy %c commit entry status %d, want corrupt", copyTag(torn), st)
			}

			s2 := openWith(t, dir, nil)
			assertAmbiguous(t, slotOf(t, s2, 2), EvidenceDisagree, Coverage{Reason: reasonMissing})
			if v := visibleSeqs(t, s2); !slices.Equal(v, []uint64{1}) {
				t.Fatalf("sender-visible = %v, want [1]", v)
			}
			if d := s2.RestartResolution().Discarded; len(d) != 0 {
				t.Fatalf("discarded = %+v, want none", d)
			}
			if got := s2.NextSequence(); got != 3 {
				t.Fatalf("next sequence = %d, want 3", got)
			}
		})
	}
}

// A commit marker is written only after the record is durable, so a committed slot
// whose bytes were later lost did land: it is charged as a missing binding, not
// excused as a torn tail, and later commits do not change that.
func TestLostCommittedRecordIsNotTornTail(t *testing.T) {
	cases := []struct {
		name     string
		evidence EvidenceState
		commit   func(t *testing.T, s *Spool)
	}{
		{"both copies committed", EvidenceCommitted, func(t *testing.T, s *Spool) {
			t.Helper()
			mustAppend(t, s, 2, "two")
		}},
		{"one copy committed", EvidenceDisagree, func(t *testing.T, s *Spool) {
			t.Helper()
			s.beforeBarrier = crashBefore(barrierCommitB)
			if _, err := s.Commit(evid(2), []byte("two"), Bindings{}); err == nil {
				t.Fatal("commit succeeded through an injected crash")
			}
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			s, err := Open(dir)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			mustAppend(t, s, 1, "one")
			tc.commit(t, s)
			_ = s.Close()
			truncateSegment(t, dir, int64(minRecordLen+len("one")))

			s1 := openWith(t, dir, nil)
			assertAmbiguous(t, slotOf(t, s1, 2), tc.evidence, Coverage{Reason: reasonMissing})
			if got := mustAppend(t, s1, 3, "0123456789"); got != 3 {
				t.Fatalf("append = %d, want 3", got)
			}
			_ = s1.Close()

			s2 := openWith(t, dir, nil)
			assertAmbiguous(t, slotOf(t, s2, 2), tc.evidence, Coverage{Reason: reasonMissing})
			if v := visibleSeqs(t, s2); !slices.Equal(v, []uint64{1, 3}) {
				t.Fatalf("sender-visible = %v, want [1 3]", v)
			}
		})
	}
}

// A record can tear inside its header, leaving fewer bytes than a minimal record. It
// still consumed its sequence, so a record committed after it is found, and neither
// sequence is reused, even once every evidence copy is lost.
func TestRecordAfterTornHeaderSurvivesEvidenceLoss(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustAppend(t, s, 1, "one")
	s.beforeBarrier = crashBefore(barrierCommitA)
	if _, err := s.Commit(evid(2), []byte("two"), Bindings{}); err == nil {
		t.Fatal("commit succeeded through an injected crash")
	}
	_ = s.Close()
	truncateSegment(t, dir, int64(minRecordLen+len("one")+20))

	s1 := openWith(t, dir, nil)
	if got := mustAppend(t, s1, 3, "0123456789"); got != 3 {
		t.Fatalf("append = %d, want 3", got)
	}
	_ = s1.Close()
	for _, c := range []int{copyA, copyB} {
		if err := os.RemoveAll(filepath.Join(dir, evidenceDirName(c))); err != nil {
			t.Fatal(err)
		}
	}

	s2 := openWith(t, dir, nil)
	res := s2.RestartResolution()
	if res.HighWater != 3 || len(res.Discarded) != 0 {
		t.Fatalf("high-water %d discarded %+v, want 3 and none", res.HighWater, res.Discarded)
	}
	assertAmbiguous(t, slotOf(t, s2, 2), EvidenceNone, Coverage{Reason: reasonTornTail})
	assertAmbiguous(t, slotOf(t, s2, 3), EvidenceNone, Coverage{Reason: reasonMissing})
	if got := mustAppend(t, s2, 4, "four"); got != 4 {
		t.Fatalf("append = %d, want 4 (sequences 2 and 3 must not be reused)", got)
	}
}

// An append that fails after its preparation consumes a sequence and writes no record
// bytes, so the next record lands where it would have. Past such a gap and a torn
// one-byte fragment, a record committed later must still be found once every evidence
// copy is lost: it is allocated and ambiguous, and no sequence up to it is reused.
func TestRecordAfterZeroByteAllocationSurvivesEvidenceLoss(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustAppend(t, s, 1, "one")
	s.beforeBarrier = crashBefore(barrierRecord)
	if _, err := s.Commit(evid(2), []byte("two"), Bindings{}); err == nil {
		t.Fatal("commit succeeded through an injected crash")
	}
	_ = s.Close()

	s1 := openWith(t, dir, nil)
	s1.beforeBarrier = crashBefore(barrierCommitA)
	if _, err := s1.Commit(evid(3), []byte("three"), Bindings{}); err == nil {
		t.Fatal("commit succeeded through an injected crash")
	}
	_ = s1.Close()
	truncateSegment(t, dir, int64(minRecordLen+len("one")+1))

	s2 := openWith(t, dir, nil)
	if got := mustAppend(t, s2, 4, "0123456789"); got != 4 {
		t.Fatalf("append = %d, want 4", got)
	}
	_ = s2.Close()
	for _, c := range []int{copyA, copyB} {
		if err := os.RemoveAll(filepath.Join(dir, evidenceDirName(c))); err != nil {
			t.Fatal(err)
		}
	}

	s3 := openWith(t, dir, nil)
	res := s3.RestartResolution()
	if res.HighWater != 4 || len(res.Discarded) != 0 {
		t.Fatalf("high-water %d discarded %+v, want 4 and none", res.HighWater, res.Discarded)
	}
	for seq := uint64(2); seq <= 3; seq++ {
		assertAmbiguous(t, slotOf(t, s3, seq), EvidenceNone, Coverage{Reason: reasonTornTail})
	}
	assertAmbiguous(t, slotOf(t, s3, 4), EvidenceNone, Coverage{Reason: reasonMissing})
	if got := mustAppend(t, s3, 5, "five"); got != 5 {
		t.Fatalf("append = %d, want 5 (sequences 2 through 4 must not be reused)", got)
	}
}

// The agent's sender keeps one handle open while a producer appends through its own
// handle on the same directory.
func TestScanAdoptsCommitsFromAnotherHandle(t *testing.T) {
	dir := t.TempDir()
	reader := openWith(t, dir, nil)
	if v := visibleSeqs(t, reader); len(v) != 0 {
		t.Fatalf("sender-visible on an empty spool = %v, want none", v)
	}

	writer := openWith(t, dir, nil)
	mustAppend(t, writer, 1, "one")
	mustAppend(t, writer, 2, "two")
	if v := visibleSeqs(t, reader); !slices.Equal(v, []uint64{1, 2}) {
		t.Fatalf("sender-visible = %v, want [1 2]", v)
	}

	// A slot still in flight in its writer is neither exposed nor given up on.
	var midCommit []uint64
	writer.beforeBarrier = func(b barrier) error {
		if b == barrierCommitB {
			midCommit = visibleSeqs(t, reader)
		}
		return nil
	}
	mustAppend(t, writer, 3, "three")
	if !slices.Equal(midCommit, []uint64{1, 2}) {
		t.Fatalf("sender-visible mid-commit = %v, want [1 2]", midCommit)
	}
	if v := visibleSeqs(t, reader); !slices.Equal(v, []uint64{1, 2, 3}) {
		t.Fatalf("sender-visible after the commit = %v, want [1 2 3]", v)
	}
	if got := reader.NextSequence(); got != 4 {
		t.Fatalf("reader next sequence = %d, want 4", got)
	}
}

// A writer that fails a barrier abandons its slot and reopens to resolve it. A reader
// that stays open waits on that slot only until the writer moves past it: the slot is
// then settled, stays uncommitted and unreused, and later commits become visible.
func TestScanMovesPastSlotAbandonedByAnotherHandle(t *testing.T) {
	dir := t.TempDir()
	reader := openWith(t, dir, nil)
	writer := openWith(t, dir, nil)
	mustAppend(t, writer, 1, "one")
	mustAppend(t, writer, 2, "two")
	if v := visibleSeqs(t, reader); !slices.Equal(v, []uint64{1, 2}) {
		t.Fatalf("sender-visible = %v, want [1 2]", v)
	}

	writer.beforeBarrier = crashBefore(barrierRecord)
	if _, err := writer.Commit(evid(3), []byte("three"), Bindings{}); err == nil {
		t.Fatal("commit succeeded through an injected barrier failure")
	}
	_ = writer.Close()
	if v := visibleSeqs(t, reader); !slices.Equal(v, []uint64{1, 2}) {
		t.Fatalf("sender-visible with the abandoned slot on top = %v, want [1 2]", v)
	}

	reopened := openWith(t, dir, nil)
	for _, want := range []uint64{4, 5} {
		if got := mustAppend(t, reopened, byte(want), "later"); got != want {
			t.Fatalf("append after reopen = %d, want %d", got, want)
		}
	}
	if v := visibleSeqs(t, reader); !slices.Equal(v, []uint64{1, 2, 4, 5}) {
		t.Fatalf("sender-visible after the writer moved on = %v, want [1 2 4 5]", v)
	}
	if got := reader.NextSequence(); got != 6 {
		t.Fatalf("reader next sequence = %d, want 6 (sequence 3 must not be reused)", got)
	}
}

// A reader settles slots by file sizes it captures while another handle keeps
// appending. However far the writer gets between those captures, a record it committed
// is never settled as uncommitted: once the writer is done, the reader sees it.
func TestRefreshNeverSettlesACommitFromStaleSizes(t *testing.T) {
	cases := []struct {
		name  string
		after string
	}{
		{"writer moves on after the segment size is captured", segmentFile},
		{"writer moves on between the evidence copies' sizes", evidenceDirName(copyA)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			reader := openWith(t, dir, nil)
			writer := openWith(t, dir, nil)
			mustAppend(t, writer, 1, "one")
			if v := visibleSeqs(t, reader); !slices.Equal(v, []uint64{1}) {
				t.Fatalf("sender-visible = %v, want [1]", v)
			}

			captured := make(chan struct{})
			resume := make(chan struct{})
			var pause, release sync.Once
			resumeReader := func() { release.Do(func() { close(resume) }) }
			defer resumeReader()
			reader.afterStat = func(file string) {
				if file == tc.after {
					pause.Do(func() {
						close(captured)
						<-resume
					})
				}
			}

			type scan struct {
				recs []Record
				err  error
			}
			scanned := make(chan scan, 1)
			var midScan scan
			records := 0
			writer.beforeBarrier = func(b barrier) error {
				if b != barrierRecord {
					return nil
				}
				records++
				switch records {
				case 1:
					// Sequence 2 is prepared but its record is not written yet.
					go func() {
						recs, err := reader.Unresolved()
						scanned <- scan{recs: recs, err: err}
					}()
					select {
					case <-captured:
					case <-time.After(10 * time.Second):
						return errors.New("reader never captured the size")
					}
				case 2:
					// Sequence 2 is committed and sequence 3 is prepared.
					resumeReader()
					select {
					case midScan = <-scanned:
					case <-time.After(10 * time.Second):
						return errors.New("reader scan never finished")
					}
				}
				return nil
			}
			mustAppend(t, writer, 2, "two")
			mustAppend(t, writer, 3, "three")
			if midScan.err != nil {
				t.Fatalf("scan racing the writer: %v", midScan.err)
			}
			if v := visibleSeqs(t, reader); !slices.Equal(v, []uint64{1, 2, 3}) {
				t.Fatalf("sender-visible once the writer finished = %v, want [1 2 3]", v)
			}
		})
	}
}

// A torn record's body can hold a forged record header whose checksums verify and
// whose sequence is far beyond anything the files could hold. Open must stay bounded
// by the files: it succeeds, without sizing its work from that sequence, and still
// allocates and never reuses the torn slot.
func TestForgedFarSequenceInTornBodyKeepsOpenBounded(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustAppend(t, s, 1, "one")
	forged := encodeRecord(1<<60, evid(9), []byte("forged"))
	body := slices.Concat(bytes.Repeat([]byte{'x'}, 16), forged, bytes.Repeat([]byte{'y'}, 100))
	s.beforeBarrier = crashBefore(barrierCommitA)
	if _, err := s.Commit(evid(2), body, Bindings{}); err == nil {
		t.Fatal("commit succeeded through an injected crash")
	}
	_ = s.Close()
	// The tear keeps the forged record whole and cuts the body just after it.
	truncateSegment(t, dir, int64(minRecordLen+len("one")+headerLen+headerCRC+16+len(forged)))

	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	s2, err := Open(dir)
	runtime.ReadMemStats(&after)
	if err != nil {
		t.Fatalf("open with a forged far sequence: %v", err)
	}
	t.Cleanup(func() { _ = s2.Close() })
	if grew := after.TotalAlloc - before.TotalAlloc; grew > 64<<20 {
		t.Fatalf("open allocated %d bytes", grew)
	}

	if hw := s2.RestartResolution().HighWater; hw != 2 {
		t.Fatalf("high-water = %d, want 2: the forged sequence allocates nothing", hw)
	}
	assertAmbiguous(t, slotOf(t, s2, 2), EvidencePrepared, Coverage{Reason: reasonTornTail})
	if v := visibleSeqs(t, s2); !slices.Equal(v, []uint64{1}) {
		t.Fatalf("sender-visible = %v, want [1]", v)
	}
	if got := mustAppend(t, s2, 3, "after"); got != 3 {
		t.Fatalf("append = %d, want 3", got)
	}
	_ = s2.Close()

	// The forged header stays in the segment; later restarts must not spend sequences on it.
	for restart := 1; restart <= 2; restart++ {
		s3 := openWith(t, dir, nil)
		if hw := s3.RestartResolution().HighWater; hw != 3 {
			t.Fatalf("restart %d after a later commit: high-water = %d, want 3", restart, hw)
		}
		assertAmbiguous(t, slotOf(t, s3, 2), EvidencePrepared, Coverage{Reason: reasonTornTail})
		if v := visibleSeqs(t, s3); !slices.Equal(v, []uint64{1, 3}) {
			t.Fatalf("restart %d: sender-visible = %v, want [1 3]", restart, v)
		}
		_ = s3.Close()
	}
}

// Appends that fail after their preparation consume sequences and write nothing, so the
// next record lands right after the last one and the walk reaches it by stepping over
// intact records. With every evidence copy lost, that record's sequence counts however
// far it jumps: it stays allocated and ambiguous, and no sequence up to it is reused.
func TestCleanWalkRecordAfterZeroByteAllocationsKeepsItsSequence(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustAppend(t, s, 1, "one")
	_ = s.Close()

	const failures = 4
	for i := range failures {
		failing := openWith(t, dir, nil)
		failing.beforeBarrier = crashBefore(barrierRecord)
		if _, err := failing.Commit(evid(byte(2+i)), []byte("lost"), Bindings{}); err == nil {
			t.Fatal("commit succeeded through an injected crash")
		}
		_ = failing.Close()
	}
	kept := uint64(2 + failures)
	last := openWith(t, dir, nil)
	if got := mustAppend(t, last, byte(kept), "kept"); got != kept {
		t.Fatalf("append = %d, want %d", got, kept)
	}
	_ = last.Close()
	for _, c := range []int{copyA, copyB} {
		if err := os.RemoveAll(filepath.Join(dir, evidenceDirName(c))); err != nil {
			t.Fatal(err)
		}
	}

	reopened := openWith(t, dir, nil)
	res := reopened.RestartResolution()
	if res.HighWater != kept || len(res.Discarded) != 0 {
		t.Fatalf("high-water %d discarded %+v, want %d and none", res.HighWater, res.Discarded, kept)
	}
	assertAmbiguous(t, slotOf(t, reopened, kept), EvidenceNone, Coverage{Reason: reasonMissing})
	if got := mustAppend(t, reopened, byte(kept+1), "next"); got != kept+1 {
		t.Fatalf("append = %d, want %d (no sequence up to %d may be reused)", got, kept+1, kept)
	}
}

func TestSplitWriteCommitIsAmbiguousInBothOrderings(t *testing.T) {
	cases := []struct {
		name  string
		order [evidenceCopies]int
		crash barrier
	}{
		{"A committed, B not yet updated", [evidenceCopies]int{copyA, copyB}, barrierCommitB},
		{"B committed, A not yet updated", [evidenceCopies]int{copyB, copyA}, barrierCommitA},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			s, err := Open(dir)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			s.copyOrder = tc.order
			mustAppend(t, s, 1, "prior")
			s.beforeBarrier = crashBefore(tc.crash)
			r, err := s.Commit(evid(2), []byte("split"), Bindings{AttributionSHA256: digestOf(7)})
			if err == nil {
				t.Fatal("commit succeeded through an injected crash")
			}
			assertNoReceipt(t, r)
			_ = s.Close()

			// Both copies are READABLE and record DIFFERENT states.
			written, stale := tc.order[0], tc.order[1]
			if st := entryStatusAt(t, dir, written, 2, stateCommitted); st != entryValid {
				t.Fatalf("copy %c commit entry status %d, want valid", copyTag(written), st)
			}
			if st := entryStatusAt(t, dir, stale, 2, statePrepared); st != entryValid {
				t.Fatalf("copy %c prepare entry status %d, want valid", copyTag(stale), st)
			}
			if st := entryStatusAt(t, dir, stale, 2, stateCommitted); st != entryAbsent {
				t.Fatalf("copy %c commit entry status %d, want absent", copyTag(stale), st)
			}

			// Even with a verifying, representable binding and intact bytes, the copy
			// holding the higher generation is not taken as a commit.
			b := attributionAt(2, AttributionVerdict{State: AttributionVerifies, Representable: true, Digest: digestOf(7)})
			s2 := openWith(t, dir, b)
			assertAmbiguous(t, slotOf(t, s2, 2), EvidenceDisagree, Coverage{Attributed: true})
			if v := visibleSeqs(t, s2); !slices.Equal(v, []uint64{1}) {
				t.Fatalf("sender-visible = %v, want [1]", v)
			}
			if d := s2.RestartResolution().Discarded; len(d) != 0 {
				t.Fatalf("discarded = %+v, want none", d)
			}
			if got := s2.NextSequence(); got != 3 {
				t.Fatalf("next sequence = %d, want 3", got)
			}
		})
	}
}

func TestSingleCorruptMarkerCopyDoesNotCauseDiscard(t *testing.T) {
	committedPair := func(t *testing.T) string {
		t.Helper()
		dir := t.TempDir()
		s, err := Open(dir)
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		mustAppend(t, s, 1, "one")
		mustAppend(t, s, 2, "two")
		_ = s.Close()
		return dir
	}

	for _, c := range []int{copyA, copyB} {
		t.Run(fmt.Sprintf("copy %c commit entry corrupt over its preparation", copyTag(c)), func(t *testing.T) {
			// On disk this is a commit write that tore before any receipt, so it cannot
			// be taken as agreement with the other copy's commit.
			dir := committedPair(t)
			corruptEntry(t, dir, c, 1, stateCommitted)
			s := openWith(t, dir, nil)
			assertAmbiguous(t, slotOf(t, s, 1), EvidenceDisagree, Coverage{Reason: reasonMissing})
			if d := s.RestartResolution().Discarded; len(d) != 0 {
				t.Fatalf("discarded = %+v, want none", d)
			}
			if v := visibleSeqs(t, s); !slices.Equal(v, []uint64{2}) {
				t.Fatalf("sender-visible = %v, want [2]", v)
			}
			if got := mustAppend(t, s, 3, "three"); got != 3 {
				t.Fatalf("append = %d, want 3", got)
			}
		})
		t.Run(fmt.Sprintf("copy %c both entries corrupt", copyTag(c)), func(t *testing.T) {
			dir := committedPair(t)
			corruptEntry(t, dir, c, 1, statePrepared)
			corruptEntry(t, dir, c, 1, stateCommitted)
			s := openWith(t, dir, nil)
			if got := slotOf(t, s, 1); got.Outcome != OutcomeCommitted {
				t.Fatalf("slot 1 = %s, want COMMITTED from the redundant copy", got.Outcome)
			}
		})
		t.Run(fmt.Sprintf("copy %c file lost", copyTag(c)), func(t *testing.T) {
			dir := committedPair(t)
			if err := os.RemoveAll(filepath.Join(dir, evidenceDirName(c))); err != nil {
				t.Fatal(err)
			}
			s := openWith(t, dir, nil)
			if v := visibleSeqs(t, s); !slices.Equal(v, []uint64{1, 2}) {
				t.Fatalf("sender-visible = %v, want [1 2]", v)
			}
			if got := mustAppend(t, s, 3, "three"); got != 3 {
				t.Fatalf("append = %d, want 3", got)
			}
		})
	}

	t.Run("the only commit marker copy unreadable", func(t *testing.T) {
		dir := t.TempDir()
		s, err := Open(dir)
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		mustAppend(t, s, 1, "one")
		s.beforeBarrier = crashBefore(barrierCommitB)
		if _, err := s.Commit(evid(2), []byte("two"), Bindings{}); err == nil {
			t.Fatal("commit succeeded through an injected crash")
		}
		_ = s.Close()
		corruptEntry(t, dir, copyA, 2, stateCommitted)

		s2 := openWith(t, dir, nil)
		assertAmbiguous(t, slotOf(t, s2, 2), EvidencePrepared, Coverage{Reason: reasonMissing})
		if d := s2.RestartResolution().Discarded; len(d) != 0 {
			t.Fatalf("discarded = %+v, want none", d)
		}
		if got := s2.NextSequence(); got != 3 {
			t.Fatalf("next sequence = %d, want 3", got)
		}
	})

	t.Run("every commit marker copy unreadable", func(t *testing.T) {
		dir := committedPair(t)
		corruptEntry(t, dir, copyA, 1, stateCommitted)
		corruptEntry(t, dir, copyB, 1, stateCommitted)
		s := openWith(t, dir, nil)
		assertAmbiguous(t, slotOf(t, s, 1), EvidencePrepared, Coverage{Reason: reasonMissing})
		if v := visibleSeqs(t, s); !slices.Equal(v, []uint64{2}) {
			t.Fatalf("sender-visible = %v, want [2]", v)
		}
	})
}

func TestAllocatedButUnmarkedSequenceReachesRolloverCoverage(t *testing.T) {
	cases := []struct {
		name    string
		verdict AttributionVerdict
		want    Coverage
	}{
		{"no binding", AttributionVerdict{}, Coverage{Reason: reasonMissing}},
		{"binding verifies and span representable", AttributionVerdict{State: AttributionVerifies, Representable: true}, Coverage{Attributed: true}},
		{"binding verifies but span not representable", AttributionVerdict{State: AttributionVerifies}, Coverage{Reason: reasonUnrepresentable}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			s, err := Open(dir)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			mustAppend(t, s, 1, "one")
			mustAppend(t, s, 2, "two")
			mustAppend(t, s, 3, "three")
			_ = s.Close()

			// Sequence 2 keeps only its place under the high-water: no marker in either
			// copy and no intact record.
			for _, c := range []int{copyA, copyB} {
				zeroEntry(t, dir, c, 2, statePrepared)
				zeroEntry(t, dir, c, 2, stateCommitted)
			}
			corruptBody(t, dir, int64(minRecordLen+len("one")))

			s2 := openWith(t, dir, attributionAt(2, tc.verdict))
			assertAmbiguous(t, slotOf(t, s2, 2), EvidenceNone, tc.want)
			if v := visibleSeqs(t, s2); !slices.Equal(v, []uint64{1, 3}) {
				t.Fatalf("sender-visible = %v, want [1 3]", v)
			}
			if got := mustAppend(t, s2, 4, "four"); got != 4 {
				t.Fatalf("append = %d, want 4 (sequence 2 must not be reused)", got)
			}
		})
	}
}

func TestCompletePreparedRecordWithoutMarkerIsAmbiguous(t *testing.T) {
	t.Run("commit marker never written", func(t *testing.T) {
		dir := t.TempDir()
		s, err := Open(dir)
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		s.beforeBarrier = crashBefore(barrierCommitA)
		if _, err := s.Commit(evid(1), []byte("one"), Bindings{}); err == nil {
			t.Fatal("commit succeeded through an injected crash")
		}
		_ = s.Close()

		s2 := openWith(t, dir, nil)
		assertAmbiguous(t, slotOf(t, s2, 1), EvidencePrepared, Coverage{Reason: reasonMissing})
		if v := visibleSeqs(t, s2); len(v) != 0 {
			t.Fatalf("sender-visible = %v, want none", v)
		}
	})

	t.Run("all commit evidence lost", func(t *testing.T) {
		dir := t.TempDir()
		s, err := Open(dir)
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		mustAppend(t, s, 1, "one")
		mustAppend(t, s, 2, "two")
		_ = s.Close()
		for _, c := range []int{copyA, copyB} {
			if err := os.RemoveAll(filepath.Join(dir, evidenceDirName(c))); err != nil {
				t.Fatal(err)
			}
		}

		s2 := openWith(t, dir, nil)
		for seq := uint64(1); seq <= 2; seq++ {
			assertAmbiguous(t, slotOf(t, s2, seq), EvidenceNone, Coverage{Reason: reasonMissing})
		}
		if v := visibleSeqs(t, s2); len(v) != 0 {
			t.Fatalf("sender-visible = %v, want none", v)
		}
		if got := s2.NextSequence(); got != 3 {
			t.Fatalf("next sequence = %d, want 3", got)
		}
	})
}

func TestNoReceiptUntilEvidenceCopiesAndDirectoryMetadataAreDurable(t *testing.T) {
	for _, at := range allBarriers {
		t.Run(barrierName(at), func(t *testing.T) {
			dir := t.TempDir()
			s, err := Open(dir)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			if !isDirBarrier(at) {
				mustAppend(t, s, 1, "prior")
			}
			inFlight := s.NextSequence()

			s.beforeBarrier = crashBefore(at)
			r, err := s.Commit(evid(9), []byte("pending"), Bindings{})
			if err == nil {
				t.Fatal("commit succeeded with a barrier not durable")
			}
			assertNoReceipt(t, r)

			// The failed spool issues no receipt for anything until restart resolves it.
			s.beforeBarrier = nil
			r, err = s.Commit(evid(9), []byte("pending"), Bindings{})
			if !errors.Is(err, ErrFailStopped) {
				t.Fatalf("retry after failed barrier = %v, want ErrFailStopped", err)
			}
			assertNoReceipt(t, r)
			_ = s.Close()

			s2 := openWith(t, dir, nil)
			if got, ok := s2.RestartResolution().Slot(inFlight); ok && got.Outcome == OutcomeCommitted {
				t.Fatalf("sequence %d resolved COMMITTED without a receipt", inFlight)
			}
			if slices.Contains(visibleSeqs(t, s2), inFlight) {
				t.Fatalf("sequence %d is sender-visible without a receipt", inFlight)
			}
		})
	}

	t.Run("copy whose directory entry was lost", func(t *testing.T) {
		dir := t.TempDir()
		s, err := Open(dir)
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		mustAppend(t, s, 1, "one")
		_ = s.Close()
		if err := os.RemoveAll(filepath.Join(dir, evidenceDirName(copyB))); err != nil {
			t.Fatal(err)
		}

		s2 := openWith(t, dir, nil)
		s2.beforeBarrier = crashBefore(barrierEvidenceDirB)
		r, err := s2.Commit(evid(2), []byte("two"), Bindings{})
		if err == nil {
			t.Fatal("commit succeeded before the recreated copy's directory metadata was durable")
		}
		assertNoReceipt(t, r)
	})

	t.Run("receipt follows every barrier", func(t *testing.T) {
		dir := t.TempDir()
		s := openWith(t, dir, nil)
		var crossed []barrier
		s.beforeBarrier = func(b barrier) error {
			crossed = append(crossed, b)
			return nil
		}
		r, err := s.Commit(evid(1), []byte("one"), Bindings{})
		if err != nil {
			t.Fatalf("commit: %v", err)
		}
		if !slices.Equal(crossed, allBarriers) {
			t.Fatalf("barriers crossed before the receipt = %v, want %v", crossed, allBarriers)
		}
		if r.Sequence != 1 || r.EvidenceGeneration == 0 {
			t.Fatalf("receipt = %+v", r)
		}
		for _, c := range []int{copyA, copyB} {
			buf, err := os.ReadFile(evidenceFilePath(dir, c))
			if err != nil {
				t.Fatal(err)
			}
			pos := evidencePosition(1, stateCommitted)
			e, st := decodeEvidence(buf[pos:pos+evidenceEntryLen], c, 1, stateCommitted)
			if st != entryValid || e.generation != r.EvidenceGeneration {
				t.Fatalf("copy %c commit entry = %+v status %d, want valid at generation %d",
					copyTag(c), e, st, r.EvidenceGeneration)
			}
		}
	})
}

// A binding that verifies for the slot but whose span the frozen identity cannot
// carry is UNATTRIBUTABLE(DISCRIMINATOR_UNREPRESENTABLE) -- the only runtime path to
// that reason -- and never an attributed loss.
func TestVerifiedButUnrepresentableBindingIsDiscriminatorUnrepresentable(t *testing.T) {
	cases := []struct {
		name          string
		representable bool
		want          Outcome
		cov           Coverage
	}{
		{"positive control: representable", true, OutcomeAttributedLoss, Coverage{Attributed: true}},
		{"verifies but not representable", false, OutcomeUnattributable, Coverage{Reason: reasonUnrepresentable}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			s, err := Open(dir)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			if _, err := s.Commit(evid(1), []byte("one"), Bindings{AttributionSHA256: digestOf(7)}); err != nil {
				t.Fatalf("commit: %v", err)
			}
			_ = s.Close()
			corruptBody(t, dir, 0)

			b := attributionAt(1, AttributionVerdict{State: AttributionVerifies, Representable: tc.representable, Digest: digestOf(7)})
			s2 := openWith(t, dir, b)
			got := slotOf(t, s2, 1)
			if got.Outcome != tc.want || got.Coverage != tc.cov || !got.EntersCoverage() {
				t.Fatalf("slot 1 = %s %+v, want %s %+v", got.Outcome, got.Coverage, tc.want, tc.cov)
			}
			if v := visibleSeqs(t, s2); len(v) != 0 {
				t.Fatalf("sender-visible = %v, want none", v)
			}
		})
	}
}

func TestAttributionBindingMustBeTheCommittedOne(t *testing.T) {
	cases := []struct {
		name     string
		declared []byte
		verdict  AttributionVerdict
		want     Coverage
	}{
		{"transplanted from another slot", digestOf(7),
			AttributionVerdict{State: AttributionVerifies, Representable: true, Digest: digestOf(8)}, Coverage{Reason: reasonCorrupt}},
		{"binding the commit never declared", nil,
			AttributionVerdict{State: AttributionVerifies, Representable: true, Digest: digestOf(7)}, Coverage{Reason: reasonCorrupt}},
		{"declared binding with unsupported version", digestOf(7),
			AttributionVerdict{State: AttributionVersionUnsupported}, Coverage{Reason: reasonUnsupported}},
		{"declared binding absent", digestOf(7), AttributionVerdict{}, Coverage{Reason: reasonMissing}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			s, err := Open(dir)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			if _, err := s.Commit(evid(1), []byte("one"), Bindings{AttributionSHA256: tc.declared}); err != nil {
				t.Fatalf("commit: %v", err)
			}
			_ = s.Close()
			corruptBody(t, dir, 0)

			s2 := openWith(t, dir, attributionAt(1, tc.verdict))
			assertAmbiguous(t, slotOf(t, s2, 1), EvidenceCommitted, tc.want)
		})
	}
}

func TestCommittedSlotRequiresItsReceiptBinding(t *testing.T) {
	cases := []struct {
		name    string
		verdict ReceiptVerdict
		commit  bool
	}{
		{"receipt binding valid", ReceiptVerdict{State: ReceiptValid, Digest: digestOf(3)}, true},
		{"receipt binding missing", ReceiptVerdict{}, false},
		{"receipt binding unverifiable", ReceiptVerdict{State: ReceiptUnverifiable}, false},
		{"receipt binding for another commit", ReceiptVerdict{State: ReceiptValid, Digest: digestOf(4)}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			s, err := Open(dir)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			if _, err := s.Commit(evid(1), []byte("one"), Bindings{ReceiptSHA256: digestOf(3)}); err != nil {
				t.Fatalf("commit: %v", err)
			}
			_ = s.Close()

			s2 := openWith(t, dir, fakeBindings{receipt: map[uint64]ReceiptVerdict{1: tc.verdict}})
			got := slotOf(t, s2, 1)
			if tc.commit {
				if got.Outcome != OutcomeCommitted {
					t.Fatalf("slot 1 = %s, want COMMITTED", got.Outcome)
				}
				return
			}
			assertAmbiguous(t, got, EvidenceCommitted, Coverage{Reason: reasonMissing})
			if v := visibleSeqs(t, s2); len(v) != 0 {
				t.Fatalf("sender-visible = %v, want none", v)
			}
		})
	}
}

func TestWrapperNamingAnotherSlotIsAmbiguous(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustAppend(t, s, 1, "aaaa")
	mustAppend(t, s, 2, "bbbb")
	_ = s.Close()

	// Checksum-valid bytes at slot 1's location that describe slot 2.
	substitute := encodeRecord(2, evid(2), []byte("bbbb"))
	mutate(t, filepath.Join(dir, segmentFile), 0, len(substitute), func(b []byte) { copy(b, substitute) })

	s2 := openWith(t, dir, nil)
	assertAmbiguous(t, slotOf(t, s2, 1), EvidenceCommitted, Coverage{Reason: reasonMissing})
	if v := visibleSeqs(t, s2); !slices.Equal(v, []uint64{2}) {
		t.Fatalf("sender-visible = %v, want [2]", v)
	}
}

func TestUnreadableRecordHeaderDoesNotHideLaterSequences(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustAppend(t, s, 1, "one")
	mustAppend(t, s, 2, "two")
	mustAppend(t, s, 3, "three")
	_ = s.Close()
	for _, c := range []int{copyA, copyB} {
		if err := os.RemoveAll(filepath.Join(dir, evidenceDirName(c))); err != nil {
			t.Fatal(err)
		}
	}
	mutate(t, filepath.Join(dir, segmentFile), int64(minRecordLen+len("one")), 1, func(b []byte) { b[0] ^= 0xFF })

	s2 := openWith(t, dir, nil)
	if hw := s2.RestartResolution().HighWater; hw != 3 {
		t.Fatalf("high-water = %d, want 3", hw)
	}
	for seq := uint64(1); seq <= 3; seq++ {
		if got := slotOf(t, s2, seq); got.Outcome != OutcomeAmbiguousAllocated {
			t.Fatalf("slot %d = %s, want AMBIGUOUS_ALLOCATED_SLOT", seq, got.Outcome)
		}
	}
	if got := mustAppend(t, s2, 4, "four"); got != 4 {
		t.Fatalf("append = %d, want 4", got)
	}
}
