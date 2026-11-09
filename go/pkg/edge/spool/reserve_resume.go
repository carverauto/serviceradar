// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"fmt"
	"math/bits"
	"os"
	"path/filepath"
	"strings"
)

// RecoveryArtifact identifies retained output to measure when resuming a
// recovery. It grants no authority to delete the file or treat it as complete.
type RecoveryArtifact struct {
	Artifact Artifact
	Path     string
}

// ResumeRecovery restores retained files before checking the remaining physical
// reserve. The coordinator must serialize recovery work and inventory all its
// retained output, including interrupted temporary files. terminalSlots is the
// number of committed destination slots whose terminal evidence is still owed.
// The footprint covers retained bytes plus all remaining writes and repairs;
// no caller-provided byte count is accepted as a measurement of a file.
func (a *Allocator) ResumeRecovery(lane string, artifacts []RecoveryArtifact, terminalSlots uint64) (*RecoveryGrant, error) {
	return a.resumeRecovery(lane, nil, artifacts, terminalSlots)
}

// RecoveryControlInventory identifies each retained control attempt. The last
// entry is the current append destination; earlier attempts remain charged.
type RecoveryControlInventory struct {
	Directory     string
	TerminalSlots uint64
}

// ResumeRecoveryWithControls measures every attempted control generation in the
// same grant before checking remaining physical backing. Inventory includes their
// record/evidence/sidecar files as ArtifactManifestPages.
func (a *Allocator) ResumeRecoveryWithControls(lane string, controls []RecoveryControlInventory, artifacts []RecoveryArtifact, terminalSlots uint64) (*RecoveryGrant, error) {
	for _, c := range controls {
		if err := validateRecoveryControlLane(lane, c.Directory); err != nil {
			return nil, err
		}
	}
	return a.resumeRecovery(lane, controls, artifacts, terminalSlots)
}

func (a *Allocator) resumeRecovery(lane string, controls []RecoveryControlInventory, artifacts []RecoveryArtifact, terminalSlots uint64) (*RecoveryGrant, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.failErr != nil {
		return nil, a.failErr
	}
	if len(a.active) >= a.maxActive {
		return nil, ErrRecoveryConcurrencyExhausted
	}
	lane = filepath.Clean(lane)
	owners := []string{lane}
	controlSet := map[string]uint64{}
	var currentControl string
	for _, c := range controls {
		path := filepath.Clean(c.Directory)
		if _, ok := controlSet[path]; ok || path == lane {
			return nil, ErrInvalidAllocatorConfig
		}
		controlSet[path] = c.TerminalSlots
		owners = append(owners, path)
		currentControl = path
	}
	for _, owner := range owners {
		if a.recoveryOwnerLocked(owner) != nil {
			return nil, fmt.Errorf("%w: generation already has an active recovery", ErrInvalidAllocatorConfig)
		}
	}
	g := &RecoveryGrant{alloc: a, lane: lane, controlLane: currentControl, laneFiles: make(map[string]uint64), controlFiles: make(map[string]uint64), controlAllowances: make(map[string]uint64)}
	if err := g.restoreArtifacts(artifacts, controlSet); err != nil {
		return nil, err
	}
	allowance, err := g.restoreTerminalAllowance(ArtifactDestinationSegment, terminalSlots)
	if err != nil {
		return nil, err
	}
	g.terminalAllowance = allowance
	var carry uint64
	for owner, slots := range controlSet {
		n, err := g.restoreTerminalAllowance(ArtifactManifestPages, slots)
		if err != nil {
			return nil, err
		}
		g.controlAllowances[owner] = n
		allowance, carry = bits.Add64(allowance, n, 0)
		if carry != 0 {
			return nil, ErrInvalidAllocatorConfig
		}
	}
	if _, carry = bits.Add64(a.inflight, allowance, 0); carry != 0 {
		return nil, ErrInvalidAllocatorConfig
	}
	if err := a.installRecoveryRestore(g, owners, allowance); err != nil {
		return nil, err
	}
	return g, nil
}

