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
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.failErr != nil {
		return nil, a.failErr
	}
	if len(a.active) >= a.maxActive {
		return nil, ErrRecoveryConcurrencyExhausted
	}
	lane = filepath.Clean(lane)
	for other := range a.active {
		if other.lane == lane {
			return nil, fmt.Errorf("%w: destination already has an active recovery", ErrInvalidAllocatorConfig)
		}
	}
	g := &RecoveryGrant{alloc: a, lane: lane, laneFiles: make(map[string]uint64)}
	seen := make(map[string]bool, len(artifacts))
	for _, entry := range artifacts {
		if entry.Artifact >= artifactCount {
			return nil, ErrInvalidAllocatorConfig
		}
		path := filepath.Clean(entry.Path)
		if seen[path] {
			return nil, fmt.Errorf("%w: duplicate retained artifact", ErrInvalidAllocatorConfig)
		}
		seen[path] = true
		if err := g.inLane(entry.Artifact, path); err != nil {
			return nil, err
		}
		info, err := os.Lstat(path)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() || info.Size() < 0 {
			return nil, fmt.Errorf("%w: retained artifact is not a regular file", ErrInvalidAllocatorConfig)
		}
		n := uint64(info.Size())
		if n > a.budgets[entry.Artifact]-g.used[entry.Artifact] {
			return nil, &ReserveExhaustedError{Artifact: entry.Artifact, Requested: n, Remaining: a.budgets[entry.Artifact] - g.used[entry.Artifact]}
		}
		g.used[entry.Artifact] += n
		if laneArtifact(entry.Artifact) {
			g.laneFiles[path] = n
		}
	}
	hi, allowance := bits.Mul64(terminalSlots, terminalEvidenceAllowance)
	if hi != 0 || allowance > a.budgets[ArtifactDestinationSegment]-g.used[ArtifactDestinationSegment] {
		return nil, &ReserveExhaustedError{Artifact: ArtifactDestinationSegment, Requested: allowance, Remaining: a.budgets[ArtifactDestinationSegment] - g.used[ArtifactDestinationSegment]}
	}
	g.used[ArtifactDestinationSegment] += allowance
	g.pending[ArtifactDestinationSegment] = allowance
	g.terminalAllowance = allowance
	if _, carry := bits.Add64(a.inflight, allowance, 0); carry != 0 {
		return nil, ErrInvalidAllocatorConfig
	}
	// Installing the measured grant first subtracts retained files from the
	// outstanding floor. The prepaid terminal bytes remain in flight because
	// those files do not yet exist.
	previousOrdinary, hadOrdinary := a.ordinary[lane]
	a.active[g] = struct{}{}
	a.inflight += allowance
	a.ordinary[lane] -= min(a.ordinary[lane], g.laneHeldLocked())
	if err := a.requireBackedLocked(ErrReserveUnbacked, 0); err != nil {
		delete(a.active, g)
		a.inflight -= allowance
		if hadOrdinary {
			a.ordinary[lane] = previousOrdinary
		} else {
			delete(a.ordinary, lane)
		}
		return nil, err
	}
	return g, nil
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
}

// chargeAppend holds the grant's step lock until land/fail. All artifacts are
// preflighted before any charge changes, so a partial budget cannot start PREPARED.
func (g *RecoveryGrant) chargeAppend(s *Spool, costs []recoveryAppendCost, terminalAllowance uint64) (*recoveryAppendCharge, error) {
	if g == nil || s == nil || s.alloc != g.alloc || filepath.Clean(s.dir) != g.lane {
		return nil, ErrOutsideLane
	}
	g.step.Lock()
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
	var charges [artifactCount]uint64
	charges[ArtifactDestinationSegment] = allowance
	copied := make([]recoveryAppendCost, len(costs))
	copy(copied, costs)
	for i, cost := range copied {
		if !laneArtifact(cost.Artifact) || cost.Growth > cost.Written {
			return nil, ErrInvalidAllocatorConfig
		}
		copied[i].Path = filepath.Clean(cost.Path)
		if err := g.inLane(cost.Artifact, copied[i].Path); err != nil {
			return nil, err
		}
		sum, carry := bits.Add64(charges[cost.Artifact], cost.Written, 0)
		if carry != 0 {
			return nil, ErrInvalidAllocatorConfig
		}
		charges[cost.Artifact] = sum
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
	return &recoveryAppendCharge{grant: g, costs: copied, allowance: allowance}, nil
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
		g.laneFiles[cost.Path] += cost.Growth
	}
	g.terminalAllowance += c.allowance
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
