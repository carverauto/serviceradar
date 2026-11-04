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
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/sweeper"
	monitoringpb "github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

var errTestScannerInterrupted = errors.New("scanner interrupted")

// All addresses and identity material are synthetic. The scanner boundary is
// replaced so this exercises actual batching, authority binding and fsynced
// spool publication without depending on external hosts or raw-socket access.
func edgeSweepFixture(t *testing.T) (*models.Config, *edgev1.SweepLeaseV1, *edgev1.SweepLeaseSlotV1, *spool.Spool) {
	t.Helper()
	now := time.Now()
	lease := buildExecutableLease(t, now.Add(-time.Minute), now.Add(-time.Second), nil).lease
	lease.SweepGroupId = newUUIDBytes()
	slot := lease.Slots[0]
	cfg := &models.Config{Networks: []string{"192.0.2.0/30"}, SweepModes: []models.SweepMode{models.ModeICMP, models.ModeTCPConnect}, Ports: []int{443}, SweepGroupID: testLeaseGroup.String()}
	r := slot.PlanPages[0].Ranges[0]
	r.Cidr = "192.0.2.0/30"
	r.TargetCount = 4
	slot.PlanHeader.TotalTargetCount = 4
	carrySweepChecks(lease, slot, sweepTestChecks(edgev1.SweepMode_SWEEP_MODE_ICMP, 0), sweepTestChecks(edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT, 443))
	source := slot.SourceAuthorizations[0]
	c := lease.ProductionCapability.GetProduction()
	c.ScopeId = lease.SweepGroupId
	digest := sha256.Sum256([]byte("synthetic-sweep-contract"))
	c.ContractId = "serviceradar.sweep.observation"
	c.ContractVersion = 1
	c.ContractBundleSha256 = digest[:]
	c.RegistryEpoch = 1
	c.RegistrySnapshotSha256 = digest[:]
	c.EffectiveGrantSha256 = digest[:]
	c.OriginKind = edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT
	c.OriginPrincipalId = []byte("agent-synthetic-edge")
	c.ProducerInstanceId = c.OriginPrincipalId
	c.PackageId = "serviceradar.agent.sweep"
	c.PackageSha256 = digest[:]
	c.ScopeSha256 = digest[:]
	c.RouteProfile = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1
	c.TrafficClass = edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK
	c.CostModelVersion = 1
	// One host plus an open port/error fits. Two hosts must flush separately.
	c.MaxProjectedRowCount = 2
	c.MaxProjectedWriteBytes = 4096
	sourceClaims := source.Capability.GetSource()
	sourceClaims.OriginPrincipalId = c.OriginPrincipalId
	sourceClaims.ProducerInstanceId = c.ProducerInstanceId
	sourceClaims.OriginKind = c.OriginKind
	sourceClaims.RouteProfile = c.RouteProfile
	sourceClaims.TrafficClass = c.TrafficClass
	sp, err := spool.Open(t.TempDir())
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })
	return cfg, lease, slot, sp
}

// sweepTestChecks is mode on each port, as the check-set grammar spells it.
func sweepTestChecks(mode edgev1.SweepMode, ports ...uint32) []*edgev1.SweepTestV1 {
	protocol := edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP
	if mode == edgev1.SweepMode_SWEEP_MODE_ICMP {
		protocol = edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP
	}
	checks := make([]*edgev1.SweepTestV1, 0, len(ports))
	for _, port := range ports {
		checks = append(checks, &edgev1.SweepTestV1{Mode: mode, Protocol: protocol, Port: port})
	}
	return checks
}

// carrySweepChecks makes the lease carry groups (in grammar order) as the one
// check set its slot runs, and rebinds the slot's signed plan to it.
func carrySweepChecks(lease *edgev1.SweepLeaseV1, slot *edgev1.SweepLeaseSlotV1, groups ...[]*edgev1.SweepTestV1) {
	var checks []*edgev1.SweepTestV1
	for _, group := range groups {
		checks = append(checks, group...)
	}
	key := edgerecord.CheckSetDigest(checks)
	lease.LeaseVersion = edgerecord.SweepLeaseCheckSetsVersion
	lease.CheckSets = []*edgev1.SweepCheckSetV1{{CheckSetSha256: key, DigestVersion: edgerecord.CheckSetDigestVersion, Checks: checks}}
	resignSweepFixtureChecks(slot, key)
}

