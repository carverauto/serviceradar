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
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/rs/zerolog"
	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
)

// rowBoundedGrantSpec names the contract-specific claims of a synthetic
// row-bounded standing grant.
type rowBoundedGrantSpec struct {
	contractID       string
	contractVersion  uint32
	packageID        string
	digestSeed       string
	maxRows          uint32
	writeBytesPerRow uint64
}

// currentRowBoundedGrant returns a signed standing grant for sysmonEdgeAgentID
// that is valid now and caps projected rows and write bytes per spec.
func currentRowBoundedGrant(t *testing.T, spec rowBoundedGrantSpec) *proto.EdgeOutputGrant {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	now := time.Now()
	digest := sha256.Sum256([]byte(spec.digestSeed))
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("test-issuer"),
		IssuerKeyId:       []byte("test-issuer-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: now.Add(-time.Hour).UnixNano(),
		ExpiresAtUnixNano: now.Add(8 * 24 * time.Hour).UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId:             spec.contractID,
			ContractVersion:        spec.contractVersion,
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
			OriginPrincipalId:      []byte(sysmonEdgeAgentID),
			ProducerInstanceId:     []byte(sysmonEdgeAgentID),
			RouteProfile:           edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass:           edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:              spec.packageID,
			PackageSha256:          digest[:],
			CostModelVersion:       1,
			MaxProjectedRowCount:   spec.maxRows,
			MaxProjectedWriteBytes: uint64(spec.maxRows) * spec.writeBytesPerRow,
		}},
	}
	edgerecord.SignCapability(capability, key)
	encoded, err := gproto.Marshal(capability)
	require.NoError(t, err)
	return &proto.EdgeOutputGrant{
		ContractId:           spec.contractID,
		ContractVersion:      spec.contractVersion,
		ProductionCapability: encoded,
	}
}

