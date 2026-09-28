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
	// testLane is the lane of recoveries that land no destination segment or sidecar.
	testLane = "recovery-lane"
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

// faultSegment injects faultFS's failure into a lane segment's record write and
// fsync. Like faultFile's, a failing write lands half its bytes first.
type faultSegment struct {
	segmentHandle
	fs *faultFS
}

func (f *faultSegment) WriteAt(p []byte, off int64) (int, error) {
	if f.fs.fail("write") {
		n, _ := f.segmentHandle.WriteAt(p[:len(p)/2], off)
		return n, f.fs.errno
	}
	return f.segmentHandle.WriteAt(p, off)
}

func (f *faultSegment) Sync() error {
	if f.fs.fail("fsync") {
		return f.fs.errno
	}
	return f.segmentHandle.Sync()
}

func onDisk(t *testing.T, path string) bool {
	t.Helper()
	ok, err := exists(path)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

// laneCommitLen is what committing body adds on disk to a lane whose evidence
// covers every earlier sequence: the framed record plus a PREPARED and a
// COMMITTED entry in each evidence copy.
//
//nolint:unparam // body sizes the record the same way the caller's append does
func laneCommitLen(body string) uint64 {
	return uint64(minRecordLen+len(body)) + evidenceCopies*2*evidenceEntryLen
}

// deleteLane physically removes a lane's segment and both evidence copies.
func deleteLane(t *testing.T, dir string) {
	t.Helper()
	paths := make([]string, 0, 1+evidenceCopies)
	paths = append(paths, filepath.Join(dir, segmentFile))
	for c := range evidenceCopies {
		paths = append(paths, filepath.Join(dir, evidenceDirName(c)))
	}
	for _, path := range paths {
		if err := os.RemoveAll(path); err != nil {
			t.Fatalf("delete %s: %v", path, err)
		}
	}
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
		g, err := a.AcquireRecovery(dir)
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
	if _, err := a.AcquireRecovery(testLane); !errors.Is(err, ErrReserveUnbacked) {
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
	g1, err := a.AcquireRecovery(testLane)
	if err != nil {
		t.Fatalf("acquire 1: %v", err)
	}
	if _, err := a.AcquireRecovery(testLane); err != nil {
		t.Fatalf("acquire 2: %v", err)
	}
	if _, err := a.AcquireRecovery(testLane); !errors.Is(err, ErrRecoveryConcurrencyExhausted) {
		t.Fatalf("acquire 3 = %v, want ErrRecoveryConcurrencyExhausted", err)
	}
	if err := g1.Finish(); err != nil {
		t.Fatalf("finish: %v", err)
	}
	if err := g1.Finish(); !errors.Is(err, ErrRecoveryFinished) {
		t.Fatalf("second finish = %v, want ErrRecoveryFinished", err)
	}
	if _, err := a.AcquireRecovery(testLane); !errors.Is(err, ErrRecoveryConcurrencyExhausted) {
		t.Fatalf("acquire after finish, before any release = %v, want ErrRecoveryConcurrencyExhausted", err)
	}
	if err := g1.ReleaseArtifacts(); err != nil {
		t.Fatalf("release artifacts: %v", err)
	}
	if _, err := a.AcquireRecovery(testLane); !errors.Is(err, ErrRecoveryConcurrencyExhausted) {
		t.Fatalf("acquire before the source is released = %v, want ErrRecoveryConcurrencyExhausted", err)
	}
	if err := g1.ReleaseSource("lane", 0); err != nil {
		t.Fatalf("release source: %v", err)
	}
	if err := g1.ReleaseSource("lane", 0); !errors.Is(err, ErrRecoveryFinished) {
		t.Fatalf("second release = %v, want ErrRecoveryFinished", err)
	}
	if _, err := a.AcquireRecovery(testLane); err != nil {
		t.Fatalf("acquire after both releases: %v", err)
	}
}

// A finished recovery releases its output in two stages, each only after the
// bytes it covers are gone, and never counts a byte twice. The new lane serves
// producers while the coverage proof is pending without paying again for the
// destination the grant still holds. Deleting the source moves the destination
// segment and its attribution sidecar into the lane at what their files hold, so
// a sidecar rebound over the same path counts once; the journal stays charged to
// the grant, with the slot held, until it is deleted too, and reopening the lane
// in between re-measures its files without dropping anything.
func TestRecoveryOutputIsReleasedInTwoStages(t *testing.T) {
	a := newTestAllocator(t, 2000, 1)
	dir := t.TempDir()
	sourceLane := filepath.Join(dir, "source-lane")
	lane := filepath.Join(dir, "new-lane")
	sourceSeg := filepath.Join(dir, "source.seg")
	journal := filepath.Join(dir, "journal-a")
	// The new lane's first commit takes sequence 2, past the destination's record,
	// so each evidence copy grows to hold slot 2's entries over the hole slot 1's
	// would occupy.
	appendLen := uint64(minRecordLen+len(syntheticBody)) +
		evidenceCopies*uint64(evidencePosition(2, stateCommitted)+evidenceEntryLen)
	if err := os.WriteFile(sourceSeg, []byte("synthetic source segment"), filePerm); err != nil {
		t.Fatalf("seed source: %v", err)
	}
	if err := admitLanded(a, sourceLane, 400); err != nil {
		t.Fatalf("charge the source lane: %v", err)
	}
	if err := os.MkdirAll(lane, dirPerm); err != nil {
		t.Fatalf("create new lane: %v", err)
	}

	g, err := a.AcquireRecovery(lane)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	destination := encodeRecord(1, evid(1), bytes.Repeat([]byte{'d'}, 22))
	destPath := filepath.Join(lane, segmentFile)
	for _, chunk := range [][]byte{destination[:30], destination[30:]} {
		streamDestinationChunk(t, g, destPath, chunk)
	}
	sidecar := filepath.Join(lane, "attribution")
	for _, binding := range []byte{1, 2} {
		if err := g.WriteBarrier(ArtifactAttributionSidecar, sidecar, bytes.Repeat([]byte{binding}, 8)); err != nil {
			t.Fatalf("write sidecar binding %d: %v", binding, err)
		}
	}
	if err := g.WriteBarrier(ArtifactJournalA, journal, make([]byte, 32)); err != nil {
		t.Fatalf("write journal: %v", err)
	}

	if err := g.ReleaseSource(sourceLane, 400); !errors.Is(err, ErrRecoveryNotFinished) {
		t.Fatalf("release source before finish = %v, want ErrRecoveryNotFinished", err)
	}
	if err := g.ReleaseArtifacts(); !errors.Is(err, ErrRecoveryNotFinished) {
		t.Fatalf("release artifacts before finish = %v, want ErrRecoveryNotFinished", err)
	}
	if err := g.Finish(); err != nil {
		t.Fatalf("finish: %v", err)
	}
	assertUsage(t, a, "after finish", 400, 112, 1)
	if _, err := a.AcquireRecovery(testLane); !errors.Is(err, ErrRecoveryConcurrencyExhausted) {
		t.Fatalf("second recovery while the source and its copy share the disk = %v, want ErrRecoveryConcurrencyExhausted", err)
	}
	if err := g.WriteBarrier(ArtifactMapping, filepath.Join(dir, "mapping"), []byte{1}); !errors.Is(err, ErrRecoveryFinished) {
		t.Fatalf("write after finish = %v, want ErrRecoveryFinished", err)
	}

	newLane, err := Open(lane, WithAllocator(a))
	if err != nil {
		t.Fatalf("open new lane on the destination: %v", err)
	}
	assertUsage(t, a, "after opening the new lane on the destination", 400, 112, 1)
	mustAppend(t, newLane, 2, syntheticBody)
	assertUsage(t, a, "after the new lane appends", 400+appendLen, 112, 1)
	if err := newLane.Close(); err != nil {
		t.Fatalf("close new lane: %v", err)
	}

	if err := g.RunDestructive("delete source", func() error { return os.Remove(sourceSeg) }); err != nil {
		t.Fatalf("coverage-proof deletion through the finished grant: %v", err)
	}
	if err := g.ReleaseSource(sourceLane, 401); !errors.Is(err, ErrReleaseExceedsCharge) {
		t.Fatalf("releasing more than the source holds = %v, want ErrReleaseExceedsCharge", err)
	}
	assertUsage(t, a, "after a refused release", 400+appendLen, 112, 1)
	if err := g.ReleaseSource(sourceLane, 400); err != nil {
		t.Fatalf("release source after deleting it: %v", err)
	}
	assertUsage(t, a, "after releasing the source", 72+appendLen, 32, 1)
	if _, err := a.AcquireRecovery(testLane); !errors.Is(err, ErrRecoveryConcurrencyExhausted) {
		t.Fatalf("second recovery while the journal is still on disk = %v, want ErrRecoveryConcurrencyExhausted", err)
	}
	if err := g.ReleaseSource(sourceLane, 0); !errors.Is(err, ErrRecoveryFinished) {
		t.Fatalf("second source release = %v, want ErrRecoveryFinished", err)
	}

	reopened, err := Open(lane, WithAllocator(a))
	if err != nil {
		t.Fatalf("reopen new lane: %v", err)
	}
	if err := reopened.Close(); err != nil {
		t.Fatalf("close reopened lane: %v", err)
	}
	assertUsage(t, a, "after reopening the lane", 72+appendLen, 32, 1)

	if err := g.RunDestructive("delete journal", func() error { return os.Remove(journal) }); err != nil {
		t.Fatalf("delete journal once the recovery resolves: %v", err)
	}
	if err := g.ReleaseArtifacts(); err != nil {
		t.Fatalf("release artifacts after deleting them: %v", err)
	}
	assertUsage(t, a, "after releasing the artifacts", 72+appendLen, 0, 0)
	if err := g.ReleaseArtifacts(); !errors.Is(err, ErrRecoveryFinished) {
		t.Fatalf("second artifact release = %v, want ErrRecoveryFinished", err)
	}
	if _, err := a.AcquireRecovery(testLane); err != nil {
		t.Fatalf("acquire after both releases: %v", err)
	}
}

// streamDestinationChunk appends chunk to path as caller-written destination
// output: charged first, then reported landed once it is on disk.
func streamDestinationChunk(t *testing.T, g *RecoveryGrant, path string, chunk []byte) {
	t.Helper()
	n := uint64(len(chunk))
	if err := g.Charge(ArtifactDestinationSegment, n); err != nil {
		t.Fatalf("charge destination chunk: %v", err)
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, filePerm)
	if err != nil {
		t.Fatalf("open destination: %v", err)
	}
	if _, err := f.Write(chunk); err != nil {
		_ = f.Close()
		t.Fatalf("write destination chunk: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close destination: %v", err)
	}
	if err := g.Landed(ArtifactDestinationSegment, path, n); err != nil {
		t.Fatalf("land destination chunk: %v", err)
	}
}

func assertUsage(t *testing.T, a *Allocator, when string, ordinary, recovery uint64, active int) {
	t.Helper()
	if u := a.Usage(); u.OrdinaryUsed != ordinary || u.RecoveryUsed != recovery || u.ActiveRecoveries != active {
		t.Fatalf("%s usage = %+v, want %d ordinary, %d recovery, %d active", when, u, ordinary, recovery, active)
	}
}

// Every footprint field bounds CUMULATIVE writes: each rewrite of the same path
// is charged in full, so a journal is sized for all of its rewrites, not one copy.
func TestFootprintBoundsCumulativeRewrites(t *testing.T) {
	a := newTestAllocator(t, 500, 1)
	g, err := a.AcquireRecovery(testLane)
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

// A destination segment or sidecar counts in the lane the grant names, the
// directory Open measures. One written or landed anywhere else, such as a
// generation below a LaneSet lane directory, is refused before it is charged,
// written, or landed, so the lane neither pays again for bytes the grant holds
// nor loses bytes ReleaseSource moves.
func TestLaneArtifactOutsideTheGrantLaneIsRefused(t *testing.T) {
	a := newTestAllocator(t, 500, 1)
	ff := &faultFS{inner: osFS{}}
	a.fs = ff
	lane := filepath.Join(t.TempDir(), "1-2")
	generation := filepath.Join(lane, "generation")
	if err := os.MkdirAll(generation, dirPerm); err != nil {
		t.Fatalf("create generation: %v", err)
	}
	g, err := a.AcquireRecovery(lane)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}

	outsideSeg := filepath.Join(generation, segmentFile)
	calls := ff.calls
	if err := g.WriteBarrier(ArtifactDestinationSegment, outsideSeg, make([]byte, 64)); !errors.Is(err, ErrOutsideLane) {
		t.Fatalf("destination write outside the lane = %v, want ErrOutsideLane", err)
	}
	if ff.calls != calls || onDisk(t, outsideSeg) || onDisk(t, outsideSeg+".tmp") {
		t.Fatal("a destination write outside the lane reached storage")
	}
	if got := g.Used(ArtifactDestinationSegment); got != 0 {
		t.Fatalf("refused destination write charged %d", got)
	}

	binding := bytes.Repeat([]byte{1}, 16)
	if err := g.Charge(ArtifactAttributionSidecar, uint64(len(binding))); err != nil {
		t.Fatalf("charge sidecar: %v", err)
	}
	outsideSidecar := filepath.Join(generation, "attribution")
	if err := g.Landed(ArtifactAttributionSidecar, outsideSidecar, uint64(len(binding))); !errors.Is(err, ErrOutsideLane) {
		t.Fatalf("sidecar landed outside the lane = %v, want ErrOutsideLane", err)
	}
	if err := errors.Join(g.Err(), a.Err()); err != nil {
		t.Fatalf("a refused lane artifact stopped recovery: %v", err)
	}

	destination := encodeRecord(1, evid(1), bytes.Repeat([]byte{'d'}, 22))
	if err := g.WriteBarrier(ArtifactDestinationSegment, filepath.Join(lane, segmentFile), destination); err != nil {
		t.Fatalf("destination write in the lane: %v", err)
	}
	sidecar := filepath.Join(lane, "attribution")
	if err := os.WriteFile(sidecar, binding, filePerm); err != nil {
		t.Fatalf("write sidecar in the lane: %v", err)
	}
	if err := g.Landed(ArtifactAttributionSidecar, sidecar, uint64(len(binding))); err != nil {
		t.Fatalf("land sidecar in the lane, still in flight after the refusal: %v", err)
	}

	s, err := Open(lane, WithAllocator(a))
	if err != nil {
		t.Fatalf("open the lane: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close the lane: %v", err)
	}
	assertUsage(t, a, "after opening the lane on its recovery output", 0, 80, 1)
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
	// room is the free space above the floor the lane may commit into.
	const room = 1000
	free = floor + room

	lane, err := Open(t.TempDir(), WithAllocator(a))
	if err != nil {
		t.Fatalf("open lane: %v", err)
	}
	defer func() { _ = lane.Close() }()
	// record returns a body whose commit to the fresh lane adds exactly n bytes: its
	// framed record plus a PREPARED and a COMMITTED entry in each evidence copy.
	record := func(n int) []byte {
		return bytes.Repeat([]byte{'x'}, n-minRecordLen-evidenceCopies*2*evidenceEntryLen)
	}

	dir := t.TempDir()
	g, err := a.AcquireRecovery(dir)
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}

	hooked := false
	ff.beforeWrite = func() {
		hooked = true
		// room free bytes sit above the floor, but 64 of them belong to the
		// destination write in progress.
		if _, err := lane.Append(evid(1), record(room+1)); !errors.Is(err, ErrAdmissionRefused) {
			t.Errorf("lane admission during the recovery write = %v, want ErrAdmissionRefused", err)
		}
		free = floor - 1
		if _, err := a.AcquireRecovery(testLane); !errors.Is(err, ErrReserveUnbacked) {
			t.Errorf("acquisition backed only by in-flight bytes = %v, want ErrReserveUnbacked", err)
		}
		free = floor + room
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
	if _, err := lane.Append(evid(1), record(room+1)); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatalf("lane admission into charged, unwritten mapping bytes = %v, want ErrAdmissionRefused", err)
	}
	// The destination and sidecar writes landed, so exactly the rest fits.
	if _, err := lane.Append(evid(1), record(room)); err != nil {
		t.Fatalf("lane admission after the barrier writes landed: %v", err)
	}
	free -= room

	free -= 8
	if _, err := a.AcquireRecovery(testLane); !errors.Is(err, ErrReserveUnbacked) {
		t.Fatalf("acquisition before the mapping is reported landed = %v, want ErrReserveUnbacked", err)
	}
	if err := g.Landed(ArtifactMapping, filepath.Join(dir, "mapping"), 9); !errors.Is(err, ErrReleaseExceedsCharge) {
		t.Fatalf("landing more than is in flight = %v, want ErrReleaseExceedsCharge", err)
	}
	if err := g.Landed(ArtifactMapping, filepath.Join(dir, "mapping"), 8); err != nil {
		t.Fatalf("land mapping: %v", err)
	}
	if _, err := a.AcquireRecovery(testLane); err != nil {
		t.Fatalf("acquisition once every charged byte landed: %v", err)
	}
}

// A lane Open fails on still occupies its files on disk, so its bytes stay
// charged even though Open fails.
func TestLaneIsChargedWhenOpenFails(t *testing.T) {
	body := syntheticBody
	commitLen := laneCommitLen(body)
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
	// Restart resolution classifies damaged records instead of failing, so make Open
	// fail on I/O: a directory where the resolved watermark belongs cannot be read.
	if err := os.Mkdir(filepath.Join(dirA, resolvedFile), dirPerm); err != nil {
		t.Fatalf("make the resolved watermark unreadable: %v", err)
	}

	a := newTestAllocator(t, 3*commitLen, 1)
	if _, err := Open(dirA, WithAllocator(a)); err == nil {
		t.Fatal("open lane with an unreadable resolved watermark succeeded, want an error")
	}
	if got := a.Usage().OrdinaryUsed; got != 2*commitLen {
		t.Fatalf("lane Open failed on charged %d, want its on-disk %d", got, 2*commitLen)
	}

	laneB, err := Open(t.TempDir(), WithAllocator(a))
	if err != nil {
		t.Fatalf("open lane B: %v", err)
	}
	defer func() { _ = laneB.Close() }()
	mustAppend(t, laneB, 1, body)
	if _, err := laneB.Append(evid(2), []byte(body)); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatalf("lane B append into space lane A occupies = %v, want ErrAdmissionRefused", err)
	}
}