// resignSweepFixtureChecks rebinds the fixture's single-range plan and source
// authorization to checkHash.
func resignSweepFixtureChecks(slot *edgev1.SweepLeaseSlotV1, checkHash []byte) {
	r := slot.PlanPages[0].Ranges[0]
	r.CheckSetSha256 = checkHash
	r.RangeSha256 = edgerecord.RangeDigest(r)
	page := slot.PlanPages[0]
	page.CheckSetSha256 = checkHash
	page.PageSha256 = edgerecord.PlanPageDigest(page)
	header := slot.PlanHeader
	header.CheckSetSha256 = checkHash
	header.PlanRootSha256 = edgerecord.PlanRoot(slot.PlanPages)
	header.ExecutionPlanSha256 = edgerecord.PlanHeaderDigest(header)
	source := slot.SourceAuthorizations[0]
	source.ScopeSha256 = r.RangeSha256
	source.Capability.GetSource().ScopeSha256 = r.RangeSha256
	source.Capability.GetSource().TargetRangeSha256 = r.RangeSha256
	source.Capability.GetSource().ExecutionPlanSha256 = header.ExecutionPlanSha256
}

// recordBody is the inner contract body a record carries under its declared
// compression.
func recordBody(t *testing.T, record *edgev1.EdgeRecordV1) []byte {
	t.Helper()
	if record.Compression == edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD {
		body, err := edgerecord.DecompressZstdPayload(record.Payload, record.UncompressedSize)
		require.NoError(t, err)
		return body
	}
	require.Equal(t, edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE, record.Compression)
	return record.Payload
}

func edgeSweepResults() []models.Result {
	var results []models.Result
	now := time.Now()
	for _, mode := range []models.SweepMode{models.ModeICMP, models.ModeTCPConnect} {
		for i := 0; i < 4; i++ {
			r := models.Result{Target: models.Target{Host: fmt.Sprintf("192.0.2.%d", i), Mode: mode}, FirstSeen: now, LastSeen: now, Available: i%2 == 0, RespTime: 120 * time.Microsecond}
			if mode == models.ModeICMP {
				r.PacketsSent = 3
				if r.Available {
					r.PacketsReceived = 1
				}
				r.PacketLoss = float64(3-r.PacketsReceived) / 3 * 100
			} else {
				r.Target.Port = 443
				if !r.Available {
					r.Error = context.DeadlineExceeded
				}
			}
			results = append(results, r)
		}
	}
	return results
}

type observingSweep struct {
	*mockSweeper
	results   []models.Result
	err       error
	effective []models.SweepMode
	specs     []sweeper.RunSpec
	planned   []sweeper.RunSpec
	cidrs     []string
}

func (s *observingSweep) EffectivePlannedSweepModes(cidr string, spec sweeper.RunSpec) ([]models.SweepMode, error) {
	s.cidrs = append(s.cidrs, cidr)
	s.planned = append(s.planned, spec)
	if s.effective != nil {
		return s.effective, nil
	}
	return spec.Modes, nil
}

func (s *observingSweep) RunPlannedWithObserver(ctx context.Context, executionID string, spec sweeper.RunSpec, observe func(context.Context, *models.Result) error) error {
	s.specs = append(s.specs, spec)
	for i := range s.results {
		if err := observe(ctx, &s.results[i]); err != nil {
			return err
		}
	}
	if s.err != nil {
		return s.err
	}
	return s.RunOnceWithExecution(ctx, executionID)
}

