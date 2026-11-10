// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

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
)

// MaxRecoveryJournalBytes bounds each copy, including its uncoarsened evidence, exact
// publication bodies and checksum. It does not replace the smaller wire limits.
const MaxRecoveryJournalBytes = 1 << 20

const (
	recoveryJournalMagic   = "SRRCFRZ1"
	recoveryJournalVersion = 1
	recoveryJournalHeader  = len(recoveryJournalMagic) + 8
	recoveryCopyA          = "freeze-a.journal"
	recoveryCopyB          = "freeze-b.journal"
)

var (
	ErrRecoveryJournalIncomplete = errors.New("recovery: matching durable journal copies required")
	ErrRecoveryJournalCorrupt    = errors.New("recovery: corrupt freeze journal")
	ErrRecoveryJournalVersion    = errors.New("recovery: unsupported freeze journal version")
	ErrRecoveryJournalConflict   = errors.New("recovery: conflicting immutable freeze journals")
	ErrRecoveryGrantRequired     = errors.New("recovery: reserved write grant required")
)

type frozenRecoveryRecord struct {
	Plan     RecoveryPlan
	Manifest RecoveryManifest
}

// RecoveryJournal is an immutable, validated two-copy freeze. It grants no destructive
// authority: publication acknowledgements, committed copies, delete intents and
// consumer completion belong to a later durable phase log and coverage owner.
type RecoveryJournal struct{ raw []byte }

// FrozenPlan returns fresh per-sequence evidence, independent of caller mutations.
func (j *RecoveryJournal) FrozenPlan() (RecoveryPlan, error) {
	if j == nil {
		return RecoveryPlan{}, ErrRecoveryJournalIncomplete
	}
	reopenedRecoveryJournal, err := decodeRecoveryJournal(j.raw)
	return reopenedRecoveryJournal.Plan, err
}

// BuildManifest derives pages from reopened per-sequence evidence and checks
// them against the exact bytes frozen in the journal. It never signs anything.
func (j *RecoveryJournal) BuildManifest() (RecoveryManifest, error) {
	if j == nil {
		return RecoveryManifest{}, ErrRecoveryJournalIncomplete
	}
	reopenedRecoveryJournal, err := decodeRecoveryJournal(j.raw)
	if err != nil {
		return RecoveryManifest{}, err
	}
	return constructRecoveryManifest(reopenedRecoveryJournal.Plan)
}

// RecoveryJournalBytes returns the exact bytes needed for ONE copy. Reserve both copies
// and every allowed repair rewrite (each charged in full), plus the independent
// phase, copy, page, mapping and filesystem-metadata budgets before FreezeRecovery.
func RecoveryJournalBytes(recoveryPlan RecoveryPlan) (uint64, error) {
	raw, err := encodeRecoveryJournal(recoveryPlan)
	return uint64(len(raw)), err
}

// FreezeRecovery persists both copies before returning a usable Journal. dir must be an
// existing private recovery directory whose metadata the caller has durably
// created and budgeted. The coordinator serializes FreezeRecovery/OpenRecoveryJournal/RepairRecoveryJournal for an ID.
// Existing valid evidence is immutable; interrupted freezes require RepairRecoveryJournal.
func FreezeRecovery(dir string, recoveryGrant *RecoveryGrant, recoveryPlan RecoveryPlan) (*RecoveryJournal, error) {
	if err := usableRecoveryGrant(recoveryGrant); err != nil {
		return nil, err
	}
	raw, err := encodeRecoveryJournal(recoveryPlan)
	if err != nil {
		return nil, err
	}
	copies := readRecoveryJournalCopies(dir)
	for _, c := range copies {
		if c.err == nil && !bytes.Equal(c.raw, raw) {
			return nil, ErrRecoveryJournalConflict
		}
	}
	if !errors.Is(copies[0].err, os.ErrNotExist) || !errors.Is(copies[1].err, os.ErrNotExist) {
		return openRecoveryJournalCopies(copies)
	}
	for i, name := range []string{recoveryCopyA, recoveryCopyB} {
		if err := recoveryGrant.WriteBarrier(recoveryJournalArtifact(i), filepath.Join(dir, name), raw); err != nil {
			return nil, err
		}
	}
	return OpenRecoveryJournal(dir)
}

// OpenRecoveryJournal accepts only two valid byte-identical copies. An intact single copy is
// repair evidence, never proof that the two-copy freeze barrier completed.
func OpenRecoveryJournal(dir string) (*RecoveryJournal, error) {
	return openRecoveryJournalCopies(readRecoveryJournalCopies(dir))
}

// RepairRecoveryJournal recreates a missing or corrupt copy from the EXACT intact bytes. It
// never chooses between valid conflicting copies, guesses an unsupported format,
// or treats a filesystem read failure as corruption. No source data is touched.
func RepairRecoveryJournal(dir string, recoveryGrant *RecoveryGrant) (*RecoveryJournal, error) {
	if err := usableRecoveryGrant(recoveryGrant); err != nil {
		return nil, err
	}
	copies := readRecoveryJournalCopies(dir)
	if copies[0].err == nil && copies[1].err == nil {
		return openRecoveryJournalCopies(copies)
	}
	valid, damaged := 0, 1
	if copies[0].err != nil {
		valid, damaged = 1, 0
	}
	if copies[valid].err != nil {
		return nil, errors.Join(ErrRecoveryJournalIncomplete, copies[0].err, copies[1].err)
	}
	err := copies[damaged].err
	if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, ErrRecoveryJournalCorrupt) {
		return nil, errors.Join(ErrRecoveryJournalIncomplete, err)
	}
	name := recoveryCopyA
	if damaged == 1 {
		name = recoveryCopyB
	}
	if err := recoveryGrant.WriteBarrier(recoveryJournalArtifact(damaged), filepath.Join(dir, name), copies[valid].raw); err != nil {
		return nil, err
	}
	return OpenRecoveryJournal(dir)
}

