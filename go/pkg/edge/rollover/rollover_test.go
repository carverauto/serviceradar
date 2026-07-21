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

package rollover

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestManifestDiscreteBelowBound(t *testing.T) {
	m := NewManifest(4)
	m.Add(10, 12)
	m.Add(20, 25)
	if m.Coarsened() {
		t.Fatal("must not coarsen below the entry bound")
	}
	rs := m.Ranges()
	if len(rs) != 2 || rs[0].From != 10 || rs[1].Through != 25 {
		t.Fatalf("ranges = %+v", rs)
	}
	lo, hi, ok := m.Bounds()
	if !ok || lo != 10 || hi != 25 {
		t.Fatalf("bounds = %d,%d,%v", lo, hi, ok)
	}
}

func TestManifestCoarsensPastBound(t *testing.T) {
	m := NewManifest(3)
	// Simulate an outage-sized tail: many discrete ranges.
	for i := uint64(0); i < 1000; i++ {
		m.Add(i*10, i*10+3)
	}
	if !m.Coarsened() {
		t.Fatal("must coarsen an overlarge manifest")
	}
	rs := m.Ranges()
	if len(rs) != 1 {
		t.Fatalf("coarsened manifest must expose one conservative range, got %d", len(rs))
	}
	if rs[0].From != 0 || rs[0].Through != 9993 {
		t.Fatalf("conservative range = %+v, want [0,9993]", rs[0])
	}
}

func TestManifestDigestStableAndCoarsenSensitive(t *testing.T) {
	a := NewManifest(8)
	a.Add(1, 2)
	a.Add(5, 6)
	b := NewManifest(8)
	b.Add(5, 6) // reversed insert order -> same sorted digest
	b.Add(1, 2)
	if string(a.Digest()) != string(b.Digest()) {
		t.Fatal("digest must be insertion-order independent")
	}
	// A coarsened [1,6] must not collide with a discrete manifest spanning 1..6.
	c := NewManifest(1)
	c.Add(1, 2)
	c.Add(5, 6) // exceeds bound of 1 -> coarsens to [1,6]
	if !c.Coarsened() {
		t.Fatal("expected coarsen")
	}
	if string(c.Digest()) == string(a.Digest()) {
		t.Fatal("coarsened digest must differ from the discrete digest of the same span")
	}
}

func TestManifestTombstone(t *testing.T) {
	m := NewManifest(4)
	m.Add(100, 200)
	rec := []byte("recovery-uuid-16")
	prior := []byte("prior-spool-id16")
	next := []byte("new---spool-id16")
	ts := m.Tombstone(rec, prior, next, 1720000000000000000)
	if ts.GetLostFromSequence() != 100 || ts.GetLostThroughSequence() != 200 {
		t.Fatalf("lost span = %d..%d", ts.GetLostFromSequence(), ts.GetLostThroughSequence())
	}
	if string(ts.GetManifestSha256()) != string(m.Digest()) {
		t.Fatal("tombstone manifest digest mismatch")
	}
	if ts.GetCoarsened() {
		t.Fatal("should not be coarsened")
	}
}

func TestJournalAdvancesAndResumesAcrossRestart(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "roll")
	j, err := Open(dir)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if j.State().Phase != PhaseNone {
		t.Fatalf("fresh phase = %d", j.State().Phase)
	}
	rec := []byte("recovery-uuid-16")
	if err := j.Begin(rec, []byte("prior-spool-id16"), []byte("new---spool-id16")); err != nil {
		t.Fatalf("begin: %v", err)
	}
	if err := j.SetManifest([]byte("digest"), true); err != nil {
		t.Fatalf("set-manifest: %v", err)
	}
	if err := j.AdvanceCopy(50); err != nil {
		t.Fatalf("copy 50: %v", err)
	}
	if err := j.AdvanceCopy(120); err != nil {
		t.Fatalf("copy 120: %v", err)
	}

	// Simulate a crash+restart: reopen from disk and confirm we resume at the
	// last durable phase and watermark.
	j2, err := Open(dir)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	st := j2.State()
	if st.Phase != PhaseCopying || st.CopyWatermark != 120 {
		t.Fatalf("resumed phase=%d watermark=%d, want Copying/120", st.Phase, st.CopyWatermark)
	}
	if string(st.RecoveryID) != string(rec) || !st.Coarsened {
		t.Fatalf("resumed identity/coarsened lost: %+v", st)
	}
	// Finish the rollover from the resumed journal.
	if err := j2.Activate(st.CopyWatermark); err != nil {
		t.Fatalf("activate: %v", err)
	}
	if err := j2.Resolve(); err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if j2.State().Phase != PhaseResolved {
		t.Fatalf("final phase = %d", j2.State().Phase)
	}
}

