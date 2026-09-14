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

// This file holds the reserve and allocation primitives of task 2.26: the
// filesystem byte allocator, the recovery reserve it keeps out of producer
// admission, the unborrowable floor, and the admission refusal path.
//
// # Scope
//
// This file owns capacity: how many bytes ordinary producers may admit, how many
// a recovery may write, and the guarantee that a failed barrier or an exhausted
// reserve stops recovery before any destructive step. It deliberately does NOT
// decide whether a destructive step is AUTHORIZED. That is the coverage proof,
// task 2.28. The recovery coordinator that freezes, pages, and journals is task
// 2.27. A grant here is the capacity those tasks spend, not their state machine.

import (
	"errors"
	"fmt"
	"math/bits"
	"sync"
)

// ErrInvalidAllocatorConfig is returned by NewAllocator and Footprint.PerRecovery
// for a configuration that cannot yield a safe reserve.
var ErrInvalidAllocatorConfig = errors.New("spool: invalid allocator config")

// ErrAdmissionRefused is returned when ordinary producer admission would cross
// the ordinary ceiling or the physically backed floor. Nothing is charged and
// nothing is written; the producer must defer, not fail the work.
var ErrAdmissionRefused = errors.New("spool: admission refused")

// ErrRecoveryConcurrencyExhausted is returned by AcquireRecovery when the
// bounded number of concurrent recoveries is already running.
var ErrRecoveryConcurrencyExhausted = errors.New("spool: concurrent recovery limit reached")

// ErrReserveUnbacked is returned by AcquireRecovery when the filesystem no longer
// holds enough free bytes for the outstanding reserve. The recovery is refused
// before it writes anything, rather than started and stopped midway by ENOSPC.
var ErrReserveUnbacked = errors.New("spool: recovery reserve not backed by free space")

// ErrReserveExhausted is matched by the error returned when a recovery asks for
// more bytes of one artifact than its footprint sized. The write is refused and
// the recovery is stopped.
var ErrReserveExhausted = errors.New("spool: recovery reserve exhausted")

// ErrRecoveryStopped is returned for every request on a recovery grant after it
// stopped. A stopped grant writes nothing more, runs no destructive step, and
// cannot be finished; its reserve slot stays held until the process restarts.
var ErrRecoveryStopped = errors.New("spool: recovery stopped")

// ErrRecoveryFinished is returned for a request on a grant that already finished.
var ErrRecoveryFinished = errors.New("spool: recovery already finished")

// ErrReleaseExceedsCharge is returned when a caller releases or retains more
// bytes than are charged. Accepting it would underflow the ledger and silently
// create capacity that does not exist on disk.
var ErrReleaseExceedsCharge = errors.New("spool: release exceeds charged bytes")

// Artifact is one durable output a recovery writes. Each has its own budget, so
// an undersized artifact exhausts its reserve instead of borrowing another's.
type Artifact uint8

const (
	// ArtifactDestinationSegment is the new-lane segment the readable records are
	// copied into.
	ArtifactDestinationSegment Artifact = iota
	// ArtifactAttributionSidecar is the destination's attribution binding.
	ArtifactAttributionSidecar
	// ArtifactJournalA is the first recovery-journal copy.
	ArtifactJournalA
	// ArtifactJournalB is the second, independent recovery-journal copy.
	ArtifactJournalB
	// ArtifactManifestPages covers the loss-manifest and tombstone pages.
	ArtifactManifestPages
	// ArtifactMapping is the old->new sequence mapping.
	ArtifactMapping
	// ArtifactFilesystemMetadata is directory entries, inodes, and renames the
	// other artifacts cost the filesystem beyond their content bytes.
	ArtifactFilesystemMetadata

	artifactCount
)

//nolint:gochecknoglobals // immutable lookup table indexed by Artifact
var artifactNames = [artifactCount]string{
	ArtifactDestinationSegment: "destination segment",
	ArtifactAttributionSidecar: "attribution sidecar",
	ArtifactJournalA:           "journal copy A",
	ArtifactJournalB:           "journal copy B",
	ArtifactManifestPages:      "manifest/tombstone pages",
	ArtifactMapping:            "old->new mapping",
	ArtifactFilesystemMetadata: "filesystem metadata",
}