func currentScheduledMtrGrant(t *testing.T) *proto.EdgeOutputGrant {
	t.Helper()
	return currentRowBoundedGrant(t, rowBoundedGrantSpec{
		contractID:       edgerecord.ScheduledMtrTraceContractID,
		contractVersion:  edgerecord.ScheduledMtrTraceContractVersion,
		packageID:        "serviceradar.agent.mtr",
		digestSeed:       "synthetic-scheduled-mtr-contract",
		maxRows:          edgerecord.ScheduledMtrTraceMaxRows,
		writeBytesPerRow: edgerecord.ScheduledMtrTraceProjectedRowBytes,
	})
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

func spooledMtrAndMetricBatches(t *testing.T, sp *RecordSpool) ([]*edgev1.AgentScheduledMtrTraceBatchV1, []*metricpb.MetricBatch) {
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

	hop1 := tr.GetHops()[0]
	require.Equal(t, uint32(64512), hop1.GetAsn())
	require.Equal(t, "Example Transit AS64512", hop1.GetAsnOrg())
	require.Equal(t, [][]byte{{198, 51, 100, 2}}, hop1.GetEcmpAddresses())
	require.Len(t, hop1.GetMplsLabels(), 1)
	require.Equal(t, uint32(24001), hop1.GetMplsLabels()[0].GetLabel())
	require.True(t, hop1.GetMplsLabels()[0].GetBottomOfStack())
	require.Equal(t, uint32(63), hop1.GetMplsLabels()[0].GetTtl())
	require.Equal(t, uint32(10), hop1.GetSent())
	require.Equal(t, uint32(10), hop1.GetReceived())
	hop2 := tr.GetHops()[1]
	require.Equal(t, uint32(64513), hop2.GetAsn())
	require.Equal(t, "Example Edge AS64513", hop2.GetAsnOrg())
	require.Equal(t, uint32(10), hop2.GetSent())
	require.Equal(t, uint32(9), hop2.GetReceived())
	require.InDelta(t, 10, hop2.GetLossPct(), 0.001)
}

// A collection's traces and scalar metrics are spooled together, so MTR checks
// run only while the agent holds both grants. With either grant missing no
// check runs, nothing is spooled or sent elsewhere, and the hold is counted.
func TestMtrChecksRunOnlyWithBothGrants(t *testing.T) {
	cases := []struct {
		name         string
		metricsGrant bool
		traceGrant   bool
	}{
		{name: "neither grant held", metricsGrant: false, traceGrant: false},
		{name: "only the metrics grant held", metricsGrant: true, traceGrant: false},
		{name: "only the trace grant held", metricsGrant: false, traceGrant: true},
		{name: "both grants held", metricsGrant: true, traceGrant: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			sp := openTestEdgeSpool(t)
			loop, _ := sysmonEdgeLoop(t, sp)
			loop.mtrState = newMtrCheckerState()
			runs := 0
			loop.mtrState.runCheck = func(context.Context, *mtrCheckConfig) mtrCheckResult {
				runs++
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
			installTestEdgeGrants(t, loop, sysmonEdgeAgentID, grants, time.Now())

			both := tc.metricsGrant && tc.traceGrant
			require.Equal(t, both, loop.pushMtrResults(context.Background()))

			traceBatches, metricBatches := spooledMtrAndMetricBatches(t, sp)
			if both {
				require.Equal(t, 1, runs)
				require.Len(t, traceBatches, 1)
				require.Len(t, metricBatches, 1)
				return
			}
			require.Zero(t, runs, "an MTR check ran without both grants")
			require.Empty(t, traceBatches)
			require.Empty(t, metricBatches)
			require.Equal(t, uint64(1), loop.server.edgeProducerDrops.grantHolds[edgeProducerMTRTraces].Load())
		})
	}
}

func TestScheduledMtrSpoolBackpressurePausesDueChecksAndPreservesEventIDs(t *testing.T) {
	refusing := refusingEdgeSpool(t)
	loop, _ := sysmonEdgeLoop(t, refusing)
	loop.mtrState = newMtrCheckerState()
	runs := 0
	loop.mtrState.runCheck = func(_ context.Context, cfg *mtrCheckConfig) mtrCheckResult {
		runs++
		res := syntheticMtrCheckResult()
		res.CheckID = cfg.ID
		res.CheckName = cfg.Name
		res.Target = cfg.Target
		return res
	}
	loop.mtrState.checks["mtr-check-01"] = &mtrCheckConfig{
		ID:       "mtr-check-01",
		Name:     "Synthetic Edge Core Link",
		Target:   "target.example.com",
		Enabled:  true,
		Interval: time.Nanosecond,
	}
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{
		currentMetricsGrant(t),
		currentScheduledMtrGrant(t),
	}, time.Now())

	require.False(t, loop.pushMtrResults(context.Background()))
	require.Equal(t, 1, runs)
	require.True(t, loop.mtrEdge.hasPending())
	require.Len(t, loop.mtrEdge.traces, 1)
	require.Len(t, loop.mtrEdge.metrics, 1)
	preservedTraceEventID := append([]byte(nil), loop.mtrEdge.traces[0].record.GetEventId()...)
	preservedMetricEventID := append([]byte(nil), loop.mtrEdge.metrics[0].record.GetEventId()...)

	// While the pending batch is un-admitted, due checks are paused and nothing is
	// dropped, even if grants lapse.
	delete(loop.mtrState.lastRun, "mtr-check-01")
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, nil, time.Now())
	require.False(t, loop.pushMtrResults(context.Background()))
	require.Equal(t, 1, runs, "collectDueMtrResults must pause while a pending batch is held")
	require.Zero(t, edgeDrops(loop, edgeProducerMTRTraces, edgeDropRetryBufferFull))
	require.Zero(t, edgeDrops(loop, edgeProducerMTR, edgeDropRetryBufferFull))

	// Switch to a roomy spool with no due checks; the held trace and metric records
	// are admitted with their original event_ids and due checks can resume on later ticks.
	loop.mtrState.lastRun["mtr-check-01"] = time.Now()
	loop.mtrState.checks["mtr-check-01"].Interval = time.Hour
	roomy := openTestEdgeSpool(t)
	loop.SetEdgeMetricsSpool(roomy)

	require.True(t, loop.pushMtrResults(context.Background()))
	require.False(t, loop.mtrEdge.hasPending())
	require.Equal(t, 1, runs)

	stored, err := roomy.Unresolved()
	require.NoError(t, err)
	require.Len(t, stored, 2)
	gotIDs := [][]byte{stored[0].EventID, stored[1].EventID}
	require.Contains(t, gotIDs, preservedTraceEventID)
	require.Contains(t, gotIDs, preservedMetricEventID)
}

