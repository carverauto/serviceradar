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
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	goproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// drivenRecorder is a sweepLeaseRunner that records which groups were taken
// off their local ticker.
type drivenRecorder struct {
	driven map[string]bool
}

func (*drivenRecorder) RunSweepGroupLease(context.Context, string, *edgev1.SweepLeaseV1, *edgev1.SweepLeaseSlotV1, *RecordSpool, bool, sweepSlotClaim) error {
	return nil
}
func (r *drivenRecorder) SetGroupLeaseDriven(groupID string, driven bool) { r.driven[groupID] = driven }
func (*drivenRecorder) SetGroupLeaseState(string, string, int64, int)     {}

// A same-lease push with no slots clears the window after a started slot.
// The merged lease keeps lease_version 2 and the slot's check set, so after a
// restart it is still installed, the group stays off its ticker, and the slot
// resolves its checks from the plan.
func TestSweepLeaseSlotlessSameLeaseMergeKeepsTheLeaseAcrossReload(t *testing.T) {
	runtimeRoot := t.TempDir()
	t.Setenv("SERVICERADAR_AGENT_RUNTIME_ROOT", runtimeRoot)
	group := testLeaseGroup.String()
	now := time.Now().Unix()

	loop := &PushLoop{logger: logger.NewTestLogger()}
	store, err := loop.sweepLeaseStore()
	require.NoError(t, err)

	started := testLeaseSlot(now - 60)
	_, err = store.Install(testLeasePush(now-60, now+600, started), group)
	require.NoError(t, err)

	clear := testLeasePush(now+300, now+600)
	require.Equal(t, uint32(sweepLeaseSlotlessVersion), clear.GetLeaseVersion())
	held, err := store.Install(clear, group)
	require.NoError(t, err)
	require.Equal(t, uint32(edgerecord.SweepLeaseCheckSetsVersion), held.GetLeaseVersion())
	require.Len(t, held.GetSlots(), 1)
	require.Len(t, held.GetCheckSets(), 1)

	runner := &drivenRecorder{driven: make(map[string]bool)}
	restarted := &PushLoop{logger: logger.NewTestLogger(), server: &Server{services: []Service{runnerService{runner}}}}
	restarted.markInstalledSweepLeasesDriven()
	require.True(t, runner.driven[group], "the reloaded lease must keep the group off its local ticker")

	reloaded := restarted.loadedSweepLeaseStore().Get(group)
	require.NotNil(t, reloaded)
	require.Equal(t, uint32(edgerecord.SweepLeaseCheckSetsVersion), reloaded.GetLeaseVersion())
	plan, err := sweepPlanChecks(reloaded, reloaded.GetSlots()[0])
	require.NoError(t, err)
	require.Equal(t, []models.SweepMode{models.ModeICMP}, plan.spec.Modes)
}

// runnerService adapts a sweepLeaseRunner to the Server's service list.
type runnerService struct {
	sweepLeaseRunner
}

func (runnerService) Start(context.Context) error { return nil }
func (runnerService) Stop(context.Context) error  { return nil }
func (runnerService) Name() string                { return sweepType }
func (runnerService) UpdateConfig(*models.Config) error {
	return nil
}