func (a Artifact) String() string {
	if a >= artifactCount {
		return fmt.Sprintf("artifact(%d)", uint8(a))
	}
	return artifactNames[a]
}

// Footprint is the byte bound of everything ONE recovery must durably write.
//
// A reserve sized only for the input segment ("one segment of scratch") counts
// none of the artifacts a recovery produces, and runs out partway through the
// first recovery that needs them. Every field must therefore be sized, and a
// zero is refused rather than read as "not needed".
type Footprint struct {
	DestinationSegment uint64
	AttributionSidecar uint64
	// JournalCopy is the bound of ONE journal copy. Recovery writes two
	// independent copies, and both are reserved.
	JournalCopy        uint64
	ManifestPages      uint64
	Mapping            uint64
	FilesystemMetadata uint64
}

func (f Footprint) budgets() [artifactCount]uint64 {
	return [artifactCount]uint64{
		ArtifactDestinationSegment: f.DestinationSegment,
		ArtifactAttributionSidecar: f.AttributionSidecar,
		ArtifactJournalA:           f.JournalCopy,
		ArtifactJournalB:           f.JournalCopy,
		ArtifactManifestPages:      f.ManifestPages,
		ArtifactMapping:            f.Mapping,
		ArtifactFilesystemMetadata: f.FilesystemMetadata,
	}
}

// PerRecovery returns the aggregate bytes one recovery reserves: every artifact,
// with the journal counted twice.
func (f Footprint) PerRecovery() (uint64, error) {
	var total uint64
	for art, n := range f.budgets() {
		if n == 0 {
			return 0, fmt.Errorf("%w: %s footprint is zero", ErrInvalidAllocatorConfig, Artifact(art))
		}
		sum, carry := bits.Add64(total, n, 0)
		if carry != 0 {
			return 0, fmt.Errorf("%w: recovery footprint overflows", ErrInvalidAllocatorConfig)
		}
		total = sum
	}
	return total, nil
}

// AllocatorConfig sizes an Allocator.
type AllocatorConfig struct {
	// Capacity is the hard byte budget for durable spool storage.
	Capacity uint64
	// Recovery is the footprint of one recovery.
	Recovery Footprint
	// MaxConcurrentRecoveries bounds how many recoveries may hold a reserve at
	// once. The reserve is the footprint times this number.
	MaxConcurrentRecoveries int
	// MinFree is free space that neither producers nor recoveries allocate:
	// headroom for aborting or terminalizing work and reporting state.
	MinFree uint64
	// FreeBytes, when set, reports the bytes actually free on the filesystem.
	// Nominal accounting cannot see another process filling the disk, so every
	// ordinary admission and recovery acquisition also requires the outstanding
	// floor to be physically backed.
	FreeBytes func() (uint64, error)
}

// Usage is a point-in-time view of an Allocator's ledger.
type Usage struct {
	Capacity uint64
	// RecoveryReserve is the footprint times MaxConcurrentRecoveries.
	RecoveryReserve uint64
	// Floor is RecoveryReserve plus MinFree: bytes ordinary admission never uses.
	Floor uint64
	// OrdinaryCeiling is Capacity minus Floor.
	OrdinaryCeiling  uint64
	OrdinaryUsed     uint64
	ActiveRecoveries int
	// RecoveryUsed is the bytes charged to active recovery grants.
	RecoveryUsed uint64
}

// Allocator is the byte allocator shared by every lane and recovery on one
// spool filesystem. It is safe for concurrent use.
//
// Its ledger is in memory by design. The durable truth is the files on disk:
// after a restart, the opener re-measures them (Open charges each segment it
// recovers through ChargeExisting), so there is no second on-disk ledger that
// could disagree with them.
type Allocator struct {
	fs              fileSystem
	freeBytes       func() (uint64, error)
	budgets         [artifactCount]uint64
	maxActive       int
	minFree         uint64
	capacity        uint64
	reserve         uint64
	floor           uint64
	ordinaryCeiling uint64

	mu           sync.Mutex
	ordinaryUsed uint64
	active       map[*RecoveryGrant]struct{}
	failErr      error
}

