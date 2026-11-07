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
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	goproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/sweeper"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

var errTestPublicationBeforeObserver = errors.New("publication started before the observer returned")

// Synthetic lease fixture for executor tests: fixed identities, the
// documentation range 192.0.2.0/24, and a throwaway issuer key generated
// per test. Nothing here came from a running system. Times derive from the
// test run's clock so the lease windows are always ahead of the real
// executed-record pruning in the store.
//
//nolint:gochecknoglobals // immutable synthetic fixture, not state
var (
	testNetworkScopeID = uuid.MustParse("99999999-8888-4777-a666-555555555555")
	testSlotStart      = time.Now().Add(2 * time.Hour).Truncate(time.Minute)
	testLeaseIssuedAt  = testSlotStart.Add(-time.Hour)
	errScannerFailed   = errors.New("scanner failed")
)

const testSlotWindow = 15 * time.Minute

type executableLease struct {
	lease       *edgev1.SweepLeaseV1
	executionID string
}

// buildExecutableLease assembles a one-slot lease whose plan and
// authorizations pass the edgerecord validators, signed with a synthetic
// issuer key. mutate may tamper with the finished lease.
func buildExecutableLease(t *testing.T, issuedAt time.Time, slotStart time.Time, mutate func(*edgev1.SweepLeaseV1)) executableLease {
	t.Helper()

	_, issuerKey, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)

	checkSet := testLeaseCheckSet().GetCheckSetSha256()

	targetRange := &edgev1.TargetRangeV1{
		RangeId:              newUUIDBytes(),
		Cidr:                 "192.0.2.0/24",
		TargetCount:          256,
		CheckSetSha256:       checkSet,
		AvailabilityPolicyId: []byte("any-success-v1"),
	}
	targetRange.MtrOrdinalCount = goproto.Uint64(0)
	targetRange.RangeSha256 = edgerecord.RangeDigest(targetRange)

	planID, err := edgerecord.NewUUIDv7()
	require.NoError(t, err)

	page := &edgev1.ScheduledPlanPageV1{
		ExecutionPlanId: planID,
		PageIndex:       0,
		PageCount:       1,
		CheckSetSha256:  checkSet,
		DigestVersion:   edgerecord.PlanDigestVersion,
		Ranges:          []*edgev1.TargetRangeV1{targetRange},
	}
	page.PageSha256 = edgerecord.PlanPageDigest(page)

	pages := []*edgev1.ScheduledPlanPageV1{page}
	commitment, err := edgerecord.PlanMtrOrdinalRangeCommitment(pages)
	require.NoError(t, err)

	header := &edgev1.ScheduledPlanHeaderV1{
		ExecutionPlanId:           planID,
		PageCount:                 1,
		TotalTargetCount:          256,
		PlanRootSha256:            edgerecord.PlanRoot(pages),
		DigestVersion:             edgerecord.PlanDigestVersion,
		CheckSetSha256:            checkSet,
		AvailabilityPolicyId:      []byte("any-success-v1"),
		NetworkScopeId:            testNetworkScopeID[:],
		MtrOrdinalRangeCommitment: commitment,
	}
	header.ExecutionPlanSha256 = edgerecord.PlanHeaderDigest(header)

	slotStartNano := slotStart.UnixNano()
	slotExpiresNano := slotStart.Add(testSlotWindow).UnixNano()
	executionID, err := edgerecord.NewUUIDv7()
	require.NoError(t, err)

	sign := func(capability *edgev1.EdgeSignedCapabilityV1) *edgev1.EdgeSignedCapabilityV1 {
		capability.CapabilityVersion = 1
		capability.IssuerId = []byte("test-issuer")
		capability.IssuerKeyId = []byte("test-issuer-key-1")
		capability.Algorithm = "ed25519"
		edgerecord.SignCapability(capability, issuerKey)

		return capability
	}

	sourceCapability := sign(&edgev1.EdgeSignedCapabilityV1{
		NotBeforeUnixNano: slotStartNano,
		ExpiresAtUnixNano: slotExpiresNano,
		Claims: &edgev1.EdgeSignedCapabilityV1_Source{Source: &edgev1.EdgeSourceClaimsV1{
			Kind:                        edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
			ContextId:                   executionID,
			ScopeId:                     targetRange.GetRangeId(),
			ScopeSha256:                 targetRange.GetRangeSha256(),
			NetworkScopeId:              testNetworkScopeID[:],
			CollectionNotBeforeUnixNano: slotStartNano,
			CollectionExpiresUnixNano:   slotExpiresNano,
			ProducerAssignmentId:        testAssignmentID[:],
			RunId:                       testLeaseID[:],
			AuthorityEpoch:              1,
			ExecutionPlanSha256:         header.GetExecutionPlanSha256(),
			TargetRangeSha256:           targetRange.GetRangeSha256(),
		}},
	})

	slot := &edgev1.SweepLeaseSlotV1{
		ExecutionId:               executionID,
		SlotStartUnixNano:         slotStartNano,
		CollectionExpiresUnixNano: slotExpiresNano,
		PlanHeader:                header,
		PlanPages:                 pages,
		SourceAuthorizations: []*edgev1.EdgeSourceAuthorizationV1{{
			Kind:        edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
			Capability:  sourceCapability,
			ContextId:   executionID,
			ScopeId:     targetRange.GetRangeId(),
			ScopeSha256: targetRange.GetRangeSha256(),
		}},
	}

	productionCapability := sign(&edgev1.EdgeSignedCapabilityV1{
		NotBeforeUnixNano: issuedAt.UnixNano(),
		ExpiresAtUnixNano: slotExpiresNano,
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			NetworkScopeId:       testNetworkScopeID[:],
			ProducerAssignmentId: testAssignmentID[:],
			RunId:                testLeaseID[:],
			AuthorityEpoch:       1,
			ScopeId:              testLeaseGroup[:],
		}},
	})

	lease := &edgev1.SweepLeaseV1{
		LeaseVersion:         edgerecord.SweepLeaseCheckSetsVersion,
		CheckSets:            []*edgev1.SweepCheckSetV1{testLeaseCheckSet()},
		SweepGroupId:         testLeaseGroup[:],
		LeaseId:              testLeaseID[:],
		ProducerAssignmentId: testAssignmentID[:],
		AuthorityEpoch:       1,
		ProductionCapability: productionCapability,
		WindowStartUnixNano:  slotStartNano,
		WindowEndUnixNano:    slotStartNano + 1,
		Slots:                []*edgev1.SweepLeaseSlotV1{slot},
	}

	if mutate != nil {
		mutate(lease)
	}

	executionUUID, err := uuid.FromBytes(executionID)
	require.NoError(t, err)

	return executableLease{lease: lease, executionID: executionUUID.String()}
}

