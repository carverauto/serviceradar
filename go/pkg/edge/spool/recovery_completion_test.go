// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func recoveryReadyForCleanup(t *testing.T) *recoveryFixture {
	t.Helper()
	f := newRecoveryFixture(t, 2)
	publications := prepareRecoveryPublications(t, f)
	for sequence := uint64(1); sequence <= 2; sequence++ {
		if _, err := f.operation.Copy(sequence); err != nil {
			t.Fatal(err)
		}
	}
	acknowledgeRecoveryPublications(t, f, publications)
	if _, err := f.operation.SealCoverage(); err != nil {
		t.Fatal(err)
	}
	if err := f.operation.ArchiveTerminalEvidence(); err != nil {
		t.Fatal(err)
	}
	if err := f.operation.ReclaimSource(); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestRecoveryCompletionRetainsRejectsAndReleasesOriginalGrant(t *testing.T) {
	f := recoveryReadyForCleanup(t)
	resolution := recoveryResolutionEvidence(t, f, nil)
	if err := f.operation.FinishCleanup(resolution, []*Generation{f.control}); !errors.Is(err, ErrRecoveryCleanupPending) {
		t.Fatal("unacknowledged copy reclaimed", err)
	}
	if f.allocator.Usage().ActiveRecoveries != 1 {
		t.Fatal("pending cleanup lost original grant")
	}
	_, terminal := recoveryAuthoritativeAck(t, f.destination, bytesRepeatedAppend(f.input, 2), edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT)
	if err := f.destination.ResolveWithEvidence(2, terminal); err != nil {
		t.Fatal(err)
	}
	if f.destination.spool.baseSeq != 0 {
		t.Fatal("ordinary reclaim bypassed recovery archive")
	}
	if err := f.operation.FinishCleanup(resolution, []*Generation{f.control}); err != nil {
		t.Fatal(err)
	}
	if usage := f.allocator.Usage(); usage.ActiveRecoveries != 0 || usage.RecoveryUsed != 0 {
		t.Fatal("completion retained concurrency/reserve", usage)
	}
	if f.destination.spool.baseSeq != 2 || f.control.spool.baseSeq != f.control.NextSequence()-1 {
		t.Fatal("same-grant cleanup left physical output")
	}
	if _, err := os.Stat(filepath.Join(f.dir, recoveryCopyA)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("transient journal not collected", err)
	}
	archive, err := os.ReadFile(filepath.Join(f.dir, "destination.archive"))
	if err != nil || !bytes.Contains(archive, f.input.Body) || !bytes.Contains(archive, terminal) {
		t.Fatal("permanent rejection evidence dropped", err)
	}
	completion, err := OpenRecoveryCompletion(f.dir)
	if err != nil {
		t.Fatal("compact completion depends on collected journal", err)
	}
	body, capability, err := completion.SignedResolution()
	if err != nil || body.AppliedThroughSequence != f.plan.Last || len(capability.Signature) == 0 {
		t.Fatal("original receipt missing", err)
	}
	measured, err := regularFileBytes(f.dir)
	if err != nil {
		t.Fatal(err)
	}
	f.allocator.mu.Lock()
	charge := f.allocator.ordinary[f.dir]
	f.allocator.mu.Unlock()
	if charge != measured {
		t.Fatalf("retained mandatory archives unaccounted: charge=%d measured=%d", charge, measured)
	}
}

func TestRecoveryCompletionResumesAfterJournalCollection(t *testing.T) {
	f := recoveryReadyForCleanup(t)
	resolution := recoveryResolutionEvidence(t, f, nil)
	_, terminal := recoveryAuthoritativeAck(t, f.destination, bytesRepeatedAppend(f.input, 2), edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
	if err := f.destination.ResolveWithEvidence(2, terminal); err != nil {
		t.Fatal(err)
	}
	f.allocator.fs = recoveryCrashFS{fileSystem: f.allocator.fs, failOpen: filepath.Join(f.dir, "completed-a.tmp")}
	if err := f.operation.FinishCleanup(resolution, []*Generation{f.control}); !errors.Is(err, syscall.EIO) {
		t.Fatal("completion crash not reached", err)
	}
	if _, err := os.Stat(filepath.Join(f.dir, recoveryCopyA)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("crash preceded frozen journal collection", err)
	}
	completion, err := OpenRecoveryCompletion(f.dir)
	if err != nil {
		t.Fatal("compact intent unavailable after collection", err)
	}
	if done, err := completion.Completed(); err != nil || done {
		t.Fatal("unfinished cleanup reported complete", err)
	}
	if err = f.lanes.Close(); err != nil {
		t.Fatal(err)
	}
	f.allocator = recoveryOperationAllocator(t)
	f.lanes = openAttributedLanes(t, f.root, f.identity, f.allocator, nil)
	sourceID, destinationID, controls := completion.Generations()
	for _, g := range f.lanes.Generations(sourceID.Lane) {
		if bytes.Equal(g.id.SpoolID, sourceID.SpoolID) {
			f.source = g
		}
	}
	f.destination = retainedRecoveryGeneration(t, f.lanes, destinationID.Lane, f.plan.RecoveryID, 0)
	f.control = retainedRecoveryGeneration(t, f.lanes, controls[0].Lane, f.plan.RecoveryID, 0)
	handles := RecoveryCompletionGenerations{f.source, f.destination, []*Generation{f.control}}
	// A surviving cached object cannot replace the missing second durable copy.
	if err = os.Remove(filepath.Join(f.dir, "completion-b")); err != nil {
		t.Fatal(err)
	}
	inventory, err := InventoryRecoveryStorage(f.dir, handles)
	if err != nil {
		t.Fatal(err)
	}
	f.grant, err = inventory.Restore(f.allocator)
	if err != nil {
		t.Fatal(err)
	}
	if err = completion.Finish(f.grant, handles, resolution); !errors.Is(err, ErrRecoveryJournalIncomplete) {
		t.Fatal("cached completion replaced missing durable pair", err)
	}
	completion, err = RepairRecoveryCompletion(f.dir, f.grant)
	if err != nil {
		t.Fatal("exact surviving completion copy did not repair", err)
	}
	if err = completion.Finish(f.grant, handles, nil); err == nil {
		t.Fatal("cleanup accepted cached historical trust without current validator")
	}
	if err = completion.Finish(f.grant, handles, resolution); err != nil {
		t.Fatal("compact resume required collected journal", err)
	}
	if done, err := completion.Completed(); err != nil || !done {
		t.Fatal("completion not durable", err)
	}
	if f.allocator.Usage().ActiveRecoveries != 0 {
		t.Fatal("resumed completion held concurrency")
	}
	completedInventory, err := InventoryRecoveryStorage(f.dir, handles)
	if err != nil {
		t.Fatal(err)
	}
	fresh := recoveryOperationAllocator(t)
	if grant, err := completedInventory.Restore(fresh); err != nil || grant != nil || fresh.Usage().ActiveRecoveries != 0 || fresh.Usage().OrdinaryUsed == 0 {
		t.Fatal("completed inventory reacquired or forgot archive charge", grant, err)
	}
}
