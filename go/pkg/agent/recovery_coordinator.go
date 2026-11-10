// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

package agent

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

var ErrRecoveryPending = errors.New("edge recovery pending")

var errCopyAuthorityUnavailable = errors.New("copy authority unavailable")

// recoveryStageCompleted names the stage reported once a bounded operation's
// signed completion has been recorded and its cleanup finished.
const recoveryStageCompleted = "completed"

// RecoveryCoordinator advances one bounded operation. Startup restoration must
// finish before senders run. Each Step examines at most one generation or one
// bounded operation, independently of whether any record is sender-visible.
type RecoveryCoordinator struct {
	store     *RecordSpool
	client    proto.AgentGatewayServiceClient
	suspend   func(context.Context, *spool.Generation) (func(), error)
	step      sync.Mutex
	mu        sync.RWMutex
	ready     bool
	active    *recoveryRun
	inventory RecordSpoolCursor
	scan      RecordSpoolCursor
}

type recoveryRun struct {
	dir               string
	handles           spool.RecoveryCompletionGenerations
	grant             *spool.RecoveryGrant
	completion        *spool.RecoveryCompletion
	completionDamaged bool
	op                *spool.RecoveryOperation
	plan              spool.RecoveryPlan
	manifest          spool.RecoveryManifest
	registered        bool
	copyIndex         int
}

func NewRecoveryCoordinator(store *RecordSpool, client proto.AgentGatewayServiceClient, suspend func(context.Context, *spool.Generation) (func(), error)) *RecoveryCoordinator {
	return &RecoveryCoordinator{store: store, client: client, suspend: suspend, ready: store.recoveryReady.Load()}
}

func (c *RecoveryCoordinator) Ready() bool { c.mu.RLock(); defer c.mu.RUnlock(); return c.ready }
func (c *RecoveryCoordinator) operation() *recoveryRun {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.active
}
func (c *RecoveryCoordinator) setOperation(run *recoveryRun) {
	c.mu.Lock()
	c.active = run
	c.mu.Unlock()
}

// Step returns a bounded phase label for rate-limited runtime diagnostics. A
// refusal retains the operation, reserve and source; callers retry unchanged.
func (c *RecoveryCoordinator) Step(ctx context.Context) (phase string, err error) {
	defer func() { c.store.reportRecovery(phase, err) }()
	c.step.Lock()
	defer c.step.Unlock()
	if !c.Ready() {
		return "inventory", c.inventoryNext()
	}
	if run := c.operation(); run != nil {
		if !c.store.recoveryPeerAvailable() {
			return "negotiation", fmt.Errorf("%w: peer does not advertise recovery version 1", ErrRecoveryPending)
		}
		return c.advance(ctx, run)
	}
	return "discover", c.discover(ctx)
}

func (c *RecoveryCoordinator) inventoryNext() error {
	source, ok := c.store.NextSource(&c.inventory)
	if !ok {
		if c.store.recoveryInventoryBytes != 0 {
			return fmt.Errorf("%w: unassociated retained recovery files", ErrRecoveryPending)
		}
		c.mu.Lock()
		c.ready = true
		c.mu.Unlock()
		c.store.recoveryReady.Store(true)
		return nil
	}
	g := source.Source.(*spool.Generation)
	if len(g.RecoveryID()) == 0 || g.Identity().Lane == c.controlLane() {
		return nil
	}
	run, err := c.restore(g)
	if err != nil {
		c.inventory.ordinal = source.Identity.Ordinal - 1
		return err
	}
	if run != nil {
		if c.operation() != nil {
			return fmt.Errorf("%w: multiple unfinished operations", ErrRecoveryPending)
		}
		c.setOperation(run)
	}
	return nil
}

func (c *RecoveryCoordinator) controlLane() spool.LaneKey {
	return c.store.taxonomy.RecoveryLane()
}

