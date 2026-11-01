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
	"strings"
	"syscall"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

const (
	acceptedKind  = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE
	permanentKind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
)

// mixedAck acknowledges seqs through their last one, rejecting the sequences in
// permanent with a synthetic rejection code and accepting the rest.
func mixedAck(t *testing.T, seqs []uint64, permanent ...uint64) []byte {
	t.Helper()
	ack := &edgev1.EdgeDeliveryAckV1{SpoolId: evid(91), SessionNonce: evid(92), ResolvedThroughSequence: seqs[len(seqs)-1]}
	for _, seq := range seqs {
		d := &edgev1.EdgeRecordDisposition{Sequence: seq, EventId: evid(byte(seq)), Kind: acceptedKind}
		for _, p := range permanent {
			if p == seq {
				d.Kind, d.RejectionCode = permanentKind, "synthetic_fence_stale"
			}
		}
		ack.Dispositions = append(ack.Dispositions, d)
	}
	b, err := proto.Marshal(ack)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// quarantinedFiles returns the contents of every quarantine entry in dir.
func quarantinedFiles(t *testing.T, dir string) map[string][]byte {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string][]byte{}
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), "quarantine-") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		out[e.Name()] = b
	}
	return out
}

func diskBytes(t *testing.T, dir string) uint64 {
	t.Helper()
	var total uint64
	err := filepath.Walk(dir, func(_ string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.Mode().IsRegular() {
			total += uint64(info.Size())
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return total
}

// One permanently rejected record used to keep its whole segment on disk
// forever, so a spool shared by every producer stopped reclaiming and filled. It
// must instead leave the spool through local quarantine.
func TestPermanentRejectionIsQuarantinedAndTheSegmentReclaims(t *testing.T) {
	dir := t.TempDir()
	footprint := testFootprint()
	footprint.DestinationSegment = 64 << 10
	alloc, err := NewAllocator(AllocatorConfig{Capacity: 1 << 20, Recovery: footprint, MaxConcurrentRecoveries: 1, MinFree: 4096})
	if err != nil {
		t.Fatal(err)
	}
	s, err := Open(dir, WithAllocator(alloc))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Close() }()
	rejected := bytes.Repeat([]byte("synthetic rejected record "), 64)
	for seq := byte(1); seq <= 3; seq++ {
		body := []byte("synthetic accepted record")
		if seq == 2 {
			body = rejected
		}
		if _, err := s.Append(evid(seq), body); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.ResolveWithEvidence(3, mixedAck(t, []uint64{1, 2, 3}, 2)); err != nil {
		t.Fatal(err)
	}

	if name, err := os.Readlink(filepath.Join(dir, segmentFile)); err != nil || name != dataName(3) {
		t.Fatalf("segment not reclaimed past the permanent rejection: pointer %q, %v", name, err)
	}
	quarantined := quarantinedFiles(t, dir)
	if len(quarantined) != 1 {
		t.Fatalf("quarantine holds %d entries, want the one rejected record", len(quarantined))
	}
	for name, b := range quarantined {
		if !strings.Contains(name, "00000000000000000002") || !bytes.Contains(b, rejected) || !bytes.Contains(b, []byte("synthetic_fence_stale")) {
			t.Fatalf("quarantine entry %s lacks the rejected record, its sequence, or its rejection code", name)
		}
	}
	if u := alloc.Usage(); u.OrdinaryUsed != diskBytes(t, dir) || u.ActiveRecoveries != 0 || u.RecoveryUsed != 0 {
		t.Fatalf("allocator does not match the disk after reclaim: %+v on disk %d", u, diskBytes(t, dir))
	}
	if seq, err := s.Append(evid(4), []byte("synthetic next record")); err != nil || seq != 4 {
		t.Fatalf("append after reclaim = %d, %v", seq, err)
	}
}

// A pre-trust permanent rejection omits the event id. The drained segment must
// still reclaim, and the one quarantine entry must be named with the stored
// record's event id.
func TestPermanentRejectionOmittingEventIDReclaimsUnderStoredEventID(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Close() }()
	const seq = uint64(1)
	body := []byte("synthetic undecodable rejected record")
	if _, err := s.Append(evid(byte(seq)), body); err != nil {
		t.Fatal(err)
	}
	ack := &edgev1.EdgeDeliveryAckV1{
		SpoolId: evid(91), SessionNonce: evid(92), ResolvedThroughSequence: seq,
		Dispositions: []*edgev1.EdgeRecordDisposition{{
			Sequence: seq, Kind: permanentKind, RejectionCode: "synthetic_undecodable",
		}},
	}
	evidence, err := proto.Marshal(ack)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.ResolveWithEvidence(seq, evidence); err != nil {
		t.Fatal(err)
	}
	if name, err := os.Readlink(filepath.Join(dir, segmentFile)); err != nil || name != dataName(seq) {
		t.Fatalf("segment not reclaimed past a permanent rejection that omitted its event id: pointer %q, %v", name, err)
	}
	want := quarantineName(seq, evid(byte(seq)))
	quarantined := quarantinedFiles(t, dir)
	got, ok := quarantined[want]
	if !ok || len(quarantined) != 1 || !bytes.Contains(got, body) {
		names := make([]string, 0, len(quarantined))
		for name := range quarantined {
			names = append(names, name)
		}
		t.Fatalf("quarantine = %v, want exactly %s holding the stored record", names, want)
	}
}

// rejectOne appends one record and resolves it as permanently rejected.
func rejectOne(t *testing.T, s *Spool, seq uint64, body []byte) {
	t.Helper()
	got, err := s.Append(evid(byte(seq)), body)
	if err != nil || got != seq {
		t.Fatalf("append %d = %d, %v", seq, got, err)
	}
	if err := s.ResolveWithEvidence(seq, mixedAck(t, []uint64{seq}, seq)); err != nil {
		t.Fatalf("resolve %d: %v", seq, err)
	}
	if name, err := os.Readlink(filepath.Join(s.dir, segmentFile)); err != nil || name != dataName(seq) {
		t.Fatalf("record %d did not reclaim: pointer %q, %v", seq, name, err)
	}
}

// The quarantine is bounded: newer rejections evict the oldest entries, and a
// rejection too large for the reclaim's reserve is dropped instead of stopping
// the allocator. Both are counted, and reclaim keeps going either way.
func TestQuarantineBoundEvictsOldestAndDropsWhatCannotFit(t *testing.T) {
	dir := t.TempDir()
	footprint := testFootprint()
	footprint.DestinationSegment = 1 << 20
	alloc, err := NewAllocator(AllocatorConfig{Capacity: 16 << 20, Recovery: footprint, MaxConcurrentRecoveries: 1, MinFree: 4096})
	if err != nil {
		t.Fatal(err)
	}
	s, err := Open(dir, WithAllocator(alloc))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Close() }()

	// Five records of 900 KiB exceed the 4 MiB bound by one.
	body := bytes.Repeat([]byte("q"), 900<<10)
	for seq := uint64(1); seq <= 5; seq++ {
		rejectOne(t, s, seq, body)
	}
	h, err := s.QuarantineHealth()
	if err != nil {
		t.Fatal(err)
	}
	if h.Records != 4 || h.Quarantined != 5 || h.Evicted != 1 || h.Dropped != 0 {
		t.Fatalf("after five rejections: %+v, want 4 kept, 5 quarantined, 1 evicted", h)
	}
	if _, ok := quarantinedFiles(t, dir)[quarantineName(1, evid(1))]; ok {
		t.Fatal("the oldest entry survived eviction")
	}

	// Larger than the reserve the reclaim may spend on quarantine.
	rejectOne(t, s, 6, bytes.Repeat([]byte("o"), 1<<20))
	if h, err = s.QuarantineHealth(); err != nil || h.Records != 4 || h.Dropped != 1 {
		t.Fatalf("oversize rejection: %+v, %v; want it dropped and counted", h, err)
	}
	if u := alloc.Usage(); u.OrdinaryUsed != diskBytes(t, dir) || u.ActiveRecoveries != 0 || alloc.Err() != nil {
		t.Fatalf("allocator after the bound held: %+v on disk %d, err %v", u, diskBytes(t, dir), alloc.Err())
	}
	if h.Bytes != diskBytes(t, dir)-diskBytesExcept(t, dir, quarantinePrefix) {
		t.Fatalf("reported quarantine bytes %d do not match its entries", h.Bytes)
	}
}

func diskBytesExcept(t *testing.T, dir, prefix string) uint64 {
	t.Helper()
	var total uint64
	err := filepath.Walk(dir, func(_ string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.Mode().IsRegular() && !strings.HasPrefix(info.Name(), prefix) {
			total += uint64(info.Size())
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return total
}

// A crash after the quarantine copy is durable but before the reclaim finishes
// must leave a state the next reclaim completes, with the entry written once.
func TestReclaimCompletesAfterACrashPastQuarantine(t *testing.T) {
	for _, stop := range []barrier{barrierQuarantined, barrierReclaimPrepared, barrierReclaimPublished} {
		t.Run(fmt.Sprint(stop), func(t *testing.T) {
			dir := t.TempDir()
			s, err := Open(dir)
			if err != nil {
				t.Fatal(err)
			}
			for seq := byte(1); seq <= 2; seq++ {
				mustAppend(t, s, seq, "synthetic record before the crash")
			}
			s.beforeBarrier = func(b barrier) error {
				if b == stop {
					return syscall.EIO
				}
				return nil
			}
			if err := s.ResolveWithEvidence(2, mixedAck(t, []uint64{1, 2}, 1)); !errors.Is(err, syscall.EIO) {
				t.Fatalf("fault not observed: %v", err)
			}
			if err := s.Close(); err != nil {
				t.Fatal(err)
			}
			s, err = Open(dir)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = s.Close() }()
			if err := s.ReclaimResolved(); err != nil {
				t.Fatal(err)
			}
			if name, err := os.Readlink(filepath.Join(dir, segmentFile)); err != nil || name != dataName(2) {
				t.Fatalf("reclaim did not complete after restart: pointer %q, %v", name, err)
			}
			entries := quarantinedFiles(t, dir)
			if _, ok := entries[quarantineName(1, evid(1))]; !ok || len(entries) != 1 {
				t.Fatalf("quarantine after restart = %v, want exactly the rejected record", entries)
			}
			if seq, err := s.Append(evid(3), []byte("synthetic record after recovery")); err != nil || seq != 3 {
				t.Fatalf("append after recovery = %d, %v", seq, err)
			}
		})
	}
}
