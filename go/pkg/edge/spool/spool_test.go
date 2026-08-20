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
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func evid(b byte) []byte {
	out := make([]byte, 16)
	for i := range out {
		out[i] = b
	}
	return out
}

func mustAppend(t *testing.T, s *Spool, id byte, body string) uint64 {
	t.Helper()
	seq, err := s.Append(evid(id), []byte(body))
	if err != nil {
		t.Fatalf("append: %v", err)
	}
	return seq
}

func TestAppendAssignsContiguousSequencesFromOne(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer func() { _ = s.Close() }()

	if got := mustAppend(t, s, 1, "a"); got != 1 {
		t.Fatalf("first seq = %d, want 1", got)
	}
	if got := mustAppend(t, s, 2, "bb"); got != 2 {
		t.Fatalf("second seq = %d, want 2", got)
	}

	recs, err := s.Unresolved()
	if err != nil {
		t.Fatalf("unresolved: %v", err)
	}
	if len(recs) != 2 || recs[0].Sequence != 1 || string(recs[1].Body) != "bb" {
		t.Fatalf("unexpected records: %+v", recs)
	}
}

func TestResolveExcludesAckedRecords(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	defer func() { _ = s.Close() }()

	mustAppend(t, s, 1, "a")
	mustAppend(t, s, 2, "b")
	mustAppend(t, s, 3, "c")

	if err := s.Resolve(2); err != nil {
		t.Fatalf("resolve: %v", err)
	}
	recs, _ := s.Unresolved()
	if len(recs) != 1 || recs[0].Sequence != 3 {
		t.Fatalf("after resolve(2), unresolved = %+v, want only seq 3", recs)
	}

	// Watermark only advances.
	if err := s.Resolve(1); err != nil {
		t.Fatalf("resolve backwards: %v", err)
	}
	recs, _ = s.Unresolved()
	if len(recs) != 1 {
		t.Fatal("resolve must not move backwards")
	}
}

func TestRecoveryPreservesSequenceAndData(t *testing.T) {
	dir := t.TempDir()

	s, _ := Open(dir)
	mustAppend(t, s, 1, "a")
	mustAppend(t, s, 2, "b")
	if err := s.Resolve(1); err != nil {
		t.Fatalf("resolve: %v", err)
	}
	_ = s.Close()

	s2, err := Open(dir)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = s2.Close() }()

	if s2.NextSequence() != 3 {
		t.Fatalf("next seq after reopen = %d, want 3 (never reused)", s2.NextSequence())
	}
	recs, _ := s2.Unresolved()
	if len(recs) != 1 || recs[0].Sequence != 2 {
		t.Fatalf("resolved watermark not persisted across reopen: %+v", recs)
	}

	if got := mustAppend(t, s2, 3, "c"); got != 3 {
		t.Fatalf("append after recovery = %d, want 3", got)
	}
}

func TestTornTailIsTruncatedOnRecovery(t *testing.T) {
	dir := t.TempDir()

	s, _ := Open(dir)
	mustAppend(t, s, 1, "a")
	mustAppend(t, s, 2, "b")
	_ = s.Close()

	// Simulate a torn write: append a partial record (magic + a few bytes,
	// shorter than a full header) to the segment.
	segPath := filepath.Join(dir, segmentFile)
	f, err := os.OpenFile(segPath, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatalf("open seg: %v", err)
	}
	var partial [10]byte
	binary.LittleEndian.PutUint32(partial[0:], recordMagic)
	if _, err := f.Write(partial[:]); err != nil {
		t.Fatalf("write partial: %v", err)
	}
	_ = f.Close()

	s2, err := Open(dir)
	if err != nil {
		t.Fatalf("reopen after torn write: %v", err)
	}
	defer func() { _ = s2.Close() }()

	recs, _ := s2.Unresolved()
	if len(recs) != 2 {
		t.Fatalf("torn tail not truncated: got %d records, want 2", len(recs))
	}
	if s2.NextSequence() != 3 {
		t.Fatalf("next seq = %d, want 3", s2.NextSequence())
	}

	// Recovery left the segment writable and consistent.
	if got := mustAppend(t, s2, 9, "d"); got != 3 {
		t.Fatalf("append after torn-tail recovery = %d, want 3", got)
	}
	recs, _ = s2.Unresolved()
	if len(recs) != 3 || string(recs[2].Body) != "d" {
		t.Fatalf("post-recovery append not durable: %+v", recs)
	}
}