func usableRecoveryGrant(recoveryGrant *RecoveryGrant) error {
	if recoveryGrant == nil {
		return ErrRecoveryGrantRequired
	}
	return recoveryGrant.Err()
}

func recoveryJournalArtifact(index int) Artifact {
	if index == 0 {
		return ArtifactJournalA
	}
	return ArtifactJournalB
}

type recoveryJournalCopy struct {
	raw []byte
	err error
}

func readRecoveryJournalCopies(dir string) [2]recoveryJournalCopy {
	var copies [2]recoveryJournalCopy
	for i, name := range []string{recoveryCopyA, recoveryCopyB} {
		copies[i].raw, copies[i].err = readRecoveryJournalCopy(filepath.Join(dir, name))
	}
	return copies
}

func readRecoveryJournalCopy(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	raw, err := io.ReadAll(io.LimitReader(f, MaxRecoveryJournalBytes+1))
	if err != nil {
		return nil, err
	}
	_, err = decodeRecoveryJournal(raw)
	return raw, err
}

func openRecoveryJournalCopies(copies [2]recoveryJournalCopy) (*RecoveryJournal, error) {
	if copies[0].err != nil || copies[1].err != nil {
		return nil, errors.Join(ErrRecoveryJournalIncomplete, copies[0].err, copies[1].err)
	}
	if !bytes.Equal(copies[0].raw, copies[1].raw) {
		return nil, ErrRecoveryJournalConflict
	}
	return &RecoveryJournal{raw: copies[0].raw}, nil
}

func encodeRecoveryJournal(recoveryPlan RecoveryPlan) ([]byte, error) {
	if err := validateRecoveryPlan(recoveryPlan); err != nil {
		return nil, err
	}
	manifest, err := constructRecoveryManifest(recoveryPlan)
	if errors.Is(err, edgerecord.ErrManifestBounds) {
		return nil, errors.Join(ErrRecoverySplitRequired, err)
	}
	if err != nil {
		return nil, err
	}
	payload, err := json.Marshal(frozenRecoveryRecord{Plan: recoveryPlan, Manifest: manifest})
	if err != nil {
		return nil, err
	}
	if len(payload)+recoveryJournalHeader+sha256.Size > MaxRecoveryJournalBytes {
		return nil, ErrRecoverySplitRequired
	}
	raw := make([]byte, recoveryJournalHeader, recoveryJournalHeader+len(payload)+sha256.Size)
	copy(raw, recoveryJournalMagic)
	binary.BigEndian.PutUint64(raw[len(recoveryJournalMagic):], recoveryJournalVersion)
	raw = append(raw, payload...)
	sum := sha256.Sum256(raw)
	return append(raw, sum[:]...), nil
}

func decodeRecoveryJournal(raw []byte) (frozenRecoveryRecord, error) {
	var reopenedRecoveryJournal frozenRecoveryRecord
	if len(raw) < recoveryJournalHeader+sha256.Size || len(raw) > MaxRecoveryJournalBytes || string(raw[:len(recoveryJournalMagic)]) != recoveryJournalMagic {
		return reopenedRecoveryJournal, ErrRecoveryJournalCorrupt
	}
	if binary.BigEndian.Uint64(raw[len(recoveryJournalMagic):recoveryJournalHeader]) != recoveryJournalVersion {
		return reopenedRecoveryJournal, ErrRecoveryJournalVersion
	}
	end := len(raw) - sha256.Size
	sum := sha256.Sum256(raw[:end])
	if !bytes.Equal(sum[:], raw[end:]) {
		return reopenedRecoveryJournal, ErrRecoveryJournalCorrupt
	}
	if err := decodeRecoveryJSON(raw[recoveryJournalHeader:end], &reopenedRecoveryJournal); err != nil {
		return reopenedRecoveryJournal, fmt.Errorf("%w: %s", ErrRecoveryJournalCorrupt, err.Error())
	}
	if err := validateRecoveryPlan(reopenedRecoveryJournal.Plan); err != nil {
		return reopenedRecoveryJournal, fmt.Errorf("%w: %s", ErrRecoveryJournalCorrupt, err.Error())
	}
	manifest, err := constructRecoveryManifest(reopenedRecoveryJournal.Plan)
	if err != nil || !equalRecoveryManifest(manifest, reopenedRecoveryJournal.Manifest) {
		return reopenedRecoveryJournal, ErrRecoveryJournalCorrupt
	}
	// Only this version's canonical storage encoding may claim an immutable ID.
	canonical, err := json.Marshal(reopenedRecoveryJournal)
	if err != nil || !bytes.Equal(canonical, raw[recoveryJournalHeader:end]) {
		return reopenedRecoveryJournal, ErrRecoveryJournalCorrupt
	}
	return reopenedRecoveryJournal, nil
}