func TestSweepGroupMtrEmitsScheduledTraceEdgeRecordsWithoutSweepLease(t *testing.T) {
	sp := openTestEdgeSpool(t)
	loop, _ := sysmonEdgeLoop(t, sp)
	loop.mtrState = newMtrCheckerState()
	loop.mtrState.runCheck = func(_ context.Context, cfg *mtrCheckConfig) mtrCheckResult {
		res := syntheticMtrCheckResult()
		res.CheckID = cfg.ID
		res.CheckName = cfg.Name
		res.Target = cfg.Target
		res.DeviceID = cfg.DeviceID
		res.SweepGroupID = cfg.SweepGroupID
		res.ExecutionSource = cfg.ExecutionSource
		res.Trace.Target = cfg.Target
		res.Trace.TargetIP = cfg.Target
		return res
	}
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{
		currentMetricsGrant(t),
		currentScheduledMtrGrant(t),
	}, time.Now())

	const groupID = "0197f8a0-0000-7000-8000-000000000042"
	configJSON := []byte(`{
		"sweep": {
			"config_hash": "hash-mtr-1",
			"groups": [
				{
					"id": "` + groupID + `",
					"sweep_group_id": "` + groupID + `",
					"name": "Synthetic Edge WAN Sweep",
					"targets": ["192.0.2.10", "198.51.100.0/30"],
					"modes": ["icmp", "mtr"],
					"schedule": {"type": "interval", "interval": "5m"},
					"settings": {"concurrency": 4, "timeout": "5s"},
					"device_targets": [
						{
							"network": "192.0.2.20/32",
							"sweep_modes": ["mtr"],
							"metadata": {"device_id": "sr:0197f8a0-0000-7000-8000-000000000020"}
						},
						{
							"network": "192.0.2.30/32",
							"sweep_modes": ["icmp"],
							"metadata": {"device_id": "sr:0197f8a0-0000-7000-8000-000000000030"}
						}
					]
				}
			]
		}
	}`)

	loop.applySweepConfig(context.Background(), configJSON)
	require.Len(t, loop.mtrState.sweepChecks, 4)

	require.True(t, loop.pushMtrResults(context.Background()))

	traceBatches, metricBatches := spooledMtrAndMetricBatches(t, sp)
	require.Len(t, traceBatches, 1)
	require.Len(t, metricBatches, 1)

	traces := traceBatches[0].GetTraces()
	require.Len(t, traces, 4)

	targets := make([]string, 0, len(traces))
	deviceByTarget := make(map[string]string, len(traces))
	for _, entry := range traces {
		require.Equal(t, groupID, uuidString(t, entry.GetSweepGroupId()))
		require.Equal(t, edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP, entry.GetExecutionSource())
		require.Equal(t, "Synthetic Edge WAN Sweep", entry.GetCheckName())
		targets = append(targets, entry.GetTrace().GetTarget())
		deviceByTarget[entry.GetTrace().GetTarget()] = entry.GetDeviceId()
	}
	require.Equal(t, []string{"192.0.2.10", "192.0.2.20", "198.51.100.1", "198.51.100.2"}, targets)
	require.Equal(t, "sr:0197f8a0-0000-7000-8000-000000000020", deviceByTarget["192.0.2.20"])
	require.Empty(t, deviceByTarget["192.0.2.10"])

	// Removing MTR from the sweep group clears the derived sweep MTR checks.
	noMtrJSON := []byte(`{
		"sweep": {
			"config_hash": "hash-mtr-2",
			"groups": [
				{
					"id": "` + groupID + `",
					"sweep_group_id": "` + groupID + `",
					"name": "Synthetic Edge WAN Sweep",
					"targets": ["192.0.2.10"],
					"modes": ["icmp"],
					"schedule": {"type": "interval", "interval": "5m"}
				}
			]
		}
	}`)
	loop.applySweepConfig(context.Background(), noMtrJSON)
	require.Empty(t, loop.mtrState.sweepChecks)
}