// leaseExecutorFixture wires a real lease store and a real MultiSweepService
// (with a recording sweeper at the bottom) behind an executor with an open
// edge spool. Leased runs go through runner, which runs the slot on the
// group's sweeper without the observation producer, so executor scheduling is
// tested apart from what a run emits.
type leaseExecutorFixture struct {
	dir      string
	store    *sweepLeaseStore
	sweeper  *mockSweeper
	service  *SweepService
	multi    *MultiSweepService
	runner   *recordingLeaseRunner
	executor *sweepLeaseExecutor
	spool    *spool.Spool
	group    string
}

// recordingLeaseRunner runs a leased slot on its group's sweeper under the
// slot's execution id, refusing a slot the executor no longer considers
// runnable, as the observation producer does.
type recordingLeaseRunner struct {
	*MultiSweepService
}

func (r *recordingLeaseRunner) RunSweepGroupLease(
	ctx context.Context,
	groupID string,
	_ *edgev1.SweepLeaseV1,
	slot *edgev1.SweepLeaseSlotV1,
	_ *spool.Spool,
	_ bool,
	_ sweepSlotClaim,
) error {
	r.mu.RLock()
	svc := r.groups[groupID]
	r.mu.RUnlock()
	if svc == nil {
		return errSweepGroupNotFound
	}
	if err := sweeper.CheckExecution(ctx); err != nil {
		return err
	}
	run, ok := svc.sweeper.(interface {
		RunOnceWithExecution(context.Context, string) error
	})
	if !ok {
		return errSweepRunnerUnavailable
	}
	return run.RunOnceWithExecution(ctx, uuid.UUID(slot.GetExecutionId()).String())
}

func newLeaseExecutorFixture(t *testing.T) *leaseExecutorFixture {
	t.Helper()

	dir := t.TempDir()
	group := testLeaseGroup.String()

	store, err := newSweepLeaseStore(dir)
	require.NoError(t, err)

	sweeper := &mockSweeper{summary: &models.SweepSummary{
		Network:        "192.0.2.0/24",
		TotalHosts:     1,
		AvailableHosts: 1,
		LastSweep:      testSlotStart.Add(-time.Hour).Unix(),
		Hosts:          []models.HostResult{{Host: "192.0.2.10", Available: true}},
	}}

	service := &SweepService{
		sweeper:      sweeper,
		config:       &models.Config{SweepGroupID: group},
		stats:        newScanStats(),
		logger:       logger.NewTestLogger(),
		sweepGroupID: group,
	}

	multi := &MultiSweepService{
		groups:         map[string]*SweepService{group: service},
		groupSequences: map[string]string{group: ""},
		groupOrder:     []string{group},
		leaseDriven:    make(map[string]bool),
		logger:         logger.NewTestLogger(),
	}

	runner := &recordingLeaseRunner{MultiSweepService: multi}
	executor := newSweepLeaseExecutor(store, func() sweepLeaseRunner { return runner }, nil, logger.NewTestLogger())
	sp, err := spool.Open(t.TempDir())
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })
	executor.edgeSpool = sp

	return &leaseExecutorFixture{
		dir:      dir,
		store:    store,
		sweeper:  sweeper,
		service:  service,
		multi:    multi,
		runner:   runner,
		executor: executor,
		spool:    sp,
		group:    group,
	}
}

