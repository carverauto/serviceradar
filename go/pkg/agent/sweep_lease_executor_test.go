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
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	goproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Synthetic lease fixture for executor tests: fixed identities, the
// documentation range 192.0.2.0/24, and a throwaway issuer key generated
// per test. Nothing here came from a running system. Times derive from the
// test run's clock so the lease windows are always ahead of the real
// executed-record pruning in the store.
var (
	testNetworkScopeID = uuid.MustParse("99999999-8888-4777-a666-555555555555")
	testSlotStart      = time.Now().Add(2 * time.Hour).Truncate(time.Minute)
	testLeaseIssuedAt  = testSlotStart.Add(-time.Hour)
	testSlotWindow     = 15 * time.Minute
)

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

	checkSet := make([]byte, 32)
	for i := range checkSet {
		checkSet[i] = 0x5a
	}

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
		LeaseVersion:         sweepLeaseVersion,
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
// (with a recording sweeper at the bottom) behind an executor.
type leaseExecutorFixture struct {
	dir      string
	store    *sweepLeaseStore
	sweeper  *mockSweeper
	service  *SweepService
	multi    *MultiSweepService
	executor *sweepLeaseExecutor
	group    string
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

	executor := newSweepLeaseExecutor(store, func() sweepLeaseRunner { return multi }, nil, logger.NewTestLogger())

	return &leaseExecutorFixture{
		dir:      dir,
		store:    store,
		sweeper:  sweeper,
		service:  service,
		multi:    multi,
		executor: executor,
		group:    group,
	}
}

func (f *leaseExecutorFixture) install(t *testing.T, lease *edgev1.SweepLeaseV1) {
	t.Helper()

	_, err := f.store.Install(lease, f.group)
	require.NoError(t, err)
}

// A due slot runs exactly once under its core-minted execution id, and the
// completed cycle is what sweep results report; a restart must not re-run
// it, and the group reports the lease exhausted once no slot is left.
func TestSweepLeaseExecutorRunsDueSlotOnceAcrossRestart(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	built := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart, nil)
	fixture.install(t, built.lease)

	now := testSlotStart.Add(time.Minute)
	fixture.executor.step(context.Background(), func() time.Time { return now })

	require.True(t, fixture.sweeper.manualSchedule, "leased group must come off its local ticker")
	require.Equal(t, 1, fixture.sweeper.runCount)

	response, err := fixture.multi.GetSweepResults(context.Background(), "")
	require.NoError(t, err)
	require.True(t, response.HasNewData)
	require.Equal(t, built.executionID, response.ExecutionId, "results must carry the slot's core-minted execution id")

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

	restarted := newSweepLeaseExecutor(reopened, func() sweepLeaseRunner { return fixture.multi }, nil, logger.NewTestLogger())
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

// Two due slots: while the later slot is in progress the earlier slot's hosts
// are still the published summary, and they go out under the earlier slot's
// execution id. The later slot's own completion then publishes under its id.
func TestSweepLeaseExecutorBindsExecutionIDToTheSweepThatFinished(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	lease, firstID, secondID := twoDueLeaseSlots(t)
	fixture.install(t, lease)

	gated := newGatedSweeper(secondID)
	fixture.service.sweeper = gated

	release := make(chan struct{})
	gated.release = release
	done := make(chan struct{})
	go func() {
		defer close(done)
		fixture.executor.step(context.Background(), func() time.Time { return testSlotStart.Add(90 * time.Second) })
	}()

	select {
	case <-gated.started:
	case <-time.After(5 * time.Second):
		t.Fatal("second slot did not start")
	}

	response, err := fixture.multi.GetSweepResults(context.Background(), "")
	require.NoError(t, err)
	require.True(t, response.HasNewData)
	require.Equal(t, firstID, response.ExecutionId)
	require.Equal(t, firstID, sweepResultHost(t, response.Data))

	close(release)
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("executor pass did not finish")
	}

	fixture.multi.AcknowledgeSweepResults(response.SweepGroupId, response.CurrentSequence)
	response, err = fixture.multi.GetSweepResults(context.Background(), "")
	require.NoError(t, err)
	require.True(t, response.HasNewData)
	require.Equal(t, secondID, response.ExecutionId)
	require.Equal(t, secondID, sweepResultHost(t, response.Data))
}