func (c *RecoveryCoordinator) restore(destination *spool.Generation) (*recoveryRun, error) {
	id, err := destination.RecoverySourceIdentity()
	if err != nil {
		return nil, err
	}
	page := c.store.lanes.GenerationsPage(id.Lane, id.Ordinal-1, 1)
	if len(page) != 1 || !bytes.Equal(page[0].Identity().SpoolID, id.SpoolID) {
		return nil, spool.ErrRecoveryPlan
	}
	run := &recoveryRun{dir: c.operationDirectory(destination.RecoveryID()), handles: spool.RecoveryCompletionGenerations{Source: page[0], Destination: destination}}
	for attempt := range uint32(spool.MaxRecoveryControlAttempts) {
		if control, ok := c.store.lanes.RecoveryDestination(c.controlLane(), destination.RecoveryID(), attempt); ok {
			run.handles.Controls = append(run.handles.Controls, control)
		}
	}
	inventory, err := spool.InventoryRecoveryStorage(run.dir, run.handles)
	if err != nil {
		return nil, err
	}
	measured, err := inventory.StoredBytes()
	if err != nil {
		return nil, err
	}
	if measured > c.store.recoveryInventoryBytes {
		return nil, fmt.Errorf("%w: changed operation inventory", ErrRecoveryPending)
	}
	run.grant, err = inventory.Restore(c.store.allocator)
	if err != nil {
		return nil, err
	}
	c.store.recoveryInventoryBytes -= measured
	c.store.allocator.ChargeMeasured(filepath.Join(c.store.root, "recoveries"), c.store.recoveryInventoryBytes)
	if inventory.Completed() {
		return nil, nil
	}
	run.completion = inventory.Completion()
	run.completionDamaged = inventory.CompletionError() != nil
	return run, nil
}

func (c *RecoveryCoordinator) operationDirectory(id []byte) string {
	return filepath.Join(c.store.root, "recoveries", hex.EncodeToString(id))
}

func (c *RecoveryCoordinator) discover(ctx context.Context) error {
	source, ok := c.store.NextSource(&c.scan)
	if !ok {
		c.scan = RecordSpoolCursor{}
		return nil
	}
	g := source.Source.(*spool.Generation)
	if len(g.RecoveryID()) != 0 {
		return nil
	}
	health, err := g.Health(time.Now())
	if err != nil {
		return err
	}
	if health.GapCount == 0 {
		return nil
	}
	if !c.store.recoveryPeerAvailable() {
		return fmt.Errorf("%w: peer does not advertise recovery version 1", ErrRecoveryPending)
	}
	if c.suspend == nil {
		return fmt.Errorf("%w: source session owner unavailable", ErrRecoveryPending)
	}
	resume, err := c.suspend(ctx, g)
	if err != nil {
		return err
	}
	defer resume()
	id, err := edgerecord.NewUUIDv7()
	if err != nil {
		return err
	}
	destination, grant, err := c.store.lanes.BeginRecoveryDestination(g, id, 0, c.store.allocator)
	if err != nil {
		c.scan.ordinal = source.Identity.Ordinal - 1
		return err
	}
	run := &recoveryRun{dir: c.operationDirectory(id), handles: spool.RecoveryCompletionGenerations{Source: g, Destination: destination}, grant: grant}
	c.setOperation(run)
	_, err = spool.BeginRecoveryOperation(run.dir, g, destination, grant, time.Now().UnixNano(), "allocated_spool_gap")
	return err
}