func (f *leaseExecutorFixture) install(t *testing.T, lease *edgev1.SweepLeaseV1) {
	t.Helper()

	_, err := f.store.Install(lease, f.group)
	require.NoError(t, err)
}

// A due slot runs exactly once under its core-minted execution id; a restart
// must not re-run it, and the group reports the lease exhausted once no slot
// is left.
func TestSweepLeaseExecutorRunsDueSlotOnceAcrossRestart(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	built := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart, nil)
	fixture.install(t, built.lease)

	now := testSlotStart.Add(time.Minute)
	fixture.executor.step(context.Background(), func() time.Time { return now })

	require.True(t, fixture.sweeper.manualSchedule, "leased group must come off its local ticker")
	require.Equal(t, 1, fixture.sweeper.runCount)
	require.Equal(t, built.executionID, fixture.sweeper.summary.ExecutionID, "the slot must run under its core-minted execution id")

	_, payload, err := fixture.service.GetStatusWithMetricPayload(context.Background())
	require.NoError(t, err)
	leaseStatus, ok := payload["sweep_lease"].(map[string]any)
	require.True(t, ok, "status must report sweep lease state, got %v", payload["sweep_lease"])
	require.Equal(t, sweepLeaseStateExhausted, leaseStatus["state"])

	// Restart: a fresh store and executor over the same state dir see the
	// executed record and do not run the slot again.
	reopened, err := newSweepLeaseStore(fixture.dir)
	require.NoError(t, err)
	require.True(t, reopened.Executed(fixture.group, built.executionID))

	restarted := newSweepLeaseExecutor(reopened, func() sweepLeaseRunner { return fixture.runner }, nil, logger.NewTestLogger())
	restarted.edgeSpool = fixture.spool
	restarted.step(context.Background(), func() time.Time { return now })
	require.Equal(t, 1, fixture.sweeper.runCount, "executed slot must not re-run after restart")
}

// The issuance floor: core issued this lease ten minutes into the slot's
// window, and the agent's clock is behind core's, so at one minute past the
// slot start the agent clock is still more than the ABI tolerance before
// the signed issuance. The due slot must be refused without being settled,
// then run once the clock reaches the floor, still inside its window.
func TestSweepLeaseExecutorClockFloorBlocksDueSlot(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	built := buildExecutableLease(t, testSlotStart.Add(10*time.Minute), testSlotStart, nil)
	fixture.install(t, built.lease)

	fixture.executor.step(context.Background(), func() time.Time { return testSlotStart.Add(time.Minute) })
	require.Equal(t, 0, fixture.sweeper.runCount, "due slot must be refused while the clock is behind the issuance floor")
	require.False(t, fixture.store.Executed(fixture.group, built.executionID), "clock refusal must not settle the slot")

	fixture.executor.step(context.Background(), func() time.Time { return testSlotStart.Add(6 * time.Minute) })
	require.Equal(t, 1, fixture.sweeper.runCount)
	require.True(t, fixture.store.Executed(fixture.group, built.executionID))
}

// A slot whose authorization does not bind to its plan range is terminally
// refused: settled without running, so the group reports exhausted instead
// of retrying a broken lease forever.
func TestSweepLeaseExecutorRefusesSlotWithBrokenRangeBinding(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	built := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart, func(lease *edgev1.SweepLeaseV1) {
		lease.GetSlots()[0].GetSourceAuthorizations()[0].ScopeSha256 = make([]byte, 32)
	})
	fixture.install(t, built.lease)

	fixture.executor.step(context.Background(), func() time.Time { return testSlotStart.Add(time.Minute) })

	require.Equal(t, 0, fixture.sweeper.runCount, "a slot with a broken range binding must never run")
	require.True(t, fixture.store.Executed(fixture.group, built.executionID), "terminal refusal must settle the slot")

	_, payload, err := fixture.service.GetStatusWithMetricPayload(context.Background())
	require.NoError(t, err)
	leaseStatus, ok := payload["sweep_lease"].(map[string]any)
	require.True(t, ok)
	require.Equal(t, sweepLeaseStateExhausted, leaseStatus["state"])
}

// Revoking the lease returns the group to its local schedule.
func TestSweepLeaseExecutorRevocationRestoresLocalTicker(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	built := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart, nil)
	fixture.install(t, built.lease)

	fixture.executor.step(context.Background(), func() time.Time { return testLeaseIssuedAt.Add(time.Minute) })
	require.True(t, fixture.sweeper.manualSchedule)

	revoked := testLeasePush(100, 101)
	revoked.Revoked = true
	_, err := fixture.store.Install(revoked, fixture.group)
	require.NoError(t, err)

	fixture.executor.step(context.Background(), func() time.Time { return testLeaseIssuedAt.Add(2 * time.Minute) })
	require.False(t, fixture.sweeper.manualSchedule, "revoked group must return to its local ticker")
	require.Equal(t, 0, fixture.sweeper.runCount)
}

