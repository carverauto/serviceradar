// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestResumeRecoveryMeasuresBeforeBackingCheck(t *testing.T) {
	lane := t.TempDir()
	segment := filepath.Join(lane, "lane.seg")
	journal := filepath.Join(t.TempDir(), "freeze-a.journal")
	for path, n := range map[string]int{segment: 20, journal: 10} {
		if err := os.WriteFile(path, bytes.Repeat([]byte{0x51}, n), 0600); err != nil {
			t.Fatal(err)
		}
	}
	a := newTestAllocator(t, 100, 1)
	a.ChargeMeasured(lane, 20)
	free := uint64(testPerRecovery + testMinFree - 30)
	a.freeBytes = func() (uint64, error) { return free, nil }
	if _, err := a.AcquireRecovery(lane); !errors.Is(err, ErrReserveUnbacked) {
		t.Fatalf("control: empty grant should double-reserve existing bytes: %v", err)
	}
	retained := []RecoveryArtifact{{ArtifactDestinationSegment, segment}, {ArtifactJournalA, journal}}
	g, err := a.ResumeRecovery(lane, retained, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got := a.Usage(); got.OrdinaryUsed != 0 || got.RecoveryUsed != 30 || got.ActiveRecoveries != 1 {
		t.Fatalf("restored ownership = %+v", got)
	}
	if g.Remaining(ArtifactDestinationSegment) != 44 || g.Remaining(ArtifactJournalA) != 22 {
		t.Fatal("retained bytes did not consume the correct budgets")
	}
	if err := g.WriteBarrier(ArtifactJournalB, filepath.Join(filepath.Dir(journal), "freeze-b.journal"), []byte("proof")); err != nil {
		t.Fatal(err)
	}
	// Remeasuring a live lane must not charge its held destination twice.
	a.ChargeMeasured(lane, 20)
	if got := a.Usage().OrdinaryUsed; got != 0 {
		t.Fatalf("restored destination double charged: %d", got)
	}
}

func TestResumeRecoveryFailureLeavesLedgerUnchanged(t *testing.T) {
	for _, kind := range []string{"unbacked", "duplicate", "over budget", "missing", "outside lane", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			lane := t.TempDir()
			path := filepath.Join(lane, "lane.seg")
			if err := os.WriteFile(path, bytes.Repeat([]byte{0x61}, 20), 0600); err != nil {
				t.Fatal(err)
			}
			a := newTestAllocator(t, 100, 1)
			a.ChargeMeasured(lane, 20)
			before := a.Usage()
			entries := []RecoveryArtifact{{ArtifactDestinationSegment, path}}
			switch kind {
			case "unbacked":
				a.freeBytes = func() (uint64, error) { return testPerRecovery + testMinFree - 21, nil }
			case "duplicate":
				entries = append(entries, entries[0])
			case "over budget":
				if err := os.WriteFile(path, make([]byte, 65), 0600); err != nil {
					t.Fatal(err)
				}
			case "missing":
				entries[0].Path = filepath.Join(lane, "absent")
			case "outside lane":
				entries[0].Path = filepath.Join(t.TempDir(), "other")
				if err := os.WriteFile(entries[0].Path, []byte("synthetic"), 0600); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				link := filepath.Join(lane, "link")
				if err := os.Symlink(path, link); err != nil {
					t.Fatal(err)
				}
				entries[0].Path = link
			}
			if g, err := a.ResumeRecovery(lane, entries, 0); g != nil || err == nil {
				t.Fatalf("invalid restore = %v %v", g, err)
			}
			if got := a.Usage(); got != before {
				t.Fatalf("failed restore changed ledger: before %+v after %+v", before, got)
			}
		})
	}
}

func TestRecoveryAppendPreflightsWholeBatch(t *testing.T) {
	lane := t.TempDir()
	a := newTestAllocator(t, 100, 1)
	g, err := a.AcquireRecovery(lane)
	if err != nil {
		t.Fatal(err)
	}
	s := &Spool{alloc: a, dir: lane}
	costs := []recoveryAppendCost{{ArtifactDestinationSegment, filepath.Join(lane, "lane.seg"), 20, 20}, {ArtifactAttributionSidecar, filepath.Join(lane, "attr"), 17, 17}}
	token, err := g.chargeAppend(s, costs, 0)
	if token != nil || !errors.Is(err, ErrReserveExhausted) {
		t.Fatalf("oversized batch = %v %v", token, err)
	}
	if g.Used(ArtifactDestinationSegment) != 0 || g.Used(ArtifactAttributionSidecar) != 0 {
		t.Fatal("partial batch consumed reserve before all artifacts fitted")
	}
	if _, err := g.chargeAppend(s, costs[:1], 0); !errors.Is(err, ErrRecoveryStopped) {
		t.Fatalf("exhausted grant resumed: %v", err)
	}
}