// The encoder must keep the check's values. The validator, not a rewrite, is
// what refuses a trace Tracer.Run cannot emit. Legacy failed starts have no
// trace object, so the stored event keeps IPv4 and a zero packet size.
func TestScheduledMtrEncoderPreservesIllegalStatsAndFailedStartDefaults(t *testing.T) {
	t.Run("check identity and execution source are copied", func(t *testing.T) {
		res := syntheticMtrCheckResult()
		res.CommandID = "cmd-synthetic-01"
		res.SweepGroupID = "0197f8a0-0000-7000-8000-0000000000aa"
		res.ExecutionID = "0197f8a0-0000-7000-8000-0000000000bb"
		res.ExecutionSource = "scheduled_sweep"
		entry := mustScheduledMtrEntry(t, res)
		require.Equal(t, "cmd-synthetic-01", entry.GetCommandId())
		require.Equal(t, "0197f8a0-0000-7000-8000-0000000000aa", uuidString(t, entry.GetSweepGroupId()))
		require.Equal(t, "0197f8a0-0000-7000-8000-0000000000bb", uuidString(t, entry.GetExecutionId()))
		require.Equal(t, edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP, entry.GetExecutionSource())
		require.NoError(t, edgerecord.ValidateScheduledMtrTraceBatch(mustScheduledMtrBatch(t, res)))
	})

	t.Run("bulk_job is not an ad hoc alias", func(t *testing.T) {
		bulk := syntheticMtrCheckResult()
		bulk.ExecutionSource = "bulk_job"
		require.Equal(t,
			edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
			mustScheduledMtrEntry(t, bulk).GetExecutionSource())

		adHoc := syntheticMtrCheckResult()
		adHoc.ExecutionSource = "ad_hoc"
		require.Equal(t,
			edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_AD_HOC,
			mustScheduledMtrEntry(t, adHoc).GetExecutionSource())
	})

	t.Run("a tracer that never starts keeps ipv4 and a zero packet size", func(t *testing.T) {
		res := mtrCheckResult{
			CheckID:   "mtr-check-fail",
			CheckName: "Failed Start",
			Target:    "2001:db8::1",
			Timestamp: 1_780_000_000_000_000_000,
			Error:     "tracer did not start",
		}
		entry := mustScheduledMtrEntry(t, res)
		tr := entry.GetTrace()
		require.Equal(t, uint32(4), tr.GetIpVersion())
		require.Equal(t, uint32(0), tr.GetPacketSize())
		require.Len(t, tr.GetResolvedAddress(), 16)
		require.Equal(t, "2001:db8::1", tr.GetTarget())
		require.False(t, tr.GetTargetReached())
		require.Empty(t, tr.GetHops())
		require.Equal(t, edgev1.MtrOutcome_MTR_OUTCOME_PROBE_FAILED, tr.GetOutcome())
		require.NoError(t, edgerecord.ValidateScheduledMtrTraceBatch(mustScheduledMtrBatch(t, res)))
	})

	t.Run("a missing timestamp is left at zero and rejected", func(t *testing.T) {
		res := mtrCheckResult{Target: "192.0.2.10", Error: "tracer did not start"}
		entry := mustScheduledMtrEntry(t, res)
		require.Equal(t, int64(0), entry.GetTrace().GetObservedAtUnixNano())
		err := edgerecord.ValidateScheduledMtrTraceBatch(mustScheduledMtrBatch(t, res))
		require.Error(t, err)
		require.ErrorIs(t, err, edgerecord.ErrScheduledMtrBatch)
	})

	t.Run("received greater than sent is stored and rejected", func(t *testing.T) {
		res := illegalHopResult(t, func(hop *mtr.HopSnapshot) { hop.Sent, hop.Received = 1, 5 })
		hop := mustScheduledMtrEntry(t, res).GetTrace().GetHops()[0]
		require.Equal(t, uint32(1), hop.GetSent())
		require.Equal(t, uint32(5), hop.GetReceived())
		require.ErrorIs(t, edgerecord.ValidateScheduledMtrTraceBatch(mustScheduledMtrBatch(t, res)), edgerecord.ErrMtrHop)
	})

	t.Run("hop number zero is stored and rejected", func(t *testing.T) {
		res := illegalHopResult(t, func(hop *mtr.HopSnapshot) { hop.HopNumber = 0 })
		require.Equal(t, uint32(0), mustScheduledMtrEntry(t, res).GetTrace().GetHops()[0].GetHopNumber())
		require.ErrorIs(t, edgerecord.ValidateScheduledMtrTraceBatch(mustScheduledMtrBatch(t, res)), edgerecord.ErrMtrHop)
	})

	t.Run("loss outside 0 to 100 is stored and rejected", func(t *testing.T) {
		res := illegalHopResult(t, func(hop *mtr.HopSnapshot) { hop.LossPct = 150 })
		require.InDelta(t, 150, mustScheduledMtrEntry(t, res).GetTrace().GetHops()[0].GetLossPct(), 0.001)
		require.ErrorIs(t, edgerecord.ValidateScheduledMtrTraceBatch(mustScheduledMtrBatch(t, res)), edgerecord.ErrMtrHop)
	})

	t.Run("target reached with no hops is stored and rejected", func(t *testing.T) {
		res := syntheticMtrCheckResult()
		res.Available = true
		res.Trace.TargetReached = true
		res.Trace.TotalHops = 0
		res.Trace.Hops = nil
		tr := mustScheduledMtrEntry(t, res).GetTrace()
		require.True(t, tr.GetTargetReached())
		require.Equal(t, uint32(0), tr.GetTotalHops())
		err := edgerecord.ValidateScheduledMtrTraceBatch(mustScheduledMtrBatch(t, res))
		require.Error(t, err)
		require.ErrorIs(t, err, edgerecord.ErrScheduledMtrBatch)
	})
}