// NewAllocator validates cfg and returns an allocator with nothing charged.
func NewAllocator(cfg AllocatorConfig) (*Allocator, error) {
	per, err := cfg.Recovery.PerRecovery()
	if err != nil {
		return nil, err
	}
	if cfg.MaxConcurrentRecoveries < 1 {
		return nil, fmt.Errorf("%w: MaxConcurrentRecoveries must be at least 1, got %d",
			ErrInvalidAllocatorConfig, cfg.MaxConcurrentRecoveries)
	}
	if cfg.MinFree == 0 {
		return nil, fmt.Errorf("%w: MinFree must be non-zero", ErrInvalidAllocatorConfig)
	}
	hi, reserve := bits.Mul64(per, uint64(cfg.MaxConcurrentRecoveries))
	if hi != 0 {
		return nil, fmt.Errorf("%w: recovery reserve overflows", ErrInvalidAllocatorConfig)
	}
	floor, carry := bits.Add64(reserve, cfg.MinFree, 0)
	if carry != 0 {
		return nil, fmt.Errorf("%w: floor overflows", ErrInvalidAllocatorConfig)
	}
	if cfg.Capacity <= floor {
		return nil, fmt.Errorf("%w: capacity %d leaves no ordinary space above floor %d (reserve %d + min free %d)",
			ErrInvalidAllocatorConfig, cfg.Capacity, floor, reserve, cfg.MinFree)
	}

	return &Allocator{
		fs:              osFS{},
		freeBytes:       cfg.FreeBytes,
		budgets:         cfg.Recovery.budgets(),
		maxActive:       cfg.MaxConcurrentRecoveries,
		minFree:         cfg.MinFree,
		capacity:        cfg.Capacity,
		reserve:         reserve,
		floor:           floor,
		ordinaryCeiling: cfg.Capacity - floor,
		active:          make(map[*RecoveryGrant]struct{}),
	}, nil
}

// Admit charges n bytes of ordinary producer data, or refuses. A refusal charges
// nothing, and it is never partial.
//
// Ordinary data may only use OrdinaryCeiling; the recovery reserve and MinFree
// are unborrowable no matter how empty they are. Admission is also refused once
// the allocator has fail-stopped.
func (a *Allocator) Admit(n uint64) error {
	a.mu.Lock()
	defer a.mu.Unlock()

	if a.failErr != nil {
		return a.failErr
	}
	var left uint64
	if a.ordinaryUsed < a.ordinaryCeiling {
		left = a.ordinaryCeiling - a.ordinaryUsed
	}
	if n > left {
		return fmt.Errorf("%w: requested %d, ordinary space left %d of ceiling %d",
			ErrAdmissionRefused, n, left, a.ordinaryCeiling)
	}
	if err := a.requireBackedLocked(n); err != nil {
		return err
	}
	a.ordinaryUsed += n
	return nil
}

// ChargeExisting charges n bytes already on disk -- a segment recovered at open,
// or a recovery's retained output. It cannot refuse: those bytes exist whether or
// not they fit. If they push usage past the ordinary ceiling, later Admit calls
// are refused until space is released.
func (a *Allocator) ChargeExisting(n uint64) {
	a.mu.Lock()
	defer a.mu.Unlock()
	sum, carry := bits.Add64(a.ordinaryUsed, n, 0)
	if carry != 0 {
		sum = ^uint64(0)
	}
	a.ordinaryUsed = sum
}

// ReleaseOrdinary returns n ordinary bytes after they have been PHYSICALLY
// removed from disk. It is accounting that follows a completed deletion; it
// neither authorizes one nor performs one.
func (a *Allocator) ReleaseOrdinary(n uint64) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if n > a.ordinaryUsed {
		return fmt.Errorf("%w: release %d, charged %d", ErrReleaseExceedsCharge, n, a.ordinaryUsed)
	}
	a.ordinaryUsed -= n
	return nil
}

// AcquireRecovery takes one concurrent-recovery slot and its full footprint.
func (a *Allocator) AcquireRecovery() (*RecoveryGrant, error) {
	a.mu.Lock()
	defer a.mu.Unlock()

	if a.failErr != nil {
		return nil, a.failErr
	}
	if len(a.active) >= a.maxActive {
		return nil, fmt.Errorf("%w: %d active", ErrRecoveryConcurrencyExhausted, len(a.active))
	}
	if a.freeBytes != nil {
		free, err := a.freeBytes()
		if err != nil {
			return nil, fmt.Errorf("%w: measure free space: %w", ErrReserveUnbacked, err)
		}
		if need := a.outstandingFloorLocked(); free < need {
			return nil, fmt.Errorf("%w: free %d, outstanding floor %d", ErrReserveUnbacked, free, need)
		}
	}

	g := &RecoveryGrant{alloc: a}
	a.active[g] = struct{}{}
	return g, nil
}

