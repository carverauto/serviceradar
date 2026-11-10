// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"errors"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
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
	const kindMissing = "missing"
	for _, kind := range []string{"unbacked", "duplicate", "over budget", kindMissing, "outside lane", "symlink"} {
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
			case kindMissing:
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

func TestInterruptedControlAppendReconstructsUnderSameReserve(t *testing.T) {
	input, key, id := attributionAppend(t, fixtureKindControl)
	root := t.TempDir()
	firstAllocator := attributionAllocator(t)
	lanes := openAttributedLanes(t, root, id, firstAllocator, func(s *Spool) {
		if s.attributionIdentity.Lane == key {
			s.beforeBarrier = func(at barrier) error {
				if at == barrierCommitA {
					return os.ErrPermission
				}
				return nil
			}
		}
	})
	if _, err := lanes.Rotate(bulkLane); err != nil {
		t.Fatal(err)
	}
	destination, _ := lanes.OpenGeneration(bulkLane)
	if _, err := lanes.Rotate(key); err != nil {
		t.Fatal(err)
	}
	interrupted, _ := lanes.OpenGeneration(key)
	grant, err := firstAllocator.AcquireRecovery(destination.dir)
	if err != nil {
		t.Fatal(err)
	}
	if err = grant.AttachControlLane(interrupted); err != nil {
		t.Fatal(err)
	}
	if receipt, err := interrupted.spool.CommitRecoveryControl(input, grant); !errors.Is(err, os.ErrPermission) || receipt.Sequence != 0 {
		t.Fatalf("partial control issued receipt: %+v %v", receipt, err)
	}
	if err = lanes.Close(); err != nil {
		t.Fatal(err)
	}
	fresh := attributionAllocator(t)
	lanes = openAttributedLanes(t, root, id, fresh, nil)
	interrupted, _ = lanes.OpenGeneration(key)
	if _, err = interrupted.CommittedAttribution(1); err == nil {
		t.Fatal("incomplete control became sender-visible")
	}
	paths := []string{filepath.Join(interrupted.dir, segmentFile), filepath.Join(interrupted.dir, attributionFile), interrupted.spool.evidencePath(copyA), interrupted.spool.evidencePath(copyB)}
	inventory := make([]RecoveryArtifact, 0, len(paths))
	retained := map[string][]byte{}
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		retained[path] = raw
		inventory = append(inventory, RecoveryArtifact{ArtifactManifestPages, path})
	}
	if _, err = lanes.Rotate(key); err != nil {
		t.Fatal(err)
	}
	replacement, _ := lanes.OpenGeneration(key)
	attempts := []RecoveryControlInventory{{Directory: interrupted.dir, TerminalSlots: 1}, {Directory: replacement.dir}}
	restored, err := fresh.ResumeRecoveryWithControls(destination.dir, attempts, inventory, 0)
	if err != nil {
		t.Fatal(err)
	}
	usage := fresh.Usage()
	fresh.ChargeMeasured(filepath.Join(root, "synthetic-full-lane"), usage.OrdinaryCeiling-usage.OrdinaryUsed)
	receipt, err := replacement.spool.CommitRecoveryControl(input, restored)
	if err != nil {
		t.Fatal(err)
	}
	witness, err := replacement.CommittedAttribution(receipt.Sequence)
	if err != nil || !bytes.Equal(witness.record.Body, input.Body) || !bytes.Equal(witness.record.EventID, input.EventID) {
		t.Fatalf("reconstruction changed publication: %v", err)
	}
	if fresh.Usage().ActiveRecoveries != 1 {
		t.Fatal("reconstruction acquired second grant")
	}
	for path, want := range retained {
		got, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(got, want) {
			t.Fatalf("reconstruction changed interrupted evidence: %s %v", path, err)
		}
	}
	// Another capacity refusal cannot release or forget the failed attempt.
	before := fresh.Usage()
	if _, err = fresh.AcquireRecovery(replacement.dir); !errors.Is(err, ErrRecoveryConcurrencyExhausted) {
		t.Fatalf("concurrency guard: %v", err)
	}
	if fresh.Usage() != before {
		t.Fatal("refused recovery changed retained accounting")
	}
}

func TestCoordinatorFootprintBoundsConfiguration(t *testing.T) {
	f := DefaultRecoveryFootprint()
	if err := f.ValidateCoordinator(); err != nil {
		t.Fatal(err)
	}
	total, err := f.PerRecovery()
	if err != nil || total != 47<<20 {
		t.Fatalf("default footprint changed: %d %v", total, err)
	}
	for _, art := range []Artifact{ArtifactDestinationSegment, ArtifactAttributionSidecar, ArtifactJournalA, ArtifactManifestPages, ArtifactMapping, ArtifactFilesystemMetadata} {
		t.Run(art.String(), func(t *testing.T) {
			small := f
			switch art {
			case ArtifactDestinationSegment:
				small.DestinationSegment = edgerecord.MaxRecordBytes
			case ArtifactAttributionSidecar:
				small.AttributionSidecar = sidecarSlotSize
			case ArtifactJournalA:
				small.JournalCopy = MaxRecoveryJournalBytes
			case ArtifactManifestPages:
				small.ManifestPages = MaxRecoveryPublicationBytes
			case ArtifactMapping:
				small.Mapping = 1
			case ArtifactFilesystemMetadata:
				small.FilesystemMetadata = 1
			case ArtifactJournalB, artifactCount:
				t.Fatalf("artifact %v has no footprint field under test", art)
			}
			if err := small.ValidateCoordinator(); !errors.Is(err, ErrInvalidAllocatorConfig) {
				t.Fatalf("incomplete footprint accepted: %v", err)
			}
		})
	}
	if _, err = NewAllocator(AllocatorConfig{Capacity: total + 4095, MinFree: 4096, Recovery: f, MaxConcurrentRecoveries: 1}); !errors.Is(err, ErrInvalidAllocatorConfig) {
		t.Fatalf("impossible total capacity accepted: %v", err)
	}
}