func mustScheduledMtrBatch(t *testing.T, res mtrCheckResult) *edgev1.AgentScheduledMtrTraceBatchV1 {
	t.Helper()
	batch, err := buildScheduledMtrTraceBatch([]mtrCheckResult{res}, metricEnvelopeContext{})
	require.NoError(t, err)
	return batch
}

func mustScheduledMtrEntry(t *testing.T, res mtrCheckResult) *edgev1.AgentScheduledMtrTraceV1 {
	t.Helper()
	traces := mustScheduledMtrBatch(t, res).GetTraces()
	require.Len(t, traces, 1)
	return traces[0]
}

func illegalHopResult(t *testing.T, mutate func(*mtr.HopSnapshot)) mtrCheckResult {
	t.Helper()
	res := syntheticMtrCheckResult()
	res.Trace.TotalHops = 1
	res.Trace.ProbedHops = 1
	res.Trace.LastRespondingHop = 1
	hop := res.Trace.Hops[0]
	mutate(&hop)
	res.Trace.Hops = []mtr.HopSnapshot{hop}
	return res
}

func uuidString(t *testing.T, raw []byte) string {
	t.Helper()
	id, err := uuid.FromBytes(raw)
	require.NoError(t, err)
	return id.String()
}

func sweepMtrConfigJSON(groupID, targets, schedule string) []byte {
	return []byte(`{
		"sweep": {
			"config_hash": "hash-` + groupID + `",
			"groups": [
				{
					"id": "` + groupID + `",
					"sweep_group_id": "` + groupID + `",
					"name": "Synthetic Edge Sweep",
					"targets": ` + targets + `,
					"modes": ["icmp", "mtr"],
					"schedule": ` + schedule + `
				}
			]
		}
	}`)
}