// Err returns the error that fail-stopped the allocator, or nil.
func (a *Allocator) Err() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.failErr
}

// Usage returns a snapshot of the ledger.
func (a *Allocator) Usage() Usage {
	a.mu.Lock()
	defer a.mu.Unlock()
	return Usage{
		Capacity:         a.capacity,
		RecoveryReserve:  a.reserve,
		Floor:            a.floor,
		OrdinaryCeiling:  a.ordinaryCeiling,
		OrdinaryUsed:     a.ordinaryUsed,
		ActiveRecoveries: len(a.active),
		RecoveryUsed:     a.recoveryUsedLocked(),
	}
}

// failStop makes the allocator refuse all further admission, acquisition, and
// grant work. The first cause wins, so the error every caller sees is stable.
func (a *Allocator) failStop(err error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.failStopLocked(err)
}

func (a *Allocator) failStopLocked(err error) {
	if a.failErr != nil {
		return
	}
	var fs *FailStopError
	if !errors.As(err, &fs) {
		err = &FailStopError{Op: "storage", Err: err}
	}
	a.failErr = err
}

func (a *Allocator) recoveryUsedLocked() uint64 {
	var used uint64
	for g := range a.active {
		used += g.totalLocked()
	}
	return used
}

// outstandingFloorLocked is the free space the floor still needs on disk: the
// whole reserve less what active recoveries have already written, plus MinFree.
func (a *Allocator) outstandingFloorLocked() uint64 {
	return a.reserve - a.recoveryUsedLocked() + a.minFree
}

func (a *Allocator) requireBackedLocked(n uint64) error {
	if a.freeBytes == nil {
		return nil
	}
	free, err := a.freeBytes()
	if err != nil {
		return fmt.Errorf("%w: measure free space: %w", ErrAdmissionRefused, err)
	}
	need, carry := bits.Add64(a.outstandingFloorLocked(), n, 0)
	if carry != 0 || free < need {
		return fmt.Errorf("%w: requested %d, free %d, outstanding floor %d",
			ErrAdmissionRefused, n, free, a.outstandingFloorLocked())
	}
	return nil
}

// ReserveExhaustedError reports the artifact whose sized budget a recovery tried
// to exceed. It matches ErrReserveExhausted.
type ReserveExhaustedError struct {
	Artifact  Artifact
	Requested uint64
	Remaining uint64
}

func (e *ReserveExhaustedError) Error() string {
	return fmt.Sprintf("spool: recovery reserve exhausted: %s requested %d, remaining %d",
		e.Artifact, e.Requested, e.Remaining)
}

// Is makes every ReserveExhaustedError match ErrReserveExhausted.
func (e *ReserveExhaustedError) Is(target error) bool { return target == ErrReserveExhausted }

// RecoveryGrant is one recovery's share of the reserve. A grant's steps are
// serialized; the coordinator driving it owns the order.
//
// A grant stops, permanently, the first time a request exhausts an artifact's
// budget, a barrier write fails, or a destructive step fails. The allocator also
// stops every grant when it fail-stops. Nothing that follows a stop proceeds.
type RecoveryGrant struct {
	alloc *Allocator

	// step serializes WriteBarrier, RunDestructive, and Finish on this grant, so
	// a destructive step can never interleave with a failing barrier write.
	step sync.Mutex

	// Guarded by alloc.mu.
	used     [artifactCount]uint64
	stopErr  error
	finished bool
}

// Charge reserves n bytes of art from this grant's footprint, for output the
// caller writes itself. Prefer WriteBarrier, which charges and writes as one
// step.
func (g *RecoveryGrant) Charge(art Artifact, n uint64) error {
	g.step.Lock()
	defer g.step.Unlock()
	return g.charge(art, n)
}