// A slot lease stored before this agent ran slots from carried checks is
// discarded on load, so its group returns to the ticker until core pushes a
// full window. A held lease without slots is kept.
func TestSweepLeaseStoreDiscardsPrePlanSlotLeasesOnLoad(t *testing.T) {
	dir := t.TempDir()
	stale := testLeasePush(100, 400, testLeaseSlot(100))
	stale.LeaseVersion = 1
	stale.CheckSets = nil
	staleGroup := testLeaseGroup.String()

	held := testLeasePush(100, 400)
	heldGroup := uuid.New().String()

	for group, lease := range map[string]*edgev1.SweepLeaseV1{staleGroup: stale, heldGroup: held} {
		data, err := goproto.Marshal(lease)
		require.NoError(t, err)
		require.NoError(t, os.WriteFile(filepath.Join(dir, group+".pb"), data, 0o600))
	}
	require.NoError(t, os.WriteFile(filepath.Join(dir, staleGroup+sweepLeaseExecutedSuffix), []byte(`{}`), 0o600))

	store, err := newSweepLeaseStore(dir)
	require.NoError(t, err)
	require.Nil(t, store.Get(staleGroup))
	require.NotNil(t, store.Get(heldGroup))
	for _, name := range []string{staleGroup + ".pb", staleGroup + sweepLeaseExecutedSuffix} {
		_, statErr := os.Stat(filepath.Join(dir, name))
		require.ErrorIs(t, statErr, os.ErrNotExist, "%s must be removed with the discarded lease", name)
	}
}

func controlRequestsSent(stream *fakeControlStreamClient) []*proto.ControlStreamRequest {
	stream.mu.Lock()
	defer stream.mu.Unlock()

	return append([]*proto.ControlStreamRequest(nil), stream.sent...)
}

// refusingLeaseRunner refuses every leased run with err.
type refusingLeaseRunner struct {
	*MultiSweepService
	calls int
	err   error
}

func (r *refusingLeaseRunner) RunSweepGroupLease(context.Context, string, *edgev1.SweepLeaseV1, *edgev1.SweepLeaseSlotV1, *RecordSpool, bool, sweepSlotClaim) error {
	r.calls++
	return r.err
}

type refusalRecorder struct {
	noted         [][]string
	heldWhenNoted []int
	reported      []*proto.SweepLeaseSlotRefusal
	changed       []bool
}

func (r *refusalRecorder) wire(e *sweepLeaseExecutor, now time.Time) {
	e.noteUnavailable = func(markers []string) bool {
		r.noted = append(r.noted, markers)
		r.heldWhenNoted = append(r.heldWhenNoted, len(e.store.Refusals(now)))
		return len(r.noted) == 1
	}
	e.reportRefusal = func(refusal *proto.SweepLeaseSlotRefusal, changed bool) {
		r.reported = append(r.reported, refusal)
		r.changed = append(r.changed, changed)
	}
}

// A refused slot is settled, never re-run, and its refusal outlives a restart.
// The markers are recorded before the refusal is persisted or reported.
func TestSweepLeaseExecutorPersistsAndReportsASlotRefusal(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	built := buildExecutableLease(t, testLeaseIssuedAt, testSlotStart, nil)
	fixture.install(t, built.lease)

	sp, err := openTestRecordSpool(t, t.TempDir())
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })

	runner := &refusingLeaseRunner{
		MultiSweepService: fixture.multi,
		err:               refuseUnavailableChecks([]string{capabilityTCPSynIPv6Unavailable}, "2001:db8::/120 runs tcp_connect"),
	}
	fixture.executor.runnerFor = func() sweepLeaseRunner { return runner }
	fixture.executor.edgeSpool = sp
	now := testSlotStart.Add(time.Minute)
	recorder := &refusalRecorder{}
	recorder.wire(fixture.executor, now)

	fixture.executor.step(context.Background(), func() time.Time { return now })
	fixture.executor.step(context.Background(), func() time.Time { return now.Add(time.Second) })

	require.Equal(t, 1, runner.calls, "a refused slot must not run again")
	require.True(t, fixture.store.Executed(fixture.group, built.executionID))
	require.Equal(t, [][]string{{capabilityTCPSynIPv6Unavailable}}, recorder.noted)
	require.Equal(t, []int{0}, recorder.heldWhenNoted, "markers must be recorded before the refusal is persisted")
	require.Equal(t, []bool{true}, recorder.changed)
	require.Len(t, recorder.reported, 1)

	report := recorder.reported[0]
	require.Equal(t, fixture.group, report.GetSweepGroupId())
	require.Equal(t, built.lease.GetLeaseId(), report.GetLeaseId())
	require.Equal(t, built.lease.GetSlots()[0].GetExecutionId(), report.GetExecutionId())
	require.Equal(t, proto.SweepLeaseSlotRefusalReason_SWEEP_LEASE_SLOT_REFUSAL_REASON_CHECK_UNAVAILABLE, report.GetReason())
	require.Equal(t, []string{capabilityTCPSynIPv6Unavailable}, report.GetUnavailableCapabilities())
	require.Equal(t, now.UnixNano(), report.GetRefusedAtUnixNano())

	reopened, err := newSweepLeaseStore(fixture.dir)
	require.NoError(t, err)
	held := reopened.Refusals(now)
	require.Len(t, held, 1)
	require.True(t, goproto.Equal(report, held[0]))
	// Decision 12 keeps re-sending until 24 hours past collection expiry, the
	// LeaseMisses lookback. The bound is that lookback, not the store's constant.
	const leaseMissLookback = 24 * time.Hour
	expires := time.Unix(0, built.lease.GetSlots()[0].GetCollectionExpiresUnixNano())
	require.Len(t, reopened.Refusals(expires.Add(leaseMissLookback-time.Nanosecond)), 1,
		"a refusal is still re-sent until 24 hours past collection expiry")
	require.Empty(t, reopened.Refusals(expires.Add(leaseMissLookback)),
		"a refusal is dropped once core can no longer judge its slot")
}