func TestEdgeSweepPublishesCompleteWindowsWithoutLegacyOutput(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	scanner := &observingSweep{mockSweeper: &mockSweeper{summary: &models.SweepSummary{LastSweep: 1, TotalHosts: 4, Hosts: []models.HostResult{{Host: "192.0.2.1", Available: true}}}}, results: edgeSweepResults()}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	claims := 0
	require.NoError(t, svc.runLeaseToSpool(context.Background(), lease, slot, sp, false, sweepSlotClaim{claim: func() error { claims++; return nil }}))
	require.Equal(t, 1, claims)
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Len(t, records, 4)
	for i, stored := range records {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, proto.Unmarshal(stored.Body, record))
		require.NoError(t, edgerecord.ValidateRecord(record))
		batch := &edgev1.SweepObservationBatchV1{}
		require.NoError(t, proto.Unmarshal(recordBody(t, record), batch))
		require.NoError(t, edgerecord.ValidateSweepObservationBatch(batch))
		require.Equal(t, uint64(i+1), batch.BatchSequence)
		require.Equal(t, slot.ExecutionId, batch.ExecutionId)
		require.Equal(t, lease.SweepGroupId, batch.SweepGroupId)
		require.True(t, proto.Equal(record.SourceAuthorization, slot.SourceAuthorizations[0]))
		require.Equal(t, lease.ProducerAssignmentId, record.ProducerContext.ProducerAssignmentId)
		require.Len(t, batch.Hosts, 1)
		host := batch.Hosts[0]
		require.Equal(t, uint32(5), host.ResultModeBits)
		require.Equal(t, uint32(3), host.Icmp.Sent)
		require.Equal(t, uint32(1), host.Tcp.TestedCount)
		if i%2 == 0 {
			require.True(t, host.Icmp.TargetReached)
			require.Equal(t, uint32(1), host.Icmp.Received)
			require.Equal(t, uint64(120), host.Icmp.GetRoundTripMicro())
			require.Len(t, host.OpenPorts, 1)
		} else {
			require.False(t, host.Icmp.TargetReached)
			require.Equal(t, uint32(0), host.Icmp.Received)
			require.Len(t, host.PortErrors, 1)
			require.Equal(t, "timeout", host.PortErrors[0].ErrorCode)
		}
	}
	legacy, err := svc.GetSweepResults(context.Background(), "")
	require.NoError(t, err)
	require.False(t, legacy.HasNewData)
	require.Empty(t, legacy.Data)
}

func TestEdgeSweepKeepsOtherExecutionsOnLegacyPath(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	scanner := &observingSweep{mockSweeper: &mockSweeper{summary: &models.SweepSummary{LastSweep: 1, TotalHosts: 1, Hosts: []models.HostResult{{Host: "192.0.2.1", Available: true}}}}, results: edgeSweepResults()}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	ctx := context.Background()

	require.NoError(t, svc.RunOnceForExecution(ctx, "queued"))
	require.NoError(t, svc.runLeaseToSpool(ctx, lease, slot, sp, false, sweepSlotClaim{}))

	queued, err := svc.GetSweepResults(ctx, "")
	require.NoError(t, err)
	require.True(t, queued.HasNewData)
	require.Equal(t, "queued", queued.ExecutionId)
	leased, err := svc.GetSweepResults(ctx, queued.CurrentSequence)
	require.NoError(t, err)
	require.False(t, leased.HasNewData)

	require.NoError(t, svc.RunOnceForExecution(ctx, "manual"))
	manual, err := svc.GetSweepResults(ctx, leased.CurrentSequence)
	require.NoError(t, err)
	require.True(t, manual.HasNewData)
	require.Equal(t, "manual", manual.ExecutionId)
}

func TestEdgeSweepFailedLeaseKeepsEarlierLeasedCycleOffLegacyPath(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	scanner := &observingSweep{mockSweeper: &mockSweeper{summary: &models.SweepSummary{LastSweep: 1, TotalHosts: 1, Hosts: []models.HostResult{{Host: "192.0.2.1", Available: true}}}}, results: edgeSweepResults()}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	ctx := context.Background()

	require.NoError(t, svc.RunOnceForExecution(ctx, "queued"))
	require.NoError(t, svc.runLeaseToSpool(ctx, lease, slot, sp, false, sweepSlotClaim{}))
	leasedAgain := proto.Clone(slot).(*edgev1.SweepLeaseSlotV1)
	leasedAgain.ExecutionId = newUUIDBytes()
	scanner.results = []models.Result{{Target: models.Target{Host: "not-an-address", Mode: models.ModeICMP}}}
	require.ErrorContains(t, svc.runLeaseToSpool(ctx, lease, leasedAgain, sp, false, sweepSlotClaim{}), "edge sweep result address")

	queued, err := svc.GetSweepResults(ctx, "")
	require.NoError(t, err)
	require.True(t, queued.HasNewData)
	require.Equal(t, "queued", queued.ExecutionId)
	after, err := svc.GetSweepResults(ctx, queued.CurrentSequence)
	require.NoError(t, err)
	require.False(t, after.HasNewData)
	require.Equal(t, queued.CurrentSequence, after.CurrentSequence)
}

