// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package recovery

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
)

// MaxJournalBytes bounds each copy, including its uncoarsened evidence, exact
// publication bodies and checksum. It does not replace the smaller wire limits.
const MaxJournalBytes = 1 << 20

const (
	journalMagic   = "SRRCFRZ1"
	journalVersion = 1
	journalHeader  = len(journalMagic) + 8
	copyA          = "freeze-a.journal"
	copyB          = "freeze-b.journal"
)

var (
	ErrJournalIncomplete = errors.New("recovery: matching durable journal copies required")
	ErrJournalCorrupt    = errors.New("recovery: corrupt freeze journal")
	ErrJournalVersion    = errors.New("recovery: unsupported freeze journal version")
	ErrJournalConflict   = errors.New("recovery: conflicting immutable freeze journals")
	ErrGrantRequired     = errors.New("recovery: reserved write grant required")
)

type frozenRecord struct {
	Plan     Plan
	Manifest Manifest
}

// Journal is an immutable, validated two-copy freeze. It grants no destructive
// authority: publication acknowledgements, committed copies, delete intents and
// consumer completion belong to a later durable phase log and coverage owner.
type Journal struct{ raw []byte }

// Snapshot returns fresh per-sequence evidence, independent of caller mutations.
func (j *Journal) Snapshot() (Plan, error) {
	if j == nil {
		return Plan{}, ErrJournalIncomplete
	}
	frozen, err := decodeJournal(j.raw)
	return frozen.Plan, err
}

// BuildManifest derives pages from reopened per-sequence evidence and checks
// them against the exact bytes frozen in the journal. It never signs anything.
func (j *Journal) BuildManifest() (Manifest, error) {
	if j == nil {
		return Manifest{}, ErrJournalIncomplete
	}
	frozen, err := decodeJournal(j.raw)
	if err != nil {
		return Manifest{}, err
	}
	return constructManifest(frozen.Plan)
}

// JournalBytes returns the exact bytes needed for ONE copy. Reserve both copies
// and every allowed repair rewrite (each charged in full), plus the independent
// phase, copy, page, mapping and filesystem-metadata budgets before Freeze.
func JournalBytes(plan Plan) (uint64, error) {
	raw, err := encodeJournal(plan)
	return uint64(len(raw)), err
}

// Freeze persists both copies before returning a usable Journal. dir must be an
// existing private recovery directory whose metadata the caller has durably
// created and budgeted. The coordinator serializes Freeze/Open/Repair for an ID.
// Existing valid evidence is immutable; interrupted freezes require Repair.
func Freeze(dir string, grant *spool.RecoveryGrant, plan Plan) (*Journal, error) {
	if err := usableGrant(grant); err != nil {
		return nil, err
	}
	raw, err := encodeJournal(plan)
	if err != nil {
		return nil, err
	}
	copies := readCopies(dir)
	for _, c := range copies {
		if c.err == nil && !bytes.Equal(c.raw, raw) {
			return nil, ErrJournalConflict
		}
	}
	if !errors.Is(copies[0].err, os.ErrNotExist) || !errors.Is(copies[1].err, os.ErrNotExist) {
		return openCopies(copies)
	}
	for i, name := range []string{copyA, copyB} {
		if err := grant.WriteBarrier(journalArtifact(i), filepath.Join(dir, name), raw); err != nil {
			return nil, err
		}
	}
	return Open(dir)
}

// Open accepts only two valid byte-identical copies. An intact single copy is
// repair evidence, never proof that the two-copy freeze barrier completed.
func Open(dir string) (*Journal, error) { return openCopies(readCopies(dir)) }

// Repair recreates a missing or corrupt copy from the EXACT intact bytes. It
// never chooses between valid conflicting copies, guesses an unsupported format,
// or treats a filesystem read failure as corruption. No source data is touched.
func Repair(dir string, grant *spool.RecoveryGrant) (*Journal, error) {
	if err := usableGrant(grant); err != nil {
		return nil, err
	}
	copies := readCopies(dir)
	if copies[0].err == nil && copies[1].err == nil {
		return openCopies(copies)
	}
	valid, damaged := 0, 1
	if copies[0].err != nil {
		valid, damaged = 1, 0
	}
	if copies[valid].err != nil {
		return nil, errors.Join(ErrJournalIncomplete, copies[0].err, copies[1].err)
	}
	err := copies[damaged].err
	if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, ErrJournalCorrupt) {
		return nil, errors.Join(ErrJournalIncomplete, err)
	}
	name := copyA
	if damaged == 1 {
		name = copyB
	}
	if err := grant.WriteBarrier(journalArtifact(damaged), filepath.Join(dir, name), copies[valid].raw); err != nil {
		return nil, err
	}
	return Open(dir)
}

