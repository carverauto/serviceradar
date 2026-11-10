// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const recoveryPhaseMagic = "SRRCPHS1"
const recoveryPhaseOverhead = 8 + 32 + 32 + 4 + 32
const maxRecoveryPhases = 64

// Phase keys shared by the completion and coverage owners.
const (
	recoveryPhaseCompleted = "completed"
	recoveryPhaseCoverage  = "coverage"
)

// Phase records are immutable pairs, independently bound to the complete freeze
// journal and a typed step name. A later record never replaces or proves an
// earlier barrier. Only the operation owner writes the private step names.
func encodeRecoveryPhase(frozen [32]byte, key string, payload []byte) ([]byte, error) {
	if !validRecoveryPhaseKey(key) && key != "completion" && key != recoveryPhaseCompleted {
		return nil, ErrRecoveryPlan
	}
	limit := maxRecoveryMetadataPhaseBytes
	if key == "completion" || key == recoveryPhaseCompleted {
		limit = maxRecoveryCompletionBytes
	}
	if strings.HasPrefix(key, "publications-") {
		limit = maxRecoveryPublicationBundleBytes
	}
	if key == recoveryPhaseCoverage {
		limit = maxRecoveryCoverageBytes
	}
	if len(payload) > limit {
		return nil, ErrRecoverySplitRequired
	}
	raw := append([]byte(recoveryPhaseMagic), frozen[:]...)
	kind := sha256.Sum256([]byte(key))
	raw = append(raw, kind[:]...)
	raw = binary.BigEndian.AppendUint32(raw, uint32(len(payload)))
	raw = append(raw, payload...)
	sum := sha256.Sum256(raw)
	return append(raw, sum[:]...), nil
}

func decodeRecoveryPhase(raw []byte, frozen [32]byte, key string) ([]byte, error) {
	if len(raw) < recoveryPhaseOverhead || len(raw) > MaxRecoveryPhaseBytes || string(raw[:8]) != recoveryPhaseMagic {
		return nil, ErrRecoveryJournalCorrupt
	}
	kind := sha256.Sum256([]byte(key))
	if !bytes.Equal(raw[8:40], frozen[:]) || !bytes.Equal(raw[40:72], kind[:]) || int(binary.BigEndian.Uint32(raw[72:76])) != len(raw)-recoveryPhaseOverhead {
		return nil, ErrRecoveryJournalConflict
	}
	end := len(raw) - sha256.Size
	sum := sha256.Sum256(raw[:end])
	if !bytes.Equal(raw[end:], sum[:]) {
		return nil, ErrRecoveryJournalCorrupt
	}
	return bytes.Clone(raw[76:end]), nil
}

func recoveryPhasePath(dir, key string, copy int) string {
	return filepath.Join(dir, fmt.Sprintf("phase-%s-%c", key, 'a'+copy))
}

func readRecoveryPhaseCopy(path string, frozen [32]byte, key string) recoveryJournalCopy {
	f, err := os.Open(path)
	if err != nil {
		return recoveryJournalCopy{err: err}
	}
	defer func() { _ = f.Close() }()
	raw, err := io.ReadAll(io.LimitReader(f, MaxRecoveryPhaseBytes+1))
	if err != nil {
		return recoveryJournalCopy{err: err}
	}
	_, err = decodeRecoveryPhase(raw, frozen, key)
	return recoveryJournalCopy{raw: raw, err: err}
}

func readRecoveryPhase(dir, key string, frozen [32]byte) ([]byte, error) {
	a := readRecoveryPhaseCopy(recoveryPhasePath(dir, key, 0), frozen, key)
	b := readRecoveryPhaseCopy(recoveryPhasePath(dir, key, 1), frozen, key)
	if a.err != nil || b.err != nil {
		return nil, errors.Join(ErrRecoveryJournalIncomplete, a.err, b.err)
	}
	if !bytes.Equal(a.raw, b.raw) {
		return nil, ErrRecoveryJournalConflict
	}
	return decodeRecoveryPhase(a.raw, frozen, key)
}

func writeRecoveryPhase(dir, key string, frozen [32]byte, payload []byte, grant *RecoveryGrant) error {
	if err := usableRecoveryGrant(grant); err != nil {
		return err
	}
	raw, err := encodeRecoveryPhase(frozen, key, payload)
	if err != nil {
		return err
	}
	a := readRecoveryPhaseCopy(recoveryPhasePath(dir, key, 0), frozen, key)
	b := readRecoveryPhaseCopy(recoveryPhasePath(dir, key, 1), frozen, key)
	if a.err == nil && b.err == nil {
		if bytes.Equal(a.raw, raw) && bytes.Equal(b.raw, raw) {
			return nil
		}
		return ErrRecoveryJournalConflict
	}
	if !errors.Is(a.err, os.ErrNotExist) || !errors.Is(b.err, os.ErrNotExist) {
		return errors.Join(ErrRecoveryJournalIncomplete, a.err, b.err)
	}
	if err = checkRecoveryPhaseBudget(dir, uint64(len(raw))); err != nil {
		return err
	}
	for c := range 2 {
		if err = grant.WriteBarrier(recoveryPhaseArtifact(key, c), recoveryPhasePath(dir, key, c), raw); err != nil {
			return err
		}
	}
	_, err = readRecoveryPhase(dir, key, frozen)
	return err
}

func recoveryPhaseEntries(dir string) ([]os.DirEntry, error) {
	f, err := os.Open(dir)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	entries, err := f.ReadDir(2*maxRecoveryPhases + 9)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	if len(entries) > 2*maxRecoveryPhases+8 {
		return nil, ErrRecoverySplitRequired
	}
	return entries, nil
}

