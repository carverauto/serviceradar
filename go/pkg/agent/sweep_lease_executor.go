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

package agent

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/google/uuid"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Sweep lease execution (openspec/changes/unify-sweep-results-proto, M2.0e):
// for a leased group the lease replaces the agent's local ticker. The
// executor runs each installed slot at its signed time from the agent's own
// clock, connected or not, under the slot's core-minted execution id. A slot
// is refused while the wall clock reads earlier than the lease's signed
// issuance time (the production capability's not_before, the last
// authenticated time the agent saw) minus the ABI's 5-minute clock
// tolerance; there is no NTP-sync requirement, and a fast clock stays
// bounded by the signed slot windows. When no valid slot remains the group
// stops sweeping and reports the lease exhausted in its status payload.
//
// Slot checks are the plan and capability structure plus their correlation
// (ValidatePlanPages, ValidateCapability, claim bindings). Cryptographic
// signature verification is the gateway's: it alone receives issuer public
// keys (M2.0f), while the lease reached the agent over the authenticated
// control path. Producing edge records from the runs is M2.1; until then a
// leased run's results flow the existing sweep-results path under the
// slot's execution id, and M2.2's per-agent opt-in decides which groups
// core leases at all.

const (
	// sweepLeaseStateActive and sweepLeaseStateExhausted are the lease
	// states a leased group reports in its sweep status payload.
	sweepLeaseStateActive    = "active"
	sweepLeaseStateExhausted = "exhausted"

	// sweepLeaseExecutorMaxWait caps how long the executor sleeps between
	// passes, so clock jumps and lease installs the wake signal missed are
	// still picked up promptly.
	sweepLeaseExecutorMaxWait = 30 * time.Second
	// sweepLeaseExecutorMinWait floors the sleep so a due slot that cannot
	// run yet (clock floor, missing group service) is retried soon without
	// busy-looping.
	sweepLeaseExecutorMinWait = 250 * time.Millisecond
)

// errSweepLeaseClockFloor marks a slot refused only because the agent's wall
// clock is behind the lease's signed issuance floor. That refusal is not
// terminal: the slot is retried until its collection window closes.
var errSweepLeaseClockFloor = errors.New("sweep lease clock floor")

// sweepLeaseRunner is the slice of MultiSweepService the executor drives.
type sweepLeaseRunner interface {
	RunSweepGroupExecution(ctx context.Context, groupID string, executionID string) error
	SetGroupLeaseDriven(groupID string, driven bool)
	SetGroupLeaseState(groupID string, state string, nextSlotUnixNano int64, slotsRemaining int)
}

// sweepLeaseExecutor runs installed lease slots. Services are resolved per
// pass through runnerFor because config pushes replace group services while
// the executor keeps running.
type sweepLeaseExecutor struct {
	store     *sweepLeaseStore
	runnerFor func() sweepLeaseRunner
	logger    logger.Logger
	wake      <-chan struct{}

	// driven tracks the groups this executor has taken off their local
	// ticker, so a group whose lease disappears (revoked) is handed back.
	driven map[string]bool
}

func newSweepLeaseExecutor(store *sweepLeaseStore, runnerFor func() sweepLeaseRunner, wake <-chan struct{}, log logger.Logger) *sweepLeaseExecutor {
	return &sweepLeaseExecutor{
		store:     store,
		runnerFor: runnerFor,
		logger:    log,
		wake:      wake,
		driven:    make(map[string]bool),
	}
}

// run drives slots until ctx ends. It is the agent-lifetime loop started by
// the push loop; gateway connection state plays no part in it.
func (e *sweepLeaseExecutor) run(ctx context.Context) {
	for {
		wait := e.step(ctx, time.Now())

		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-e.wake:
			timer.Stop()
		case <-timer.C:
		}
	}
}

// step makes one pass at now: it syncs which groups are lease-driven, runs
// every due slot, refreshes each leased group's reported state, and returns
// how long to sleep before the next pass.
func (e *sweepLeaseExecutor) step(ctx context.Context, now time.Time) time.Duration {
	wait := sweepLeaseExecutorMaxWait
	runner := e.runnerFor()
	groups := e.store.Groups()
	installed := make(map[string]bool, len(groups))

	for _, groupID := range groups {
		installed[groupID] = true

		lease := e.store.Get(groupID)
		if lease == nil {
			continue
		}

		if runner != nil && !e.driven[groupID] {
			runner.SetGroupLeaseDriven(groupID, true)
			e.driven[groupID] = true
		}

		if groupWait := e.runGroup(ctx, runner, groupID, lease, now); groupWait < wait {
			wait = groupWait
		}
	}

	for groupID := range e.driven {
		if installed[groupID] {
			continue
		}

		if runner != nil {
			runner.SetGroupLeaseDriven(groupID, false)
		}
		delete(e.driven, groupID)
	}

	if wait < sweepLeaseExecutorMinWait {
		wait = sweepLeaseExecutorMinWait
	}

	return wait
}