func usableGrant(grant *spool.RecoveryGrant) error {
	if grant == nil {
		return ErrGrantRequired
	}
	return grant.Err()
}

func journalArtifact(index int) spool.Artifact {
	if index == 0 {
		return spool.ArtifactJournalA
	}
	return spool.ArtifactJournalB
}

type journalCopy struct {
	raw []byte
	err error
}

func readCopies(dir string) [2]journalCopy {
	var copies [2]journalCopy
	for i, name := range []string{copyA, copyB} {
		copies[i].raw, copies[i].err = readCopy(filepath.Join(dir, name))
	}
	return copies
}

func readCopy(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	raw, err := io.ReadAll(io.LimitReader(f, MaxJournalBytes+1))
	if err != nil {
		return nil, err
	}
	_, err = decodeJournal(raw)
	return raw, err
}

func openCopies(copies [2]journalCopy) (*Journal, error) {
	if copies[0].err != nil || copies[1].err != nil {
		return nil, errors.Join(ErrJournalIncomplete, copies[0].err, copies[1].err)
	}
	if !bytes.Equal(copies[0].raw, copies[1].raw) {
		return nil, ErrJournalConflict
	}
	return &Journal{raw: copies[0].raw}, nil
}

func encodeJournal(plan Plan) ([]byte, error) {
	if err := validatePlan(plan); err != nil {
		return nil, err
	}
	manifest, err := constructManifest(plan)
	if errors.Is(err, edgerecord.ErrManifestBounds) {
		return nil, errors.Join(ErrSplitRequired, err)
	}
	if err != nil {
		return nil, err
	}
	payload, err := json.Marshal(frozenRecord{Plan: plan, Manifest: manifest})
	if err != nil {
		return nil, err
	}
	if len(payload)+journalHeader+sha256.Size > MaxJournalBytes {
		return nil, ErrSplitRequired
	}
	raw := make([]byte, journalHeader, journalHeader+len(payload)+sha256.Size)
	copy(raw, journalMagic)
	binary.BigEndian.PutUint64(raw[len(journalMagic):], journalVersion)
	raw = append(raw, payload...)
	sum := sha256.Sum256(raw)
	return append(raw, sum[:]...), nil
}

func decodeJournal(raw []byte) (frozenRecord, error) {
	var frozen frozenRecord
	if len(raw) < journalHeader+sha256.Size || len(raw) > MaxJournalBytes || string(raw[:len(journalMagic)]) != journalMagic {
		return frozen, ErrJournalCorrupt
	}
	if binary.BigEndian.Uint64(raw[len(journalMagic):journalHeader]) != journalVersion {
		return frozen, ErrJournalVersion
	}
	end := len(raw) - sha256.Size
	sum := sha256.Sum256(raw[:end])
	if !bytes.Equal(sum[:], raw[end:]) {
		return frozen, ErrJournalCorrupt
	}
	if err := decodeJSON(raw[journalHeader:end], &frozen); err != nil {
		return frozen, fmt.Errorf("%w: %v", ErrJournalCorrupt, err)
	}
	if err := validatePlan(frozen.Plan); err != nil {
		return frozen, fmt.Errorf("%w: %v", ErrJournalCorrupt, err)
	}
	manifest, err := constructManifest(frozen.Plan)
	if err != nil || !equalManifest(manifest, frozen.Manifest) {
		return frozen, ErrJournalCorrupt
	}
	// Only this version's canonical storage encoding may claim an immutable ID.
	canonical, err := json.Marshal(frozen)
	if err != nil || !bytes.Equal(canonical, raw[journalHeader:end]) {
		return frozen, ErrJournalCorrupt
	}
	return frozen, nil
}
