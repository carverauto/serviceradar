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
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
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
	checks, _, _, err := sweepChecks(cfg)
	require.NoError(t, err)
	checkHash := sweepCheckSetDigest(checks)
	r := slot.PlanPages[0].Ranges[0]
	r.Cidr = "192.0.2.0/30"
	r.TargetCount = 4
	r.CheckSetSha256 = checkHash
	r.RangeSha256 = edgerecord.RangeDigest(r)
	page := slot.PlanPages[0]
	page.CheckSetSha256 = checkHash
	page.PageSha256 = edgerecord.PlanPageDigest(page)
	header := slot.PlanHeader
	header.TotalTargetCount = 4
	header.CheckSetSha256 = checkHash
	header.PlanRootSha256 = edgerecord.PlanRoot(slot.PlanPages)
	header.ExecutionPlanSha256 = edgerecord.PlanHeaderDigest(header)
	source := slot.SourceAuthorizations[0]
	source.ScopeSha256 = r.RangeSha256
	source.Capability.GetSource().ScopeSha256 = r.RangeSha256
	source.Capability.GetSource().TargetRangeSha256 = r.RangeSha256
	source.Capability.GetSource().ExecutionPlanSha256 = header.ExecutionPlanSha256
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
	results []models.Result
	err     error
}

func (s *observingSweep) RunOnceWithObserver(_ context.Context, _ string, observe func(*models.Result) error) error {
	for i := range s.results {
		if err := observe(&s.results[i]); err != nil {
			return err
		}
	}
	return s.err
}

func TestEdgeSweepPublishesCompleteWindowsWithoutLegacyOutput(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	scanner := &observingSweep{mockSweeper: &mockSweeper{summary: &models.SweepSummary{LastSweep: 1, TotalHosts: 4, Hosts: []models.HostResult{{Host: "192.0.2.1", Available: true}}}}, results: edgeSweepResults()}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	claims := 0
	require.NoError(t, svc.runLeaseToSpool(context.Background(), lease, slot, sp, func() error { claims++; return nil }))
	require.Equal(t, 1, claims)
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Len(t, records, 4)
	for i, stored := range records {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, proto.Unmarshal(stored.Body, record))
		require.NoError(t, edgerecord.ValidateRecord(record))
		batch := &edgev1.SweepObservationBatchV1{}
		require.NoError(t, proto.Unmarshal(record.Payload, batch))
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

func TestEdgeSweepIncompleteBeforePublicationRemainsRetryable(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	// Only the ICMP half completed. None of these is a terminal host window.
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()[:4], err: errTestScannerInterrupted}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	claimed := false
	require.ErrorContains(t, svc.runLeaseToSpool(context.Background(), lease, slot, sp, func() error { claimed = true; return nil }), "scanner interrupted")
	require.False(t, claimed)
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Empty(t, records)
}

func TestEdgeSweepRefusesMismatchedPlanBeforeScanning(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	cfg.Ports = []int{8443}
	_, err := newSweepEdgeProducer(cfg, lease, slot, sp, time.Now())
	require.ErrorContains(t, err, "check set differs")
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Empty(t, records)
}

func TestEdgeSweepInterruptedAfterPublicationConsumesAttempt(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	scanner := &observingSweep{mockSweeper: &mockSweeper{}, results: edgeSweepResults()[:7], err: errTestScannerInterrupted}
	svc := &SweepService{config: cfg, sweeper: scanner, logger: logger.NewTestLogger()}
	claimed := false
	require.ErrorContains(t, svc.runLeaseToSpool(context.Background(), lease, slot, sp, func() error { claimed = true; return nil }), "scanner interrupted")
	require.True(t, claimed)
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Len(t, records, 2)
}

func TestEdgeSweepMatchesSharedStaticPlanCheckDigest(t *testing.T) {
	// Frozen vector from proto/edge/v1/testdata/sweep_static_plan_corpus.txt,
	// independently computed by the Go and Elixir plan contract tests.
	checks, _, _, err := sweepChecks(&models.Config{SweepModes: []models.SweepMode{models.ModeTCP, models.ModeICMP}, Ports: []int{443, 22, 443}})
	require.NoError(t, err)
	require.Equal(t, "e9449cfb0b14842f2f541b720e3be9ffa81c21da39d175330e2df72c270401f5", fmt.Sprintf("%x", sweepCheckSetDigest(checks)))
}

func TestEdgeSweepSeparatesRangeAuthorityAndSharesBatchSequence(t *testing.T) {
	cfg, lease, slot, sp := edgeSweepFixture(t)
	cfg.Networks = []string{"192.0.2.0/31", "192.0.2.2/31"}
	first := slot.PlanPages[0].Ranges[0]
	first.Cidr = cfg.Networks[0]
	first.TargetCount = 2
	first.RangeSha256 = edgerecord.RangeDigest(first)
	second := proto.Clone(first).(*edgev1.TargetRangeV1)
	second.RangeId = newUUIDBytes()
	second.Cidr = cfg.Networks[1]
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
	producer, err := newSweepEdgeProducer(cfg, lease, slot, sp, time.Now())
	require.NoError(t, err)
	for _, result := range edgeSweepResults() {
		require.NoError(t, producer.observe(&result))
	}
	require.NoError(t, producer.finish())
	records, err := sp.Unresolved()
	require.NoError(t, err)
	require.Len(t, records, 4)
	for i, stored := range records {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, proto.Unmarshal(stored.Body, record))
		batch := &edgev1.SweepObservationBatchV1{}
		require.NoError(t, proto.Unmarshal(record.Payload, batch))
		expected := firstSource
		if batch.Hosts[0].Address[3] >= 2 {
			expected = secondSource
		}
		require.True(t, proto.Equal(expected, record.SourceAuthorization))
		require.Equal(t, expected.ScopeId, batch.TargetRangeId)
		require.Equal(t, uint64(i+1), batch.BatchSequence)
	}
}