// Without an edge spool a leased run has nowhere to emit: the due slot is
// neither run nor consumed, and once the spool is available the next pass
// inside the collection window runs it.
func TestSweepLeaseExecutorHoldsDueSlotWithoutSpool(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	built := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart, nil)
	fixture.install(t, built.lease)
	fixture.executor.edgeSpool = nil

	now := testSlotStart.Add(time.Minute)
	fixture.executor.step(context.Background(), func() time.Time { return now })

	require.Zero(t, fixture.sweeper.runCount, "a leased slot ran without a spool to emit into")
	require.False(t, fixture.store.Executed(fixture.group, built.executionID), "a held slot was consumed")

	fixture.executor.edgeSpool = fixture.spool
	fixture.executor.step(context.Background(), func() time.Time { return now })
	require.Equal(t, 1, fixture.sweeper.runCount)
	require.True(t, fixture.store.Executed(fixture.group, built.executionID))
}

// A sweep error leaves the slot due. The next pass inside the collection
// window runs it.
func TestSweepLeaseExecutorRetriesFailedSlot(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	built := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart, nil)
	fixture.install(t, built.lease)
	fixture.sweeper.runErr = errScannerFailed

	now := testSlotStart.Add(time.Minute)
	fixture.executor.step(context.Background(), func() time.Time { return now })

	require.Equal(t, 1, fixture.sweeper.runCount)
	require.False(t, fixture.store.Executed(fixture.group, built.executionID))

	_, payload, err := fixture.service.GetStatusWithMetricPayload(context.Background())
	require.NoError(t, err)
	leaseStatus, ok := payload["sweep_lease"].(map[string]any)
	require.True(t, ok)
	require.Equal(t, sweepLeaseStateActive, leaseStatus["state"])

	fixture.sweeper.runErr = nil
	fixture.executor.step(context.Background(), func() time.Time { return now })
	require.Equal(t, 2, fixture.sweeper.runCount)
	require.True(t, fixture.store.Executed(fixture.group, built.executionID))
}

// A leased run whose first record the spool refuses spools nothing, so it must
// not consume its slot: the slot stays runnable after the agent stops mid-wait
// and across a reload of the lease store, and once the spool has room the next
// pass inside the collection window runs it.
func TestSweepLeaseExecutorRefusedFirstRecordLeavesSlotRunnable(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	cfg, lease, slot, _ := edgeSweepFixture(t)
	fixture.group = uuid.UUID(lease.SweepGroupId).String()
	cfg.SweepGroupID = fixture.group
	fixture.service.sweepGroupID = fixture.group
	fixture.service.config = cfg
	fixture.service.sweeper = &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()}
	fixture.multi.groups = map[string]*SweepService{fixture.group: fixture.service}
	fixture.multi.groupSequences = map[string]string{fixture.group: ""}
	fixture.multi.groupOrder = []string{fixture.group}
	fixture.install(t, lease)
	sp, freeSpool := fullEdgeSweepSpool(t)
	fixture.executor.edgeSpool = sp
	fixture.executor.runnerFor = func() sweepLeaseRunner { return fixture.multi }
	executionID := uuid.UUID(slot.ExecutionId).String()

	// The agent stops while the producer waits for admission.
	stopping, stop := context.WithTimeout(context.Background(), 600*time.Millisecond)
	fixture.executor.step(stopping, time.Now)
	stop()

	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Empty(t, records)
	require.False(t, fixture.store.Executed(fixture.group, executionID), "a run that spooled nothing consumed its slot")
	reopened, err := newSweepLeaseStore(fixture.dir)
	require.NoError(t, err)
	require.False(t, reopened.Executed(fixture.group, executionID), "the released slot is consumed again after a restart")

	freeSpool()
	fixture.executor.step(context.Background(), time.Now)

	records, err = sp.Unresolved()
	require.NoError(t, err)
	require.NotEmpty(t, records)
	require.True(t, fixture.store.Executed(fixture.group, executionID))
}

// Revoking during a slot stops the rest of the pass and does not write the
// executed sidecar Install removed.
func TestSweepLeaseExecutorRevokeDuringPassSkipsRemainingSlots(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	lease, firstID, secondID := twoDueLeaseSlots(t)
	fixture.install(t, lease)

	fixture.sweeper.onRun = func() {
		revoked := testLeasePush(100, 101)
		revoked.Revoked = true
		_, err := fixture.store.Install(revoked, fixture.group)
		require.NoError(t, err)
	}

	fixture.executor.step(context.Background(), func() time.Time { return testSlotStart.Add(90 * time.Second) })

	require.Equal(t, 1, fixture.sweeper.runCount)
	require.False(t, fixture.store.Executed(fixture.group, firstID))
	require.False(t, fixture.store.Executed(fixture.group, secondID))
	require.False(t, fixture.sweeper.manualSchedule)
	_, err := os.Stat(filepath.Join(fixture.dir, fixture.group+sweepLeaseExecutedSuffix))
	require.ErrorIs(t, err, os.ErrNotExist)

	status, err := fixture.multi.GetStatus(context.Background())
	require.NoError(t, err)
	var doc map[string]any
	require.NoError(t, json.Unmarshal(status.Message, &doc))
	_, present := doc["sweep_leases"]
	require.False(t, present)
}

