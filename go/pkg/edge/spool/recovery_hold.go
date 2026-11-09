// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/carverauto/serviceradar/go/pkg/durablefs"
)

var ErrRecoveryHeld = fmt.Errorf("%w: recovery coverage hold", ErrRetryable)

const recoveryDirectory = ".recovery"
const recoveryHoldFile = "hold"
const recoverySourceHoldFile = "source-hold"
const recoveryHoldMagic = "SRHOLD01"
const recoveryHoldBytes = 8 + 32 + 32 + 32

func (s *Spool) recoveryHoldPath() string {
	return filepath.Join(s.dir, recoveryDirectory, recoveryHoldFile)
}

func (s *Spool) recoverySourceHoldPath() string {
	return filepath.Join(s.dir, recoveryDirectory, recoverySourceHoldFile)
}

// RecoverySourceHeld tells the coordinator/sender supervisor to suspend the old
// generation session. Destination coverage holds deliberately do not suppress
// ScanFrom: relocated records must remain deliverable while their proof seals.
func (g *Generation) RecoverySourceHeld() (bool, error) {
	raw, err := readRecoveryHold(g.spool.recoverySourceHoldPath())
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	identity := sha256.Sum256(encodeIdentity(g.id))
	if !bytes.Equal(raw[8:40], identity[:]) {
		return false, ErrRecoveryJournalConflict
	}
	return true, nil
}

func recoveryHoldRecord(id GenerationIdentity, owner [32]byte) []byte {
	identity := sha256.Sum256(encodeIdentity(id))
	raw := append([]byte(recoveryHoldMagic), identity[:]...)
	raw = append(raw, owner[:]...)
	sum := sha256.Sum256(raw)
	return append(raw, sum[:]...)
}

func readRecoveryHold(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, recoveryHoldBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) != recoveryHoldBytes || string(raw[:8]) != recoveryHoldMagic {
		return nil, ErrRecoveryJournalCorrupt
	}
	sum := sha256.Sum256(raw[:len(raw)-32])
	if !bytes.Equal(sum[:], raw[len(raw)-32:]) {
		return nil, ErrRecoveryJournalCorrupt
	}
	return raw, nil
}

// Every resolving handle consults durable storage. A cached bool would permit a
// sender opened before the hold to erase copy evidence after an early ACK.
func (s *Spool) requireNoRecoveryHold() error {
	for _, path := range []string{s.recoveryHoldPath(), s.recoverySourceHoldPath()} {
		_, err := readRecoveryHold(path)
		if !errors.Is(err, os.ErrNotExist) {
			return errors.Join(ErrRecoveryHeld, err)
		}
	}
	return nil
}

// beginRecoveryHold runs under the generation lifecycle lock and spool mutex.
// The hold is durable before the first operation-owned relocation is permitted.
func (s *Spool) beginRecoveryHold(owner [32]byte, grant *RecoveryGrant, empty bool) error {
	return s.beginHold(s.recoveryHoldPath(), owner, grant, empty)
}

func (s *Spool) beginRecoverySourceHold(owner [32]byte, grant *RecoveryGrant) error {
	return s.beginHold(s.recoverySourceHoldPath(), owner, grant, false)
}

func (s *Spool) beginHold(path string, owner [32]byte, grant *RecoveryGrant, empty bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.attributionIdentity == nil || s.alloc != grant.alloc {
		return ErrAttributionRequired
	}
	want := recoveryHoldRecord(*s.attributionIdentity, owner)
	got, err := readRecoveryHold(path)
	if err == nil {
		if !bytes.Equal(want, got) {
			return ErrRecoveryJournalConflict
		}
		return nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if empty && s.nextSeq != s.baseSeq+1 {
		return ErrRecoveryHeld
	}
	dir := filepath.Dir(path)
	if err = grant.Charge(ArtifactFilesystemMetadata, 4096); err != nil {
		return err
	}
	if err = durablefs.MkdirAll(dir, dirPerm); err != nil {
		return grant.FailStop("create recovery hold directory", err)
	}
	if err = grant.Landed(ArtifactFilesystemMetadata, dir, 4096); err != nil {
		return err
	}
	return grant.WriteBarrier(ArtifactMapping, path, want)
}

// releaseRecoveryHold is private to the paired coverage owner. It checks the
// exact owner again while holding the same mutex used by resolving senders.
func (s *Spool) releaseRecoveryHold(owner [32]byte, grant *RecoveryGrant) error {
	return s.releaseHold(s.recoveryHoldPath(), owner, grant)
}
func (s *Spool) releaseRecoverySourceHold(owner [32]byte, grant *RecoveryGrant) error {
	return s.releaseHold(s.recoverySourceHoldPath(), owner, grant)
}
func (s *Spool) releaseHold(path string, owner [32]byte, grant *RecoveryGrant) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	got, err := readRecoveryHold(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if s.attributionIdentity == nil || !bytes.Equal(got, recoveryHoldRecord(*s.attributionIdentity, owner)) {
		return ErrRecoveryJournalConflict
	}
	return grant.RunDestructive("release recovery hold", func() error {
		if err := grant.alloc.fs.Remove(path); err != nil {
			return err
		}
		return grant.alloc.fs.SyncDir(filepath.Dir(path))
	})
}
