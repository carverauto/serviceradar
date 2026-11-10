// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"fmt"
	"os"
	"path/filepath"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// AttachControlLane assigns a dedicated recovery-control generation to this
// grant. Its complete records, evidence, sidecars and terminal allowance consume
// ManifestPages, so a single active recovery needs no second concurrency slot.
// The coordinator must persist this identity in its phase inventory before any
// control append. Recovery controls never share the producer destination.
func (g *RecoveryGrant) AttachControlLane(control *Generation) error {
	if g == nil || control == nil || control.spool.alloc != g.alloc {
		return ErrOutsideLane
	}
	g.step.Lock()
	defer g.step.Unlock()
	g.alloc.mu.Lock()
	defer g.alloc.mu.Unlock()
	if err := g.healthyLocked(); err != nil {
		return err
	}
	if g.finished || g.artifactsReleased {
		return ErrRecoveryFinished
	}
	path := filepath.Clean(control.dir)
	if err := validateRecoveryControlLane(g.lane, path); err != nil {
		return err
	}
	if owner := g.alloc.recoveryOwnerLocked(path); owner != nil && owner != g {
		return ErrOutsideLane
	}
	if g.controlAllowances == nil {
		g.controlAllowances = make(map[string]uint64)
	}
	if _, ok := g.controlAllowances[path]; !ok {
		g.controlAllowances[path] = 0
	}
	g.controlLane = path
	if g.controlFiles == nil {
		g.controlFiles = make(map[string]uint64)
	}
	return nil
}

func validateRecoveryControlLane(destination, control string) error {
	if filepath.Clean(destination) == filepath.Clean(control) {
		return ErrOutsideLane
	}
	dest, err := readGenerationIdentity(destination)
	if err != nil {
		return err
	}
	ctl, err := readGenerationIdentity(control)
	if err != nil {
		return err
	}
	if !dest.Identity.equal(ctl.Identity) || ctl.Lane.RouteProfile != edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1 {
		return fmt.Errorf("%w: recovery control namespace or route", ErrOutsideLane)
	}
	return nil
}

func readGenerationIdentity(dir string) (GenerationIdentity, error) {
	raw, err := os.ReadFile(filepath.Join(dir, identityFile))
	if err != nil {
		return GenerationIdentity{}, err
	}
	return decodeIdentity(raw)
}

// CommitRecoveryControl commits a typed, authorized control using the same
// durable attributed append and sender-visible slot contract as ordinary data.
// AttachControlLane and the coordinator's frozen publication plan precede it.
func (s *Spool) CommitRecoveryControl(a AttributedAppend, grant *RecoveryGrant) (CommitReceipt, error) {
	if grant == nil {
		return CommitReceipt{}, ErrOutsideLane
	}
	grant.alloc.mu.Lock()
	attached := grant.controlLane == filepath.Clean(s.dir)
	grant.alloc.mu.Unlock()
	if !attached {
		return CommitReceipt{}, ErrOutsideLane
	}
	return s.commit("", a.EventID, a.Body, Bindings{ReceiptSHA256: a.ReceiptSHA256}, &pendingAttribution{validated: &a.Validated, grant: grant})
}

func (g *RecoveryGrant) controlHeldLocked(owner string) uint64 {
	if g.artifactsReleased {
		return 0
	}
	held := g.controlAllowances[owner]
	for path, n := range g.controlFiles {
		if recoveryLanePath(owner, path) {
			held += n
		}
	}
	return held
}

func (a *Allocator) recoveryOwnerLocked(path string) *RecoveryGrant {
	for g := range a.active {
		_, control := g.controlAllowances[path]
		if g.lane == path || control {
			return g
		}
	}
	return nil
}