// A replacement that drops a later slot before it starts does not run or
// record that slot. The slot that already started, and is still installed,
// is recorded.
func TestSweepLeaseExecutorSkipsSlotRemovedDuringPass(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	lease, firstID, secondID := twoDueLeaseSlots(t)
	fixture.install(t, lease)

	fixture.sweeper.onRun = func() {
		push := testLeasePush(testSlotStart.Add(time.Minute).Unix(), testSlotStart.Add(2*time.Minute).Unix())
		_, err := fixture.store.Install(push, fixture.group)
		require.NoError(t, err)
	}

	fixture.executor.step(context.Background(), func() time.Time { return testSlotStart.Add(90 * time.Second) })

	require.Equal(t, 1, fixture.sweeper.runCount)
	require.True(t, fixture.store.Executed(fixture.group, firstID))
	require.False(t, fixture.store.Executed(fixture.group, secondID))
	require.True(t, fixture.sweeper.manualSchedule)
}

// The pushed status document counts every leased group, including one whose
// last_sweep is older than another group's and one that has not completed, and
// its size does not grow with the number of leased groups.
func TestMultiSweepStatusCountsEveryLeasedGroup(t *testing.T) {
	newer := newLeaseStatusGroup("group-newer", 200)
	older := newLeaseStatusGroup("group-older", 100)
	quiet := newLeaseStatusGroup("group-quiet", 0)
	older.SetLeaseState(sweepLeaseStateActive, 50, 2)
	quiet.SetLeaseState(sweepLeaseStateExhausted, 0, 0)

	multi := &MultiSweepService{
		groups: map[string]*SweepService{
			"group-newer": newer,
			"group-older": older,
			"group-quiet": quiet,
		},
		groupOrder: []string{"group-quiet", "group-older", "group-newer"},
		logger:     logger.NewTestLogger(),
	}

	const extraLeased = 300
	for i := 0; i < extraLeased; i++ {
		group := fmt.Sprintf("group-leased-%03d", i)
		svc := newLeaseStatusGroup(group, int64(10+i%50))
		svc.SetLeaseState(sweepLeaseStateActive, int64(1_000+i), 1)
		multi.groups[group] = svc
		multi.groupOrder = append(multi.groupOrder, group)
	}

	status, err := multi.GetStatus(context.Background())
	require.NoError(t, err)
	require.LessOrEqual(t, len(status.Message), gatewayStatusSummaryLimitBytes)

	leases := sweepLeaseSummaryOf(t, status.Message)
	require.InDelta(t, float64(2+extraLeased), leases["groups"], 0)
	require.InDelta(t, float64(1+extraLeased), leases["active"], 0)
	require.InDelta(t, float64(1), leases["exhausted"], 0)
	require.InDelta(t, float64(2+extraLeased), leases["slots_remaining"], 0)
	require.InDelta(t, float64(50), leases["next_slot_unix_nano"], 0)
}

func twoDueLeaseSlots(t *testing.T) (lease *edgev1.SweepLeaseV1, firstID, secondID string) {
	t.Helper()

	first := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart, nil)
	second := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart.Add(time.Minute), nil)
	lease = first.lease
	lease.Slots = []*edgev1.SweepLeaseSlotV1{first.lease.GetSlots()[0], second.lease.GetSlots()[0]}
	lease.WindowStartUnixNano = testSlotStart.UnixNano()
	lease.WindowEndUnixNano = testSlotStart.Add(2 * time.Minute).UnixNano()

	return lease, first.executionID, second.executionID
}

func newLeaseStatusGroup(group string, lastSweep int64) *SweepService {
	return &SweepService{
		sweeper: &mockSweeper{summary: &models.SweepSummary{
			Network:        "192.0.2.0/24",
			TotalHosts:     1,
			AvailableHosts: 1,
			LastSweep:      lastSweep,
			Hosts:          []models.HostResult{{Host: "192.0.2.10", Available: true}},
		}},
		config:       &models.Config{Networks: []string{"192.0.2.0/24"}, SweepGroupID: group},
		stats:        newScanStats(),
		logger:       logger.NewTestLogger(),
		sweepGroupID: group,
	}
}

func sweepLeaseSummaryOf(t *testing.T, message []byte) map[string]any {
	t.Helper()

	var doc map[string]any
	require.NoError(t, json.Unmarshal(message, &doc))
	leases, ok := doc["sweep_leases"].(map[string]any)
	require.True(t, ok, "status message sweep_leases = %#v", doc["sweep_leases"])

	return leases
}