// One directory spelled two ways is one owner: reopening replaces its charge,
// and a release under another spelling finds it.
func TestOwnerSpellingsOfOneDirectoryShareACharge(t *testing.T) {
	body := syntheticBody
	commitLen := laneCommitLen(body)
	a := newTestAllocator(t, 10*commitLen, 1)
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
	if got := a.Usage().OrdinaryUsed; got != 2*commitLen {
		t.Fatalf("reopening under another spelling charged %d, want %d", got, 2*commitLen)
	}
	if err := reopened.Close(); err != nil {
		t.Fatalf("close reopened: %v", err)
	}

	deleteLane(t, dir)
	if err := a.ReleaseOrdinary(dir+sep+sep, 2*commitLen); err != nil {
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

	g, err := a.AcquireRecovery(testLane)
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
	if ff.calls != calls || onDisk(t, over) || onDisk(t, over+".tmp") {
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
	if !errors.Is(err, ErrRecoveryStopped) || ran || !onDisk(t, source) {
		t.Fatalf("destructive step after exhaustion: err=%v ran=%v; want refused and source intact", err, ran)
	}
	if err := g.Finish(); !errors.Is(err, ErrRecoveryStopped) {
		t.Fatalf("finish after exhaustion = %v, want ErrRecoveryStopped", err)
	}
	if ff.calls != calls || onDisk(t, journalB) {
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
	other, err := a.AcquireRecovery(testLane)
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

				g, err := a.AcquireRecovery(dir)
				if err != nil {
					t.Fatalf("acquire: %v", err)
				}
				other, err := a.AcquireRecovery(testLane)
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
					if onDisk(t, dest) || onDisk(t, dest+".tmp") {
						t.Fatalf("failed %s left a destination or temporary file", op)
					}
				case "fsync dir":
					if !onDisk(t, dest) {
						t.Fatal("a failed directory fsync deleted the renamed destination")
					}
				}

				calls := ff.calls
				ran := false
				destroy := func() error { ran = true; return os.Remove(source) }
				for name, grant := range map[string]*RecoveryGrant{"failed": g, "other": other} {
					assertStoppedGrantRefusesEverything(t, name, grant, errno, dir, source, destroy)
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
				if _, err := a.AcquireRecovery(testLane); !errors.Is(err, ErrFailStopped) {
					t.Fatalf("AcquireRecovery after fail-stop = %v, want ErrFailStopped", err)
				}
				if got := a.Usage().ActiveRecoveries; got != 2 {
					t.Fatalf("fail-stopped recoveries released their reserve: active = %d", got)
				}
			})
		}
	}
}