func TestRecoveryAppendTransfersPrepaidTerminalEvidence(t *testing.T) {
	lane := t.TempDir()
	fp := testFootprint()
	fp.DestinationSegment = 1024
	per, err := fp.PerRecovery()
	if err != nil {
		t.Fatal(err)
	}
	a, err := NewAllocator(AllocatorConfig{Capacity: per + testMinFree + 2048, MinFree: testMinFree, Recovery: fp, MaxConcurrentRecoveries: 1})
	if err != nil {
		t.Fatal(err)
	}
	source := t.TempDir()
	a.ChargeMeasured(source, 1000)
	g, err := a.AcquireRecovery(lane)
	if err != nil {
		t.Fatal(err)
	}
	s := &Spool{alloc: a, dir: lane}
	path := filepath.Join(lane, evidenceDirName(copyA), "slots")
	costs := []recoveryAppendCost{{ArtifactDestinationSegment, path, 40, 20}, {ArtifactAttributionSidecar, filepath.Join(lane, "attr"), 8, 8}}
	token, err := g.chargeAppend(s, costs, terminalEvidenceAllowance)
	if err != nil {
		t.Fatal(err)
	}
	if err := token.land(); err != nil {
		t.Fatal(err)
	}
	if g.Used(ArtifactDestinationSegment) != 40+terminalEvidenceAllowance {
		t.Fatal("overwritten evidence bytes escaped the write budget")
	}
	// Measured lane usage includes the ordinary append contract's prepaid terminal
	// allowance even though those bytes are not yet a terminal evidence file.
	a.ChargeMeasured(lane, 28+terminalEvidenceAllowance)
	if got := a.Usage().OrdinaryUsed; got != 1000 {
		t.Fatalf("held destination prepaid bytes counted twice: %d", got)
	}
	if err := g.Finish(); err != nil {
		t.Fatal(err)
	}
	if err := g.ReleaseSource(source, 1000); err != nil {
		t.Fatal(err)
	}
	if got := a.Usage().OrdinaryUsed; got != 28+terminalEvidenceAllowance {
		t.Fatalf("destination lost its prepaid terminal evidence: %d", got)
	}
	if err := g.ReleaseArtifacts(); err != nil {
		t.Fatal(err)
	}
	if got := a.Usage(); got.OrdinaryUsed != 28+terminalEvidenceAllowance || got.ActiveRecoveries != 0 {
		t.Fatalf("artifact release changed retained destination: %+v", got)
	}
}

func TestRecoveryAppendRejectsForeignOwnerAndPaths(t *testing.T) {
	for _, kind := range []string{"allocator", "lane", "subdir", "traversal"} {
		t.Run(kind, func(t *testing.T) {
			lane := t.TempDir()
			a := newTestAllocator(t, 100, 1)
			g, err := a.AcquireRecovery(lane)
			if err != nil {
				t.Fatal(err)
			}
			s := &Spool{alloc: a, dir: lane}
			path := filepath.Join(lane, "lane.seg")
			switch kind {
			case "allocator":
				s.alloc = newTestAllocator(t, 100, 1)
			case "lane":
				s.dir = t.TempDir()
			case "subdir":
				path = filepath.Join(lane, "other", "slots")
			case "traversal":
				path = filepath.Join(lane, "..", "slots")
			}
			token, err := g.chargeAppend(s, []recoveryAppendCost{{ArtifactDestinationSegment, path, 1, 1}}, 0)
			if token != nil || !errors.Is(err, ErrOutsideLane) {
				t.Fatalf("foreign append = %v %v", token, err)
			}
			if g.Used(ArtifactDestinationSegment) != 0 {
				t.Fatal("foreign append consumed reserve")
			}
		})
	}
}