// sameSecondSweeper keeps one summary and rewrites it in place. Both
// completions share a LastSweep unix second, which is what a catch-up of
// two slots in the same second looks like after the store has pruned the
// earlier hosts.
type sameSecondSweeper struct {
	mu      sync.Mutex
	summary *models.SweepSummary
}

func newSameSecondSweeper() *sameSecondSweeper {
	return &sameSecondSweeper{
		summary: &models.SweepSummary{
			Network:        "192.0.2.0/24",
			TotalHosts:     1,
			AvailableHosts: 1,
			LastSweep:      1_700_000_000,
			Hosts:          []models.HostResult{{Available: true}},
		},
	}
}

func (s *sameSecondSweeper) RunOnce(ctx context.Context) error {
	return s.RunOnceWithExecution(ctx, "")
}

func (s *sameSecondSweeper) RunOnceWithExecution(_ context.Context, executionID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.summary.ExecutionID = executionID
	s.summary.Hosts[0].Host = executionID

	return nil
}

func (s *sameSecondSweeper) GetStatus(context.Context) (*models.SweepSummary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// The live summary is rewritten in place, the way the sweeper store keeps
	// only the latest cycle. Callers have to snapshot it themselves.
	return s.summary, nil
}

func (*sameSecondSweeper) Start(context.Context) error           { return nil }
func (*sameSecondSweeper) Stop() error                           { return nil }
func (*sameSecondSweeper) UpdateConfig(*models.Config) error     { return nil }
func (*sameSecondSweeper) GetScannerStats() *models.ScannerStats { return nil }
func (*sameSecondSweeper) GetBannerGrabStats() *models.BannerGrabStats {
	return nil
}
func (*sameSecondSweeper) SetManualSchedule(bool) {}

func TestSweepLeaseExecutorDoesNotDispatchSlotsExpiredDuringScan(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	lease, firstID, secondID := twoDueLeaseSlots(t)
	fixture.install(t, lease)
	now := testSlotStart.Add(90 * time.Second)
	fixture.sweeper.onRun = func() { now = testSlotStart.Add(20 * time.Minute) }

	wait := fixture.executor.step(context.Background(), func() time.Time { return now })

	require.Equal(t, 1, fixture.sweeper.runCount)
	require.True(t, fixture.store.Executed(fixture.group, firstID))
	require.False(t, fixture.store.Executed(fixture.group, secondID))
	require.Equal(t, sweepLeaseExecutorMaxWait, wait)
	status, err := fixture.multi.GetStatus(context.Background())
	require.NoError(t, err)
	leases := sweepLeaseSummaryOf(t, status.Message)
	require.InDelta(t, float64(1), leases["exhausted"], 0)
	require.InDelta(t, float64(0), leases["active"], 0)
	require.InDelta(t, float64(0), leases["slots_remaining"], 0)
}

func TestSweepLeaseExecutorRefreshesClockBetweenGroups(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	first := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart, nil)
	fixture.install(t, first.lease)
	otherGroup := uuid.MustParse("eeeeeeee-eeee-4eee-aeee-eeeeeeeeeeee")
	second := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart, func(lease *edgev1.SweepLeaseV1) {
		lease.SweepGroupId = otherGroup[:]
		lease.ProductionCapability.GetProduction().ScopeId = otherGroup[:]
	})
	_, err := fixture.store.Install(second.lease, otherGroup.String())
	require.NoError(t, err)
	fixture.multi.groups[otherGroup.String()] = fixture.service
	fixture.multi.groupOrder = append(fixture.multi.groupOrder, otherGroup.String())
	now := testSlotStart.Add(time.Minute)
	fixture.sweeper.onRun = func() { now = testSlotStart.Add(20 * time.Minute) }
	fixture.executor.step(context.Background(), func() time.Time { return now })
	require.Equal(t, 1, fixture.sweeper.runCount)
}

type metadataSweeper struct {
	*sameSecondSweeper
	cancelled bool
	scanner   models.ScannerStats
	banner    models.BannerGrabStats
}

func (s *metadataSweeper) WasCancelledSweep() bool                     { return s.cancelled }
func (s *metadataSweeper) GetScannerStats() *models.ScannerStats       { return &s.scanner }
func (s *metadataSweeper) GetBannerGrabStats() *models.BannerGrabStats { return &s.banner }