func TestJournalRejectsRegression(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "roll")
	j, _ := Open(dir)
	_ = j.Begin([]byte("r"), []byte("p"), []byte("n"))
	_ = j.SetManifest([]byte("d"), false)
	_ = j.AdvanceCopy(10)
	if err := j.AdvanceCopy(9); !errors.Is(err, ErrWatermarkRegression) {
		t.Fatalf("want ErrWatermarkRegression, got %v", err)
	}
	// Cannot begin again mid-rollover.
	if err := j.Begin([]byte("r2"), []byte("p"), []byte("n")); !errors.Is(err, ErrPhaseRegression) {
		t.Fatalf("want ErrPhaseRegression, got %v", err)
	}
}

func TestJournalDetectsCorruption(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "roll")
	j, _ := Open(dir)
	_ = j.Begin([]byte("r"), []byte("p"), []byte("n"))

	// Flip a byte in the persisted journal payload.
	path := filepath.Join(dir, journalFile)
	buf, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	buf[len(buf)/2] ^= 0xFF
	if err := os.WriteFile(path, buf, 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := Open(dir); !errors.Is(err, ErrCorruptJournal) {
		t.Fatalf("want ErrCorruptJournal, got %v", err)
	}
}

// Finding usp-13/P1: Activate must require PhaseCopying and a sufficient copy
// watermark; it must not activate from PhaseManifestDurable (CopyWatermark 0),
// which would strand every readable record in the old spool.
func TestJournalActivationRequiresCopyProgress(t *testing.T) {
	dir := t.TempDir()
	j, _ := Open(dir)
	_ = j.Begin([]byte("r"), []byte("p"), []byte("n"))
	_ = j.SetManifest([]byte("d"), false)

	// Cannot activate straight from PhaseManifestDurable.
	if err := j.Activate(0); !errors.Is(err, ErrPhaseRegression) {
		t.Fatalf("activate from manifest-durable = %v, want ErrPhaseRegression", err)
	}
	// Enter copying, but with a watermark below the required completion point.
	if err := j.AdvanceCopy(30); err != nil {
		t.Fatalf("advance copy: %v", err)
	}
	if err := j.Activate(50); !errors.Is(err, ErrCopyIncomplete) {
		t.Fatalf("activate before copy complete = %v, want ErrCopyIncomplete", err)
	}
	// Once the watermark reaches the required point, activation succeeds.
	if err := j.AdvanceCopy(50); err != nil {
		t.Fatalf("advance copy 50: %v", err)
	}
	if err := j.Activate(50); err != nil {
		t.Fatalf("activate at required watermark: %v", err)
	}
	if j.State().Phase != PhaseNewSpoolActive {
		t.Fatalf("phase = %d, want PhaseNewSpoolActive", j.State().Phase)
	}
}

// A rollover with nothing to recover still passes through PhaseCopying via
// AdvanceCopy(0) and activates with requiredCopyThrough == 0.
func TestJournalZeroCopyRolloverActivates(t *testing.T) {
	dir := t.TempDir()
	j, _ := Open(dir)
	_ = j.Begin([]byte("r"), []byte("p"), []byte("n"))
	_ = j.SetManifest([]byte("d"), true)
	if err := j.AdvanceCopy(0); err != nil {
		t.Fatalf("advance copy 0: %v", err)
	}
	if err := j.Activate(0); err != nil {
		t.Fatalf("zero-copy activate: %v", err)
	}
}

// Finding usp-13/P2: equivalent loss sets must normalize to the same canonical
// ranges and hash identically; overlaps/adjacency are merged.
func TestManifestNormalizesEquivalentSets(t *testing.T) {
	whole := NewManifest(8)
	whole.Add(1, 5)

	split := NewManifest(8)
	split.Add(1, 3)
	split.Add(4, 5) // adjacent to [1,3]

	if string(whole.Digest()) != string(split.Digest()) {
		t.Fatal("[1,5] and [1,3]+[4,5] must hash identically after normalization")
	}
	rs := split.Ranges()
	if len(rs) != 1 || rs[0].From != 1 || rs[0].Through != 5 {
		t.Fatalf("adjacent ranges not merged: %+v", rs)
	}

	// Overlapping and duplicate reports must not consume the entry cap.
	m := NewManifest(2)
	m.Add(1, 10)
	m.Add(3, 6)  // fully inside
	m.Add(1, 10) // duplicate
	m.Add(9, 12) // overlaps/extends
	if m.Coarsened() {
		t.Fatal("overlapping/duplicate reports must not trigger coarsening")
	}
	rs = m.Ranges()
	if len(rs) != 1 || rs[0].Through != 12 {
		t.Fatalf("overlaps not merged: %+v", rs)
	}
}
