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
	"crypto/sha256"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
)

func scheduledMtrGrantRows(t *testing.T, agentID string, notBefore, expires time.Time, maxRows uint32) *proto.EdgeOutputGrant {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	digest := sha256.Sum256([]byte("synthetic-scheduled-mtr-contract"))
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("test-issuer"),
		IssuerKeyId:       []byte("test-issuer-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: notBefore.UnixNano(),
		ExpiresAtUnixNano: expires.UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId:             edgerecord.ScheduledMtrTraceContractID,
			ContractVersion:        edgerecord.ScheduledMtrTraceContractVersion,
			ContractBundleSha256:   digest[:],
			RegistryEpoch:          1,
			RegistrySnapshotSha256: digest[:],
			EffectiveGrantSha256:   digest[:],
			NetworkScopeId:         testNetworkScopeID[:],
			ProducerAssignmentId:   testAssignmentID[:],
			RunId:                  testAssignmentID[:],
			AuthorityEpoch:         1,
			ScopeId:                testAssignmentID[:],
			ScopeSha256:            digest[:],
			OriginKind:             edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT,
			OriginPrincipalId:      []byte(agentID),
			ProducerInstanceId:     []byte(agentID),
			RouteProfile:           edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass:           edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:              "serviceradar.agent.mtr",
			PackageSha256:          digest[:],
			CostModelVersion:       1,
			MaxProjectedRowCount:   maxRows,
			MaxProjectedWriteBytes: uint64(maxRows) * edgerecord.ScheduledMtrTraceProjectedRowBytes,
		}},
	}
	edgerecord.SignCapability(capability, key)
	encoded, err := gproto.Marshal(capability)
	require.NoError(t, err)
	return &proto.EdgeOutputGrant{
		ContractId:           edgerecord.ScheduledMtrTraceContractID,
		ContractVersion:      edgerecord.ScheduledMtrTraceContractVersion,
		ProductionCapability: encoded,
	}
}

func currentScheduledMtrGrant(t *testing.T) *proto.EdgeOutputGrant {
	t.Helper()
	now := time.Now()
	return scheduledMtrGrantRows(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour), edgerecord.ScheduledMtrTraceMaxRows)
}

func syntheticMtrCheckResult() mtrCheckResult {
	unreachableCode := 3
	srvResp := int64(3100)
	return mtrCheckResult{
		CheckID:   "mtr-check-01",
		CheckName: "Synthetic Edge Core Link",
		Target:    "target.example.com",
		DeviceID:  "sr:0197f8a0-0000-7000-8000-000000000001",
		Available: true,
		Timestamp: 1_780_000_000_000_000_000,
		Trace: &mtr.TraceResult{
			Target:            "target.example.com",
			TargetIP:          "192.0.2.10",
			TargetReached:     true,
			TotalHops:         2,
			ProbedHops:        4,
			LastRespondingHop: 2,
			Protocol:          "tcp",
			TCPPort:           443,
			TCPProbeMode:      "syn",
			IPVersion:         4,
			PacketSize:        64,
			Timestamp:         1_780_000_000_000_000_000,
			TCPHandshake: &mtr.TCPHandshakeStats{
				TTL:               64,
				Attempts:          3,
				SYNSent:           4,
				SYNACKReceived:    3,
				RSTReceived:       0,
				Unanswered:        1,
				DropPct:           25.0,
				Retransmits:       1,
				AnsweredAfterRetx: 1,
				AckMismatch:       0,
				SYNACKDuplicates:  0,
				RTTMinUs:          2900,
				RTTAvgUs:          3200,
				RTTMaxUs:          3800,
				ServerResponseUs:  &srvResp,
			},
			Hops: []mtr.HopSnapshot{
				{
					HopNumber:            1,
					Addr:                 "198.51.100.1",
					Hostname:             "hop1.example.com",
					ECMPAddrs:            []string{"198.51.100.2"},
					ASN:                  mtr.ASNInfo{ASN: 64512, Org: "Example Transit AS64512"},
					MPLSLabels:           []mtr.MPLSLabel{{Label: 24001, Exp: 0, S: true, TTL: 63}},
					Sent:                 10,
					Received:             10,
					LossPct:              0,
					LastUs:               1200,
					AvgUs:                1150,
					MinUs:                1000,
					MaxUs:                1400,
					StdDevUs:             120,
					JitterUs:             80,
					JitterWorstUs:        200,
					JitterInterarrivalUs: 95,
					ReplyTimeExceeded:    10,
				},
				{
					HopNumber:            2,
					Addr:                 "192.0.2.10",
					Hostname:             "target.example.com",
					ASN:                  mtr.ASNInfo{ASN: 64513, Org: "Example Edge AS64513"},
					Sent:                 10,
					Received:             9,
					LossPct:              10,
					LastUs:               3400,
					AvgUs:                3200,
					MinUs:                2900,
					MaxUs:                3800,
					StdDevUs:             250,
					JitterUs:             140,
					JitterWorstUs:        400,
					JitterInterarrivalUs: 160,
					UnreachableCode:      &unreachableCode,
					ReplyUnreachable:     1,
					ReplySynack:          8,
				},
			},
		},
	}
}