func TestRetainedSweepCompletionMetadata(t *testing.T) {
	for _, cancelled := range []bool{false, true} {
		t.Run(fmt.Sprint(cancelled), func(t *testing.T) {
			sweeper := &metadataSweeper{sameSecondSweeper: newSameSecondSweeper(), cancelled: cancelled}
			sweeper.scanner.PacketsSent = 11
			sweeper.banner.ProbesTotal = 7
			service := &SweepService{sweeper: sweeper, config: &models.Config{}, logger: logger.NewTestLogger()}
			retainCycle := func(id string) {
				require.NoError(t, service.runAndRetain(context.Background(), func(ctx context.Context) error {
					return sweeper.RunOnceWithExecution(ctx, id)
				}))
			}
			retainCycle("first")
			sweeper.cancelled = !cancelled
			sweeper.scanner.PacketsSent = 23
			sweeper.banner.ProbesTotal = 17
			retainCycle("second")

			sequence := ""
			for i, expected := range []struct {
				id              string
				cancelled       bool
				packets, probes uint64
			}{
				{"first", cancelled, 11, 7}, {"second", !cancelled, 23, 17},
			} {
				response, err := service.GetSweepResults(context.Background(), sequence)
				require.NoError(t, err)
				require.Equal(t, expected.id, response.ExecutionId)
				var data struct {
					Cancelled bool                   `json:"cancelled"`
					Scanner   models.ScannerStats    `json:"scanner_stats"`
					Banner    models.BannerGrabStats `json:"banner_grab"`
				}
				require.NoError(t, json.Unmarshal(response.Data, &data))
				require.Equal(t, expected.cancelled, data.Cancelled)
				require.Equal(t, expected.packets, data.Scanner.PacketsSent)
				require.Equal(t, expected.probes, data.Banner.ProbesTotal)
				require.Equal(t, expected.packets, response.SweepCompletion.ScannerStats.PacketsSent)
				require.Equal(t, int64(1_700_000_000), response.SweepCompletion.CompletionTime)
				if i == 0 {
					retry, err := service.GetSweepResults(context.Background(), "")
					require.NoError(t, err)
					require.Equal(t, response.Data, retry.Data)
				}
				sequence = response.CurrentSequence
			}
		})
	}
}

type snapshotBlockingSweeper struct {
	*sameSecondSweeper
	snapshotStarted  chan struct{}
	releaseSnapshot  chan struct{}
	observerFinished chan struct{}
	runStarted       chan string
	once             sync.Once
}

func (s *snapshotBlockingSweeper) pausePublication() {
	s.once.Do(func() {
		close(s.snapshotStarted)
		<-s.releaseSnapshot
	})
}

func (s *snapshotBlockingSweeper) GetStatus(ctx context.Context) (*models.SweepSummary, error) {
	s.pausePublication()
	return s.sameSecondSweeper.GetStatus(ctx)
}

func (s *snapshotBlockingSweeper) RunOnce(ctx context.Context) error {
	return s.RunOnceWithExecution(ctx, "on-demand")
}

func (s *snapshotBlockingSweeper) RunOnceWithExecution(ctx context.Context, id string) error {
	s.runStarted <- id
	return s.sameSecondSweeper.RunOnceWithExecution(ctx, id)
}

func (*snapshotBlockingSweeper) EffectivePlannedSweepModes(_ string, spec sweeper.RunSpec) ([]models.SweepMode, error) {
	return spec.Modes, nil
}

func (s *snapshotBlockingSweeper) RunPlannedWithObserver(ctx context.Context, id string, _ sweeper.RunSpec, observe func(context.Context, *models.Result) error) error {
	if err := s.RunOnceWithExecution(ctx, id); err != nil {
		return err
	}
	results := edgeSweepResults()
	for i := range results {
		if err := observe(ctx, &results[i]); err != nil {
			return err
		}
	}
	close(s.observerFinished)
	return nil
}

func TestSweepCallersSerializeThroughSnapshot(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	group := uuid.UUID(lease.SweepGroupId).String()
	cfg.SweepGroupID = group
	// Buffer every host until finish, so the claim pauses publication after
	// the scanner has returned and released its own run lock.
	lease.ProductionCapability.GetProduction().MaxProjectedRowCount = 16
	lease.ProductionCapability.GetProduction().MaxProjectedWriteBytes = 16 * sweepProjectedRowBytes
	sw := &snapshotBlockingSweeper{
		sameSecondSweeper: newSameSecondSweeper(),
		snapshotStarted:   make(chan struct{}), releaseSnapshot: make(chan struct{}),
		observerFinished: make(chan struct{}), runStarted: make(chan string, 2),
	}
	release := sync.OnceFunc(func() { close(sw.releaseSnapshot) })
	defer release()
	service := &SweepService{sweeper: sw, config: cfg, logger: logger.NewTestLogger()}
	multi := &MultiSweepService{groups: map[string]*SweepService{group: service}}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	firstID := uuid.UUID(slot.ExecutionId).String()
	first := make(chan error, 1)
	second := make(chan error, 1)
	go func() {
		first <- multi.RunSweepGroupLease(ctx, group, lease, slot, sp, false, sweepSlotClaim{claim: func() error {
			select {
			case <-sw.observerFinished:
			default:
				return errTestPublicationBeforeObserver
			}
			sw.pausePublication()
			return nil
		}})
	}()
	select {
	case <-sw.snapshotStarted:
	case err := <-first:
		t.Fatalf("first sweep ended before publication barrier: %v", err)
	case <-ctx.Done():
		t.Fatal("first sweep never reached publication barrier")
	}
	require.Equal(t, firstID, <-sw.runStarted)
	secondCalling := make(chan struct{})
	go func() {
		close(secondCalling)
		second <- multi.RunSweepGroup(ctx, group)
	}()
	<-secondCalling
	var secondID string
	select {
	case secondID = <-sw.runStarted:
		t.Errorf("%s started before prior publication completed", secondID)
	case <-time.After(50 * time.Millisecond):
	}
	release()
	require.NoError(t, <-first)
	require.NoError(t, <-second)
	if secondID == "" {
		secondID = <-sw.runStarted
	}
	require.Equal(t, "on-demand", secondID)
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Len(t, records, 1)
	record := &edgev1.EdgeRecordV1{}
	require.NoError(t, goproto.Unmarshal(records[0].Body, record))
	batch := &edgev1.SweepObservationBatchV1{}
	require.NoError(t, goproto.Unmarshal(recordBody(t, record), batch))
	require.Equal(t, slot.ExecutionId, batch.ExecutionId)
	require.Len(t, batch.Hosts, 4)
	result, err := service.GetSweepResults(ctx, "")
	require.NoError(t, err)
	require.True(t, result.HasNewData)
	require.Equal(t, "on-demand", result.ExecutionId)
}