// assertStoppedGrantRefusesEverything checks that a grant stopped by errno runs
// no destructive step, writes nothing, and cannot finish or release.
func assertStoppedGrantRefusesEverything(t *testing.T, name string, grant *RecoveryGrant, errno error,
	dir, source string, destroy func() error,
) {
	t.Helper()
	err := grant.RunDestructive("delete source", destroy)
	if !errors.Is(err, ErrRecoveryStopped) || !errors.Is(err, errno) {
		t.Fatalf("%s grant destructive step = %v, want ErrRecoveryStopped caused by %v", name, err, errno)
	}
	err = grant.WriteBarrier(ArtifactJournalA, filepath.Join(dir, name+"-journal"), []byte{1})
	if !errors.Is(err, ErrRecoveryStopped) || !errors.Is(err, errno) {
		t.Fatalf("%s grant write after fail-stop = %v, want refused", name, err)
	}
	if err := grant.Finish(); !errors.Is(err, ErrRecoveryStopped) {
		t.Fatalf("%s grant finish after fail-stop = %v, want refused", name, err)
	}
	if err := grant.ReleaseSource(source, 0); !errors.Is(err, ErrRecoveryStopped) {
		t.Fatalf("%s grant source release after fail-stop = %v, want refused", name, err)
	}
	if err := grant.ReleaseArtifacts(); !errors.Is(err, ErrRecoveryStopped) {
		t.Fatalf("%s grant artifact release after fail-stop = %v, want refused", name, err)
	}
}