// Two due slots finish in one pass before anything is published. Each cycle
// is returned in order under its own execution id, including when both
// completions share a LastSweep unix second. An unacknowledged read repeats
// the unpublished cycle instead of jumping ahead.
func TestSweepLeaseExecutorPublishesEveryCatchUpSlot(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	lease, firstID, secondID := twoDueLeaseSlots(t)
	fixture.install(t, lease)
	fixture.service.sweeper = newSameSecondSweeper()

	fixture.executor.step(context.Background(), func() time.Time { return testSlotStart.Add(90 * time.Second) })

	first, err := fixture.multi.GetSweepResults(context.Background(), "")
	require.NoError(t, err)
	require.True(t, first.HasNewData)
	require.Equal(t, firstID, first.ExecutionId)
	require.Equal(t, firstID, sweepResultHost(t, first.Data))

	repeated, err := fixture.multi.GetSweepResults(context.Background(), "")
	require.NoError(t, err)
	require.True(t, repeated.HasNewData)
	require.Equal(t, first.CurrentSequence, repeated.CurrentSequence)
	require.Equal(t, firstID, repeated.ExecutionId)

	fixture.multi.AcknowledgeSweepResults(first.SweepGroupId, first.CurrentSequence)
	second, err := fixture.multi.GetSweepResults(context.Background(), "")
	require.NoError(t, err)
	require.True(t, second.HasNewData)
	require.Equal(t, secondID, second.ExecutionId)
	require.Equal(t, secondID, sweepResultHost(t, second.Data))

	fixture.multi.AcknowledgeSweepResults(second.SweepGroupId, second.CurrentSequence)
	done, err := fixture.multi.GetSweepResults(context.Background(), "")
	require.NoError(t, err)
	require.False(t, done.HasNewData)
}

// A leased cycle that publishes no hosts must not leave its execution id
// attached to the next cycle, including a local sweep after the lease id
// was cleared.
func TestSweepLeaseUnpublishedExecutionDoesNotLabelTheNextCycle(t *testing.T) {
	sweeper := &mockSweeper{summary: &models.SweepSummary{LastSweep: 10}}
	service := &SweepService{
		sweeper: sweeper,
		config:  &models.Config{},
		stats:   newScanStats(),
		logger:  logger.NewTestLogger(),
	}

	err := service.RunOnceForExecution(context.Background(), "leased-id")
	require.NoError(t, err)

	response, err := service.GetSweepResults(context.Background(), "")
	require.NoError(t, err)
	require.False(t, response.HasNewData)
	require.NotEqual(t, "leased-id", response.ExecutionId)

	sweeper.summary.Hosts = []models.HostResult{{Host: "192.0.2.10", Available: true}}
	require.NoError(t, service.RunOnce(context.Background()))

	response, err = service.GetSweepResults(context.Background(), "")
	require.NoError(t, err)
	require.True(t, response.HasNewData)
	require.NotEqual(t, "leased-id", response.ExecutionId)
	_, err = uuid.Parse(response.ExecutionId)
	require.NoError(t, err)
}

// A sweep error leaves the slot due. The next pass inside the collection
// window runs it.
func TestSweepLeaseExecutorRetriesFailedSlot(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	built := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart, nil)
	fixture.install(t, built.lease)
	fixture.sweeper.runErr = errors.New("scanner failed")

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
	_, present := doc["sweep_lease"]
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