// runGroup runs one group's due slots and reports its lease state. The
// returned wait is when this group next needs attention.
func (e *sweepLeaseExecutor) runGroup(ctx context.Context, runner sweepLeaseRunner, groupID string, lease *edgev1.SweepLeaseV1, now time.Time) time.Duration {
	nowNano := now.UnixNano()
	wait := sweepLeaseExecutorMaxWait

	for _, slot := range lease.GetSlots() {
		if slot.GetCollectionExpiresUnixNano() <= nowNano || slot.GetSlotStartUnixNano() > nowNano {
			continue
		}

		executionID, err := uuid.FromBytes(slot.GetExecutionId())
		if err != nil || e.store.Executed(groupID, executionID.String()) {
			continue
		}

		if retryIn := e.runSlot(ctx, runner, groupID, lease, slot, executionID.String(), now); retryIn > 0 && retryIn < wait {
			wait = retryIn
		}
	}

	// Remaining horizon after this pass: unexecuted slots whose collection
	// window is still open.
	remaining := 0
	var nextStart int64

	for _, slot := range lease.GetSlots() {
		if slot.GetCollectionExpiresUnixNano() <= nowNano {
			continue
		}

		executionID, err := uuid.FromBytes(slot.GetExecutionId())
		if err != nil || e.store.Executed(groupID, executionID.String()) {
			continue
		}

		remaining++
		if nextStart == 0 {
			nextStart = slot.GetSlotStartUnixNano()
		}

		if slot.GetSlotStartUnixNano() > nowNano {
			if until := time.Duration(slot.GetSlotStartUnixNano() - nowNano); until < wait {
				wait = until
			}
		}
	}

	if runner != nil {
		state := sweepLeaseStateActive
		if remaining == 0 {
			state = sweepLeaseStateExhausted
		}
		runner.SetGroupLeaseState(groupID, state, nextStart, remaining)
	}

	return wait
}

// runSlot executes one due slot. A positive return asks for a retry after
// that long (clock floor or no group service yet); zero means the slot is
// settled, whether it ran or was terminally refused.
func (e *sweepLeaseExecutor) runSlot(ctx context.Context, runner sweepLeaseRunner, groupID string, lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1, executionID string, now time.Time) time.Duration {
	nowNano := now.UnixNano()

	if err := validateSweepLeaseSlot(lease, slot, nowNano); err != nil {
		if errors.Is(err, errSweepLeaseClockFloor) {
			e.logger.Warn().Err(err).
				Str("sweep_group_id", groupID).
				Str("execution_id", executionID).
				Msg("Refusing leased sweep slot until the wall clock reaches the lease issuance floor")

			floor := lease.GetProductionCapability().GetNotBeforeUnixNano() - edgerecord.MaxClockToleranceNano
			if until := time.Duration(floor - nowNano); until > 0 {
				return until
			}

			return sweepLeaseExecutorMinWait
		}

		e.logger.Error().Err(err).
			Str("sweep_group_id", groupID).
			Str("execution_id", executionID).
			Msg("Refusing invalid leased sweep slot")
		e.markExecuted(groupID, executionID, slot, now)

		return 0
	}

	if runner == nil {
		return sweepLeaseExecutorMinWait
	}

	err := runner.RunSweepGroupExecution(ctx, groupID, executionID)
	if err != nil && (errors.Is(err, errSweepGroupNotFound) || errors.Is(err, errSweepRunnerUnavailable)) {
		// The group's service is not running yet (its config push may lag
		// the lease push); retry until the collection window closes.
		e.logger.Debug().Err(err).
			Str("sweep_group_id", groupID).
			Str("execution_id", executionID).
			Msg("Leased sweep slot waiting for its group service")

		return sweepLeaseExecutorMinWait
	}

	if err != nil {
		e.logger.Error().Err(err).
			Str("sweep_group_id", groupID).
			Str("execution_id", executionID).
			Msg("Leased sweep slot run failed")
	} else {
		e.logger.Info().
			Str("sweep_group_id", groupID).
			Str("execution_id", executionID).
			Int64("slot_start_unix_nano", slot.GetSlotStartUnixNano()).
			Msg("Ran leased sweep slot")
	}

	e.markExecuted(groupID, executionID, slot, now)

	return 0
}

func (e *sweepLeaseExecutor) markExecuted(groupID string, executionID string, slot *edgev1.SweepLeaseSlotV1, now time.Time) {
	if err := e.store.MarkExecuted(groupID, executionID, slot.GetCollectionExpiresUnixNano(), now); err != nil {
		e.logger.Warn().Err(err).
			Str("sweep_group_id", groupID).
			Str("execution_id", executionID).
			Msg("Failed to persist leased slot execution; it may re-run after a restart")
	}
}