func TestFailedDestructiveStepIsFailStop(t *testing.T) {
	for errName, errno := range map[string]error{"ENOSPC": syscall.ENOSPC, "EIO": syscall.EIO} {
		t.Run(errName, func(t *testing.T) {
			a := newTestAllocator(t, 500, 1)
			g, err := a.AcquireRecovery(testLane)
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
			g, err := a.AcquireRecovery(testLane)
			if err != nil {
				t.Fatalf("acquire: %v", err)
			}
			other, err := a.AcquireRecovery(testLane)
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
			if ran || !onDisk(t, source) {
				t.Fatalf("destructive step ran=%v after FailStop; want refused and source intact", ran)
			}
			if err := admitLanded(a, "lane", 1); !errors.Is(err, ErrFailStopped) || !errors.Is(err, errno) {
				t.Fatalf("Admit after FailStop = %v, want ErrFailStopped caused by %s", err, errName)
			}
			if _, err := a.AcquireRecovery(testLane); !errors.Is(err, ErrFailStopped) {
				t.Fatalf("AcquireRecovery after FailStop = %v, want ErrFailStopped", err)
			}
		})
	}
}

func TestSpoolAdmissionRefusalWritesNothing(t *testing.T) {
	body := syntheticBody
	recLen := uint64(headerLen + headerCRC + len(body) + bodyCRCLen)
	commitLen := laneCommitLen(body)
	a := newTestAllocator(t, 2*commitLen, 1)
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

	// A restart re-measures: the recovered segment and evidence are charged to the new ledger.
	a2 := newTestAllocator(t, 2*commitLen, 1)
	s2, err := Open(dir, WithAllocator(a2))
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = s2.Close() }()
	if got := a2.Usage().OrdinaryUsed; got != 2*commitLen {
		t.Fatalf("reopened ledger charged %d, want the recovered lane's %d", got, 2*commitLen)
	}
	if _, err := s2.Append(evid(3), []byte(body)); !errors.Is(err, ErrAdmissionRefused) {
		t.Fatalf("append after reopen = %v, want ErrAdmissionRefused", err)
	}
}

