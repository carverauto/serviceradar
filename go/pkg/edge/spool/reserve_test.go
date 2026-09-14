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
	"math"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

var errProbe = errors.New("synthetic statfs failure")

// testFootprint sizes every artifact differently so a formula that drops or
// double-counts one cannot land on the right total by accident.
func testFootprint() Footprint {
	return Footprint{
		DestinationSegment: 64,
		AttributionSidecar: 16,
		JournalCopy:        32,
		ManifestPages:      24,
		Mapping:            8,
		FilesystemMetadata: 12,
	}
}

const (
	// testPerRecovery is testFootprint's aggregate with BOTH journal copies.
	testPerRecovery = 64 + 16 + 2*32 + 24 + 8 + 12
	testMinFree     = 100
	// syntheticBody is an invented record body for ledger tests.
	syntheticBody = "synthetic payload"
)

// newTestAllocator sizes capacity so exactly ordinary bytes sit above the floor.
func newTestAllocator(t *testing.T, ordinary uint64, maxRecoveries int) *Allocator {
	t.Helper()
	capacity := testPerRecovery*uint64(maxRecoveries) + testMinFree + ordinary
	a, err := NewAllocator(AllocatorConfig{
		Capacity:                capacity,
		Recovery:                testFootprint(),
		MaxConcurrentRecoveries: maxRecoveries,
		MinFree:                 testMinFree,
	})
	if err != nil {
		t.Fatalf("NewAllocator: %v", err)
	}
	return a
}

// admitLanded admits n ordinary bytes for owner and reports them written, as
// Spool.Append does around its write.
func admitLanded(a *Allocator, owner string, n uint64) error {
	if err := a.admit(owner, n); err != nil {
		return err
	}
	a.settle(n, nil)
	return nil
}

// faultFS fails exactly one barrier operation with a chosen errno and counts
// every storage call, so a test can prove a stopped recovery touches nothing.
// beforeWrite, when set, runs while a write is in progress, before its bytes land.
type faultFS struct {
	inner       fileSystem
	failOp      string
	errno       error
	calls       int
	beforeWrite func()
}

func (f *faultFS) fail(op string) bool {
	f.calls++
	return op == f.failOp
}

func (f *faultFS) OpenFile(name string, flag int, perm os.FileMode) (durableFile, error) {
	if f.fail("create") {
		return nil, f.errno
	}
	file, err := f.inner.OpenFile(name, flag, perm)
	if err != nil {
		return nil, err
	}
	return &faultFile{inner: file, fs: f}, nil
}

func (f *faultFS) Rename(oldpath, newpath string) error {
	if f.fail("rename") {
		return f.errno
	}
	return f.inner.Rename(oldpath, newpath)
}

func (f *faultFS) Remove(name string) error {
	f.calls++
	return f.inner.Remove(name)
}

func (f *faultFS) SyncDir(dir string) error {
	if f.fail("fsync dir") {
		return f.errno
	}
	return f.inner.SyncDir(dir)
}

type faultFile struct {
	inner durableFile
	fs    *faultFS
}

// Write fails after landing half the bytes: a real ENOSPC or EIO rarely leaves
// the file untouched.
func (f *faultFile) Write(p []byte) (int, error) {
	if f.fs.fail("write") {
		n, _ := f.inner.Write(p[:len(p)/2])
		return n, f.fs.errno
	}
	if f.fs.beforeWrite != nil {
		f.fs.beforeWrite()
	}
	return f.inner.Write(p)
}

func (f *faultFile) Sync() error {
	if f.fs.fail("fsync") {
		return f.fs.errno
	}
	return f.inner.Sync()
}

func (f *faultFile) Close() error {
	err := f.inner.Close()
	if f.fs.fail("close") {
		return f.fs.errno
	}
	return err
}

func exists(t *testing.T, path string) bool {
	t.Helper()
	_, err := os.Stat(path)
	if err == nil {
		return true
	}
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stat %s: %v", path, err)
	}
	return false
}

func TestFootprintCountsEveryArtifactAndBothJournalCopies(t *testing.T) {
	per, err := testFootprint().PerRecovery()
	if err != nil {
		t.Fatalf("PerRecovery: %v", err)
	}
	if per != testPerRecovery {
		t.Fatalf("PerRecovery = %d, want %d (every artifact, journal twice)", per, testPerRecovery)
	}

	zeroed := map[string]func(*Footprint){
		"destination segment":      func(f *Footprint) { f.DestinationSegment = 0 },
		"attribution sidecar":      func(f *Footprint) { f.AttributionSidecar = 0 },
		"journal copy A":           func(f *Footprint) { f.JournalCopy = 0 },
		"manifest/tombstone pages": func(f *Footprint) { f.ManifestPages = 0 },
		"old->new mapping":         func(f *Footprint) { f.Mapping = 0 },
		"filesystem metadata":      func(f *Footprint) { f.FilesystemMetadata = 0 },
	}
	for name, zero := range zeroed {
		t.Run(name, func(t *testing.T) {
			f := testFootprint()
			zero(&f)
			_, err := f.PerRecovery()
			if !errors.Is(err, ErrInvalidAllocatorConfig) {
				t.Fatalf("PerRecovery with zero %s = %v, want ErrInvalidAllocatorConfig", name, err)
			}
			if !strings.Contains(err.Error(), name) {
				t.Fatalf("error %q does not name the unsized artifact %q", err, name)
			}
		})
	}

	overflow := testFootprint()
	overflow.JournalCopy = math.MaxUint64 / 2
	if _, err := overflow.PerRecovery(); !errors.Is(err, ErrInvalidAllocatorConfig) {
		t.Fatalf("overflowing footprint = %v, want ErrInvalidAllocatorConfig", err)
	}
}

