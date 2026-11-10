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
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

func mixedRecoveryTerminal(t *testing.T, g *Generation, input AttributedAppend, count int, allRejected bool) []byte {
	t.Helper()
	valid, _ := recoveryAuthoritativeAck(t, g, bytesRepeatedAppend(input, count), edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
	ack, session, err := valid.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	for i, disposition := range ack.Dispositions {
		if allRejected || i == len(ack.Dispositions)-1 {
			disposition.Kind = edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT
			disposition.RejectionCode = "SYNTHETIC_REJECTION"
		}
	}
	if _, err = edgerecord.ValidateAckEvidence(ack, session, 0, 0); err != nil {
		t.Fatal(err)
	}
	raw, err := proto.Marshal(ack)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestBeginRecoveryReopensPreFreezeReservationAndRetainedTerminalPrefix(t *testing.T) {
	f := newRecoveryFixtureBeforeFreeze(t, 2, func(g *Generation, input AttributedAppend) {
		if err := g.ResolveWithEvidence(2, mixedRecoveryTerminal(t, g, input, 2, false)); err != nil {
			t.Fatal(err)
		}
	})
	f.dir = filepath.Join(t.TempDir(), "absent-operation")
	restartRecoveryStorage(t, f)
	if _, err := os.Stat(f.dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("inventory wrote unreserved directory", err)
	}
	if _, err := f.source.CommittedAttribution(1); !errors.Is(err, ErrCommittedAttribution) {
		t.Fatal("fixture lacks retained resolved prefix", err)
	}
	op, err := BeginRecoveryOperation(f.dir, f.source, f.destination, f.grant, f.plan.DetectedAtUnixNano, f.plan.Reason)
	if err != nil {
		t.Fatal(err)
	}
	if op.plan.First != 1 || op.plan.Last != 3 || op.plan.ReclaimThrough != 0 || len(op.plan.Slots) != 3 || op.plan.Slots[0].Copy == nil || op.plan.Slots[1].Copy == nil || op.plan.Slots[2].Loss == nil {
		t.Fatal("freeze skipped retained accepted/rejected prefix", op.plan)
	}
	for seq := uint64(1); seq <= 2; seq++ {
		if _, err = op.Copy(seq); err != nil {
			t.Fatal(err)
		}
	}
	original, err := os.ReadFile(filepath.Join(f.dir, recoveryCopyA))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = BeginRecoveryOperation(f.dir, f.source, f.destination, f.grant, f.plan.DetectedAtUnixNano+1, "new caller reason"); err != nil {
		t.Fatal(err)
	}
	retained, err := os.ReadFile(filepath.Join(f.dir, recoveryCopyA))
	if err != nil || !bytes.Equal(original, retained) {
		t.Fatal("restart replaced frozen detection evidence", err)
	}
	if f.allocator.Usage().ActiveRecoveries != 1 {
		t.Fatal("pre-freeze restart acquired a second grant")
	}
}

type recoveryBlockingHoldFS struct {
	fileSystem
	path             string
	entered, release chan struct{}
}

func (f recoveryBlockingHoldFS) OpenFile(path string, flag int, mode os.FileMode) (durableFile, error) {
	if path == f.path {
		close(f.entered)
		<-f.release
	}
	return f.fileSystem.OpenFile(path, flag, mode)
}

func TestBeginRecoveryExcludesResolutionUntilDurableHold(t *testing.T) {
	f := newRecoveryFixtureBeforeFreeze(t, 2, nil)
	entered, release := make(chan struct{}), make(chan struct{})
	f.allocator.fs = recoveryBlockingHoldFS{f.allocator.fs, f.source.spool.recoverySourceHoldPath() + ".tmp", entered, release}
	started := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		_, err := BeginRecoveryOperation(f.dir, f.source, f.destination, f.grant, f.plan.DetectedAtUnixNano, f.plan.Reason)
		done <- err
	}()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("source hold write never reached")
	}
	_, raw := recoveryAuthoritativeAck(t, f.source, bytesRepeatedAppend(f.input, 2), edgev1.EdgeRecordDispositionKind_EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE)
	resolved := make(chan error, 1)
	go func() { close(started); resolved <- f.source.ResolveWithEvidence(2, raw) }()
	<-started
	select {
	case err := <-resolved:
		close(release)
		<-done
		t.Fatal("resolution crossed freeze-to-hold window", err)
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if err := <-resolved; !errors.Is(err, ErrRecoveryHeld) {
		t.Fatal("resolution escaped durable source hold", err)
	}
	if f.source.Resolved() != 0 {
		t.Fatal("freeze raced terminal watermark")
	}
}

func TestBeginRecoveryDoesNotInventLossForHealthySource(t *testing.T) {
	input, key, identity := attributionAppend(t, fixtureKindMetrics)
	allocator := recoveryOperationAllocator(t)
	lanes := openAttributedLanes(t, t.TempDir(), identity, allocator, nil)
	defer func() { _ = lanes.Close() }()
	source := closedRecoverySource(t, lanes, key, identity, input)
	destination, grant, err := lanes.BeginRecoveryDestination(source, recoveryUUID(91), 0, allocator)
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(t.TempDir(), "absent")
	if _, err = BeginRecoveryOperation(dir, source, destination, grant, 1800000000000000000, "synthetic healthy source"); !errors.Is(err, ErrRecoveryNoLoss) {
		t.Fatal("healthy copy-only source acquired fabricated loss", err)
	}
	if held, err := source.RecoverySourceHeld(); err != nil || held {
		t.Fatal("healthy source drain held", err)
	}
	if _, err = os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("healthy source produced journal", err)
	}
}