// TCP SYN on an IPv6 range without raw IPv6 SYN would run as connect. The
// slot is refused with the marker the planner reacts to, before it claims or
// scans anything, instead of running the substitute under the signed plan.
func TestEdgeSweepRefusesSignedModeTheScannerWouldRemap(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	carrySweepChecks(lease, slot, sweepTestChecks(edgev1.SweepMode_SWEEP_MODE_ICMP, 0), sweepTestChecks(edgev1.SweepMode_SWEEP_MODE_TCP_SYN, 443))
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults(), effective: []models.SweepMode{models.ModeICMP, models.ModeTCPConnect}}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	claimed := false
	err := svc.runLeaseToSpool(context.Background(), lease, slot, sp, false, sweepSlotClaim{claim: func() error { claimed = true; return nil }})
	var refusal *sweepSlotRefusal
	require.ErrorAs(t, err, &refusal)
	require.Equal(t, monitoringpb.SweepLeaseSlotRefusalReason_SWEEP_LEASE_SLOT_REFUSAL_REASON_CHECK_UNAVAILABLE, refusal.reason)
	require.Equal(t, []string{capabilityTCPSynIPv6Unavailable}, refusal.markers)
	require.False(t, claimed)
	require.Empty(t, scanner.specs)
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Empty(t, records)
}

// A group configured without TCP still runs a carried TCP SYN on IPv6 when the
// scanner the planned run will use can send raw IPv6 SYN. The run is the signed
// plan, not the group config.
func TestEdgeSweepRunsCarriedIPv6SYNWhenThePlannedScannerCanSendIt(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	cfg.Networks = []string{"198.51.100.0/24"}
	cfg.SweepModes = []models.SweepMode{models.ModeICMP}
	cfg.Ports = []int{80}
	r := slot.PlanPages[0].Ranges[0]
	r.Cidr = "2001:db8::/128"
	r.TargetCount = 1
	slot.PlanHeader.TotalTargetCount = 1
	carrySweepChecks(lease, slot, sweepTestChecks(edgev1.SweepMode_SWEEP_MODE_ICMP, 0), sweepTestChecks(edgev1.SweepMode_SWEEP_MODE_TCP_SYN, 443))
	now := time.Now()
	host := "2001:db8::"
	results := []models.Result{
		{Target: models.Target{Host: host, Mode: models.ModeICMP}, FirstSeen: now, LastSeen: now, Available: true, RespTime: 120 * time.Microsecond, PacketsSent: 3, PacketsReceived: 1},
		{Target: models.Target{Host: host, Mode: models.ModeTCP, Port: 443}, FirstSeen: now, LastSeen: now, Available: true, RespTime: 120 * time.Microsecond},
	}
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: results}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	claims := 0
	require.NoError(t, svc.runLeaseToSpool(context.Background(), lease, slot, sp, false, sweepSlotClaim{claim: func() error { claims++; return nil }}))
	require.Equal(t, 1, claims)
	plan := sweeper.RunSpec{
		Networks: []string{"2001:db8::/128"},
		Modes:    []models.SweepMode{models.ModeICMP, models.ModeTCP},
		Ports:    []int{443},
	}
	require.Equal(t, []string{"2001:db8::/128"}, scanner.cidrs)
	require.Equal(t, []sweeper.RunSpec{plan}, scanner.planned)
	require.Equal(t, []sweeper.RunSpec{plan}, scanner.specs)
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.NotEmpty(t, records)
}

// ICMP unavailability is refused with the planned-mode markers, before claim.
// A plan the scanner can run as signed still refuses when ICMP sockets cannot open.
func TestEdgeSweepRefusesUnavailableICMPBeforeClaim(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	claimed := false
	err := svc.runLeaseToSpool(context.Background(), lease, slot, sp, true, sweepSlotClaim{claim: func() error { claimed = true; return nil }})
	var refusal *sweepSlotRefusal
	require.ErrorAs(t, err, &refusal)
	require.Equal(t, monitoringpb.SweepLeaseSlotRefusalReason_SWEEP_LEASE_SLOT_REFUSAL_REASON_CHECK_UNAVAILABLE, refusal.reason)
	require.Equal(t, []string{capabilityICMPUnavailable}, refusal.markers)
	require.False(t, claimed)
	require.Empty(t, scanner.specs)
}