func TestReserveIsFootprintTimesConcurrentRecoveries(t *testing.T) {
	for _, n := range []int{1, 3} {
		a := newTestAllocator(t, 500, n)
		u := a.Usage()
		if u.RecoveryReserve != testPerRecovery*uint64(n) {
			t.Fatalf("n=%d: reserve = %d, want %d", n, u.RecoveryReserve, testPerRecovery*uint64(n))
		}
		if u.Floor != u.RecoveryReserve+100 {
			t.Fatalf("n=%d: floor = %d, want reserve + MinFree = %d", n, u.Floor, u.RecoveryReserve+100)
		}
		if u.OrdinaryCeiling != 500 || u.OrdinaryCeiling != u.Capacity-u.Floor {
			t.Fatalf("n=%d: ordinary ceiling = %d, want capacity - floor = 500", n, u.OrdinaryCeiling)
		}
	}
}

func TestNewAllocatorRejectsUnsafeConfig(t *testing.T) {
	floor := uint64(testPerRecovery*2 + 100)
	cases := map[string]AllocatorConfig{
		"no concurrent recoveries": {Capacity: 10_000, Recovery: testFootprint(), MaxConcurrentRecoveries: 0, MinFree: 100},
		"no minimum free floor":    {Capacity: 10_000, Recovery: testFootprint(), MaxConcurrentRecoveries: 2, MinFree: 0},
		"capacity equals floor":    {Capacity: floor, Recovery: testFootprint(), MaxConcurrentRecoveries: 2, MinFree: 100},
		"unsized footprint":        {Capacity: 10_000, Recovery: Footprint{}, MaxConcurrentRecoveries: 2, MinFree: 100},
		"reserve overflows": {
			Capacity: math.MaxUint64, Recovery: testFootprint(),
			MaxConcurrentRecoveries: math.MaxInt, MinFree: 100,
		},
	}
	for name, cfg := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := NewAllocator(cfg); !errors.Is(err, ErrInvalidAllocatorConfig) {
				t.Fatalf("NewAllocator = %v, want ErrInvalidAllocatorConfig", err)
			}
		})
	}

	a, err := NewAllocator(AllocatorConfig{
		Capacity: floor + 1, Recovery: testFootprint(), MaxConcurrentRecoveries: 2, MinFree: 100,
	})
	if err != nil {
		t.Fatalf("capacity one byte above floor: %v", err)
	}
	if got := a.Usage().OrdinaryCeiling; got != 1 {
		t.Fatalf("ordinary ceiling = %d, want 1", got)
	}
}

// Ordinary producers fill everything they are allowed; every concurrent
// recovery must still be able to write its ENTIRE footprint.
func TestOrdinaryAdmissionCannotBorrowTheReserve(t *testing.T) {
	a := newTestAllocator(t, 500, 2)

	if err := admitLanded(a, "lane", 500); err != nil {
		t.Fatalf("Admit up to the ordinary ceiling: %v", err)
	}
	if err := admitLanded(a, "other-lane", 1); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatalf("Admit past the ceiling = %v, want ErrAdmissionRefused", err)
	}
	if got := a.Usage().OrdinaryUsed; got != 500 {
		t.Fatalf("refused admission charged bytes: ordinary used = %d, want 500", got)
	}

	dir := t.TempDir()
	budgets := testFootprint().budgets()
	for i := range 2 {
		g, err := a.AcquireRecovery()
		if err != nil {
			t.Fatalf("recovery %d: AcquireRecovery with ordinary full: %v", i, err)
		}
		for art, n := range budgets {
			path := filepath.Join(dir, fmt.Sprintf("recovery-%d-artifact-%d", i, art))
			if err := g.WriteBarrier(Artifact(art), path, make([]byte, n)); err != nil {
				t.Fatalf("recovery %d: full %s write: %v", i, Artifact(art), err)
			}
		}
	}
	if got := a.Usage().RecoveryUsed; got != 2*testPerRecovery {
		t.Fatalf("recovery used = %d, want both full footprints %d", got, 2*testPerRecovery)
	}

	if err := a.ReleaseOrdinary("lane", 100); err != nil {
		t.Fatalf("ReleaseOrdinary: %v", err)
	}
	if err := admitLanded(a, "lane", 100); err != nil {
		t.Fatalf("Admit after release: %v", err)
	}
	if err := a.ReleaseOrdinary("lane", 10_000); !errors.Is(err, ErrReleaseExceedsCharge) {
		t.Fatalf("over-release = %v, want ErrReleaseExceedsCharge", err)
	}
}

func TestAdmissionRequiresThePhysicalFloor(t *testing.T) {
	var free uint64
	var probeErr error
	cfg := AllocatorConfig{
		Capacity:                testPerRecovery*2 + 100 + 500,
		Recovery:                testFootprint(),
		MaxConcurrentRecoveries: 2,
		MinFree:                 100,
		FreeBytes:               func() (uint64, error) { return free, probeErr },
	}
	a, err := NewAllocator(cfg)
	if err != nil {
		t.Fatalf("NewAllocator: %v", err)
	}
	floor := a.Usage().Floor

	// Another process has eaten the disk: the nominal ceiling still has 500
	// bytes, but only 49 exist above the floor.
	free = floor + 49
	if err := admitLanded(a, "lane", 50); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatalf("Admit beyond physical free space = %v, want ErrAdmissionRefused", err)
	}
	if err := admitLanded(a, "lane", 49); err != nil {
		t.Fatalf("Admit within physical free space: %v", err)
	}

	free = floor - 1
	if _, err := a.AcquireRecovery(); !errors.Is(err, ErrReserveUnbacked) {
		t.Fatalf("AcquireRecovery with the reserve unbacked = %v, want ErrReserveUnbacked", err)
	}
	if got := a.Usage().ActiveRecoveries; got != 0 {
		t.Fatalf("refused acquisition held a slot: active = %d", got)
	}

	free, probeErr = floor+1000, errProbe
	if err := admitLanded(a, "lane", 1); !errors.Is(err, ErrAdmissionRefused) || !errors.Is(err, errProbe) {
		t.Fatalf("Admit with a failing probe = %v, want ErrAdmissionRefused wrapping the probe error", err)
	}
	if a.Err() != nil {
		t.Fatalf("a probe failure wrote nothing and must not fail-stop: %v", a.Err())
	}
}