func TestAppendRejectsBadEventID(t *testing.T) {
	s, _ := Open(t.TempDir())
	defer func() { _ = s.Close() }()
	if _, err := s.Append([]byte{1, 2, 3}, []byte("x")); err == nil {
		t.Fatal("expected error for non-16-byte event id")
	}
}

func TestSpoolDirIsPrivate(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "lane")
	s, err := Open(dir)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer func() { _ = s.Close() }()

	info, err := os.Stat(dir)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		t.Fatalf("spool dir perms %o are group/world-accessible", perm)
	}
}

// Finding usp-05/P1: Resolve must reject a watermark past the durable append
// high-water, or a stale/forged ACK permanently hides never-appended frames.
func TestResolveRejectsBeyondHighWater(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	defer func() { _ = s.Close() }()
	mustAppend(t, s, 1, "a") // seq 1 is the high-water

	if err := s.Resolve(100); !errors.Is(err, ErrResolveBeyondHighWater) {
		t.Fatalf("Resolve(100) = %v, want ErrResolveBeyondHighWater", err)
	}
	// The bogus watermark must not have taken effect.
	recs, err := s.Unresolved()
	if err != nil {
		t.Fatalf("unresolved: %v", err)
	}
	if len(recs) != 1 || recs[0].Sequence != 1 {
		t.Fatalf("frame hidden by rejected resolve: %+v", recs)
	}
	// A legitimate in-range resolve still works.
	if err := s.Resolve(1); err != nil {
		t.Fatalf("Resolve(1): %v", err)
	}
}

// Finding usp-05/P1: a fully-present record with a bad body CRC is committed
// corruption, not a torn tail, and must be surfaced (for rollover) rather than
// silently truncated -- otherwise later readable records are dropped unaudited.
func TestCorruptCommittedBodyIsDetected(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	mustAppend(t, s, 1, "a")
	mustAppend(t, s, 2, "b") // a second record follows, so record 1 is not the tail
	_ = s.Close()

	// Flip a byte inside record 1's body. Body of the first record sits right
	// after headerLen+headerCRC.
	segPath := filepath.Join(dir, segmentFile)
	buf, err := os.ReadFile(segPath)
	if err != nil {
		t.Fatalf("read seg: %v", err)
	}
	bodyOff := headerLen + headerCRC
	buf[bodyOff] ^= 0xFF
	if err := os.WriteFile(segPath, buf, 0o600); err != nil {
		t.Fatalf("write seg: %v", err)
	}

	_, err = Open(dir)
	var corrupt *CorruptBodyError
	if !errors.As(err, &corrupt) {
		t.Fatalf("Open on corrupt committed body = %v, want *CorruptBodyError", err)
	}
	if corrupt.Sequence != 1 {
		t.Fatalf("corruption reported at seq %d, want 1", corrupt.Sequence)
	}
}

// Finding usp-05/P1 (sender backpressure): ScanFrom must stop early and honor
// the `after` cursor so the whole spool is never materialized to apply a small
// credit window.
func TestScanFromBoundedAndCursor(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir)
	defer func() { _ = s.Close() }()
	for i := byte(1); i <= 10; i++ {
		mustAppend(t, s, i, "payload")
	}

	// Early stop after 3 records (simulating an exhausted credit window).
	var seen []uint64
	err := s.ScanFrom(0, func(rec Record) bool {
		seen = append(seen, rec.Sequence)
		return len(seen) < 3
	})
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(seen) != 3 || seen[0] != 1 {
		t.Fatalf("early-stop scan = %v, want first 3", seen)
	}

	// Cursor: resume after sequence 7, take the rest.
	seen = nil
	if err := s.ScanFrom(7, func(rec Record) bool { seen = append(seen, rec.Sequence); return true }); err != nil {
		t.Fatalf("scan from 7: %v", err)
	}
	if len(seen) != 3 || seen[0] != 8 || seen[2] != 10 {
		t.Fatalf("cursor scan from 7 = %v, want 8,9,10", seen)
	}
}