// ICMP and raw IPv6 SYN are judged together. When both are missing, one refusal
// names both markers and the slot is not claimed or scanned.
func TestSweepLeaseExecutorRefusesICMPAndIPv6SYNInOneRefusal(t *testing.T) {
	fixture := newLeaseExecutorFixture(t)
	cfg, lease, slot, sp := edgeSweepFixture(t)
	cfg.SweepModes = []models.SweepMode{models.ModeTCPConnect}
	cfg.Ports = []int{80}
	target := slot.PlanPages[0].Ranges[0]
	target.Cidr = "2001:db8::/128"
	target.TargetCount = 1
	slot.PlanHeader.TotalTargetCount = 1
	carrySweepChecks(lease, slot, sweepTestChecks(edgev1.SweepMode_SWEEP_MODE_ICMP, 0), sweepTestChecks(edgev1.SweepMode_SWEEP_MODE_TCP_SYN, 443))

	group := uuid.UUID(lease.GetSweepGroupId()).String()
	fixture.group = group
	fixture.service.sweepGroupID = group
	fixture.service.config = cfg
	fixture.multi.groups = map[string]*SweepService{group: fixture.service}
	fixture.multi.groupSequences = map[string]string{group: ""}
	fixture.multi.groupOrder = []string{group}
	scanner := &observingSweep{
		mockSweeper: fixture.sweeper,
		effective:   []models.SweepMode{models.ModeICMP, models.ModeTCPConnect},
	}
	fixture.service.sweeper = scanner
	fixture.executor.runnerFor = func() sweepLeaseRunner { return fixture.multi }
	fixture.executor.edgeSpool = sp
	fixture.executor.icmpUnavailable = true
	fixture.install(t, lease)

	now := time.Now()
	recorder := &refusalRecorder{}
	recorder.wire(fixture.executor, now)
	fixture.executor.step(context.Background(), func() time.Time { return now })

	require.Equal(t, []string{"2001:db8::/128"}, scanner.cidrs)
	require.Equal(t, []models.SweepMode{models.ModeICMP, models.ModeTCP}, scanner.planned[0].Modes)
	require.Empty(t, scanner.specs)
	require.Zero(t, fixture.sweeper.runCount)
	require.Len(t, recorder.reported, 1)
	require.Equal(t, proto.SweepLeaseSlotRefusalReason_SWEEP_LEASE_SLOT_REFUSAL_REASON_CHECK_UNAVAILABLE, recorder.reported[0].GetReason())
	require.Equal(t, []string{capabilityICMPUnavailable, capabilityTCPSynIPv6Unavailable}, recorder.reported[0].GetUnavailableCapabilities())
	require.Equal(t, [][]string{{capabilityICMPUnavailable, capabilityTCPSynIPv6Unavailable}}, recorder.noted)
	require.Equal(t, []int{0}, recorder.heldWhenNoted)
	require.True(t, fixture.store.Executed(group, uuid.UUID(slot.GetExecutionId()).String()))
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Empty(t, records)
}