func spooledMtrAndMetricBatches(t *testing.T, sp *spool.Spool) ([]*edgev1.AgentScheduledMtrTraceBatchV1, []*metricpb.MetricBatch) {
	t.Helper()
	stored, err := sp.Unresolved()
	require.NoError(t, err)
	var traces []*edgev1.AgentScheduledMtrTraceBatchV1
	var metrics []*metricpb.MetricBatch
	for _, s := range stored {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, gproto.Unmarshal(s.Body, record))
		switch record.GetOutputContract().GetContractId() {
		case edgerecord.ScheduledMtrTraceContractID:
			require.NoError(t, edgerecord.ValidateScheduledMtrTraceRecord(record))
			batch := &edgev1.AgentScheduledMtrTraceBatchV1{}
			require.NoError(t, gproto.Unmarshal(recordBody(t, record), batch))
			traces = append(traces, batch)
		case edgerecord.MetricsBatchContractID:
			require.NoError(t, edgerecord.ValidateMetricBatchRecord(record))
			batch := &metricpb.MetricBatch{}
			require.NoError(t, gproto.Unmarshal(recordBody(t, record), batch))
			metrics = append(metrics, batch)
		default:
			t.Fatalf("unexpected contract in spool: %s", record.GetOutputContract().GetContractId())
		}
	}
	return traces, metrics
}