// WriteBarrier charges len(data) bytes of art and durably writes data to path
// (temporary file, fsync, rename, directory fsync). Nothing is written when the
// charge is refused. A storage failure at any barrier position fail-stops the
// grant and the whole allocator, and the returned error still matches its cause
// (syscall.ENOSPC, syscall.EIO, ...).
func (g *RecoveryGrant) WriteBarrier(art Artifact, path string, data []byte) error {
	g.step.Lock()
	defer g.step.Unlock()

	if err := g.charge(art, uint64(len(data))); err != nil {
		return err
	}
	if err := writeBarrier(g.alloc.fs, path, data); err != nil {
		g.alloc.failStop(err)
		return err
	}
	return nil
}

// RunDestructive runs fn -- a delete, truncate, or other step that destroys
// data -- only if this grant and the allocator are still healthy. If fn fails,
// the grant and allocator fail-stop, so no later step builds on a destruction
// that may have half-happened.
//
// Health is necessary, not sufficient: whether the step is AUTHORIZED is the
// coverage proof's decision (task 2.28), and the caller must hold it first.
func (g *RecoveryGrant) RunDestructive(op string, fn func() error) error {
	g.step.Lock()
	defer g.step.Unlock()

	if err := g.healthy(); err != nil {
		return err
	}
	if err := fn(); err != nil {
		stop := &FailStopError{Op: op, Err: err}
		g.alloc.failStop(stop)
		return stop
	}
	return nil
}

// Finish ends a healthy recovery, returns its concurrency slot and reserve, and
// moves retained bytes -- output that stays on disk, such as the destination
// segment and journals kept until the recovery resolves -- into ordinary usage.
// A stopped grant cannot finish: its partial output is on disk, so its reserve
// stays held until the process restarts and re-measures.
func (g *RecoveryGrant) Finish(retained uint64) error {
	g.step.Lock()
	defer g.step.Unlock()

	a := g.alloc
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := g.healthyLocked(); err != nil {
		return err
	}
	if total := g.totalLocked(); retained > total {
		return fmt.Errorf("%w: retain %d, recovery wrote %d", ErrReleaseExceedsCharge, retained, total)
	}
	g.finished = true
	delete(a.active, g)
	sum, carry := bits.Add64(a.ordinaryUsed, retained, 0)
	if carry != 0 {
		sum = ^uint64(0)
	}
	a.ordinaryUsed = sum
	return nil
}

// Err returns the error that stopped this grant, or nil.
func (g *RecoveryGrant) Err() error {
	g.alloc.mu.Lock()
	defer g.alloc.mu.Unlock()
	return g.stopCauseLocked()
}

// Used returns the bytes of art this grant has charged.
func (g *RecoveryGrant) Used(art Artifact) uint64 {
	g.alloc.mu.Lock()
	defer g.alloc.mu.Unlock()
	if art >= artifactCount {
		return 0
	}
	return g.used[art]
}

func (g *RecoveryGrant) charge(art Artifact, n uint64) error {
	a := g.alloc
	a.mu.Lock()
	defer a.mu.Unlock()

	if err := g.healthyLocked(); err != nil {
		return err
	}
	if art >= artifactCount {
		return fmt.Errorf("%w: unknown %s", ErrInvalidAllocatorConfig, art)
	}
	remaining := a.budgets[art] - g.used[art]
	if n > remaining {
		exhausted := &ReserveExhaustedError{Artifact: art, Requested: n, Remaining: remaining}
		g.stopErr = exhausted
		return exhausted
	}
	g.used[art] += n
	return nil
}

func (g *RecoveryGrant) healthy() error {
	g.alloc.mu.Lock()
	defer g.alloc.mu.Unlock()
	return g.healthyLocked()
}

func (g *RecoveryGrant) healthyLocked() error {
	if g.finished {
		return ErrRecoveryFinished
	}
	if cause := g.stopCauseLocked(); cause != nil {
		return fmt.Errorf("%w: %w", ErrRecoveryStopped, cause)
	}
	return nil
}

// stopCauseLocked prefers the grant's own stop; an allocator fail-stop stops
// every grant.
func (g *RecoveryGrant) stopCauseLocked() error {
	if g.stopErr != nil {
		return g.stopErr
	}
	return g.alloc.failErr
}

func (g *RecoveryGrant) totalLocked() uint64 {
	var total uint64
	for _, n := range g.used {
		total += n
	}
	return total
}
