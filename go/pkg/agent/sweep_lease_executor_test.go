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
	fixture.executor.step(context.Background(), now)

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
	restarted.step(context.Background(), now)
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

	fixture.executor.step(context.Background(), testSlotStart.Add(time.Minute))
	require.Equal(t, 0, fixture.sweeper.runCount, "due slot must be refused while the clock is behind the issuance floor")
	require.False(t, fixture.store.Executed(fixture.group, built.executionID), "clock refusal must not settle the slot")

	fixture.executor.step(context.Background(), testSlotStart.Add(6*time.Minute))
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

	fixture.executor.step(context.Background(), testSlotStart.Add(time.Minute))

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

	fixture.executor.step(context.Background(), testLeaseIssuedAt.Add(time.Minute))
	require.True(t, fixture.sweeper.manualSchedule)

	revoked := testLeasePush(100, 101)
	revoked.Revoked = true
	_, err := fixture.store.Install(revoked, fixture.group)
	require.NoError(t, err)

	fixture.executor.step(context.Background(), testLeaseIssuedAt.Add(2*time.Minute))
	require.False(t, fixture.sweeper.manualSchedule, "revoked group must return to its local ticker")
	require.Equal(t, 0, fixture.sweeper.runCount)
}
