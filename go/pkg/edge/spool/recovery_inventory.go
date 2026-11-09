// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
)

// RecoveryStorageInventory is a bounded, storage-owned classification of exact
// retained paths. It includes interrupted writes and metadata; no caller byte
// count or unsupported filename can silently disappear from reserve accounting.
type RecoveryStorageInventory struct {
	dir, destination string
	artifacts        []RecoveryArtifact
	controls         []RecoveryControlInventory
	terminalSlots    uint64
	completion       *RecoveryCompletion
	completed        bool
	completionErr    error
}

func (i *RecoveryStorageInventory) Completion() *RecoveryCompletion { return i.completion }
func (i *RecoveryStorageInventory) Completed() bool                 { return i.completed }

func (i *RecoveryStorageInventory) CompletionError() error { return i.completionErr }

// Restore measures retained artifacts before checking remaining physical backing.
// Completed operations are charged as ordinary retained evidence and acquire no
// slot. A refusal leaves their measured directory charge visible to admission.
func (i *RecoveryStorageInventory) Restore(allocator *Allocator) (*RecoveryGrant, error) {
	if allocator == nil {
		return nil, ErrRecoveryGrantRequired
	}
	measured, err := regularFileBytes(i.dir)
	if err != nil {
		return nil, err
	}
	allocator.ChargeMeasured(i.dir, measured)
	if i.completed {
		return nil, nil
	}
	grant, err := allocator.ResumeRecoveryWithControls(i.destination, i.controls, i.artifacts, i.terminalSlots)
	if err != nil {
		return nil, err
	}
	// The exact files just adopted by this grant were conservatively measured as
	// ordinary while no active owner existed. Remove only that duplicate charge.
	allocator.ChargeMeasured(i.dir, 0)
	return grant, nil
}

