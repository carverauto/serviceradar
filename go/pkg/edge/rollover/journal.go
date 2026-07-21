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
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// Phase is the durable phase of a spool rollover. It only ever advances; a
// restart resumes at the last phase written durably.
type Phase uint8

const (
	// PhaseNone means no rollover is in progress.
	PhaseNone Phase = iota
	// PhaseStarted: the recovery id and new spool id are allocated.
	PhaseStarted
	// PhaseManifestDurable: the bounded loss manifest is fsynced.
	PhaseManifestDurable
	// PhaseCopying: old->new segment copy is under way; CopyWatermark advances.
	PhaseCopying
	// PhaseNewSpoolActive: the new spool is the active delivery lane.
	PhaseNewSpoolActive
	// PhaseResolved: a signed, consumer-committed resolution is durable; the
	// journal may be retired.
	PhaseResolved
)

// State is the persisted rollover state. It is written atomically on every
// advance so a crash leaves either the prior or the new complete state.
type State struct {
	RecoveryID     []byte `json:"recovery_id"`
	PriorSpoolID   []byte `json:"prior_spool_id"`
	NewSpoolID     []byte `json:"new_spool_id"`
	Phase          Phase  `json:"phase"`
	CopyWatermark  uint64 `json:"copy_watermark"`
	ManifestSHA256 []byte `json:"manifest_sha256"`
	Coarsened      bool   `json:"coarsened"`
}

var (
	// ErrPhaseRegression is returned when an advance would move the phase
	// backward.
	ErrPhaseRegression = errors.New("rollover: phase cannot regress")
	// ErrWatermarkRegression is returned when a copy watermark would move
	// backward.
	ErrWatermarkRegression = errors.New("rollover: copy watermark cannot regress")
	// ErrCorruptJournal is returned when the journal file fails its checksum.
	ErrCorruptJournal = errors.New("rollover: corrupt journal")
	// ErrCopyIncomplete is returned when activation is attempted before the
	// durable copy watermark has reached the required copy-completion point. The
	// new spool must not become active while recoverable records remain uncopied
	// in the old spool.
	ErrCopyIncomplete = errors.New("rollover: copy not complete before activation")
)

// Journal is a crash-safe rollover phase journal backed by a single file that is
// rewritten atomically (temp write + fsync + rename + directory fsync) on every
// advance. Not safe for concurrent use.
type Journal struct {
	dir   string
	path  string
	state State
}

const journalFile = "rollover.journal"

// Open loads an existing journal from dir or returns an empty PhaseNone journal.
// The directory is created 0700 if absent.
func Open(dir string) (*Journal, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	j := &Journal{dir: dir, path: filepath.Join(dir, journalFile)}
	st, ok, err := readState(j.path)
	if err != nil {
		return nil, err
	}
	if ok {
		j.state = st
	}
	return j, nil
}

// State returns a copy of the current durable state.
func (j *Journal) State() State { return j.state }

// Begin records the start of a rollover. It is valid only from PhaseNone.
func (j *Journal) Begin(recoveryID, priorSpoolID, newSpoolID []byte) error {
	if j.state.Phase != PhaseNone {
		return fmt.Errorf("%w: begin from phase %d", ErrPhaseRegression, j.state.Phase)
	}
	next := State{
		RecoveryID:   recoveryID,
		PriorSpoolID: priorSpoolID,
		NewSpoolID:   newSpoolID,
		Phase:        PhaseStarted,
	}
	return j.commit(next)
}

// SetManifest records the durable loss manifest and advances to
// PhaseManifestDurable.
func (j *Journal) SetManifest(manifestSHA256 []byte, coarsened bool) error {
	if j.state.Phase != PhaseStarted {
		return fmt.Errorf("%w: set-manifest from phase %d", ErrPhaseRegression, j.state.Phase)
	}
	next := j.state
	next.Phase = PhaseManifestDurable
	next.ManifestSHA256 = manifestSHA256
	next.Coarsened = coarsened
	return j.commit(next)
}

// AdvanceCopy records a monotonically increasing old->new copy watermark. The
// first call moves the phase to PhaseCopying.
func (j *Journal) AdvanceCopy(watermark uint64) error {
	if j.state.Phase != PhaseManifestDurable && j.state.Phase != PhaseCopying {
		return fmt.Errorf("%w: advance-copy from phase %d", ErrPhaseRegression, j.state.Phase)
	}
	if watermark < j.state.CopyWatermark {
		return fmt.Errorf("%w: %d < %d", ErrWatermarkRegression, watermark, j.state.CopyWatermark)
	}
	next := j.state
	next.Phase = PhaseCopying
	next.CopyWatermark = watermark
	return j.commit(next)
}

// Activate marks the new spool as the active delivery lane. It is valid only
// from PhaseCopying (the segment-copy layer must have started and durably
// recorded its progress), and the durable copy watermark must have reached
// requiredCopyThrough -- the copy-completion point the segment-copy layer
// supplies. A rollover with nothing to recover still passes through PhaseCopying
// via AdvanceCopy(0) and activates with requiredCopyThrough == 0; a rollover with
// records to copy cannot activate until they are durably copied, so no readable
// record is stranded in the old spool.
func (j *Journal) Activate(requiredCopyThrough uint64) error {
	if j.state.Phase != PhaseCopying {
		return fmt.Errorf("%w: activate from phase %d (must be PhaseCopying)", ErrPhaseRegression, j.state.Phase)
	}
	if j.state.CopyWatermark < requiredCopyThrough {
		return fmt.Errorf("%w: copy watermark %d < required %d", ErrCopyIncomplete,
			j.state.CopyWatermark, requiredCopyThrough)
	}
	next := j.state
	next.Phase = PhaseNewSpoolActive
	return j.commit(next)
}

// Resolve records that a signed, consumer-committed resolution is durable.
func (j *Journal) Resolve() error {
	if j.state.Phase != PhaseNewSpoolActive {
		return fmt.Errorf("%w: resolve from phase %d", ErrPhaseRegression, j.state.Phase)
	}
	next := j.state
	next.Phase = PhaseResolved
	return j.commit(next)
}

// commit atomically persists next and updates the in-memory state only on
// success.
func (j *Journal) commit(next State) error {
	if err := writeStateAtomic(j.dir, j.path, next); err != nil {
		return err
	}
	j.state = next
	return nil
}

// --- persistence: length+payload+sha256, atomic rename, dir fsync ---

func writeStateAtomic(dir, path string, st State) error {
	payload, err := json.Marshal(st)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(payload)
	buf := make([]byte, 4+len(payload)+len(sum))
	binary.BigEndian.PutUint32(buf[0:4], uint32(len(payload)))
	copy(buf[4:], payload)
	copy(buf[4+len(payload):], sum[:])

	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(buf); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	return fsyncDir(dir)
}

func readState(path string) (State, bool, error) {
	buf, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return State{}, false, nil
		}
		return State{}, false, err
	}
	if len(buf) < 4+sha256.Size {
		return State{}, false, ErrCorruptJournal
	}
	n := binary.BigEndian.Uint32(buf[0:4])
	if int(n) != len(buf)-4-sha256.Size {
		return State{}, false, ErrCorruptJournal
	}
	payload := buf[4 : 4+n]
	want := buf[4+n:]
	got := sha256.Sum256(payload)
	if !equalBytes(got[:], want) {
		return State{}, false, ErrCorruptJournal
	}
	var st State
	if err := json.Unmarshal(payload, &st); err != nil {
		return State{}, false, ErrCorruptJournal
	}
	return st, true, nil
}

func fsyncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer func() { _ = d.Close() }()
	return d.Sync()
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