func (a *Allocator) installRecoveryRestore(g *RecoveryGrant, owners []string, allowance uint64) error {
	// Measure both owners before checking backing: retained files have already
	// reduced physical free space and must not be reserved a second time.
	previous := map[string]uint64{}
	present := map[string]bool{}
	for _, owner := range owners {
		previous[owner], present[owner] = a.ordinary[owner]
	}
	a.active[g] = struct{}{}
	a.inflight += allowance
	for _, owner := range owners {
		a.ordinary[owner] -= min(a.ordinary[owner], a.heldInLaneLocked(owner))
	}
	if err := a.requireBackedLocked(ErrReserveUnbacked, 0); err != nil {
		delete(a.active, g)
		a.inflight -= allowance
		for _, owner := range owners {
			if present[owner] {
				a.ordinary[owner] = previous[owner]
			} else {
				delete(a.ordinary, owner)
			}
		}
		return err
	}
	return nil
}

func (g *RecoveryGrant) restoreArtifacts(artifacts []RecoveryArtifact, controlSet map[string]uint64) error {
	seen := make(map[string]bool, len(artifacts))
	for _, entry := range artifacts {
		if entry.Artifact >= artifactCount {
			return ErrInvalidAllocatorConfig
		}
		path := filepath.Clean(entry.Path)
		if seen[path] {
			return fmt.Errorf("%w: duplicate retained artifact", ErrInvalidAllocatorConfig)
		}
		seen[path] = true
		if err := g.inLane(entry.Artifact, path); err != nil {
			return err
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		if info.Size() < 0 || (!info.Mode().IsRegular() && !(entry.Artifact == ArtifactFilesystemMetadata && info.IsDir())) {
			return fmt.Errorf("%w: retained artifact is not a regular file or metadata directory", ErrInvalidAllocatorConfig)
		}
		n := uint64(info.Size())
		if info.IsDir() {
			// The same minimum charged when durable recovery directories are made.
			// Larger measured directories cannot disappear from physical backing.
			n = max(n, 4096)
		}
		if n > g.alloc.budgets[entry.Artifact]-g.used[entry.Artifact] {
			return &ReserveExhaustedError{Artifact: entry.Artifact, Requested: n, Remaining: g.alloc.budgets[entry.Artifact] - g.used[entry.Artifact]}
		}
		g.used[entry.Artifact] += n
		if laneArtifact(entry.Artifact) {
			g.laneFiles[path] = n
		}
		if entry.Artifact == ArtifactManifestPages {
			for owner := range controlSet {
				if recoveryLanePath(owner, path) {
					g.controlFiles[path] = n
					break
				}
			}
		}
	}
	return nil
}

func (g *RecoveryGrant) restoreTerminalAllowance(art Artifact, slots uint64) (uint64, error) {
	hi, allowance := bits.Mul64(slots, terminalEvidenceAllowance)
	if hi != 0 || allowance > g.alloc.budgets[art]-g.used[art] {
		return 0, &ReserveExhaustedError{Artifact: art, Requested: allowance, Remaining: g.alloc.budgets[art] - g.used[art]}
	}
	g.used[art] += allowance
	g.pending[art] += allowance
	return allowance, nil
}

// recoveryAppendCost separates cumulative reserve consumption from growth of
// retained destination files. Overwriting prepared bytes consumes reserve even
// when it does not grow the file; sparse growth must also be fully reserved.
type recoveryAppendCost struct {
	Artifact        Artifact
	Path            string
	Written, Growth uint64
}

type recoveryAppendCharge struct {
	grant     *RecoveryGrant
	costs     []recoveryAppendCost
	allowance uint64
	closed    bool
	control   bool
	owner     string
}

// chargeAppend holds the grant's step lock until land/fail. All artifacts are
// preflighted before any charge changes, so a partial budget cannot start PREPARED.
func (g *RecoveryGrant) chargeAppend(s *Spool, costs []recoveryAppendCost, terminalAllowance uint64) (*recoveryAppendCharge, error) {
	if g == nil || s == nil || s.alloc != g.alloc {
		return nil, ErrOutsideLane
	}
	g.step.Lock()
	control := filepath.Clean(s.dir) == g.controlLane && g.controlLane != ""
	if filepath.Clean(s.dir) != g.lane && !control {
		g.step.Unlock()
		return nil, ErrOutsideLane
	}
	if control {
		costs = append([]recoveryAppendCost(nil), costs...)
		for i := range costs {
			costs[i].Artifact = ArtifactManifestPages
		}
	}
	token, err := g.chargeAppendLocked(costs, terminalAllowance)
	if err != nil {
		g.step.Unlock()
	}
	return token, err
}

func (g *RecoveryGrant) chargeAppendLocked(costs []recoveryAppendCost, allowance uint64) (*recoveryAppendCharge, error) {
	a := g.alloc
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := g.healthyLocked(); err != nil {
		return nil, err
	}
	if g.finished || g.sourceReleased {
		return nil, ErrRecoveryFinished
	}
	token, charges, err := g.prepareAppendCharge(costs, allowance)
	if err != nil {
		return nil, err
	}
	for art, n := range charges {
		remaining := a.budgets[art] - g.used[art]
		if n > remaining {
			err := &ReserveExhaustedError{Artifact: Artifact(art), Requested: n, Remaining: remaining}
			g.stopErr = err
			return nil, err
		}
	}
	for art, n := range charges {
		g.used[art] += n
		g.pending[art] += n
		a.inflight += n
	}
	return token, nil
}

func (g *RecoveryGrant) prepareAppendCharge(costs []recoveryAppendCost, allowance uint64) (*recoveryAppendCharge, [artifactCount]uint64, error) {
	var charges [artifactCount]uint64
	control := len(costs) > 0 && costs[0].Artifact == ArtifactManifestPages
	allowanceArtifact := ArtifactDestinationSegment
	if control {
		allowanceArtifact = ArtifactManifestPages
	}
	charges[allowanceArtifact] = allowance
	copied := make([]recoveryAppendCost, len(costs))
	copy(copied, costs)
	for i, cost := range copied {
		if (!control && !laneArtifact(cost.Artifact)) || (control && cost.Artifact != ArtifactManifestPages) || cost.Growth > cost.Written {
			return nil, charges, ErrInvalidAllocatorConfig
		}
		copied[i].Path = filepath.Clean(cost.Path)
		if control {
			if g.controlLane == "" || !recoveryLanePath(g.controlLane, copied[i].Path) {
				return nil, charges, ErrOutsideLane
			}
		} else if err := g.inLane(cost.Artifact, copied[i].Path); err != nil {
			return nil, charges, err
		}
		sum, carry := bits.Add64(charges[cost.Artifact], cost.Written, 0)
		if carry != 0 {
			return nil, charges, ErrInvalidAllocatorConfig
		}
		charges[cost.Artifact] = sum
	}

	return &recoveryAppendCharge{grant: g, costs: copied, allowance: allowance, control: control, owner: g.controlLane}, charges, nil
}

func (c *recoveryAppendCharge) land() error {
	if c.closed {
		return ErrRecoveryFinished
	}
	c.closed = true
	g := c.grant
	a := g.alloc
	a.mu.Lock()
	for _, cost := range c.costs {
		g.landLocked(cost.Artifact, cost.Written)
		if c.control {
			g.controlFiles[cost.Path] += cost.Growth
		} else {
			g.laneFiles[cost.Path] += cost.Growth
		}
	}
	if c.control {
		g.controlAllowances[c.owner] += c.allowance
	} else {
		g.terminalAllowance += c.allowance
	}
	err := g.healthyLocked()
	a.mu.Unlock()
	g.step.Unlock()
	return err
}

func (c *recoveryAppendCharge) fail(op string, err error) error {
	if c.closed {
		return err
	}
	c.closed = true
	stopped := c.grant.FailStop(op, err)
	c.grant.step.Unlock()
	return stopped
}

// recoveryLanePath accepts only the existing generation layout: direct files,
// the two evidence directories, and those same files under a reclaim data dir.
func recoveryLanePath(lane, path string) bool {
	relative, err := filepath.Rel(lane, filepath.Clean(path))
	if err != nil {
		return false
	}
	parts := strings.Split(relative, string(filepath.Separator))
	if len(parts) == 0 || parts[0] == ".." || parts[0] == "." {
		return false
	}
	if len(parts) == 1 {
		return true
	}
	if _, ok := dataBase(parts[0]); ok {
		parts = parts[1:]
		if len(parts) == 1 {
			return true
		}
	}
	return len(parts) == 2 && (parts[0] == evidenceDirName(copyA) || parts[0] == evidenceDirName(copyB))
}