// The scanner runs every TCP mode on every port, so a carried set that probes
// different ports per TCP mode cannot run as signed and is refused unsupported.
func TestEdgeSweepRefusesACheckSetTheScannerCannotExpress(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	carrySweepChecks(lease, slot, sweepTestChecks(edgev1.SweepMode_SWEEP_MODE_TCP_SYN, 22, 443), sweepTestChecks(edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT, 80))
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	claimed := false
	err := svc.runLeaseToSpool(context.Background(), lease, slot, sp, false, sweepSlotClaim{claim: func() error { claimed = true; return nil }})
	var refusal *sweepSlotRefusal
	require.ErrorAs(t, err, &refusal)
	require.Equal(t, monitoringpb.SweepLeaseSlotRefusalReason_SWEEP_LEASE_SLOT_REFUSAL_REASON_UNSUPPORTED_PLAN, refusal.reason)
	require.False(t, claimed)
	require.Empty(t, scanner.specs)
}

func TestEdgeSweepIncompleteBeforePublicationRemainsRetryable(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	// Only the ICMP half completed. None of these is a terminal host window.
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()[:4], err: errTestScannerInterrupted}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	claimed := false
	require.ErrorContains(t, svc.runLeaseToSpool(context.Background(), lease, slot, sp, false, sweepSlotClaim{claim: func() error { claimed = true; return nil }}), "scanner interrupted")
	require.False(t, claimed)
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Empty(t, records)
}

// The group config and the signed plan travel separately. A slot runs its
// plan's CIDRs, modes and ports however far the config has drifted, and every
// batch claims exactly the carried checks.
func TestEdgeSweepRunsThePlanWhenTheConfigDiffers(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	cfg.Networks = []string{"198.51.100.0/24"}
	cfg.SweepModes = []models.SweepMode{models.ModeTCP}
	cfg.Ports = []int{8443}
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	require.NoError(t, svc.runLeaseToSpool(context.Background(), lease, slot, sp, false, sweepSlotClaim{}))
	require.Equal(t, []sweeper.RunSpec{{
		Networks: []string{"192.0.2.0/30"},
		Modes:    []models.SweepMode{models.ModeICMP, models.ModeTCPConnect},
		Ports:    []int{443},
	}}, scanner.specs)
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Len(t, records, 4)
	for _, stored := range records {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, proto.Unmarshal(stored.Body, record))
		batch := &edgev1.SweepObservationBatchV1{}
		require.NoError(t, proto.Unmarshal(recordBody(t, record), batch))
		require.Len(t, batch.TestedChecks, len(lease.CheckSets[0].Checks))
		for i, check := range lease.CheckSets[0].Checks {
			require.True(t, proto.Equal(check, batch.TestedChecks[i]))
		}
	}
}

func TestEdgeSweepInterruptedAfterPublicationConsumesAttempt(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()[:7], err: errTestScannerInterrupted}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	claimed := false
	released := false
	require.ErrorContains(t, svc.runLeaseToSpool(context.Background(), lease, slot, sp, false, sweepSlotClaim{
		claim:   func() error { claimed = true; return nil },
		release: func() error { released = true; return nil },
	}), "scanner interrupted")
	require.True(t, claimed)
	require.False(t, released, "a slot that already admitted a record stays consumed")
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Len(t, records, 2)
}

func TestEdgeSweepSeparatesRangeAuthorityAndSharesBatchSequence(t *testing.T) {
	_, lease, slot, sp := edgeSweepFixture(t)
	networks := []string{"192.0.2.0/31", "192.0.2.2/31"}
	first := slot.PlanPages[0].Ranges[0]
	first.Cidr = networks[0]
	first.TargetCount = 2
	first.RangeSha256 = edgerecord.RangeDigest(first)
	second := proto.Clone(first).(*edgev1.TargetRangeV1)
	second.RangeId = newUUIDBytes()
	second.Cidr = networks[1]
	second.RangeSha256 = edgerecord.RangeDigest(second)
	slot.PlanPages[0].Ranges = append(slot.PlanPages[0].Ranges, second)
	firstSource := slot.SourceAuthorizations[0]
	firstSource.ScopeSha256 = first.RangeSha256
	firstSource.Capability.GetSource().ScopeSha256 = first.RangeSha256
	firstSource.Capability.GetSource().TargetRangeSha256 = first.RangeSha256
	secondSource := proto.Clone(firstSource).(*edgev1.EdgeSourceAuthorizationV1)
	secondSource.ScopeId = second.RangeId
	secondSource.ScopeSha256 = second.RangeSha256
	secondSource.Capability.GetSource().ScopeId = second.RangeId
	secondSource.Capability.GetSource().ScopeSha256 = second.RangeSha256
	secondSource.Capability.GetSource().TargetRangeSha256 = second.RangeSha256
	slot.SourceAuthorizations = append(slot.SourceAuthorizations, secondSource)
	producer, err := newSweepEdgeProducer(lease, slot, sp, time.Now())
	require.NoError(t, err)
	for _, result := range edgeSweepResults() {
		require.NoError(t, producer.observe(context.Background(), &result))
	}
	require.NoError(t, producer.finish())
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Len(t, records, 4)
	for i, stored := range records {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, proto.Unmarshal(stored.Body, record))
		batch := &edgev1.SweepObservationBatchV1{}
		require.NoError(t, proto.Unmarshal(recordBody(t, record), batch))
		expected := firstSource
		if batch.Hosts[0].Address[3] >= 2 {
			expected = secondSource
		}
		require.True(t, proto.Equal(expected, record.SourceAuthorization))
		require.Equal(t, expected.ScopeId, batch.TargetRangeId)
		require.Equal(t, uint64(i+1), batch.BatchSequence)
	}
}

