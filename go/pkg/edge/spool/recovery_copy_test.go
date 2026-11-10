// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// Restart through the production inventory owner, including interrupted files and
// outstanding terminal allowance, rather than supplying claimed artifact sizes.
func restartRecoveryCopy(t *testing.T, f *recoveryFixture) {
	t.Helper()
	restartRecoveryStorage(t, f)
	var err error
	f.operation, err = OpenRecoveryOperation(f.dir, f.source, f.destination, f.grant)
	if err != nil {
		t.Fatal(err)
	}
}

func restartRecoveryStorage(t *testing.T, f *recoveryFixture) {
	t.Helper()
	sourceDir, destinationDir, controlDir := f.source.dir, f.destination.dir, f.control.dir
	if err := f.lanes.Close(); err != nil {
		t.Fatal(err)
	}
	f.allocator = recoveryOperationAllocator(t)
	f.lanes = openAttributedLanes(t, f.root, f.identity, f.allocator, nil)
	for _, key := range f.lanes.Lanes() {
		for _, g := range f.lanes.Generations(key) {
			switch g.dir {
			case sourceDir:
				f.source = g
			case destinationDir:
				f.destination = g
			case controlDir:
				f.control = g
			}
		}
	}
	inventory, err := InventoryRecoveryStorage(f.dir, RecoveryCompletionGenerations{f.source, f.destination, []*Generation{f.control}})
	if err != nil {
		t.Fatal(err)
	}
	f.grant, err = inventory.Restore(f.allocator)
	if err != nil {
		t.Fatal(err)
	}
}

func TestRecoveryCopyResumesFrozenAllocationAfterEveryBarrier(t *testing.T) {
	for _, sequence := range []uint64{1, 2} {
		for _, stop := range []barrier{barrierPrepareA, barrierPrepareB, barrierRecord, barrierAttribution, barrierAttributionDir, barrierRelocation, barrierRelocationDir, barrierCommitA, barrierCommitB} {
			t.Run(fmt.Sprintf("slot_%d_barrier_%d", sequence, stop), func(t *testing.T) {
				f := newRecoveryFixture(t, 2)
				if sequence == 2 {
					if _, err := f.operation.Copy(1); err != nil {
						t.Fatal(err)
					}
				}
				f.destination.spool.beforeBarrier = func(at barrier) error {
					if at == stop {
						return syscall.EIO
					}
					return nil
				}
				if _, err := f.operation.Copy(sequence); !errors.Is(err, syscall.EIO) {
					t.Fatal("copy crash not reached", err)
				}
				restartRecoveryCopy(t, f)
				before := f.destination.NextSequence()
				receipt, err := f.operation.Copy(sequence)
				if err != nil {
					t.Fatal("frozen allocated copy remained wedged", err)
				}
				if receipt.Sequence != sequence || f.destination.NextSequence() != sequence+1 || (stop != barrierPrepareA && before != sequence+1) {
					t.Fatal("repair changed planned allocation", receipt, before, f.destination.NextSequence())
				}
				proof, err := f.destination.CommittedAttribution(sequence)
				if err != nil || !bytes.Equal(proof.record.Body, f.input.Body) || !bytes.Equal(proof.record.EventID, f.input.EventID) {
					t.Fatal("repaired copy lost original bytes", err)
				}
				if _, err = f.source.spool.retainedCopySource(sequence); err != nil {
					t.Fatal("repair changed source", err)
				}
				if err = f.operation.requireSourceHold(); err != nil {
					t.Fatal("source hold disappeared", err)
				}
				if _, err = readRecoveryHold(f.destination.spool.recoveryHoldPath()); err != nil {
					t.Fatal("destination hold disappeared", err)
				}
				// A second restart must recover the same committed mapping and allocation.
				restartRecoveryCopy(t, f)
				if _, err = f.operation.Copy(sequence); err != nil {
					t.Fatal("repaired commit was not durable", err)
				}
				if f.allocator.Usage().ActiveRecoveries != 1 {
					t.Fatal("repair acquired another grant")
				}
			})
		}
	}
}