func TestConcurrentRecoveriesAreBounded(t *testing.T) {
	a := newTestAllocator(t, 500, 2)
	g1, err := a.AcquireRecovery()
	if err != nil {
		t.Fatalf("acquire 1: %v", err)
	}
	if _, err := a.AcquireRecovery(); err != nil {
		t.Fatalf("acquire 2: %v", err)
	}
	if _, err := a.AcquireRecovery(); !errors.Is(err, ErrRecoveryConcurrencyExhausted) {
		t.Fatalf("acquire 3 = %v, want ErrRecoveryConcurrencyExhausted", err)
	}
	if err := g1.Finish(0); err != nil {
		t.Fatalf("finish: %v", err)
	}
	if err := g1.Finish(0); !errors.Is(err, ErrRecoveryFinished) {
		t.Fatalf("second finish = %v, want ErrRecoveryFinished", err)
	}
	if _, err := a.AcquireRecovery(); !errors.Is(err, ErrRecoveryConcurrencyExhausted) {
		t.Fatalf("acquire after finish, before the source is released = %v, want ErrRecoveryConcurrencyExhausted", err)
	}
	if err := g1.ReleaseSource("lane", 0, "lane"); err != nil {
		t.Fatalf("release source: %v", err)
	}
	if err := g1.ReleaseSource("lane", 0, "lane"); !errors.Is(err, ErrRecoveryFinished) {
		t.Fatalf("second release = %v, want ErrRecoveryFinished", err)
	}
	if _, err := a.AcquireRecovery(); err != nil {
		t.Fatalf("acquire after release: %v", err)
	}
}

// A finished recovery releases nothing while the source segment it replaces is
// still on disk: its output stays charged against the reserve and its slot stays
// held, so no second recovery is granted a footprint the disk no longer holds.
// Only deleting the source turns the retained output into ordinary usage.
func TestRetainedOutputStaysInTheReserveUntilTheSourceIsDeleted(t *testing.T) {
	a := newTestAllocator(t, 500, 1)
	dir := t.TempDir()
	sourceLane := filepath.Join(dir, "source-lane")
	destLane := filepath.Join(dir, "dest-lane")
	sourceSeg := filepath.Join(dir, "source.seg")
	if err := os.WriteFile(sourceSeg, []byte("synthetic source segment"), filePerm); err != nil {
		t.Fatalf("seed source: %v", err)
	}
	if err := admitLanded(a, sourceLane, 500); err != nil {
		t.Fatalf("fill the ordinary ceiling: %v", err)
	}

	g, err := a.AcquireRecovery()
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if err := g.WriteBarrier(ArtifactDestinationSegment, filepath.Join(dir, "dest.seg"), make([]byte, 64)); err != nil {
		t.Fatalf("write destination: %v", err)
	}
	if err := g.WriteBarrier(ArtifactJournalA, filepath.Join(dir, "journal-a"), make([]byte, 32)); err != nil {
		t.Fatalf("write journal: %v", err)
	}

	if err := g.ReleaseSource(sourceLane, 500, destLane); !errors.Is(err, ErrRecoveryNotFinished) {
		t.Fatalf("release before finish = %v, want ErrRecoveryNotFinished", err)
	}
	if err := g.Finish(97); !errors.Is(err, ErrReleaseExceedsCharge) {
		t.Fatalf("retaining more than was written = %v, want ErrReleaseExceedsCharge", err)
	}
	if err := g.Finish(96); err != nil {
		t.Fatalf("finish: %v", err)
	}
	if u := a.Usage(); u.OrdinaryUsed != 500 || u.RecoveryUsed != 96 || u.ActiveRecoveries != 1 {
		t.Fatalf("after finish usage = %+v, want 500 ordinary, 96 recovery, 1 active", u)
	}
	if _, err := a.AcquireRecovery(); !errors.Is(err, ErrRecoveryConcurrencyExhausted) {
		t.Fatalf("second recovery while the source and its copy share the disk = %v, want ErrRecoveryConcurrencyExhausted", err)
	}
	if err := g.WriteBarrier(ArtifactMapping, filepath.Join(dir, "mapping"), []byte{1}); !errors.Is(err, ErrRecoveryFinished) {
		t.Fatalf("write after finish = %v, want ErrRecoveryFinished", err)
	}

	if err := g.RunDestructive("delete source", func() error { return os.Remove(sourceSeg) }); err != nil {
		t.Fatalf("coverage-proof deletion through the finished grant: %v", err)
	}
	if exists(t, sourceSeg) {
		t.Fatal("source segment survived its deletion")
	}
	if err := g.ReleaseSource(sourceLane, 501, destLane); !errors.Is(err, ErrReleaseExceedsCharge) {
		t.Fatalf("releasing more than the source holds = %v, want ErrReleaseExceedsCharge", err)
	}
	if u := a.Usage(); u.OrdinaryUsed != 500 || u.RecoveryUsed != 96 || u.ActiveRecoveries != 1 {
		t.Fatalf("a refused release changed the ledger: %+v", u)
	}
	if err := g.ReleaseSource(sourceLane, 500, destLane); err != nil {
		t.Fatalf("release source after deleting it: %v", err)
	}
	if u := a.Usage(); u.OrdinaryUsed != 96 || u.RecoveryUsed != 0 || u.ActiveRecoveries != 0 {
		t.Fatalf("after releasing the source usage = %+v, want 96 ordinary, 0 recovery, 0 active", u)
	}
	if err := a.ReleaseOrdinary(destLane, 96); err != nil {
		t.Fatalf("retained output is not charged to its owner: %v", err)
	}
	if _, err := a.AcquireRecovery(); err != nil {
		t.Fatalf("acquire after the source is released: %v", err)
	}
}

