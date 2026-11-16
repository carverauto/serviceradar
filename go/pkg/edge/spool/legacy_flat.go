/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package spool

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Agents before the bounded lane format kept one flat single-lane spool directly
// under the edge record root: the segment pointer lane.seg, the resolved
// watermark, the sender's spool_id, and either root-level evidence copies (a
// segment never reclaimed) or a reclaimed data directory and its checkpoint.
// The current agent never opens that storage. A spool its sender fully drained
// before the upgrade holds only that metadata, and nothing in it is undelivered.

// legacySpoolIDFile is the identity the pre-lane sender persisted beside the spool.
const legacySpoolIDFile = "spool_id"

// currentFormatEntry reports root entries that belong to the bounded lane format
// and are never legacy storage.
func currentFormatEntry(name string) bool { return name == "lanes" || name == "recoveries" }

// ErrLegacyFlatNotDrained refuses to retire flat storage that may hold records.
var ErrLegacyFlatNotDrained = errors.New("spool: legacy flat storage is not provably drained")

// LegacyFlatInventory is a read-only account of the flat spool under a root.
type LegacyFlatInventory struct {
	// Entries are the root entry names that belong to the flat spool, sorted.
	Entries []string
	// Bytes is the size of every regular file under those entries.
	Bytes uint64
	// Drained is true when no flat segment holds a record byte and no evidence
	// copy holds an entry, so no committed record can lie above the resolved
	// prefix: every record the old sender wrote was reclaimed after a durable
	// disposition.
	Drained bool
	// Unrecognized are root entries that are neither the flat spool nor the
	// current format. Their presence keeps the flat spool, since the inventory
	// cannot account for them.
	Unrecognized []string
}

// Present reports whether any flat spool entry exists.
func (inv LegacyFlatInventory) Present() bool { return len(inv.Entries) > 0 }

// InspectLegacyFlat inventories the flat spool under root without opening,
// creating or modifying anything. Its emptiness proof is structural: a record
// exists only as bytes in a segment and entries in both evidence copies, so a
// flat spool whose every segment and evidence file is empty holds no record.
// It does not rely on the resolved watermark, which a partially retired spool
// may already have lost.
func InspectLegacyFlat(root string) (LegacyFlatInventory, error) {
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return LegacyFlatInventory{}, nil
	}
	if err != nil {
		return LegacyFlatInventory{}, fmt.Errorf("spool: inspect legacy flat storage: %w", err)
	}
	inv := LegacyFlatInventory{Drained: true}
	for _, entry := range entries {
		name := entry.Name()
		if currentFormatEntry(name) {
			continue
		}
		empty, recognized, err := inspectLegacyEntry(root, name)
		if err != nil {
			return LegacyFlatInventory{}, err
		}
		if !recognized {
			inv.Unrecognized = append(inv.Unrecognized, name)
			inv.Drained = false
			continue
		}
		size, err := treeBytes(filepath.Join(root, name))
		if err != nil {
			return LegacyFlatInventory{}, err
		}
		inv.Entries = append(inv.Entries, name)
		inv.Bytes += size
		inv.Drained = inv.Drained && empty
	}
	sort.Strings(inv.Entries)
	sort.Strings(inv.Unrecognized)
	inv.Drained = inv.Drained && inv.Present()
	return inv, nil
}

// inspectLegacyEntry classifies one root entry: whether it belongs to the flat
// spool, and whether it can hold no record.
func inspectLegacyEntry(root, name string) (empty, recognized bool, err error) {
	path := filepath.Join(root, name)
	info, err := os.Lstat(path)
	if err != nil {
		return false, false, fmt.Errorf("spool: inspect legacy flat storage: %w", err)
	}
	switch {
	case name == resolvedFile || name == legacySpoolIDFile:
		return true, info.Mode().IsRegular(), nil
	case name == segmentFile && info.Mode()&os.ModeSymlink != 0:
		// The pointer to a reclaimed data directory carries no record itself.
		return true, true, nil
	case name == segmentFile:
		return info.Size() == 0, info.Mode().IsRegular(), nil
	case strings.HasSuffix(name, checkpointSuffix):
		_, ok := dataBase(strings.TrimSuffix(name, checkpointSuffix))
		return true, ok && info.Mode().IsRegular(), nil
	case name == evidenceDirName(copyA) || name == evidenceDirName(copyB):
		return evidenceDirEmpty(path, info)
	}
	if _, ok := dataBase(name); ok && info.IsDir() {
		return dataDirEmpty(path)
	}
	return false, false, nil
}