// A refusal that adds a marker reaches core after a hello that carries it,
// and every held refusal is sent again on the next control stream.
func TestSweepLeaseSlotRefusalReportedAfterItsMarkerAndResentOnConnect(t *testing.T) {
	runtimeRoot := t.TempDir()
	t.Setenv("SERVICERADAR_AGENT_RUNTIME_ROOT", runtimeRoot)
	cfg := &ServerConfig{AgentID: "agent-1", Partition: "default"}
	loop := NewPushLoop(&Server{config: cfg, sockets: socketProbe{icmp: scan.ICMPSocketProbe{IPv4: true}, mtr: true}}, nil, 30*time.Second, logger.NewTestLogger())

	require.NotContains(t, loop.getAgentCapabilities(cfg), capabilityTCPSynIPv6Unavailable)
	require.Contains(t, loop.getAgentCapabilities(cfg), capabilitySweepLeasePlanChecksV1)

	store, err := loop.sweepLeaseStore()
	require.NoError(t, err)
	now := time.Now()
	slot := testLeaseSlot(now.Unix())
	_, err = store.Install(testLeasePush(now.Unix(), now.Unix()+60, slot), testLeaseGroup.String())
	require.NoError(t, err)
	executionID := uuid.UUID(slot.GetExecutionId()).String()
	refusal := &proto.SweepLeaseSlotRefusal{
		SweepGroupId:            testLeaseGroup.String(),
		ExecutionId:             slot.GetExecutionId(),
		Reason:                  proto.SweepLeaseSlotRefusalReason_SWEEP_LEASE_SLOT_REFUSAL_REASON_CHECK_UNAVAILABLE,
		UnavailableCapabilities: []string{capabilityTCPSynIPv6Unavailable},
	}
	require.NoError(t, store.MarkRefused(testLeaseGroup.String(), executionID, slot.GetCollectionExpiresUnixNano(), refusal, now))

	live := &fakeControlStreamClient{}
	loop.setControlStreamSender(newControlStreamSender(live))
	changed := loop.noteUnavailableChecks(refusal.GetUnavailableCapabilities())
	require.True(t, changed)
	require.False(t, loop.noteUnavailableChecks(refusal.GetUnavailableCapabilities()), "the marker latches once")
	loop.reportSweepLeaseSlotRefusal(refusal, changed)

	sent := controlRequestsSent(live)
	require.Len(t, sent, 2)
	require.Contains(t, sent[0].GetHello().GetCapabilities(), capabilityTCPSynIPv6Unavailable, "the hello carrying the marker goes first")
	require.True(t, goproto.Equal(refusal, sent[1].GetSweepLeaseSlotRefusal()))

	var status agentCapabilityStatusPayload
	require.NoError(t, json.Unmarshal(loop.buildAgentCapabilityGatewayStatus(cfg, nil, nil).GetMessage(), &status))
	require.True(t, slices.Contains(status.Capabilities, capabilityTCPSynIPv6Unavailable))

	reconnected := &fakeControlStreamClient{}
	require.NoError(t, loop.openControlStream(newControlStreamSender(reconnected)))
	resent := controlRequestsSent(reconnected)
	require.Len(t, resent, 2)
	require.NotNil(t, resent[0].GetHello())
	require.True(t, goproto.Equal(refusal, resent[1].GetSweepLeaseSlotRefusal()))
}