func checkRecoveryPhaseBudget(dir string, added uint64) error {
	entries, err := recoveryPhaseEntries(dir)
	if err != nil {
		return err
	}
	var used [2]uint64
	var records [2]int
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "phase-") {
			continue
		}
		copy := 0
		if strings.HasSuffix(name, "-b") {
			copy = 1
		} else if !strings.HasSuffix(name, "-a") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > MaxRecoveryPhaseBytes {
			return ErrRecoveryJournalCorrupt
		}
		used[copy] += uint64(info.Size())
		records[copy]++
		if added > 0 && records[copy] >= maxRecoveryPhases {
			return ErrRecoverySplitRequired
		}
	}
	for _, n := range used {
		if n > MaxRecoveryPhaseBytes || added > MaxRecoveryPhaseBytes-n {
			return ErrRecoverySplitRequired
		}
	}
	return nil
}

// RepairRecoveryPhases only recreates exact intact immutable phase bytes. It
// does not validate progress or authorize deletion; operation replay still reads
// every prerequisite pair and checks its typed payload. The caller serializes
// repair with operation work and resumes all retained artifacts into the grant.
func RepairRecoveryPhases(dir string, grant *RecoveryGrant) error {
	if err := usableRecoveryGrant(grant); err != nil {
		return err
	}
	journal, err := OpenRecoveryJournal(dir)
	if err != nil {
		return err
	}
	frozen := sha256.Sum256(journal.raw)
	if err = checkRecoveryPhaseBudget(dir, 0); err != nil {
		return err
	}
	entries, err := recoveryPhaseEntries(dir)
	if err != nil {
		return err
	}
	keys := map[string]bool{}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "phase-") || (!strings.HasSuffix(name, "-a") && !strings.HasSuffix(name, "-b")) {
			continue
		}
		key := name[len("phase-") : len(name)-2]
		if !validRecoveryPhaseKey(key) {
			return ErrRecoveryJournalCorrupt
		}
		keys[key] = true
	}
	if len(keys) > maxRecoveryPhases {
		return ErrRecoverySplitRequired
	}
	ordered := make([]string, 0, len(keys))
	for key := range keys {
		ordered = append(ordered, key)
	}
	sort.Strings(ordered)
	var logical uint64
	// Preflight the union, not each surviving copy separately. Disjoint torn
	// pairs cannot repair into an aggregate larger than the phase bound.
	for _, key := range ordered {
		a := readRecoveryPhaseCopy(recoveryPhasePath(dir, key, 0), frozen, key)
		b := readRecoveryPhaseCopy(recoveryPhasePath(dir, key, 1), frozen, key)
		if a.err == nil && b.err == nil && !bytes.Equal(a.raw, b.raw) {
			return ErrRecoveryJournalConflict
		}
		var size int
		switch {
		case a.err == nil:
			size = len(a.raw)
		case b.err == nil:
			size = len(b.raw)
		default:
			return errors.Join(ErrRecoveryJournalIncomplete, a.err, b.err)
		}
		logical += uint64(size)
		if logical > MaxRecoveryPhaseBytes {
			return ErrRecoverySplitRequired
		}
	}
	for _, key := range ordered {
		if err = repairRecoveryPhase(dir, key, frozen, grant); err != nil {
			return err
		}
	}
	return nil
}

func validRecoveryPhaseKey(key string) bool {
	switch key {
	case recoveryPhaseCoverage, "archive", "delete", "reclaimed", "resolved":
		return true
	}
	offset := 4
	if strings.HasPrefix(key, "publications-") {
		offset = 13
	} else if strings.HasPrefix(key, "attempt-") {
		offset = 8
	}
	if len(key) != offset+3 || (offset == 4 && !strings.HasPrefix(key, "ack-")) {
		return false
	}
	n := uint32(0)
	for _, b := range []byte(key[offset:]) {
		if b < '0' || b > '9' {
			return false
		}
		n = n*10 + uint32(b-'0')
	}
	if offset != 4 {
		return n < MaxRecoveryControlAttempts
	}
	return n < maxRecoveryPublications
}

func repairRecoveryPhase(dir, key string, frozen [32]byte, grant *RecoveryGrant) error {
	copies := [2]recoveryJournalCopy{}
	for c := range copies {
		copies[c] = readRecoveryPhaseCopy(recoveryPhasePath(dir, key, c), frozen, key)
	}
	if copies[0].err == nil && copies[1].err == nil {
		if !bytes.Equal(copies[0].raw, copies[1].raw) {
			return ErrRecoveryJournalConflict
		}
		return nil
	}
	valid, damaged := 0, 1
	if copies[0].err != nil {
		valid, damaged = 1, 0
	}
	if copies[valid].err != nil {
		return errors.Join(ErrRecoveryJournalIncomplete, copies[0].err, copies[1].err)
	}
	if err := copies[damaged].err; !errors.Is(err, os.ErrNotExist) && !errors.Is(err, ErrRecoveryJournalCorrupt) {
		return errors.Join(ErrRecoveryJournalIncomplete, err)
	}
	return grant.WriteBarrier(recoveryPhaseArtifact(key, damaged), recoveryPhasePath(dir, key, damaged), copies[valid].raw)
}

func recoveryPhaseArtifact(key string, copy int) Artifact {
	if key == recoveryPhaseCoverage {
		return ArtifactMapping
	}
	return recoveryJournalArtifact(copy)
}