func (c *RecoveryCoordinator) openOperation(ctx context.Context, run *recoveryRun) error {
	if run.op != nil || run.completion != nil {
		return nil
	}
	journal, err := spool.OpenRecoveryJournal(run.dir)
	if errors.Is(err, spool.ErrRecoveryJournalIncomplete) {
		journal, err = spool.RepairRecoveryJournal(run.dir, run.grant)
	}
	if errors.Is(err, os.ErrNotExist) {
		if c.suspend == nil {
			return ErrRecoveryPending
		}
		resume, stopErr := c.suspend(ctx, run.handles.Source)
		if stopErr != nil {
			return stopErr
		}
		defer resume()
		if _, _, err = c.store.lanes.BeginRecoveryDestination(run.handles.Source, run.handles.Destination.RecoveryID(), 0, c.store.allocator); err != nil {
			return err
		}
		if _, err = spool.BeginRecoveryOperation(run.dir, run.handles.Source, run.handles.Destination, run.grant, time.Now().UnixNano(), "allocated_spool_gap"); err != nil {
			return err
		}
		journal, err = spool.OpenRecoveryJournal(run.dir)
	}
	if err != nil {
		return err
	}
	if err = spool.RepairRecoveryPhases(run.dir, run.grant); err != nil {
		return err
	}
	operation, err := spool.OpenRecoveryOperation(run.dir, run.handles.Source, run.handles.Destination, run.grant)
	if err != nil {
		return err
	}
	run.plan, err = journal.FrozenPlan()
	if err != nil {
		return err
	}
	run.manifest, err = journal.BuildManifest()
	if err != nil {
		return err
	}
	run.op = operation
	return nil
}

func (c *RecoveryCoordinator) advance(ctx context.Context, run *recoveryRun) (string, error) {
	if err := c.restoreCompletion(run); err != nil {
		return "completion_inventory", err
	}

	if run.completion != nil {
		if err := c.finishCompletion(run); err != nil {
			return "cleanup", err
		}
		return recoveryStageCompleted, nil
	}
	if err := c.openOperation(ctx, run); err != nil {
		return "freeze", err
	}
	if !run.registered {
		_, err := c.client.RegisterEdgeRecovery(ctx, recoveryRegistration(run))
		if err == nil {
			c.mu.Lock()
			run.registered = true
			c.mu.Unlock()
		}
		return "register", err
	}
	progress, err := run.op.PublicationProgress()
	if err != nil {
		return "publication_inventory", err
	}
	if !progress.CoverageSealed || !progress.SourceReclaimed {
		return c.advanceCoverage(ctx, run, progress)
	}
	return c.completeConsumer(ctx, run)
}