func TestRecoveryResumesAfterDestinationPublishedBeforeSourceClose(t *testing.T) {
	input, key, identity := attributionAppend(t, fixtureKindMetrics)
	root := t.TempDir()
	allocator := recoveryOperationAllocator(t)
	lanes := openAttributedLanes(t, root, identity, allocator, nil)
	defer func() {
		if err := lanes.Close(); err != nil {
			t.Error(err)
		}
	}()
	if _, err := lanes.AppendAttributed(key, identity, input); err != nil {
		t.Fatal(err)
	}
	source, _ := lanes.OpenGeneration(key)
	source.spool.beforeBarrier = func(at barrier) error {
		if at == barrierRecord {
			return syscall.EIO
		}
		return nil
	}
	if _, err := lanes.AppendAttributed(key, identity, input); !errors.Is(err, syscall.EIO) {
		t.Fatal(err)
	}
	if err := lanes.Close(); err != nil {
		t.Fatal(err)
	}
	allocator = recoveryOperationAllocator(t)
	lanes = openAttributedLanes(t, root, identity, allocator, nil)
	source, _ = lanes.OpenGeneration(key)
	allocator.fs = recoveryCrashFS{fileSystem: allocator.fs, failOpen: filepath.Join(source.dir, closedFile) + ".tmp"}
	id := recoveryUUID(92)
	if _, _, err := lanes.BeginRecoveryDestination(source, id, 0, allocator); !errors.Is(err, syscall.EIO) {
		t.Fatal("source-close crash not reached", err)
	}
	if err := lanes.Close(); err != nil {
		t.Fatal(err)
	}
	allocator = recoveryOperationAllocator(t)
	lanes = openAttributedLanes(t, root, identity, allocator, nil)
	source, _ = lanes.OpenGeneration(key)
	if source == nil || source.Closed() {
		t.Fatal("crash did not retain active source")
	}
	destination := retainedRecoveryGeneration(t, lanes, key, id, 0)
	dir := filepath.Join(t.TempDir(), "operation")
	inventory, err := InventoryRecoveryStorage(dir, RecoveryCompletionGenerations{Source: source, Destination: destination})
	if err != nil {
		t.Fatal(err)
	}
	grant, err := inventory.Restore(allocator)
	if err != nil {
		t.Fatal(err)
	}
	replay, restored, err := lanes.BeginRecoveryDestination(source, id, 0, allocator)
	if err != nil || replay != destination || restored != grant {
		t.Fatal("restart replaced reserved destination", err)
	}
	if !source.Closed() {
		t.Fatal("resumed source remained producer-writable")
	}
	if _, open := lanes.OpenGeneration(key); open {
		t.Fatal("source closure allocated an ordinary successor")
	}
	if _, err = BeginRecoveryOperation(dir, source, destination, grant, 1800000000000000000, "synthetic interrupted source closure"); err != nil {
		t.Fatal(err)
	}
}