// validateSweepLeaseSlot is the gate a slot must pass before it runs: the
// lease's production capability and the slot's plan and per-range source
// authorizations are structurally valid and bound to this lease, execution
// and plan, and the agent's clock is not behind the signed issuance floor.
func validateSweepLeaseSlot(lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1, nowUnixNano int64) error {
	capability := lease.GetProductionCapability()
	if err := edgerecord.ValidateCapability(capability, edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION); err != nil {
		return fmt.Errorf("%w: production capability: %v", errInvalidSweepLease, err)
	}

	production := capability.GetProduction()
	switch {
	case !bytes.Equal(production.GetRunId(), lease.GetLeaseId()):
		return fmt.Errorf("%w: production capability run is not the lease", errInvalidSweepLease)
	case !bytes.Equal(production.GetProducerAssignmentId(), lease.GetProducerAssignmentId()):
		return fmt.Errorf("%w: production capability assignment is not the lease assignment", errInvalidSweepLease)
	case production.GetAuthorityEpoch() != lease.GetAuthorityEpoch():
		return fmt.Errorf("%w: production capability epoch is not the lease epoch", errInvalidSweepLease)
	case !bytes.Equal(production.GetScopeId(), lease.GetSweepGroupId()):
		return fmt.Errorf("%w: production capability scope is not the sweep group", errInvalidSweepLease)
	}

	if nowUnixNano < capability.GetNotBeforeUnixNano()-edgerecord.MaxClockToleranceNano {
		return fmt.Errorf("%w: wall clock %d is before lease issuance %d minus tolerance",
			errSweepLeaseClockFloor, nowUnixNano, capability.GetNotBeforeUnixNano())
	}

	header := slot.GetPlanHeader()
	if err := edgerecord.ValidatePlanPages(header, slot.GetPlanPages()); err != nil {
		return fmt.Errorf("%w: slot plan: %v", errInvalidSweepLease, err)
	}

	if !bytes.Equal(production.GetNetworkScopeId(), header.GetNetworkScopeId()) {
		return fmt.Errorf("%w: plan network scope is not the lease network scope", errInvalidSweepLease)
	}

	var ranges []*edgev1.TargetRangeV1
	for _, page := range slot.GetPlanPages() {
		ranges = append(ranges, page.GetRanges()...)
	}

	authorizations := slot.GetSourceAuthorizations()
	if len(ranges) == 0 || len(authorizations) != len(ranges) {
		return fmt.Errorf("%w: slot has %d source authorizations for %d ranges",
			errInvalidSweepLease, len(authorizations), len(ranges))
	}

	byScope := make(map[string]*edgev1.EdgeSourceAuthorizationV1, len(authorizations))
	for _, authorization := range authorizations {
		byScope[string(authorization.GetScopeId())] = authorization
	}

	for _, targetRange := range ranges {
		authorization, ok := byScope[string(targetRange.GetRangeId())]
		if !ok {
			return fmt.Errorf("%w: no source authorization for a plan range", errInvalidSweepLease)
		}

		if err := validateSweepLeaseSourceAuthorization(lease, slot, targetRange, authorization); err != nil {
			return err
		}
	}

	return nil
}