// dataDirEmpty accepts only a reclaimed data directory's own layout: its segment
// and the two evidence copies. Anything else in it cannot be accounted for.
func dataDirEmpty(dir string) (empty, recognized bool, err error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false, false, fmt.Errorf("spool: inspect legacy data directory: %w", err)
	}
	empty = true
	for _, entry := range entries {
		path := filepath.Join(dir, entry.Name())
		info, err := os.Lstat(path)
		if err != nil {
			return false, false, fmt.Errorf("spool: inspect legacy data directory: %w", err)
		}
		switch name := entry.Name(); {
		case name == segmentFile && info.Mode().IsRegular():
			empty = empty && info.Size() == 0
		case name == evidenceDirName(copyA) || name == evidenceDirName(copyB):
			copyEmpty, ok, err := evidenceDirEmpty(path, info)
			if err != nil || !ok {
				return false, ok, err
			}
			empty = empty && copyEmpty
		default:
			return false, false, nil
		}
	}
	return empty, true, nil
}

func evidenceDirEmpty(dir string, info fs.FileInfo) (empty, recognized bool, err error) {
	if !info.IsDir() {
		return false, false, nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false, false, fmt.Errorf("spool: inspect legacy evidence: %w", err)
	}
	for _, entry := range entries {
		file, err := entry.Info()
		if err != nil {
			return false, false, fmt.Errorf("spool: inspect legacy evidence: %w", err)
		}
		if entry.Name() != evidenceFile || !file.Mode().IsRegular() {
			return false, false, nil
		}
		if file.Size() != 0 {
			return false, true, nil
		}
	}
	return true, true, nil
}

func treeBytes(path string) (uint64, error) {
	var total uint64
	err := filepath.WalkDir(path, func(p string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !entry.Type().IsRegular() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		total += uint64(info.Size())
		return nil
	})
	if err != nil {
		return 0, fmt.Errorf("spool: measure legacy flat storage: %w", err)
	}
	return total, nil
}

// RetireDrainedLegacyFlat removes the flat spool under root only when
// InspectLegacyFlat proves it drained, and returns the inventory it removed.
// Storage that may hold a record is refused with ErrLegacyFlatNotDrained and
// left untouched. The pointer goes before the data it names, so every state an
// interrupted retirement leaves behind is still recognized and still provably
// drained, and the next start finishes it.
func RetireDrainedLegacyFlat(root string) (LegacyFlatInventory, error) {
	inv, err := InspectLegacyFlat(root)
	if err != nil {
		return LegacyFlatInventory{}, err
	}
	if !inv.Present() {
		return inv, nil
	}
	if !inv.Drained {
		return inv, ErrLegacyFlatNotDrained
	}
	for _, name := range retirementOrder(inv.Entries) {
		if err := os.RemoveAll(filepath.Join(root, name)); err != nil {
			return inv, fmt.Errorf("spool: retire legacy flat storage: %w", err)
		}
	}
	if err := fsyncDir(root); err != nil {
		return inv, err
	}
	return inv, nil
}

// retirementOrder removes metadata and the segment pointer before the data it
// names, then checkpoints before their data directories.
func retirementOrder(entries []string) []string {
	rank := func(name string) int {
		switch {
		case name == legacySpoolIDFile, name == resolvedFile:
			return 0
		case name == segmentFile:
			return 1
		case strings.HasSuffix(name, checkpointSuffix):
			return 2
		default:
			return 3
		}
	}
	ordered := append([]string(nil), entries...)
	sort.SliceStable(ordered, func(i, j int) bool { return rank(ordered[i]) < rank(ordered[j]) })
	return ordered
}