// Every footprint field bounds CUMULATIVE writes: each rewrite of the same path
// is charged in full, so a journal is sized for all of its rewrites, not one copy.
func TestFootprintBoundsCumulativeRewrites(t *testing.T) {
	a := newTestAllocator(t, 500, 1)
	g, err := a.AcquireRecovery()
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	journal := filepath.Join(t.TempDir(), "journal-a")
	phase1 := bytes.Repeat([]byte{1}, 16)
	if err := g.WriteBarrier(ArtifactJournalA, journal, bytes.Repeat([]byte{0}, 16)); err != nil {
		t.Fatalf("phase 0 journal write: %v", err)
	}
	if err := g.WriteBarrier(ArtifactJournalA, journal, phase1); err != nil {
		t.Fatalf("phase 1 rewrite within the cumulative budget: %v", err)
	}
	if got := g.Used(ArtifactJournalA); got != 32 {
		t.Fatalf("journal A charged %d after two 16-byte writes of one path, want 32", got)
	}

	err = g.WriteBarrier(ArtifactJournalA, journal, []byte{2})
	if !errors.Is(err, ErrReserveExhausted) {
		t.Fatalf("rewrite past the cumulative budget with one 16-byte copy on disk = %v, want ErrReserveExhausted", err)
	}
	got, err := os.ReadFile(journal)
	if err != nil || !bytes.Equal(got, phase1) {
		t.Fatalf("journal after a refused rewrite = %v, %v; want the phase 1 copy untouched", got, err)
	}
}

// Bytes charged but not yet on disk stay in the physically backed floor. The
// probe cannot see them until they land, so neither a lane's admission nor
// another recovery's acquisition may spend them in the meantime.
func TestInFlightBytesStayInTheBackedFloor(t *testing.T) {
	var free uint64
	a, err := NewAllocator(AllocatorConfig{
		Capacity:                testPerRecovery*2 + testMinFree + 10_000,
		Recovery:                testFootprint(),
		MaxConcurrentRecoveries: 2,
		MinFree:                 testMinFree,
		FreeBytes:               func() (uint64, error) { return free, nil },
	})
	if err != nil {
		t.Fatalf("NewAllocator: %v", err)
	}
	ff := &faultFS{inner: osFS{}}
	a.fs = ff
	floor := a.Usage().Floor
	free = floor + 100

	lane, err := Open(t.TempDir(), WithAllocator(a))
	if err != nil {
		t.Fatalf("open lane: %v", err)
	}
	defer func() { _ = lane.Close() }()
	// record returns a body whose framed record is exactly n bytes.
	record := func(n int) []byte { return bytes.Repeat([]byte{'x'}, n-headerLen-headerCRC-bodyCRCLen) }

	g, err := a.AcquireRecovery()
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	dir := t.TempDir()

	hooked := false
	ff.beforeWrite = func() {
		hooked = true
		// 100 free bytes sit above the floor, but 64 of them belong to the
		// destination write in progress.
		if _, err := lane.Append(evid(1), record(101)); !errors.Is(err, ErrAdmissionRefused) {
			t.Errorf("lane admission during the recovery write = %v, want ErrAdmissionRefused", err)
		}
		free = floor - 1
		if _, err := a.AcquireRecovery(); !errors.Is(err, ErrReserveUnbacked) {
			t.Errorf("acquisition backed only by in-flight bytes = %v, want ErrReserveUnbacked", err)
		}
		free = floor + 100
	}
	if err := g.WriteBarrier(ArtifactDestinationSegment, filepath.Join(dir, "dest.seg"), make([]byte, 64)); err != nil {
		t.Fatalf("destination write: %v", err)
	}
	ff.beforeWrite = nil
	if !hooked {
		t.Fatal("the in-flight checks never ran")
	}
	free -= 64

	// Mapping bytes the caller writes itself are in flight from Charge until
	// Landed; an unrelated step in between does not take them out of flight.
	if err := g.Charge(ArtifactMapping, 8); err != nil {
		t.Fatalf("charge mapping: %v", err)
	}
	if err := g.WriteBarrier(ArtifactAttributionSidecar, filepath.Join(dir, "sidecar"), make([]byte, 16)); err != nil {
		t.Fatalf("sidecar write: %v", err)
	}
	free -= 16
	if _, err := lane.Append(evid(1), record(101)); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatalf("lane admission into charged, unwritten mapping bytes = %v, want ErrAdmissionRefused", err)
	}
	// The destination and sidecar writes landed, so exactly the rest fits.
	if _, err := lane.Append(evid(1), record(100)); err != nil {
		t.Fatalf("lane admission after the barrier writes landed: %v", err)
	}
	free -= 100

	free -= 8
	if _, err := a.AcquireRecovery(); !errors.Is(err, ErrReserveUnbacked) {
		t.Fatalf("acquisition before the mapping is reported landed = %v, want ErrReserveUnbacked", err)
	}
	if err := g.Landed(ArtifactMapping, 9); !errors.Is(err, ErrReleaseExceedsCharge) {
		t.Fatalf("landing more than is in flight = %v, want ErrReleaseExceedsCharge", err)
	}
	if err := g.Landed(ArtifactMapping, 8); err != nil {
		t.Fatalf("land mapping: %v", err)
	}
	if _, err := a.AcquireRecovery(); err != nil {
		t.Fatalf("acquisition once every charged byte landed: %v", err)
	}
}

// A lane Open rejects as corrupt still occupies its segment on disk, so its
// bytes stay charged even though Open fails.
func TestCorruptLaneIsChargedWhenOpenFails(t *testing.T) {
	body := syntheticBody
	recLen := uint64(headerLen + headerCRC + len(body) + bodyCRCLen)
	dirA := t.TempDir()
	s, err := Open(dirA)
	if err != nil {
		t.Fatalf("open lane A: %v", err)
	}
	mustAppend(t, s, 1, body)
	mustAppend(t, s, 2, body)
	if err := s.Close(); err != nil {
		t.Fatalf("close lane A: %v", err)
	}
	seg := filepath.Join(dirA, segmentFile)
	data, err := os.ReadFile(seg)
	if err != nil {
		t.Fatalf("read segment: %v", err)
	}
	data[headerLen+headerCRC] ^= 0xFF
	if err := os.WriteFile(seg, data, filePerm); err != nil {
		t.Fatalf("corrupt the first record body: %v", err)
	}

	a := newTestAllocator(t, 3*recLen, 1)
	var corrupt *CorruptBodyError
	if _, err := Open(dirA, WithAllocator(a)); !errors.As(err, &corrupt) {
		t.Fatalf("open corrupt lane = %v, want *CorruptBodyError", err)
	}
	if got := a.Usage().OrdinaryUsed; got != 2*recLen {
		t.Fatalf("corrupt lane charged %d, want its on-disk %d", got, 2*recLen)
	}

	laneB, err := Open(t.TempDir(), WithAllocator(a))
	if err != nil {
		t.Fatalf("open lane B: %v", err)
	}
	defer func() { _ = laneB.Close() }()
	mustAppend(t, laneB, 1, body)
	if _, err := laneB.Append(evid(2), []byte(body)); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatalf("lane B append into space the corrupt lane occupies = %v, want ErrAdmissionRefused", err)
	}
}

