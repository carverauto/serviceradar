// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package spool

import (
	"bytes"
	"errors"
	"path/filepath"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// ErrRecoveryResumeRequired means a retained operation must restore its artifact
// inventory into the shared allocator before performing another recovery write.
var ErrRecoveryResumeRequired = errors.New("spool: retained recovery requires inventory resume")

// BeginRecoveryDestination reserves the complete operation before any generation
// metadata is written. Repeating it within the same active allocator returns the
// original handle and grant; retained files after restart require ResumeRecovery.
func (ls *LaneSet) BeginRecoveryDestination(key LaneKey, recoveryID []byte, attempt uint32, allocator *Allocator) (*Generation, *RecoveryGrant, error) {
	if allocator == nil || key.RouteProfile == edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1 {
		return nil, nil, ErrOutsideLane
	}
	r := &generationReservation{allocator: allocator}
	g, err := ls.recoveryDestination(key, recoveryID, attempt, r)
	return g, r.grant, err
}

// CreateRecoveryControlDestination uses the data operation's existing grant,
// including before its identity and marker are published. It never acquires a
// second recovery slot. The caller freezes its publication plan before appending.
func (ls *LaneSet) CreateRecoveryControlDestination(key LaneKey, recoveryID []byte, attempt uint32, grant *RecoveryGrant) (*Generation, error) {
	if grant == nil || key.RouteProfile != edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1 {
		return nil, ErrOutsideLane
	}
	destination, err := readGenerationIdentity(grant.lane)
	if err != nil {
		return nil, err
	}
	storedID, _, err := readRecoveryDestination(grant.lane, destination)
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(storedID, recoveryID) {
		return nil, ErrOutsideLane
	}
	r := &generationReservation{allocator: grant.alloc, grant: grant, control: true}
	g, err := ls.recoveryDestination(key, recoveryID, attempt, r)
	if err != nil {
		return nil, err
	}
	return g, grant.AttachControlLane(g)
}

func (ls *LaneSet) recoveryDestination(key LaneKey, recoveryID []byte, attempt uint32, r *generationReservation) (*Generation, error) {
	ls.sessionMu.RLock()
	defer ls.sessionMu.RUnlock()
	if len(ls.session.NetworkScopeID) == 0 {
		return nil, ErrLaneNotReady
	}
	if err := edgerecord.ValidateUUIDv7(recoveryID); err != nil {
		return nil, errors.Join(ErrPermanent, err)
	}
	l, err := ls.lane(key)
	if err != nil {
		return nil, err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.shut {
		return nil, ErrLaneSetClosed
	}
	for _, g := range l.retained {
		if bytes.Equal(g.recoveryID, recoveryID) && g.recoveryAttempt == attempt {
			if !g.id.Identity.equal(ls.session) || g.spool.alloc != r.allocator {
				return nil, ErrScopeUnauthorized
			}
			if !r.control {
				r.allocator.mu.Lock()
				r.grant = r.allocator.recoveryOwnerLocked(g.dir)
				if r.grant != nil {
					err = r.grant.healthyLocked()
				}
				r.allocator.mu.Unlock()
				if err != nil {
					return nil, err
				}
				if r.grant == nil {
					return g, ErrRecoveryResumeRequired
				}
			}
			return g, nil
		}
	}
	g, err := ls.createGeneration(l, recoveryID, attempt, r)
	if err != nil {
		return nil, err
	}
	l.retain(g)
	return g, nil
}

// generationReservation holds the same append accounting token across durable
// directory publication. Landing before Open prevents metadata being measured a
// second time as ordinary bytes by the generation's configured factory.
type generationReservation struct {
	allocator *Allocator
	grant     *RecoveryGrant
	control   bool
	charge    *recoveryAppendCharge
}

func (r *generationReservation) prepare(path string, id GenerationIdentity, recoveryID []byte, attempt uint32) error {
	if r.grant == nil {
		var err error
		r.grant, err = r.allocator.AcquireRecovery(path)
		if err != nil {
			return err
		}
	}
	g := r.grant
	if r.control {
		// Before publication, compare the already durable data identity to the
		// new immutable identity. AttachControlLane repeats the disk join later.
		destination, err := readGenerationIdentity(g.lane)
		if err != nil {
			return err
		}
		if !destination.Identity.equal(id.Identity) {
			return ErrOutsideLane
		}
		g.alloc.mu.Lock()
		if g.controlAllowances == nil {
			g.controlAllowances = make(map[string]uint64)
			g.controlFiles = make(map[string]uint64)
		}
		g.controlAllowances[path] = 0
		g.controlLane = path
		g.alloc.mu.Unlock()
	}
	// Lane, temporary generation and final publication directory barriers.
	if err := g.Charge(ArtifactFilesystemMetadata, 3*4096); err != nil {
		return err
	}
	files := map[string][]byte{
		identityFile: encodeIdentity(id), recoveryDestinationFile: encodeRecoveryDestination(id, recoveryID, attempt), evidenceFormatFile: []byte(evidenceFormatV2),
	}
	costs := make([]recoveryAppendCost, 0, len(files))
	for name, raw := range files {
		costs = append(costs, recoveryAppendCost{ArtifactDestinationSegment, filepath.Join(path, name), uint64(len(raw)), uint64(len(raw))})
	}
	var err error
	r.charge, err = g.chargeAppend(&Spool{dir: path, alloc: r.allocator}, costs, 0)
	return err
}

func (r *generationReservation) land() error {
	if err := r.charge.land(); err != nil {
		return err
	}
	return r.grant.Landed(ArtifactFilesystemMetadata, r.grant.lane, 3*4096)
}

func (r *generationReservation) fail(err error) error {
	if r.charge != nil && !r.charge.closed {
		return r.charge.fail("publish recovery generation", err)
	}
	return r.grant.FailStop("publish recovery generation", err)
}