type queuedLeaseRunner struct {
	*MultiSweepService
	entered  chan struct{}
	returned chan error
}

func (r *queuedLeaseRunner) RunSweepGroupLease(ctx context.Context, group string, lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1, sp *spool.Spool, icmpUnavailable bool, claim sweepSlotClaim) error {
	close(r.entered)
	err := r.MultiSweepService.RunSweepGroupLease(ctx, group, lease, slot, sp, icmpUnavailable, claim)
	r.returned <- err
	return err
}

func TestQueuedLeaseSlotRecheckedBeforeExecution(t *testing.T) {
	for _, state := range []string{"valid", "expired", "revoked"} {
		t.Run(state, func(t *testing.T) {
			fixture := newLeaseExecutorFixture(t)
			cfg, lease, slot, sp := edgeSweepFixture(t)
			fixture.group = uuid.UUID(lease.SweepGroupId).String()
			fixture.service.sweepGroupID = fixture.group
			fixture.multi.groups = map[string]*SweepService{fixture.group: fixture.service}
			fixture.multi.groupSequences = map[string]string{fixture.group: ""}
			fixture.multi.groupOrder = []string{fixture.group}
			cfg.SweepGroupID = fixture.group
			sw := &snapshotBlockingSweeper{
				sameSecondSweeper: newSameSecondSweeper(),
				snapshotStarted:   make(chan struct{}), releaseSnapshot: make(chan struct{}),
				observerFinished: make(chan struct{}), runStarted: make(chan string, 1),
			}
			close(sw.releaseSnapshot)
			fixture.service.sweeper = sw
			fixture.service.config = cfg
			fixture.install(t, lease)
			fixture.executor.edgeSpool = sp
			var nanos atomic.Int64
			nanos.Store(slot.SlotStartUnixNano + int64(time.Second))
			runner := &queuedLeaseRunner{MultiSweepService: fixture.multi, entered: make(chan struct{}), returned: make(chan error, 1)}
			fixture.executor.runnerFor = func() sweepLeaseRunner { return runner }
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			fixture.service.runMu.Lock()
			release := sync.OnceFunc(fixture.service.runMu.Unlock)
			defer release()
			done := make(chan struct{})
			go func() {
				fixture.executor.step(ctx, func() time.Time { return time.Unix(0, nanos.Load()) })
				close(done)
			}()
			select {
			case <-runner.entered:
			case <-done:
				t.Fatal("slot never reached the queued service")
			case <-ctx.Done():
				t.Fatal("slot dispatch timed out")
			}
			switch state {
			case "revoked":
				revocation := testLeasePush(100, 101)
				revocation.SweepGroupId = lease.SweepGroupId
				revocation.Revoked = true
				fixture.install(t, revocation)
			case "expired":
				nanos.Store(slot.CollectionExpiresUnixNano)
			}
			release()
			select {
			case <-done:
			case <-ctx.Done():
				t.Fatal("queued slot did not return")
			}
			runErr := <-runner.returned
			if state == "valid" {
				require.NoError(t, runErr)
				select {
				case id := <-sw.runStarted:
					require.Equal(t, uuid.UUID(slot.ExecutionId).String(), id)
				default:
					t.Fatal("valid slot did not reach the scanner")
				}
			} else {
				select {
				case id := <-sw.runStarted:
					t.Fatalf("%s slot reached scanner as %s", state, id)
				default:
				}
				require.Error(t, runErr)
			}
			records, err := sp.Unresolved()
			require.NoError(t, err)
			if state == "valid" {
				require.Len(t, records, 4)
			} else {
				require.Empty(t, records)
			}
		})
	}
}