// fullEdgeSweepSpool returns a spool that shares one allocator with a filler lane
// that has taken every ordinary byte, so the spool's next append is refused, and
// a release func that returns the filler's bytes to the allocator.
func fullEdgeSweepSpool(t *testing.T) (*spool.Spool, func()) {
	t.Helper()
	footprint := spool.Footprint{DestinationSegment: 1024, AttributionSidecar: 64, JournalCopy: 64, ManifestPages: 64, Mapping: 64, FilesystemMetadata: 64}
	perRecovery, err := footprint.PerRecovery()
	require.NoError(t, err)
	const minFree = 4096
	alloc, err := spool.NewAllocator(spool.AllocatorConfig{Capacity: perRecovery + minFree + 64<<10, Recovery: footprint, MaxConcurrentRecoveries: 1, MinFree: minFree})
	require.NoError(t, err)

	sp, err := spool.Open(t.TempDir(), spool.WithAllocator(alloc))
	require.NoError(t, err)
	t.Cleanup(func() { _ = sp.Close() })
	fillerDir := t.TempDir()
	filler, err := spool.Open(fillerDir, spool.WithAllocator(alloc))
	require.NoError(t, err)
	before := alloc.Usage().OrdinaryUsed
	for i := 0; ; i++ {
		id, err := edgerecord.NewUUIDv7()
		require.NoError(t, err)
		if _, err := filler.Append(id, []byte("synthetic filler record")); errors.Is(err, spool.ErrAdmissionRefused) {
			break
		}
		require.NoError(t, err)
		require.Less(t, i, 10_000, "the filler never filled the allocator")
	}
	held := alloc.Usage().OrdinaryUsed - before
	require.NoError(t, filler.Close())
	return sp, func() { require.NoError(t, alloc.ReleaseOrdinary(fillerDir, held)) }
}

// A full spool pauses a leased sweep instead of failing it. Once the sender frees
// space, the run completes with every record an unconstrained run writes.
func TestEdgeSweepWaitsForSpoolAdmissionInsteadOfFailing(t *testing.T) {
	cfg, lease, slot, baseline := edgeSweepFixture(t)
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	require.NoError(t, svc.runLeaseToSpool(context.Background(), lease, slot, baseline, false, sweepSlotClaim{}))
	want, err := baseline.Unresolved()
	require.NoError(t, err)
	require.NotEmpty(t, want)

	sp, release := fullEdgeSweepSpool(t)
	go func() {
		time.Sleep(600 * time.Millisecond)
		release()
	}()
	scanner = &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()}
	svc = &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	require.NoError(t, svc.runLeaseToSpool(context.Background(), lease, slot, sp, false, sweepSlotClaim{}))
	got, err := sp.Unresolved()
	require.NoError(t, err)
	require.Len(t, got, len(want))
}

// A cancelled scan ends the admission wait while the collection window is still open.
func TestEdgeSweepAdmissionWaitEndsWhenTheScanCancels(t *testing.T) {
	cfg, lease, slot, _ := edgeSweepFixture(t)
	sp, _ := fullEdgeSweepSpool(t)
	scanner := &scanCancelSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	done := make(chan error, 1)
	go func() {
		done <- svc.runLeaseToSpool(context.Background(), lease, slot, sp, false, sweepSlotClaim{})
	}()
	select {
	case err := <-done:
		require.ErrorIs(t, err, spool.ErrAdmissionRefused)
		require.ErrorIs(t, err, context.Canceled)
	case <-time.After(2 * time.Second):
		t.Fatal("admission wait continued after the scan was cancelled")
	}
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Empty(t, records)
}