// InventoryRecoveryStorage inspects one bounded operation and its exact retained
// generation handles. The coordinator enumerates those handles with GenerationsPage;
// it never reconstructs namespaces from current configuration or parses filenames.
func InventoryRecoveryStorage(dir string, handles RecoveryCompletionGenerations) (*RecoveryStorageInventory, error) {
	if handles.Source == nil || handles.Destination == nil || len(handles.Controls) > 2 {
		return nil, ErrRecoveryPlan
	}
	controls := append([]*Generation(nil), handles.Controls...)
	for _, g := range controls {
		if g == nil {
			return nil, ErrRecoveryPlan
		}
	}
	sort.Slice(controls, func(a, b int) bool { return controls[a].RecoveryAttempt() < controls[b].RecoveryAttempt() })
	inventory := &RecoveryStorageInventory{dir: dir, destination: handles.Destination.dir, terminalSlots: handles.Destination.NextSequence() - 1 - handles.Destination.Resolved()}
	completion, err := OpenRecoveryCompletion(dir)
	completionReadErr := err
	if err == nil {
		inventory.completion = completion
		inventory.completed, err = completion.Completed()
		if err != nil {
			if !errors.Is(err, ErrRecoveryJournalIncomplete) && !errors.Is(err, ErrRecoveryJournalCorrupt) && !errors.Is(err, ErrRecoveryJournalConflict) {
				return nil, err
			}
			inventory.completionErr = err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		if !errors.Is(err, ErrRecoveryJournalIncomplete) && !errors.Is(err, ErrRecoveryJournalCorrupt) && !errors.Is(err, ErrRecoveryJournalConflict) {
			return nil, err
		}
		inventory.completionErr = err
	}
	entries, err := recoveryPhaseEntries(dir)
	if err != nil {
		return nil, err
	}
	inventory.artifacts = append(inventory.artifacts, RecoveryArtifact{ArtifactFilesystemMetadata, dir})
	for _, entry := range entries {
		if inventory.completion == nil && (strings.HasPrefix(entry.Name(), "completion-a") || strings.HasPrefix(entry.Name(), "completion-b")) {
			inventory.completionErr = errors.Join(ErrRecoveryJournalIncomplete, completionReadErr)
		}
		art, err := recoveryStoredArtifact(entry.Name())
		if err != nil {
			return nil, err
		}
		if !entry.Type().IsRegular() {
			return nil, ErrRecoveryJournalCorrupt
		}
		inventory.artifacts = append(inventory.artifacts, RecoveryArtifact{art, filepath.Join(dir, entry.Name())})
	}
	if err = inventory.addGeneration(handles.Destination, ArtifactDestinationSegment, false); err != nil {
		return nil, err
	}
	for _, g := range controls {
		if !g.id.Identity.equal(handles.Destination.id.Identity) || !bytes.Equal(g.RecoveryID(), handles.Destination.RecoveryID()) {
			return nil, ErrRecoveryPlan
		}
		inventory.controls = append(inventory.controls, RecoveryControlInventory{Directory: g.dir, TerminalSlots: g.NextSequence() - 1 - g.Resolved()})
		if err = inventory.addGeneration(g, ArtifactManifestPages, false); err != nil {
			return nil, err
		}
	}
	if err = inventory.addGeneration(handles.Source, ArtifactMapping, true); err != nil {
		return nil, err
	}
	return inventory, nil
}

func recoveryStoredArtifact(name string) (Artifact, error) {
	name = strings.TrimSuffix(name, ".tmp")
	switch name {
	case recoveryCopyA:
		return ArtifactJournalA, nil
	case recoveryCopyB:
		return ArtifactJournalB, nil
	case recoveryArchiveFile, "destination.archive", "completion-a", "completion-b", "completed-a", "completed-b":
		return ArtifactMapping, nil
	case "control-000.archive", "control-001.archive":
		return ArtifactManifestPages, nil
	}
	if strings.HasPrefix(name, "phase-") && (strings.HasSuffix(name, "-a") || strings.HasSuffix(name, "-b")) {
		key := strings.TrimPrefix(name[:len(name)-2], "phase-")
		if validRecoveryPhaseKey(key) {
			copy := 0
			if strings.HasSuffix(name, "-b") {
				copy = 1
			}
			return recoveryPhaseArtifact(key, copy), nil
		}
	}
	return 0, fmt.Errorf("%w: unsupported retained recovery artifact", ErrRecoveryJournalCorrupt)
}

func (i *RecoveryStorageInventory) addGeneration(g *Generation, artifact Artifact, holdOnly bool) error {
	root := g.dir
	if holdOnly {
		root = filepath.Join(root, recoveryDirectory)
	}
	return i.scanGeneration(root, g.dir, artifact, holdOnly, 0)
}

func (i *RecoveryStorageInventory) scanGeneration(dir, owner string, artifact Artifact, holdOnly bool, depth int) error {
	if depth > 3 {
		return ErrRecoveryJournalCorrupt
	}
	f, err := os.Open(dir)
	if errors.Is(err, os.ErrNotExist) && holdOnly {
		return nil
	}
	if err != nil {
		return err
	}
	entries, err := f.ReadDir(2*edgerecord.MaxRecoverySlots + 65)
	closeErr := f.Close()
	if err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if len(entries) > 2*edgerecord.MaxRecoverySlots+64 {
		return ErrRecoverySplitRequired
	}
	i.artifacts = append(i.artifacts, RecoveryArtifact{ArtifactFilesystemMetadata, dir})
	for _, entry := range entries {
		path := filepath.Join(dir, entry.Name())
		if entry.IsDir() {
			_, data := dataBase(entry.Name())
			if !data && entry.Name() != evidenceDirName(copyA) && entry.Name() != evidenceDirName(copyB) && entry.Name() != recoveryDirectory {
				return ErrRecoveryJournalCorrupt
			}
			nextArtifact := artifact
			if entry.Name() == recoveryDirectory {
				nextArtifact = ArtifactMapping
			}
			if err = i.scanGeneration(path, owner, nextArtifact, false, depth+1); err != nil {
				return err
			}
			continue
		}
		if entry.Type()&os.ModeSymlink != 0 {
			if dir != owner || entry.Name() != segmentFile {
				return ErrRecoveryJournalCorrupt
			}
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			if _, ok := dataBase(target); !ok {
				return ErrRecoveryJournalCorrupt
			}
			continue
		}
		if !entry.Type().IsRegular() {
			return ErrRecoveryJournalCorrupt
		}
		art := artifact
		if artifact == ArtifactDestinationSegment && (entry.Name() == attributionFile || entry.Name() == relocationFile) {
			art = ArtifactAttributionSidecar
		}
		i.artifacts = append(i.artifacts, RecoveryArtifact{art, path})
	}
	return nil
}