func recordingSweepMtrLoop(t *testing.T, sp *RecordSpool) (*PushLoop, *[]string) {
	t.Helper()
	loop, _ := sysmonEdgeLoop(t, sp)
	loop.mtrState = newMtrCheckerState()
	var ran []string
	loop.mtrState.runCheck = func(_ context.Context, cfg *mtrCheckConfig) mtrCheckResult {
		ran = append(ran, cfg.ID)
		res := syntheticMtrCheckResult()
		res.CheckID = cfg.ID
		res.CheckName = cfg.Name
		res.Target = cfg.Target
		res.SweepGroupID = cfg.SweepGroupID
		res.ExecutionSource = cfg.ExecutionSource
		res.Trace.Target = cfg.Target
		res.Trace.TargetIP = cfg.Target
		return res
	}
	return loop, &ran
}

func TestSweepGroupMtrBoundsTargetsAndPerTickRuns(t *testing.T) {
	const groupID = "0197f8a0-0000-7000-8000-000000000052"
	interval5m := `{"type": "interval", "interval": "5m"}`

	t.Run("a network above the per-group cap derives no checks and is reported", func(t *testing.T) {
		loop, _ := recordingSweepMtrLoop(t, openTestEdgeSpool(t))
		var output bytes.Buffer
		loop.logger = warnCaptureLogger{Logger: loop.logger, output: zerolog.New(&output)}
		loop.applySweepConfig(context.Background(), sweepMtrConfigJSON(groupID, `["10.0.0.0/16", "192.0.2.10"]`, interval5m))
		require.Len(t, loop.mtrState.sweepChecks, 1)
		require.Contains(t, loop.mtrState.sweepChecks, "sweep:"+groupID+":192.0.2.10")

		warnings := sweepMtrGroupWarnings(t, &output, groupID)
		require.Len(t, warnings, 1)
		require.Equal(t, []any{"10.0.0.0/16"}, warnings[0]["skipped_networks"])
	})

	t.Run("each tick runs a bounded batch, least recently run first", func(t *testing.T) {
		sp := openTestEdgeSpool(t)
		loop, ran := recordingSweepMtrLoop(t, sp)
		installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{
			currentMetricsGrant(t), currentScheduledMtrGrant(t),
		}, time.Now())
		loop.applySweepConfig(context.Background(), sweepMtrConfigJSON(groupID, `["198.51.100.0/24"]`, interval5m))
		require.Len(t, loop.mtrState.sweepChecks, 254)

		require.True(t, loop.pushMtrResults(context.Background()))
		first := append([]string(nil), *ran...)
		require.Len(t, first, sweepMtrMaxChecksPerTick)

		*ran = nil
		require.True(t, loop.pushMtrResults(context.Background()))
		require.Len(t, *ran, sweepMtrMaxChecksPerTick)
		for _, id := range *ran {
			require.NotContains(t, first, id)
		}
	})

	t.Run("groups without an interval of at least five minutes derive no checks", func(t *testing.T) {
		for _, schedule := range []string{
			`{"type": "cron", "cron": "0 0 * * *"}`,
			`{"type": "interval", "interval": "1m"}`,
			`{"type": "interval", "interval": "bogus"}`,
		} {
			loop, _ := recordingSweepMtrLoop(t, openTestEdgeSpool(t))
			var output bytes.Buffer
			loop.logger = warnCaptureLogger{Logger: loop.logger, output: zerolog.New(&output)}
			loop.applySweepConfig(context.Background(), sweepMtrConfigJSON(groupID, `["192.0.2.10"]`, schedule))
			require.Empty(t, loop.mtrState.sweepChecks, schedule)
			require.Len(t, sweepMtrGroupWarnings(t, &output, groupID), 1, schedule)
		}
	})
}

func sweepMtrGroupWarnings(t *testing.T, output *bytes.Buffer, groupID string) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, line := range bytes.Split(bytes.TrimSpace(output.Bytes()), []byte("\n")) {
		if len(line) == 0 {
			continue
		}
		var event map[string]any
		require.NoError(t, json.Unmarshal(line, &event))
		if event["sweep_group"] == groupID {
			out = append(out, event)
		}
	}
	return out
}