// One directory spelled two ways is one owner: reopening replaces its charge,
// and a release under another spelling finds it.
func TestOwnerSpellingsOfOneDirectoryShareACharge(t *testing.T) {
	body := syntheticBody
	recLen := uint64(headerLen + headerCRC + len(body) + bodyCRCLen)
	a := newTestAllocator(t, 10*recLen, 1)
	dir := t.TempDir()

	s, err := Open(dir+string(filepath.Separator), WithAllocator(a))
	if err != nil {
		t.Fatalf("open with a trailing separator: %v", err)
	}
	mustAppend(t, s, 1, body)
	mustAppend(t, s, 2, body)
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	sep := string(filepath.Separator)
	reopened, err := Open(dir+sep+"."+sep, WithAllocator(a))
	if err != nil {
		t.Fatalf("reopen under another spelling: %v", err)
	}
	if got := a.Usage().OrdinaryUsed; got != 2*recLen {
		t.Fatalf("reopening under another spelling charged %d, want %d", got, 2*recLen)
	}
	if err := reopened.Close(); err != nil {
		t.Fatalf("close reopened: %v", err)
	}

	if err := os.Remove(filepath.Join(dir, segmentFile)); err != nil {
		t.Fatalf("delete segment: %v", err)
	}
	if err := a.ReleaseOrdinary(dir+sep+sep, 2*recLen); err != nil {
		t.Fatalf("release under a third spelling: %v", err)
	}
	if got := a.Usage().OrdinaryUsed; got != 0 {
		t.Fatalf("ordinary used after release = %d, want 0", got)
	}
}

// Exhausting an artifact's reserve refuses the write, writes nothing, and stops
// the recovery -- even for artifacts that still have budget.
func TestExhaustingTheReserveStopsRecoveryDeterministically(t *testing.T) {
	a := newTestAllocator(t, 500, 2)
	ff := &faultFS{inner: osFS{}}
	a.fs = ff
	dir := t.TempDir()
	source := filepath.Join(dir, "source.seg")
	if err := os.WriteFile(source, []byte("synthetic source segment"), filePerm); err != nil {
		t.Fatalf("seed source: %v", err)
	}

	g, err := a.AcquireRecovery()
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if err := g.WriteBarrier(ArtifactJournalA, filepath.Join(dir, "journal-a"), make([]byte, 32)); err != nil {
		t.Fatalf("journal A within budget: %v", err)
	}

	calls := ff.calls
	over := filepath.Join(dir, "journal-a-2")
	err = g.WriteBarrier(ArtifactJournalA, over, []byte{1})
	var exhausted *ReserveExhaustedError
	if !errors.Is(err, ErrReserveExhausted) || !errors.As(err, &exhausted) {
		t.Fatalf("write past journal A budget = %v, want *ReserveExhaustedError", err)
	}
	if exhausted.Artifact != ArtifactJournalA || exhausted.Remaining != 0 || exhausted.Requested != 1 {
		t.Fatalf("exhaustion = %+v, want journal copy A, requested 1, remaining 0", exhausted)
	}
	if ff.calls != calls || exists(t, over) || exists(t, over+".tmp") {
		t.Fatal("a refused charge reached storage")
	}

	// Journal B still has its whole budget, but the recovery is stopped.
	journalB := filepath.Join(dir, "journal-b")
	if err := g.WriteBarrier(ArtifactJournalB, journalB, []byte{1}); !errors.Is(err, ErrRecoveryStopped) ||
		!errors.Is(err, ErrReserveExhausted) {
		t.Fatalf("write after exhaustion = %v, want ErrRecoveryStopped caused by ErrReserveExhausted", err)
	}
	if err := g.Charge(ArtifactMapping, 1); !errors.Is(err, ErrRecoveryStopped) {
		t.Fatalf("charge after exhaustion = %v, want ErrRecoveryStopped", err)
	}
	ran := false
	err = g.RunDestructive("delete source", func() error { ran = true; return os.Remove(source) })
	if !errors.Is(err, ErrRecoveryStopped) || ran || !exists(t, source) {
		t.Fatalf("destructive step after exhaustion: err=%v ran=%v; want refused and source intact", err, ran)
	}
	if err := g.Finish(0); !errors.Is(err, ErrRecoveryStopped) {
		t.Fatalf("finish after exhaustion = %v, want ErrRecoveryStopped", err)
	}
	if ff.calls != calls || exists(t, journalB) {
		t.Fatal("a stopped recovery reached storage")
	}
	if got := a.Usage().ActiveRecoveries; got != 1 {
		t.Fatalf("stopped recovery released its reserve slot: active = %d", got)
	}

	// Exhaustion is a sizing failure in THIS recovery, not a storage failure:
	// nothing was written, so the allocator and other recoveries carry on.
	if a.Err() != nil {
		t.Fatalf("allocator fail-stopped on a refused charge: %v", a.Err())
	}
	if err := admitLanded(a, "lane", 1); err != nil {
		t.Fatalf("ordinary admission after another recovery's exhaustion: %v", err)
	}
	other, err := a.AcquireRecovery()
	if err != nil {
		t.Fatalf("second recovery: %v", err)
	}
	if err := other.WriteBarrier(ArtifactJournalA, filepath.Join(dir, "other-journal-a"), make([]byte, 32)); err != nil {
		t.Fatalf("second recovery write: %v", err)
	}
}