// A closed lane's files are still on disk, so its charge survives Close and is
// released only after they are deleted. Reopening re-measures instead of
// adding, and releasing one lane can never spend another lane's charge.
func TestLaneChargeLastsUntilPhysicalDeletion(t *testing.T) {
	body := syntheticBody
	commitLen := laneCommitLen(body)
	a := newTestAllocator(t, 3*commitLen, 1)
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
	if got := a.Usage().OrdinaryUsed; got != 2*commitLen {
		t.Fatalf("after closing lane A ordinary used = %d, want its on-disk %d", got, 2*commitLen)
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
	if got := a.Usage().OrdinaryUsed; got != 3*commitLen {
		t.Fatalf("reopening lane A on the same allocator: ordinary used = %d, want %d", got, 3*commitLen)
	}
	if err := reopened.Close(); err != nil {
		t.Fatalf("close reopened lane A: %v", err)
	}

	deleteLane(t, dirA)
	if err := a.ReleaseOrdinary(dirA, 2*commitLen); err != nil {
		t.Fatalf("release lane A after deleting it: %v", err)
	}
	mustAppend(t, laneB, 2, body)
	if err := a.ReleaseOrdinary(dirA, commitLen); !errors.Is(err, ErrReleaseExceedsCharge) {
		t.Fatalf("second release of lane A while lane B holds %d = %v, want ErrReleaseExceedsCharge", 2*commitLen, err)
	}
	if got := a.Usage().OrdinaryUsed; got != 2*commitLen {
		t.Fatalf("ordinary used = %d, want lane B's %d", got, 2*commitLen)
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
	s.seg = &faultSegment{segmentHandle: s.seg, fs: ff}

	_, err = s.Append(evid(2), []byte("second"))
	var stop *FailStopError
	if !errors.Is(err, errno) || !errors.Is(err, ErrFailStopped) || !errors.As(err, &stop) || stop.Op != op {
		t.Fatalf("append with failing %s = %v, want *FailStopError(%s) wrapping %v", op, err, op, errno)
	}
	// Both PREPARED evidence copies landed before the record write, so sequence 2 is
	// allocated: restart resolution classifies it, and it is never reused.
	if s.NextSequence() != 3 {
		t.Fatalf("failed append released its allocated sequence: next = %d, want 3", s.NextSequence())
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
	if seq := mustAppend(t, s2, 4, "after reopen"); seq < 3 {
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

	g, err := a.AcquireRecovery(testLane)
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
	if err := g.Finish(); err != nil {
		t.Fatalf("finish recovery after a lane's append failure: %v", err)
	}
	if err := errors.Join(g.ReleaseSource("lane", 0), g.ReleaseArtifacts()); err != nil {
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