func TestScheduledMtrTraceBatchParity(t *testing.T) {
	res := syntheticMtrCheckResult()
	batch, err := buildScheduledMtrTraceBatch([]mtrCheckResult{res}, metricEnvelopeContext{})
	require.NoError(t, err)
	require.NoError(t, edgerecord.ValidateScheduledMtrTraceBatch(batch))
	require.Len(t, batch.GetTraces(), 1)

	entry := batch.GetTraces()[0]
	require.Equal(t, res.CheckID, entry.GetCheckId())
	require.Equal(t, res.CheckName, entry.GetCheckName())
	require.Equal(t, res.DeviceID, entry.GetDeviceId())
	require.Equal(t, uint32(4), entry.GetProbedHops())
	require.Equal(t, uint32(2), entry.GetLastRespondingHop())
	require.Equal(t, uint32(443), entry.GetTcpPort())
	require.Equal(t, edgev1.MtrTcpProbeModeV1_MTR_TCP_PROBE_MODE_V1_SYN, entry.GetTcpProbeMode())
	require.NotNil(t, entry.GetTcpHandshake())
	require.Equal(t, uint32(64), entry.GetTcpHandshake().GetTtl())
	require.Equal(t, uint32(3), entry.GetTcpHandshake().GetAttempts())
	require.Equal(t, uint32(4), entry.GetTcpHandshake().GetSynSent())
	require.Equal(t, uint32(3), entry.GetTcpHandshake().GetSynackReceived())
	require.Equal(t, int64(3100), entry.GetTcpHandshake().GetServerResponseUs())
	require.True(t, entry.GetTcpHandshake().GetHasServerResponseUs())

	require.Len(t, entry.GetHopDiagnostics(), 2)
	require.Equal(t, uint32(10), entry.GetHopDiagnostics()[0].GetReplyTimeExceeded())
	require.True(t, entry.GetHopDiagnostics()[1].GetHasUnreachableCode())
	require.Equal(t, uint32(3), entry.GetHopDiagnostics()[1].GetUnreachableCode())
	require.Equal(t, uint32(8), entry.GetHopDiagnostics()[1].GetReplySynack())

	tr := entry.GetTrace()
	require.Equal(t, "target.example.com", tr.GetTarget())
	require.Equal(t, []byte{192, 0, 2, 10}, tr.GetResolvedAddress())
	require.Equal(t, edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP, tr.GetProtocol())
	require.Equal(t, uint32(4), tr.GetIpVersion())
	require.Equal(t, uint32(64), tr.GetPacketSize())
	require.True(t, tr.GetTargetReached())
	require.Equal(t, uint32(2), tr.GetTotalHops())
	require.Len(t, tr.GetHops(), 2)
}

func TestMtrGrantsFourWayCutoffNoDoubleCounting(t *testing.T) {
	cases := []struct {
		name               string
		metricsGrant       bool
		traceGrant         bool
		wantSpoolTraces    int
		wantSpoolMetrics   int
		wantGatewayResults int
		wantGatewayMetrics int
	}{
		{
			name:               "neither grant held uses StreamStatus for both",
			metricsGrant:       false,
			traceGrant:         false,
			wantSpoolTraces:    0,
			wantSpoolMetrics:   0,
			wantGatewayResults: 1,
			wantGatewayMetrics: 1,
		},
		{
			name:               "only metrics grant held spools scalar metrics and streams traces",
			metricsGrant:       true,
			traceGrant:         false,
			wantSpoolTraces:    0,
			wantSpoolMetrics:   1,
			wantGatewayResults: 1,
			wantGatewayMetrics: 0,
		},
		{
			name:               "only trace grant held spools traces and streams scalar metrics",
			metricsGrant:       false,
			traceGrant:         true,
			wantSpoolTraces:    1,
			wantSpoolMetrics:   0,
			wantGatewayResults: 0,
			wantGatewayMetrics: 1,
		},
		{
			name:               "both grants held spools traces and scalar metrics with zero StreamStatus calls",
			metricsGrant:       true,
			traceGrant:         true,
			wantSpoolTraces:    1,
			wantSpoolMetrics:   1,
			wantGatewayResults: 0,
			wantGatewayMetrics: 0,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sp := openTestEdgeSpool(t)
			loop, gw, _ := sysmonEdgeLoop(t, sp)
			loop.mtrState = newMtrCheckerState()
			loop.mtrState.runCheck = func(context.Context, *mtrCheckConfig) mtrCheckResult {
				return syntheticMtrCheckResult()
			}
			loop.mtrState.checks["mtr-check-01"] = &mtrCheckConfig{
				ID:       "mtr-check-01",
				Name:     "Synthetic Edge Core Link",
				Target:   "target.example.com",
				Enabled:  true,
				Interval: time.Hour,
			}

			var grants []*proto.EdgeOutputGrant
			if tc.metricsGrant {
				grants = append(grants, currentMetricsGrant(t))
			}
			if tc.traceGrant {
				grants = append(grants, currentScheduledMtrGrant(t))
			}
			loop.edgeOutputGrants.replace(sysmonEdgeAgentID, grants, time.Now())

			require.True(t, loop.pushMtrResults(context.Background()))

			traceBatches, metricBatches := spooledMtrAndMetricBatches(t, sp)
			require.Len(t, traceBatches, tc.wantSpoolTraces)
			require.Len(t, metricBatches, tc.wantSpoolMetrics)
			require.Equal(t, tc.wantGatewayResults, gw.statusesFrom("results"))
			require.Equal(t, tc.wantGatewayMetrics, gw.statusesFrom("mtr-metrics"))
		})
	}
}