func TestRecoveryCopyRefusesConflictingTailWithoutChangingEvidence(t *testing.T) {
	const (
		counter, offset                = "counter", "offset"
		priorCounter, priorOffset      = "prior_counter", "prior_offset"
		recordPrefix                   = "record_prefix"
		missingHold, missingSourceHold = "missing_hold", "missing_source_hold"
	)
	for _, conflict := range []string{counter, offset, priorCounter, priorOffset, recordPrefix, missingHold, missingSourceHold} {
		t.Run(conflict, func(t *testing.T) {
			f := newRecoveryFixture(t, 2)
			if _, err := f.operation.Copy(1); err != nil {
				t.Fatal(err)
			}
			f.destination.spool.beforeBarrier = func(at barrier) error {
				if at == barrierAttribution {
					return syscall.EIO
				}
				return nil
			}
			if _, err := f.operation.Copy(2); !errors.Is(err, syscall.EIO) {
				t.Fatal(err)
			}
			restartRecoveryCopy(t, f)
			path := f.destination.spool.evidencePath(0)
			if conflict == recordPrefix {
				path = f.destination.spool.segmentPath()
			}
			if conflict == missingHold {
				path = f.destination.spool.recoveryHoldPath()
			}
			if conflict == missingSourceHold {
				path = f.source.spool.recoverySourceHoldPath()
			}
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			switch conflict {
			case counter, offset, priorCounter, priorOffset:
				seq, state := uint64(2), statePrepared
				if conflict == priorCounter || conflict == priorOffset {
					seq, state = 1, stateCommitted
				}
				pos := f.destination.spool.evidencePosition(seq, state)
				entry, status := decodeEvidenceVersion(raw[pos:pos+evidenceEntryLen2], 0, seq, state, evidenceVersion2)
				if status != entryValid {
					t.Fatal("fixture lacks prepared evidence")
				}
				if conflict == counter || conflict == priorCounter {
					entry.generation++
				} else {
					entry.recordOffset++
				}
				copy(raw[pos:], entry.encode())
			case recordPrefix:
				raw[len(raw)-1] ^= 1
			case missingHold, missingSourceHold:
				if err = os.Remove(path); err != nil {
					t.Fatal(err)
				}
			}
			if conflict != missingHold && conflict != missingSourceHold {
				if err = os.WriteFile(path, raw, filePerm); err != nil {
					t.Fatal(err)
				}
			}
			before := f.allocator.Usage()
			if _, err = f.operation.Copy(2); err == nil {
				t.Fatal("conflicting frozen copy was accepted")
			}
			if f.allocator.Usage() != before {
				t.Fatal("refusal consumed reserve")
			}
			if conflict != missingHold && conflict != missingSourceHold {
				after, err := os.ReadFile(path)
				if err != nil || !bytes.Equal(raw, after) {
					t.Fatal("conflicting evidence overwritten", err)
				}
			}
			if _, err = os.Stat(filepath.Join(f.dir, recoveryCopyA)); err != nil {
				t.Fatal("refusal lost journal", err)
			}
		})
	}
}

// Fail after actually writing a prefix: a second process must finish those exact
// bytes without truncating or changing the frozen allocation.
type recoveryPartialCopyFS struct {
	fileSystem
	path string
}
type recoveryPartialCopyFile struct{ durableFile }

func (f recoveryPartialCopyFS) OpenFile(path string, flags int, mode os.FileMode) (durableFile, error) {
	file, err := f.fileSystem.OpenFile(path, flags, mode)
	if err == nil && path == f.path && flags&os.O_APPEND != 0 {
		return recoveryPartialCopyFile{file}, nil
	}
	return file, err
}
func (f recoveryPartialCopyFile) Write(raw []byte) (int, error) {
	n, err := f.durableFile.Write(raw[:len(raw)/2])
	if err != nil {
		return n, err
	}
	return n, syscall.EIO
}

func TestRecoveryCopyResumesAfterPartialRepairWrite(t *testing.T) {
	for _, artifact := range []string{"record", "attribution", "mapping", "evidence_a", "evidence_b"} {
		t.Run(artifact, func(t *testing.T) {
			f := newRecoveryFixture(t, 2)
			if _, err := f.operation.Copy(1); err != nil {
				t.Fatal(err)
			}
			f.destination.spool.beforeBarrier = func(at barrier) error {
				if at == barrierRecord {
					return syscall.EIO
				}
				return nil
			}
			if _, err := f.operation.Copy(2); !errors.Is(err, syscall.EIO) {
				t.Fatal(err)
			}
			restartRecoveryCopy(t, f)
			s := f.destination.spool
			paths := map[string]string{"record": s.segmentPath(), "attribution": filepath.Join(s.dataDir, attributionFile), "mapping": filepath.Join(s.dataDir, relocationFile), "evidence_a": s.evidencePath(0), "evidence_b": s.evidencePath(1)}
			path := paths[artifact]
			f.allocator.fs = recoveryPartialCopyFS{f.allocator.fs, path}
			if _, err := f.operation.Copy(2); !errors.Is(err, syscall.EIO) {
				t.Fatal("partial repair crash not reached", err)
			}
			retained, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			restartRecoveryCopy(t, f)
			if _, err = f.operation.Copy(2); err != nil {
				t.Fatal("partial repair could not resume", err)
			}
			complete, err := os.ReadFile(path)
			if err != nil || len(complete) <= len(retained) || !bytes.HasPrefix(complete, retained) {
				t.Fatal("repair replaced retained prefix", err)
			}
			proof, err := f.destination.CommittedAttribution(2)
			if err != nil || !bytes.Equal(proof.record.Body, f.input.Body) {
				t.Fatal("repaired copy unavailable", err)
			}
		})
	}
}

func TestRecoveryCopyReplaysSealedCommittedDestination(t *testing.T) {
	f := newRecoveryFixture(t, 2)
	for seq := uint64(1); seq <= 2; seq++ {
		if _, err := f.operation.Copy(seq); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.destination.SealRecoveryDestination(); err != nil {
		t.Fatal(err)
	}
	restartRecoveryCopy(t, f)
	for seq := uint64(1); seq <= 2; seq++ {
		receipt, err := f.operation.Copy(seq)
		if err != nil || receipt.Sequence != seq {
			t.Fatal("healthy sealed copy replay attempted repair", seq, err)
		}
	}
}