// validateSweepLeaseSourceAuthorization checks one range's SCHEDULED_SWEEP
// authorization against the slot it must authorize and nothing else.
func validateSweepLeaseSourceAuthorization(
	lease *edgev1.SweepLeaseV1,
	slot *edgev1.SweepLeaseSlotV1,
	targetRange *edgev1.TargetRangeV1,
	authorization *edgev1.EdgeSourceAuthorizationV1,
) error {
	capability := authorization.GetCapability()
	if err := edgerecord.ValidateCapability(capability, edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_SOURCE); err != nil {
		return fmt.Errorf("%w: source authorization: %v", errInvalidSweepLease, err)
	}

	source := capability.GetSource()

	switch {
	case authorization.GetKind() != edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP ||
		source.GetKind() != authorization.GetKind():
		return fmt.Errorf("%w: source authorization is not a scheduled sweep", errInvalidSweepLease)
	case !bytes.Equal(authorization.GetContextId(), slot.GetExecutionId()) ||
		!bytes.Equal(source.GetContextId(), slot.GetExecutionId()):
		return fmt.Errorf("%w: source authorization context is not the slot execution", errInvalidSweepLease)
	case !bytes.Equal(source.GetScopeId(), targetRange.GetRangeId()):
		return fmt.Errorf("%w: source authorization scope is not its range", errInvalidSweepLease)
	case !bytes.Equal(authorization.GetScopeSha256(), targetRange.GetRangeSha256()) ||
		!bytes.Equal(source.GetScopeSha256(), targetRange.GetRangeSha256()) ||
		!bytes.Equal(source.GetTargetRangeSha256(), targetRange.GetRangeSha256()):
		return fmt.Errorf("%w: source authorization digest is not the range digest", errInvalidSweepLease)
	case !bytes.Equal(edgerecord.RangeDigest(targetRange), targetRange.GetRangeSha256()):
		return fmt.Errorf("%w: range digest does not recompute", errInvalidSweepLease)
	case source.GetCollectionNotBeforeUnixNano() != slot.GetSlotStartUnixNano() ||
		source.GetCollectionExpiresUnixNano() != slot.GetCollectionExpiresUnixNano():
		return fmt.Errorf("%w: source authorization window is not the slot window", errInvalidSweepLease)
	case capability.GetNotBeforeUnixNano() != slot.GetSlotStartUnixNano() ||
		capability.GetExpiresAtUnixNano() != slot.GetCollectionExpiresUnixNano():
		return fmt.Errorf("%w: source authorization signed window is not the slot window", errInvalidSweepLease)
	case !bytes.Equal(source.GetExecutionPlanSha256(), slot.GetPlanHeader().GetExecutionPlanSha256()):
		return fmt.Errorf("%w: source authorization plan is not the slot plan", errInvalidSweepLease)
	case !bytes.Equal(source.GetRunId(), lease.GetLeaseId()) ||
		!bytes.Equal(source.GetProducerAssignmentId(), lease.GetProducerAssignmentId()) ||
		source.GetAuthorityEpoch() != lease.GetAuthorityEpoch():
		return fmt.Errorf("%w: source authorization is not bound to the lease", errInvalidSweepLease)
	case !bytes.Equal(source.GetNetworkScopeId(), slot.GetPlanHeader().GetNetworkScopeId()):
		return fmt.Errorf("%w: source authorization network scope is not the plan scope", errInvalidSweepLease)
	}

	return nil
}

// sweepLeaseRunner resolves the sweep service the executor drives, mirroring
// the on-demand sweep dispatch over the server's services.
func (p *PushLoop) sweepLeaseRunner() sweepLeaseRunner {
	if p.server == nil {
		return nil
	}

	p.server.mu.RLock()
	services := append([]Service(nil), p.server.services...)
	p.server.mu.RUnlock()

	for _, svc := range services {
		if runner, ok := svc.(sweepLeaseRunner); ok {
			return runner
		}
	}

	return nil
}

// startSweepLeaseExecutor opens the lease store and launches the executor on
// ctx. Installed leases resume from disk, so slots keep running on the
// agent's clock through gateway outages and agent restarts alike.
func (p *PushLoop) startSweepLeaseExecutor(ctx context.Context) {
	store, err := p.sweepLeaseStore()
	if err != nil {
		p.logger.Warn().Err(err).Msg("Sweep lease executor not started: lease store unavailable")
		return
	}

	p.sweepLeaseMu.Lock()
	if p.sweepLeaseWake == nil {
		p.sweepLeaseWake = make(chan struct{}, 1)
	}
	wake := p.sweepLeaseWake
	p.sweepLeaseMu.Unlock()

	executor := newSweepLeaseExecutor(store, p.sweepLeaseRunner, wake, p.logger)
	go executor.run(ctx)
}

// onSweepLeaseInstalled applies a lease install to the group's schedule at
// once and wakes the executor: a held lease takes the group off its local
// ticker, a revocation (held == nil) hands it back.
func (p *PushLoop) onSweepLeaseInstalled(group string, held *edgev1.SweepLeaseV1) {
	if runner := p.sweepLeaseRunner(); runner != nil {
		runner.SetGroupLeaseDriven(group, held != nil)
	}

	p.sweepLeaseMu.Lock()
	wake := p.sweepLeaseWake
	p.sweepLeaseMu.Unlock()

	if wake != nil {
		select {
		case wake <- struct{}{}:
		default:
		}
	}
}

// markInstalledSweepLeasesDriven takes groups with a lease already on disk
// off their local ticker. NewPushLoop runs it before the server starts its
// services, so a restarted agent never fires a leased group's initial or
// interval sweep before the executor takes over. It only reads an existing
// lease directory; creating one stays with the first lease push.
func (p *PushLoop) markInstalledSweepLeasesDriven() {
	if p.server == nil {
		return
	}

	dir := p.sweepLeaseDir
	if dir == "" {
		dir = defaultSweepLeaseDir()
	}

	if _, err := os.Stat(dir); err != nil {
		return
	}

	store, err := p.sweepLeaseStore()
	if err != nil {
		p.logger.Warn().Err(err).Msg("Installed sweep leases not marked lease-driven at startup")
		return
	}

	runner := p.sweepLeaseRunner()
	if runner == nil {
		return
	}

	for _, groupID := range store.Groups() {
		runner.SetGroupLeaseDriven(groupID, true)
	}
}