// The pushed status document lists every leased group, including one whose
// last_sweep is older than another group's and one that has not completed.
func TestMultiSweepStatusReportsEveryLeasedGroup(t *testing.T) {
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

	status, err := multi.GetStatus(context.Background())
	require.NoError(t, err)
	leases := sweepLeaseStates(t, status.Message)
	require.NotContains(t, leases, "group-newer")
	require.Equal(t, sweepLeaseStateActive, leases["group-older"]["state"])
	require.Equal(t, sweepLeaseStateExhausted, leases["group-quiet"]["state"])
	require.Equal(t, float64(2), leases["group-older"]["slots_remaining"])
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

func sweepLeaseStates(t *testing.T, message []byte) map[string]map[string]any {
	t.Helper()

	var doc map[string]any
	require.NoError(t, json.Unmarshal(message, &doc))
	raw, ok := doc["sweep_lease"].([]any)
	require.True(t, ok, "status message sweep_lease = %#v", doc["sweep_lease"])

	states := make(map[string]map[string]any, len(raw))
	for _, item := range raw {
		lease, ok := item.(map[string]any)
		require.True(t, ok)
		group, _ := lease["sweep_group_id"].(string)
		states[group] = lease
	}

	return states
}

func sweepResultHost(t *testing.T, data []byte) string {
	t.Helper()

	var payload struct {
		Hosts []struct {
			Host string `json:"host"`
		} `json:"hosts"`
	}
	require.NoError(t, json.Unmarshal(data, &payload))
	require.NotEmpty(t, payload.Hosts)

	return payload.Hosts[0].Host
}

// gatedSweeper publishes a sweep's execution id only when that run finishes.
// While a run is in progress, status stays on the previous published summary.
type gatedSweeper struct {
	mu        sync.Mutex
	blockID   string
	published *models.SweepSummary
	started   chan struct{}
	release   chan struct{}
	lastSweep int64
}

func newGatedSweeper(blockID string) *gatedSweeper {
	return &gatedSweeper{
		blockID: blockID,
		started: make(chan struct{}),
	}
}

func (g *gatedSweeper) RunOnce(ctx context.Context) error {
	return g.RunOnceWithExecution(ctx, "")
}

func (g *gatedSweeper) RunOnceWithExecution(ctx context.Context, executionID string) error {
	g.mu.Lock()
	block := executionID == g.blockID
	g.mu.Unlock()

	if block {
		close(g.started)
		select {
		case <-g.release:
		case <-ctx.Done():
			return ctx.Err()
		}
	}

	g.mu.Lock()
	defer g.mu.Unlock()
	g.lastSweep++
	g.published = &models.SweepSummary{
		Network:        "192.0.2.0/24",
		TotalHosts:     1,
		AvailableHosts: 1,
		LastSweep:      g.lastSweep,
		Hosts:          []models.HostResult{{Host: executionID, Available: true}},
		ExecutionID:    executionID,
	}

	return nil
}

func (g *gatedSweeper) GetStatus(context.Context) (*models.SweepSummary, error) {
	g.mu.Lock()
	defer g.mu.Unlock()

	if g.published == nil {
		return &models.SweepSummary{}, nil
	}

	clone := *g.published
	clone.Hosts = append([]models.HostResult(nil), g.published.Hosts...)

	return &clone, nil
}

func (*gatedSweeper) Start(context.Context) error           { return nil }
func (*gatedSweeper) Stop() error                           { return nil }
func (*gatedSweeper) UpdateConfig(*models.Config) error     { return nil }
func (*gatedSweeper) GetScannerStats() *models.ScannerStats { return nil }
func (*gatedSweeper) GetBannerGrabStats() *models.BannerGrabStats {
	return nil
}
func (*gatedSweeper) SetManualSchedule(bool) {}

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
	state := sweepLeaseStates(t, status.Message)[fixture.group]
	require.Equal(t, sweepLeaseStateExhausted, state["state"])
	require.Equal(t, float64(0), state["slots_remaining"])
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
			require.NoError(t, service.RunOnceForExecution(context.Background(), "first"))
			sweeper.cancelled = !cancelled
			sweeper.scanner.PacketsSent = 23
			sweeper.banner.ProbesTotal = 17
			require.NoError(t, service.RunOnceForExecution(context.Background(), "second"))

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
	snapshotStarted chan struct{}
	releaseSnapshot chan struct{}
	runStarted chan string
	once sync.Once
}

func (s *snapshotBlockingSweeper) GetStatus(ctx context.Context) (*models.SweepSummary, error) {
	s.once.Do(func() {
		close(s.snapshotStarted)
		<-s.releaseSnapshot
	})
	return s.sameSecondSweeper.GetStatus(ctx)
}

func (s *snapshotBlockingSweeper) RunOnce(ctx context.Context) error {
	return s.RunOnceWithExecution(ctx, "on-demand")
}

func (s *snapshotBlockingSweeper) RunOnceWithExecution(ctx context.Context, id string) error {
	s.runStarted <- id
	return s.sameSecondSweeper.RunOnceWithExecution(ctx, id)
}

func TestSweepCallersSerializeThroughSnapshot(t *testing.T) {
	sw := &snapshotBlockingSweeper{
		sameSecondSweeper: newSameSecondSweeper(),
		snapshotStarted: make(chan struct{}), releaseSnapshot: make(chan struct{}),
		runStarted: make(chan string, 2),
	}
	service := &SweepService{sweeper: sw, config: &models.Config{}, logger: logger.NewTestLogger()}
	first := make(chan error, 1)
	second := make(chan error, 1)
	go func() { first <- service.RunOnceForExecution(context.Background(), "leased") }()
	<-sw.snapshotStarted
	require.Equal(t, "leased", <-sw.runStarted)
	go func() { second <- service.RunOnce(context.Background()) }()
	select {
	case id := <-sw.runStarted:
		t.Errorf("%s started before prior snapshot retained", id)
	case <-time.After(50 * time.Millisecond):
	}
	close(sw.releaseSnapshot)
	require.NoError(t, <-first)
	require.NoError(t, <-second)
	sequence := ""
	for _, id := range []string{"leased", "on-demand"} {
		result, err := service.GetSweepResults(context.Background(), sequence)
		require.NoError(t, err)
		require.Equal(t, id, result.ExecutionId)
		sequence = result.CurrentSequence
	}
}