// A barrier failure at ANY position, with ENOSPC or EIO, fail-stops the recovery,
// every other recovery, and producer admission; no destructive step runs after it.
func TestFailedBarrierWriteIsFailStop(t *testing.T) {
	ops := []string{"create", "write", "fsync", "close", "rename", "fsync dir"}
	errnos := map[string]error{"ENOSPC": syscall.ENOSPC, "EIO": syscall.EIO}

	for _, op := range ops {
		for errName, errno := range errnos {
			t.Run(op+"/"+errName, func(t *testing.T) {
				a := newTestAllocator(t, 500, 2)
				ff := &faultFS{inner: osFS{}, failOp: op, errno: errno}
				a.fs = ff
				dir := t.TempDir()
				source := filepath.Join(dir, "source.seg")
				sourceBytes := []byte("synthetic source segment")
				if err := os.WriteFile(source, sourceBytes, filePerm); err != nil {
					t.Fatalf("seed source: %v", err)
				}

				g, err := a.AcquireRecovery()
				if err != nil {
					t.Fatalf("acquire: %v", err)
				}
				other, err := a.AcquireRecovery()
				if err != nil {
					t.Fatalf("acquire other: %v", err)
				}

				dest := filepath.Join(dir, "dest.seg")
				err = g.WriteBarrier(ArtifactDestinationSegment, dest, bytes.Repeat([]byte{0xAB}, 64))
				var stop *FailStopError
				if !errors.Is(err, errno) || !errors.Is(err, ErrFailStopped) || !errors.As(err, &stop) {
					t.Fatalf("WriteBarrier = %v, want *FailStopError wrapping %s", err, errName)
				}
				if stop.Op != op {
					t.Fatalf("fail-stop op = %q, want %q", stop.Op, op)
				}

				// Before the rename the destination does not exist and the
				// uncommitted temporary is gone; from the rename on, nothing the
				// barrier may already have committed is deleted.
				switch op {
				case "create", "write", "fsync", "close":
					if exists(t, dest) || exists(t, dest+".tmp") {
						t.Fatalf("failed %s left a destination or temporary file", op)
					}
				case "fsync dir":
					if !exists(t, dest) {
						t.Fatal("a failed directory fsync deleted the renamed destination")
					}
				}

				calls := ff.calls
				ran := false
				destroy := func() error { ran = true; return os.Remove(source) }
				for name, grant := range map[string]*RecoveryGrant{"failed": g, "other": other} {
					err := grant.RunDestructive("delete source", destroy)
					if !errors.Is(err, ErrRecoveryStopped) || !errors.Is(err, errno) {
						t.Fatalf("%s grant destructive step = %v, want ErrRecoveryStopped caused by %s", name, err, errName)
					}
					err = grant.WriteBarrier(ArtifactJournalA, filepath.Join(dir, name+"-journal"), []byte{1})
					if !errors.Is(err, ErrRecoveryStopped) || !errors.Is(err, errno) {
						t.Fatalf("%s grant write after fail-stop = %v, want refused", name, err)
					}
					if err := grant.Finish(0); !errors.Is(err, ErrRecoveryStopped) {
						t.Fatalf("%s grant finish after fail-stop = %v, want refused", name, err)
					}
					if err := grant.ReleaseSource(source, 0, source); !errors.Is(err, ErrRecoveryStopped) {
						t.Fatalf("%s grant release after fail-stop = %v, want refused", name, err)
					}
				}
				if ran {
					t.Fatal("a destructive step ran after a failed barrier write")
				}
				got, err := os.ReadFile(source)
				if err != nil || !bytes.Equal(got, sourceBytes) {
					t.Fatalf("source segment after fail-stop = %q, %v; want it intact", got, err)
				}
				if ff.calls != calls {
					t.Fatalf("storage touched after fail-stop: %d calls", ff.calls-calls)
				}

				if err := admitLanded(a, "lane", 1); !errors.Is(err, ErrFailStopped) || !errors.Is(err, errno) {
					t.Fatalf("Admit after fail-stop = %v, want ErrFailStopped caused by %s", err, errName)
				}
				if _, err := a.AcquireRecovery(); !errors.Is(err, ErrFailStopped) {
					t.Fatalf("AcquireRecovery after fail-stop = %v, want ErrFailStopped", err)
				}
				if got := a.Usage().ActiveRecoveries; got != 2 {
					t.Fatalf("fail-stopped recoveries released their reserve: active = %d", got)
				}
			})
		}
	}
}

func TestFailedDestructiveStepIsFailStop(t *testing.T) {
	for errName, errno := range map[string]error{"ENOSPC": syscall.ENOSPC, "EIO": syscall.EIO} {
		t.Run(errName, func(t *testing.T) {
			a := newTestAllocator(t, 500, 1)
			g, err := a.AcquireRecovery()
			if err != nil {
				t.Fatalf("acquire: %v", err)
			}
			err = g.RunDestructive("delete source", func() error { return errno })
			var stop *FailStopError
			if !errors.Is(err, errno) || !errors.As(err, &stop) || stop.Op != "delete source" {
				t.Fatalf("failing destructive step = %v, want *FailStopError(delete source) wrapping %s", err, errName)
			}
			ran := false
			if err := g.RunDestructive("delete next", func() error { ran = true; return nil }); !errors.Is(err, ErrRecoveryStopped) || ran {
				t.Fatalf("destructive step after a failed one: err=%v ran=%v; want refused", err, ran)
			}
			if err := admitLanded(a, "lane", 1); !errors.Is(err, ErrFailStopped) {
				t.Fatalf("Admit after failed destructive step = %v, want ErrFailStopped", err)
			}
		})
	}
}