func (c *RecoveryCoordinator) restoreCompletion(run *recoveryRun) error {
	if run.completionDamaged {
		repaired, err := spool.RepairRecoveryCompletion(run.dir, run.grant)
		if err != nil {
			return err
		}
		run.completion = repaired
		run.completionDamaged = false
	}
	if run.completion == nil {
		completion, err := spool.OpenRecoveryCompletion(run.dir)
		if err == nil {
			run.completion = completion
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}

	return nil
}

func (c *RecoveryCoordinator) advanceCoverage(ctx context.Context, run *recoveryRun, progress spool.RecoveryPublicationProgress) (string, error) {
	var err error
	if !progress.CoverageSealed {
		for visited := 0; run.copyIndex < len(run.plan.Slots) && visited < 16; visited++ {
			slot := run.plan.Slots[run.copyIndex]
			if slot.Copy != nil {
				if _, err = run.op.Copy(slot.Sequence); err != nil {
					return "copy", err
				}
			}
			run.copyIndex++
		}
		if run.copyIndex < len(run.plan.Slots) {
			return "copy", nil
		}
		if !allRecoveryPublicationsAccepted(progress.Acknowledged) {
			return "publish", c.publish(ctx, run, progress)
		}
		_, err = run.op.SealCoverage()
		return "coverage", err
	}
	if err = run.op.ArchiveTerminalEvidence(); err != nil {
		return "source_archive", err
	}
	return "source_reclaim", run.op.ReclaimSource()
}

func (c *RecoveryCoordinator) completeConsumer(ctx context.Context, run *recoveryRun) (string, error) {
	resolved, capability, err := run.op.ReadSignedResolution()
	if errors.Is(err, os.ErrNotExist) {
		status, queryErr := c.client.GetEdgeRecovery(ctx, recoveryQuery(run))
		if queryErr != nil {
			return "consumer_query", queryErr
		}
		if status.GetState() != proto.EdgeRecoveryState_EDGE_RECOVERY_STATE_RESOLVED {
			return "consumer_pending", ErrRecoveryPending
		}
		resolved, capability, err = status.GetResolved(), status.GetResolutionCapability(), nil
	}
	if err != nil {
		return "receipt", err
	}
	validated, err := c.validateResolution(run.handles.Source.Identity(), resolved, capability)
	if err != nil {
		return "receipt_trust", err
	}
	if err = run.op.RecordResolution(validated); err != nil {
		return "receipt", err
	}
	if err = run.op.FinishCleanup(validated, run.handles.Controls); err != nil {
		return "cleanup", err
	}
	c.setOperation(nil)
	return recoveryStageCompleted, nil
}

func (c *RecoveryCoordinator) validateResolution(identity spool.GenerationIdentity, resolved *edgev1.RecoveryResolvedV1, capability *edgev1.EdgeSignedCapabilityV1) (*edgerecord.ValidatedRecoveryResolution, error) {
	if c.store.trust == nil {
		return nil, edgerecord.ErrTrustMissing
	}
	policy, err := c.store.trust().NamespacePolicy(identity.Identity.NetworkScopeID, identity.Identity.AgentID, time.Now().UnixNano())
	if err != nil {
		return nil, err
	}
	return edgerecord.ValidateRecoveryResolution(resolved, capability, identity.Identity.NetworkScopeID, identity.Identity.AgentID, policy)
}

func (c *RecoveryCoordinator) finishCompletion(run *recoveryRun) error {
	resolved, capability, err := run.completion.SignedResolution()
	if err != nil {
		return err
	}
	validated, err := c.validateResolution(run.handles.Source.Identity(), resolved, capability)
	if err != nil {
		return err
	}
	if err = run.completion.Finish(run.grant, run.handles, validated); err != nil {
		return err
	}
	c.setOperation(nil)
	return nil
}

func recoveryQuery(run *recoveryRun) *proto.EdgeRecoveryQuery {
	return &proto.EdgeRecoveryQuery{NetworkScopeId: run.handles.Source.Identity().Identity.NetworkScopeID, RecoveryId: run.handles.Destination.RecoveryID()}
}
func recoveryRegistration(run *recoveryRun) *proto.EdgeRecoveryRegistration {
	p := run.plan
	request := &proto.EdgeRecoveryRegistration{ProtocolVersion: 1, NetworkScopeId: p.Source.Identity.NetworkScopeID, RecoveryId: p.RecoveryID, PriorSpoolId: p.Source.SpoolID, NewSpoolId: p.NewSpoolID, RouteProfile: p.Source.Lane.RouteProfile, TrafficClass: p.Source.Lane.TrafficClass, SourceReclaimWatermark: p.ReclaimThrough, SourceHighWater: p.HighWater, FromSequence: p.First, ThroughSequence: p.Last, ManifestPages: run.manifest.Pages, Tombstone: run.manifest.Tombstone}
	for _, slot := range p.Slots {
		if copy := slot.Copy; copy != nil {
			request.Copies = append(request.Copies, &proto.EdgeRecoveryCopy{PriorSequence: slot.Sequence, NewSequence: copy.NewSequence, EventId: copy.EventID, RecordSha256: copy.RecordSHA256, AttributionBindingSha256: copy.AttributionBindingSHA256})
		}
	}
	return request
}

func allRecoveryPublicationsAccepted(receipts []bool) bool {
	for _, accepted := range receipts {
		if !accepted {
			return false
		}
	}
	return len(receipts) > 0
}

// OperationID is a detached diagnostic identifier, never an authority operand.
func (c *RecoveryCoordinator) OperationID() []byte {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.active == nil {
		return nil
	}
	return c.active.handles.Destination.RecoveryID()
}
