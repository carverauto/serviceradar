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
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
)

type recoveryDestinationKey struct {
	id      string
	attempt uint32
}

const recoveryDestinationSuffix = ".recovery"

const recoveryDestinationFile = "recovery-destination"
const recoveryDestinationMagic = "SRDEST01"

// Directory identifies immutable storage for retained-generation inventory.
// Returning it does not authorize a commit or deletion.
func (g *Generation) Directory() string { return g.dir }

// RecoveryID identifies a dedicated relocation destination, or is nil for an
// ordinary generation. The returned bytes are independent of the handle.
func (g *Generation) RecoveryID() []byte { return bytes.Clone(g.recoveryID) }

// RecoveryAttempt distinguishes a control-publication retry within one operation.
func (g *Generation) RecoveryAttempt() uint32 { return g.recoveryAttempt }

// CommitRelocated appends only to an operation's dedicated, still-open
// destination. The storage commit independently checks the source witness and
// grant; this facade only owns generation lifetime and producer exclusion.
func (g *Generation) CommitRelocated(source CommittedAttribution, grant *RecoveryGrant) (Receipt, error) {
	g.lifecycle.Lock()
	defer g.lifecycle.Unlock()
	if g.shut {
		return Receipt{}, ErrLaneSetClosed
	}
	if len(g.recoveryID) == 0 || g.Closed() {
		return Receipt{}, ErrRotationRequired
	}
	r, err := g.spool.CommitRelocated(source, grant)
	if err != nil {
		return Receipt{}, err
	}
	return Receipt{Generation: g.id.clone(), Sequence: r.Sequence}, nil
}

// SealRecoveryDestination freezes its high-water mark permanently. The marker is
// durable before descriptors close; recovery can still read and resolve it.
func (g *Generation) SealRecoveryDestination() error {
	g.lifecycle.Lock()
	defer g.lifecycle.Unlock()
	if g.shut {
		return ErrLaneSetClosed
	}
	if len(g.recoveryID) == 0 {
		return ErrAttributionRequired
	}
	if g.Closed() {
		return nil
	}
	if err := writeClosedMarker(g.dir); err != nil {
		return err
	}
	g.closed.Store(true)
	return g.spool.Close()
}

func encodeRecoveryDestination(id GenerationIdentity, recoveryID []byte, attempt uint32) []byte {
	b := append([]byte(recoveryDestinationMagic), recoveryID...)
	b = binary.BigEndian.AppendUint32(b, attempt)
	digest := sha256.Sum256(append(encodeIdentity(id), b...))
	return append(b, digest[:]...)
}

func writeRecoveryDestination(dir string, id GenerationIdentity, recoveryID []byte, attempt uint32) error {
	b := encodeRecoveryDestination(id, recoveryID, attempt)
	path := filepath.Join(dir, recoveryDestinationFile)
	if err := os.WriteFile(path, b, filePerm); err != nil {
		return err
	}
	return fsyncFile(path)
}

func readRecoveryDestination(dir string, id GenerationIdentity) ([]byte, uint32, error) {
	b, err := os.ReadFile(filepath.Join(dir, recoveryDestinationFile))
	if errors.Is(err, os.ErrNotExist) {
		return nil, 0, nil
	}
	if err != nil {
		return nil, 0, err
	}
	if len(b) != 60 || string(b[:8]) != recoveryDestinationMagic || edgerecord.ValidateUUIDv7(b[8:24]) != nil {
		return nil, 0, fmt.Errorf("%w: invalid recovery destination marker", ErrCorruptGeneration)
	}
	digest := sha256.Sum256(append(encodeIdentity(id), b[:28]...))
	if !bytes.Equal(digest[:], b[28:]) {
		return nil, 0, fmt.Errorf("%w: recovery destination identity mismatch", ErrCorruptGeneration)
	}
	return bytes.Clone(b[8:24]), binary.BigEndian.Uint32(b[24:28]), nil
}

// withOpen serializes a generation operation with closure. Closed generations
// borrow descriptors for one operation, preserving the same spool/allocator
// ownership and cached prefix; no second spool handle or capacity ledger exists.
// A scan callback must not recursively invoke another generation I/O operation.
func (g *Generation) withOpen(fn func(*Spool) error) (err error) {
	g.lifecycle.Lock()
	defer g.lifecycle.Unlock()
	if g.shut {
		return ErrLaneSetClosed
	}
	if !g.Closed() {
		return fn(g.spool)
	}
	s := g.spool
	s.mu.Lock()
	err = s.refreshLayout()
	if err == nil && s.seg == nil {
		s.seg, err = os.OpenFile(s.segmentPath(), os.O_RDWR, filePerm)
	}
	s.mu.Unlock()
	defer func() { err = errors.Join(err, s.Close()) }()
	if err != nil {
		return err
	}
	return fn(s)
}

func (g *Generation) shutdown() error {
	g.lifecycle.Lock()
	defer g.lifecycle.Unlock()
	g.shut = true
	return g.spool.Close()
}

// ResolveWithEvidence uses the same terminal-proof and recovery-hold boundary as
// an open spool, including when this generation has already been rotated.
func (g *Generation) ResolveWithEvidence(through uint64, evidence []byte) error {
	return g.withOpen(func(s *Spool) error { return s.ResolveWithEvidence(through, evidence) })
}

func (g *Generation) ReclaimResolved() error {
	return g.withOpen(func(s *Spool) error { return s.ReclaimResolved() })
}

func (g *Generation) Health(now time.Time) (Health, error) {
	var health Health
	err := g.withOpen(func(s *Spool) (err error) { health, err = s.Health(now); return err })
	return health, err
}

func (g *Generation) CoverageGap(sequence uint64) (SlotResolution, bool) {
	return g.spool.CoverageGap(sequence)
}

func (g *Generation) RestartResolution() Resolution { return g.spool.RestartResolution() }

// MaxGenerationPage bounds handle snapshots used by sender and coordinator loops.
const MaxGenerationPage = 64

// GenerationsPage returns at most limit handles after the lane-local ordinal.
// It includes closed, open and dedicated recovery generations, in ordinal order.
// Callers retain an ordinal cursor, not a slice of every generation. Inventory
// may change between pages; a later generation will appear after the cursor.
func (ls *LaneSet) GenerationsPage(key LaneKey, after uint64, limit int) []*Generation {
	if limit <= 0 {
		return nil
	}
	limit = min(limit, MaxGenerationPage)
	l := ls.existingLane(key)
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]*Generation, 0, limit)
	include := func(g *Generation) {
		if g == nil || g.id.Ordinal <= after {
			return
		}
		i := 0
		for i < len(out) && out[i].id.Ordinal < g.id.Ordinal {
			i++
		}
		if i == limit {
			return
		}
		if len(out) < limit {
			out = append(out, nil)
		}
		copy(out[i+1:], out[i:len(out)-1])
		out[i] = g
	}
	start := sort.Search(len(l.retained), func(i int) bool { return l.retained[i].id.Ordinal > after })
	for _, g := range l.retained[start:min(start+limit, len(l.retained))] {
		include(g)
	}
	include(l.open)
	return out
}

// retain keeps the ordinal index ordered at generation creation/closure, so a
// sender page never scans every retained generation while holding the lane lock.
func (l *lane) retain(g *Generation) {
	i := sort.Search(len(l.retained), func(i int) bool { return l.retained[i].id.Ordinal >= g.id.Ordinal })
	l.retained = append(l.retained, nil)
	copy(l.retained[i+1:], l.retained[i:len(l.retained)-1])
	l.retained[i] = g
}