// Output a recovery writes itself after Charge fail-stops through FailStop
// exactly as a failed barrier write does: no grant runs a destructive step after.
func TestCallerWrittenOutputFailureIsFailStop(t *testing.T) {
	for errName, errno := range map[string]error{"ENOSPC": syscall.ENOSPC, "EIO": syscall.EIO} {
		t.Run(errName, func(t *testing.T) {
			a := newTestAllocator(t, 500, 2)
			source := filepath.Join(t.TempDir(), "source.seg")
			if err := os.WriteFile(source, []byte("synthetic source segment"), filePerm); err != nil {
				t.Fatalf("seed source: %v", err)
			}
			g, err := a.AcquireRecovery()
			if err != nil {
				t.Fatalf("acquire: %v", err)
			}
			other, err := a.AcquireRecovery()
			if err != nil {
				t.Fatalf("acquire other: %v", err)
			}

			if err := g.Charge(ArtifactDestinationSegment, 64); err != nil {
				t.Fatalf("charge destination: %v", err)
			}
			err = g.FailStop("stream destination segment", errno)
			var stop *FailStopError
			if !errors.Is(err, errno) || !errors.Is(err, ErrFailStopped) || !errors.As(err, &stop) ||
				stop.Op != "stream destination segment" {
				t.Fatalf("FailStop = %v, want *FailStopError(stream destination segment) wrapping %s", err, errName)
			}

			ran := false
			for name, grant := range map[string]*RecoveryGrant{"failed": g, "other": other} {
				err := grant.RunDestructive("delete source", func() error { ran = true; return os.Remove(source) })
				if !errors.Is(err, ErrRecoveryStopped) || !errors.Is(err, errno) {
					t.Fatalf("%s grant destructive step = %v, want ErrRecoveryStopped caused by %s", name, err, errName)
				}
				if err := grant.Charge(ArtifactMapping, 1); !errors.Is(err, ErrRecoveryStopped) {
					t.Fatalf("%s grant charge after FailStop = %v, want ErrRecoveryStopped", name, err)
				}
			}
			if ran || !exists(t, source) {
				t.Fatalf("destructive step ran=%v after FailStop; want refused and source intact", ran)
			}
			if err := admitLanded(a, "lane", 1); !errors.Is(err, ErrFailStopped) || !errors.Is(err, errno) {
				t.Fatalf("Admit after FailStop = %v, want ErrFailStopped caused by %s", err, errName)
			}
			if _, err := a.AcquireRecovery(); !errors.Is(err, ErrFailStopped) {
				t.Fatalf("AcquireRecovery after FailStop = %v, want ErrFailStopped", err)
			}
		})
	}
}

func TestSpoolAdmissionRefusalWritesNothing(t *testing.T) {
	body := syntheticBody
	recLen := uint64(headerLen + headerCRC + len(body) + bodyCRCLen)
	a := newTestAllocator(t, 2*recLen, 1)
	dir := t.TempDir()

	s, err := Open(dir, WithAllocator(a))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustAppend(t, s, 1, body)
	mustAppend(t, s, 2, body)
	if _, err := s.Append(evid(3), []byte(body)); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatalf("append past the ordinary ceiling = %v, want ErrAdmissionRefused", err)
	}
	if s.NextSequence() != 3 {
		t.Fatalf("refused append consumed a sequence: next = %d, want 3", s.NextSequence())
	}
	info, err := os.Stat(filepath.Join(dir, segmentFile))
	if err != nil || uint64(info.Size()) != 2*recLen {
		t.Fatalf("segment after refused append: size %v, err %v; want %d", info.Size(), err, 2*recLen)
	}
	if s.failErr != nil {
		t.Fatalf("an admission refusal wrote nothing and must not fail-stop the spool: %v", s.failErr)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// A restart re-measures: the recovered segment is charged to the new ledger.
	a2 := newTestAllocator(t, 2*recLen, 1)
	s2, err := Open(dir, WithAllocator(a2))
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = s2.Close() }()
	if got := a2.Usage().OrdinaryUsed; got != 2*recLen {
		t.Fatalf("reopened ledger charged %d, want the recovered segment's %d", got, 2*recLen)
	}
	if _, err := s2.Append(evid(3), []byte(body)); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatalf("append after reopen = %v, want ErrAdmissionRefused", err)
	}
}

// A closed lane's segment is still on disk, so its charge survives Close and is
// released only after the segment is deleted. Reopening re-measures instead of
// adding, and releasing one lane can never spend another lane's charge.
func TestLaneChargeLastsUntilPhysicalDeletion(t *testing.T) {
	body := syntheticBody
	recLen := uint64(headerLen + headerCRC + len(body) + bodyCRCLen)
	a := newTestAllocator(t, 3*recLen, 1)
	dirA, dirB := t.TempDir(), t.TempDir()

	laneA, err := Open(dirA, WithAllocator(a))
	if err != nil {
		t.Fatalf("open lane A: %v", err)
	}
	mustAppend(t, laneA, 1, body)
	mustAppend(t, laneA, 2, body)
	if err := laneA.Close(); err != nil {
		t.Fatalf("close lane A: %v", err)
	}
	if got := a.Usage().OrdinaryUsed; got != 2*recLen {
		t.Fatalf("after closing lane A ordinary used = %d, want its on-disk %d", got, 2*recLen)
	}

	laneB, err := Open(dirB, WithAllocator(a))
	if err != nil {
		t.Fatalf("open lane B: %v", err)
	}
	defer func() { _ = laneB.Close() }()
	mustAppend(t, laneB, 1, body)
	if _, err := laneB.Append(evid(2), []byte(body)); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatalf("lane B append into space closed lane A still occupies = %v, want ErrAdmissionRefused", err)
	}

	reopened, err := Open(dirA, WithAllocator(a))
	if err != nil {
		t.Fatalf("reopen lane A: %v", err)
	}
	if got := a.Usage().OrdinaryUsed; got != 3*recLen {
		t.Fatalf("reopening lane A on the same allocator: ordinary used = %d, want %d", got, 3*recLen)
	}
	if err := reopened.Close(); err != nil {
		t.Fatalf("close reopened lane A: %v", err)
	}

	if err := os.Remove(filepath.Join(dirA, segmentFile)); err != nil {
		t.Fatalf("delete lane A segment: %v", err)
	}
	if err := a.ReleaseOrdinary(dirA, 2*recLen); err != nil {
		t.Fatalf("release lane A after deleting its segment: %v", err)
	}
	mustAppend(t, laneB, 2, body)
	if err := a.ReleaseOrdinary(dirA, recLen); !errors.Is(err, ErrReleaseExceedsCharge) {
		t.Fatalf("second release of lane A while lane B holds %d = %v, want ErrReleaseExceedsCharge", 2*recLen, err)
	}
	if got := a.Usage().OrdinaryUsed; got != 2*recLen {
		t.Fatalf("ordinary used = %d, want lane B's %d", got, 2*recLen)
	}
}