func TestScheduledMtrRetryPreservesEventIDAndFallbackOnGrantRevocation(t *testing.T) {
	t.Run("retryable spool refusal preserves built event_id across retries", func(t *testing.T) {
		refusing := refusingEdgeSpool(t)
		loop, gw, _ := sysmonEdgeLoop(t, refusing)
		loop.mtrState = newMtrCheckerState()
		loop.mtrState.runCheck = func(context.Context, *mtrCheckConfig) mtrCheckResult {
			return syntheticMtrCheckResult()
		}
		loop.mtrState.checks["mtr-check-01"] = &mtrCheckConfig{
			ID:       "mtr-check-01",
			Name:     "Synthetic Edge Core Link",
			Target:   "target.example.com",
			Enabled:  true,
			Interval: time.Hour,
		}
		loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{
			currentMetricsGrant(t),
			currentScheduledMtrGrant(t),
		}, time.Now())

		require.False(t, loop.pushMtrResults(context.Background()))
		require.Zero(t, gw.statusesFrom("results"))
		require.Len(t, loop.mtrTraceEdge.pending, 1)
		require.Len(t, loop.mtrTraceEdge.pending[0].ready, 1)
		preservedEventID := append([]byte(nil), loop.mtrTraceEdge.pending[0].ready[0].record.GetEventId()...)

		// Switch to a roomy spool and push again with no new due checks; the queued trace
		// record is admitted with its original event_id.
		roomy := openTestEdgeSpool(t)
		loop.SetEdgeMetricsSpool(roomy)
		loop.mtrEdge.take()
		loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{
			currentScheduledMtrGrant(t),
		}, time.Now())

		require.True(t, loop.pushMtrResults(context.Background()))
		require.Empty(t, loop.mtrTraceEdge.pending)
		stored, err := roomy.Unresolved()
		require.NoError(t, err)
		require.Len(t, stored, 1)
		require.Equal(t, preservedEventID, stored[0].EventID)
	})

	t.Run("revoked trace grant falls back to StreamStatus for un-admitted trace", func(t *testing.T) {
		refusing := refusingEdgeSpool(t)
		loop, gw, _ := sysmonEdgeLoop(t, refusing)
		loop.mtrState = newMtrCheckerState()
		loop.mtrState.runCheck = func(context.Context, *mtrCheckConfig) mtrCheckResult {
			return syntheticMtrCheckResult()
		}
		loop.mtrState.checks["mtr-check-01"] = &mtrCheckConfig{
			ID:       "mtr-check-01",
			Name:     "Synthetic Edge Core Link",
			Target:   "target.example.com",
			Enabled:  true,
			Interval: time.Hour,
		}
		loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{
			currentMetricsGrant(t),
			currentScheduledMtrGrant(t),
		}, time.Now())

		require.False(t, loop.pushMtrResults(context.Background()))
		require.Len(t, loop.mtrTraceEdge.pending, 1)
		require.Zero(t, gw.statusesFrom("results"))

		// Revoke trace grant only: the un-admitted trace is taken back and sent via StreamStatus.
		loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{
			currentMetricsGrant(t),
		}, time.Now())
		require.True(t, loop.pushMtrResults(context.Background()))
		require.Empty(t, loop.mtrTraceEdge.pending)
		require.Equal(t, 1, gw.statusesFrom("results"))
	})
}