// scanCancelSweep delivers results on a scan context it cancels immediately,
// leaving the producer's collection-expiry context running.
type scanCancelSweep struct {
	*mockSweeper
	results []models.Result
}

func (*scanCancelSweep) EffectivePlannedSweepModes(_ string, spec sweeper.RunSpec) ([]models.SweepMode, error) {
	return spec.Modes, nil
}

func (s *scanCancelSweep) RunPlannedWithObserver(ctx context.Context, _ string, _ sweeper.RunSpec, observe func(context.Context, *models.Result) error) error {
	scanCtx, cancel := context.WithCancel(ctx)
	cancel()
	for i := range s.results {
		if err := observe(scanCtx, &s.results[i]); err != nil {
			return err
		}
	}
	return nil
}

// A spool that never frees ends the wait with the run, reporting the refusal.
func TestEdgeSweepAdmissionWaitEndsWithTheRun(t *testing.T) {
	cfg, lease, slot, _ := edgeSweepFixture(t)
	sp, _ := fullEdgeSweepSpool(t)
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	err := svc.runLeaseToSpool(ctx, lease, slot, sp, false, sweepSlotClaim{})
	require.ErrorIs(t, err, spool.ErrAdmissionRefused)
	records, readErr := sp.Unresolved()
	require.NoError(t, readErr)
	require.Empty(t, records)
}

// The caller context stays open. The run context's own deadline is the slot
// collection expiry, so a spool that never frees stops there and writes nothing.
func TestEdgeSweepAdmissionWaitEndsAtCollectionExpiry(t *testing.T) {
	cfg, lease, slot, _ := edgeSweepFixture(t)
	slot.CollectionExpiresUnixNano = time.Now().Add(400 * time.Millisecond).UnixNano()
	sp, _ := fullEdgeSweepSpool(t)
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	// The parent stays open well past the slot. A wait on the caller context, or
	// on the original 15m window, would still be running when this returns.
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	start := time.Now()
	err := svc.runLeaseToSpool(ctx, lease, slot, sp, false, sweepSlotClaim{})
	elapsed := time.Since(start)
	require.NoError(t, ctx.Err())
	require.ErrorIs(t, err, spool.ErrAdmissionRefused)
	require.ErrorIs(t, err, context.DeadlineExceeded)
	require.Less(t, elapsed, time.Second, "wait followed the collection expiry, not the caller context")
	records, readErr := sp.Unresolved()
	require.NoError(t, readErr)
	require.Empty(t, records)
}

// A closed spool is not an admission refusal. The run returns that error at
// once, and the slot claim has already happened because it precedes the append.
func TestEdgeSweepReturnsOtherAppendErrorsWithoutWaiting(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	require.NoError(t, sp.Close())
	claims := 0
	releases := 0
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	start := time.Now()
	err := svc.runLeaseToSpool(context.Background(), lease, slot, sp, false, sweepSlotClaim{
		claim: func() error {
			claims++
			return nil
		},
		release: func() error {
			releases++
			return nil
		},
	})
	elapsed := time.Since(start)
	t.Logf("closed-spool append returned in %s with %d claim(s) and %d release(s): %v", elapsed, claims, releases, err)
	require.ErrorIs(t, err, os.ErrClosed)
	require.NotErrorIs(t, err, spool.ErrAdmissionRefused)
	require.Equal(t, 1, claims)
	require.Zero(t, releases, "a non-admission append error keeps the slot claim")
	require.Less(t, elapsed, sweepAdmissionInitialBackoff, "a non-admission append error must not enter the backoff")
}

func TestEdgeSweepIgnoresMtrModeWhenComparingPlannedModes(t *testing.T) {
	require.True(t, sameSweepModes(
		[]models.SweepMode{models.ModeICMP, models.ModeMTR},
		[]models.SweepMode{models.ModeICMP},
	))
	require.False(t, sameSweepModes(
		[]models.SweepMode{models.ModeMTR},
		[]models.SweepMode{models.ModeICMP},
	))
}