// The spool fail-stops on its own. A shared allocator additionally stops every
// lane's admission but keeps recovery running, since recovery repairs a failed
// lane. Both configurations run, so neither can mask the other.
func TestSpoolAppendStorageFailureIsFailStop(t *testing.T) {
	for _, op := range []string{"write", "fsync"} {
		for errName, errno := range map[string]error{"ENOSPC": syscall.ENOSPC, "EIO": syscall.EIO} {
			for _, shared := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/%s/allocator=%v", op, errName, shared), func(t *testing.T) {
					testSpoolAppendFailStop(t, op, errno, shared)
				})
			}
		}
	}
}

func testSpoolAppendFailStop(t *testing.T, op string, errno error, shared bool) {
	t.Helper()
	var opts []Option
	a := newTestAllocator(t, 10_000, 1)
	if shared {
		opts = append(opts, WithAllocator(a))
	}
	dir := t.TempDir()
	s, err := Open(dir, opts...)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustAppend(t, s, 1, "first")

	ff := &faultFS{failOp: op, errno: errno}
	s.seg = &faultFile{inner: s.seg, fs: ff}

	_, err = s.Append(evid(2), []byte("second"))
	var stop *FailStopError
	if !errors.Is(err, errno) || !errors.Is(err, ErrFailStopped) || !errors.As(err, &stop) || stop.Op != op {
		t.Fatalf("append with failing %s = %v, want *FailStopError(%s) wrapping %v", op, err, op, errno)
	}
	if s.NextSequence() != 2 {
		t.Fatalf("failed append advanced the sequence: next = %d, want 2", s.NextSequence())
	}

	calls := ff.calls
	if _, err := s.Append(evid(3), []byte("third")); !errors.Is(err, errno) || !errors.Is(err, ErrFailStopped) {
		t.Fatalf("append after fail-stop = %v, want the original fail-stop", err)
	}
	if ff.calls != calls {
		t.Fatal("append after fail-stop touched the segment")
	}
	if shared {
		assertOnlyAdmissionStopped(t, a, errno)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// The committed record survives; reopening recovers a usable spool.
	s2, err := Open(dir)
	if err != nil {
		t.Fatalf("reopen after fail-stop: %v", err)
	}
	defer func() { _ = s2.Close() }()
	recs, err := s2.Unresolved()
	if err != nil || len(recs) == 0 || recs[0].Sequence != 1 || string(recs[0].Body) != "first" {
		t.Fatalf("records after reopen = %+v, %v; want sequence 1 intact", recs, err)
	}
	if seq := mustAppend(t, s2, 4, "after reopen"); seq < 2 {
		t.Fatalf("append after reopen reused sequence %d", seq)
	}
}

// assertOnlyAdmissionStopped checks that a lane's failed append stopped every
// lane's admission on a, and that recovery still runs end to end.
func assertOnlyAdmissionStopped(t *testing.T, a *Allocator, errno error) {
	t.Helper()
	if err := a.Err(); !errors.Is(err, errno) || !errors.Is(err, ErrFailStopped) {
		t.Fatalf("shared allocator Err after spool fail-stop = %v, want the lane's failure", err)
	}
	otherDir := t.TempDir()
	otherLane, err := Open(otherDir, WithAllocator(a))
	if err != nil {
		t.Fatalf("open other lane: %v", err)
	}
	if _, err := otherLane.Append(evid(1), []byte("other lane")); !errors.Is(err, ErrFailStopped) ||
		!errors.Is(err, errno) {
		t.Fatalf("other lane append after spool fail-stop = %v, want ErrFailStopped caused by %v", err, errno)
	}
	if info, err := os.Stat(filepath.Join(otherDir, segmentFile)); err != nil || info.Size() != 0 {
		t.Fatalf("other lane segment after refused append: %v, %v; want empty", info, err)
	}
	if err := otherLane.Close(); err != nil {
		t.Fatalf("close other lane: %v", err)
	}

	g, err := a.AcquireRecovery()
	if err != nil {
		t.Fatalf("AcquireRecovery after a lane's append failure: %v", err)
	}
	journal := filepath.Join(t.TempDir(), "journal-a")
	if err := g.WriteBarrier(ArtifactJournalA, journal, []byte("synthetic journal")); err != nil {
		t.Fatalf("recovery write after a lane's append failure: %v", err)
	}
	ran := false
	if err := g.RunDestructive("synthetic step", func() error { ran = true; return nil }); err != nil || !ran {
		t.Fatalf("recovery destructive step after a lane's append failure: err=%v ran=%v", err, ran)
	}
	if err := g.Finish(0); err != nil {
		t.Fatalf("finish recovery after a lane's append failure: %v", err)
	}
	if err := g.ReleaseSource("lane", 0, "lane"); err != nil {
		t.Fatalf("release recovery after a lane's append failure: %v", err)
	}
}

func TestAppendAfterCloseIsRefusedWithoutCharging(t *testing.T) {
	a := newTestAllocator(t, 10_000, 1)
	s, err := Open(t.TempDir(), WithAllocator(a))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if _, err := s.Append(evid(1), []byte("late")); !errors.Is(err, os.ErrClosed) {
		t.Fatalf("append after close = %v, want os.ErrClosed", err)
	}
	if got := a.Usage().OrdinaryUsed; got != 0 {
		t.Fatalf("append after close charged %d bytes", got)
	}
}
