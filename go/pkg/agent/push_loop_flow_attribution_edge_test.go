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
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func flowAttributionGrant(t *testing.T, agentID string, notBefore, expires time.Time, maxRows uint32) *proto.EdgeOutputGrant {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	digest := sha256.Sum256([]byte("synthetic-flow-attribution-contract"))
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("test-issuer"),
		IssuerKeyId:       []byte("test-issuer-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: notBefore.UnixNano(),
		ExpiresAtUnixNano: expires.UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId:             edgerecord.FlowAttributionContractID,
			ContractVersion:        edgerecord.FlowAttributionContractVersion,
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
			PackageId:              "serviceradar.agent.flow_attribution",
			PackageSha256:          digest[:],
			CostModelVersion:       1,
			MaxProjectedRowCount:   maxRows,
			MaxProjectedWriteBytes: uint64(maxRows) * edgerecord.FlowAttributionWriteBytesPerRow,
		}},
	}
	edgerecord.SignCapability(capability, key)
	encoded, err := gproto.Marshal(capability)
	require.NoError(t, err)
	return &proto.EdgeOutputGrant{
		ContractId:           edgerecord.FlowAttributionContractID,
		ContractVersion:      edgerecord.FlowAttributionContractVersion,
		ProductionCapability: encoded,
	}
}

func currentFlowAttributionGrant(t *testing.T) *proto.EdgeOutputGrant {
	t.Helper()
	now := time.Now()
	return flowAttributionGrant(t, sysmonEdgeAgentID, now.Add(-time.Hour), now.Add(8*24*time.Hour), edgerecord.FlowAttributionMaxRows)
}

func spooledFlowAttributionRecords(t *testing.T, sp *spool.Spool) ([]*edgev1.EdgeRecordV1, []*netprobepb.FlowAttributionEventBatch) {
	t.Helper()
	stored, err := sp.Unresolved()
	require.NoError(t, err)
	records := make([]*edgev1.EdgeRecordV1, 0, len(stored))
	batches := make([]*netprobepb.FlowAttributionEventBatch, 0, len(stored))
	for _, s := range stored {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, gproto.Unmarshal(s.Body, record))
		require.NoError(t, edgerecord.ValidateFlowAttributionRecord(record))
		require.Nil(t, record.GetSourceAuthorization())
		batch := &netprobepb.FlowAttributionEventBatch{}
		require.NoError(t, gproto.Unmarshal(recordBody(t, record), batch))
		records = append(records, record)
		batches = append(batches, batch)
	}
	return records, batches
}

func TestFlowAttributionWithGrantSpoolsEdgeRecordAndSkipsStreamStatus(t *testing.T) {
	sp := openTestEdgeSpool(t)
	now := time.Now().UTC()
	pending := &flowAttributionPendingBatch{
		events:              sampleFlowAttributionEvents(3),
		batchStart:          now.Add(-time.Second),
		batchEnd:            now,
		cumulativeDropped:   11,
		dropped:             4,
		dropBaselinePending: true,
	}

	streamCalls := 0
	loop := &PushLoop{
		server:                  &Server{config: &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default", HostIP: "192.0.2.10"}},
		logger:                  logger.NewTestLogger(),
		flowAttributionDelivery: flowAttributionDeliveryQueue{pending: pending},
		flowAttributionStreamStatus: func(_ context.Context, _ []*proto.GatewayStatusChunk) (*proto.GatewayStatusResponse, error) {
			streamCalls++
			return &proto.GatewayStatusResponse{Received: true}, nil
		},
	}
	loop.SetEdgeMetricsSpool(sp)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentFlowAttributionGrant(t)}, now)

	require.True(t, loop.pushFlowAttribution(context.Background()))
	require.Zero(t, streamCalls, "StreamStatus must not be called while the agent holds a flow attribution grant")
	require.Nil(t, loop.flowAttributionDelivery.pending)
	require.Equal(t, uint64(11), loop.flowAttributionDelivery.droppedAcked.Load())
	require.Equal(t, uint64(3), loop.server.deliveryTelemetry.flowAttributionForwarded.Load())

	records, batches := spooledFlowAttributionRecords(t, sp)
	require.Len(t, records, 1)
	require.Equal(t, uint32(3), records[0].GetProjectedRowCount())
	require.Equal(t, uint64(3)*edgerecord.FlowAttributionWriteBytesPerRow, records[0].GetProjectedWriteBytes())
	require.Len(t, batches[0].GetEvents(), 3)
	require.Equal(t, uint32(4), batches[0].GetDroppedSinceLast())
}

func TestFlowAttributionWithoutGrantUsesLegacyStreamStatus(t *testing.T) {
	sp := openTestEdgeSpool(t)
	now := time.Now().UTC()
	pending := &flowAttributionPendingBatch{
		events:     sampleFlowAttributionEvents(2),
		batchStart: now.Add(-time.Second),
		batchEnd:   now,
	}

	streamCalls := 0
	loop := &PushLoop{
		server:                  &Server{config: &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default", HostIP: "192.0.2.10"}},
		logger:                  logger.NewTestLogger(),
		flowAttributionDelivery: flowAttributionDeliveryQueue{pending: pending},
		flowAttributionStreamStatus: func(_ context.Context, _ []*proto.GatewayStatusChunk) (*proto.GatewayStatusResponse, error) {
			streamCalls++
			return &proto.GatewayStatusResponse{Received: true}, nil
		},
	}
	loop.SetEdgeMetricsSpool(sp)

	require.True(t, loop.pushFlowAttribution(context.Background()))
	require.Equal(t, 1, streamCalls)
	records, _ := spooledFlowAttributionRecords(t, sp)
	require.Empty(t, records)
}

func TestFlowAttributionRetryableSpoolRefusalRetainsBuiltEventIDAndFallbackOnGrantWithdrawal(t *testing.T) {
	now := time.Now().UTC()
	pending := &flowAttributionPendingBatch{
		events:              sampleFlowAttributionEvents(2),
		batchStart:          now.Add(-time.Second),
		batchEnd:            now,
		cumulativeDropped:   7,
		dropped:             7,
		dropBaselinePending: true,
	}

	loop := &PushLoop{
		server:                  &Server{config: &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default", HostIP: "192.0.2.10"}},
		logger:                  logger.NewTestLogger(),
		flowAttributionDelivery: flowAttributionDeliveryQueue{pending: pending},
	}
	loop.SetEdgeMetricsSpool(refusingEdgeSpool(t))
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentFlowAttributionGrant(t)}, now)

	require.False(t, loop.pushFlowAttribution(context.Background()))
	require.NotNil(t, loop.flowAttributionDelivery.pending)
	require.Zero(t, loop.flowAttributionDelivery.droppedAcked.Load())
	require.NotNil(t, loop.flowAttributionDelivery.edgePending)
	cachedEventID := append([]byte(nil), loop.flowAttributionDelivery.edgePending.built.record.GetEventId()...)
	require.Len(t, cachedEventID, 16)

	roomy := openTestEdgeSpool(t)
	loop.SetEdgeMetricsSpool(roomy)
	require.True(t, loop.pushFlowAttribution(context.Background()))
	require.Nil(t, loop.flowAttributionDelivery.pending)
	require.Nil(t, loop.flowAttributionDelivery.edgePending)
	require.Equal(t, uint64(7), loop.flowAttributionDelivery.droppedAcked.Load())

	records, _ := spooledFlowAttributionRecords(t, roomy)
	require.Len(t, records, 1)
	require.Equal(t, cachedEventID, records[0].GetEventId(), "retryable spool refusal must retry the exact same event_id")

	// Also verify fallback to legacy StreamStatus if grant is withdrawn before any record is appended.
	pendingFallback := &flowAttributionPendingBatch{
		events:     sampleFlowAttributionEvents(2),
		batchStart: now.Add(-time.Second),
		batchEnd:   now,
	}
	streamCalls := 0
	loop.flowAttributionDelivery.pending = pendingFallback
	loop.SetEdgeMetricsSpool(refusingEdgeSpool(t))
	loop.flowAttributionStreamStatus = func(_ context.Context, _ []*proto.GatewayStatusChunk) (*proto.GatewayStatusResponse, error) {
		streamCalls++
		return &proto.GatewayStatusResponse{Received: true}, nil
	}
	require.False(t, loop.pushFlowAttribution(context.Background()))
	require.NotNil(t, loop.flowAttributionDelivery.edgePending)

	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, nil, now)
	require.True(t, loop.pushFlowAttribution(context.Background()))
	require.Equal(t, 1, streamCalls)
	require.Nil(t, loop.flowAttributionDelivery.edgePending)
	require.Nil(t, loop.flowAttributionDelivery.pending)
}

func TestFlowAttributionSingleOversizedEventQuarantinedOnEdgePath(t *testing.T) {
	sp := openTestEdgeSpool(t)
	now := time.Now().UTC()
	oversized := &netprobepb.FlowAttributionEvent{
		Pid:             9000,
		Comm:            "oversized-proc",
		RedactedCmdline: []string{strings.Repeat("x", edgerecord.MaxRecordBytes+1024)},
	}
	normal := &netprobepb.FlowAttributionEvent{
		Pid:             9001,
		Comm:            "normal-proc",
		RedactedCmdline: []string{"normal-proc", "--ok"},
	}
	pending := &flowAttributionPendingBatch{
		events:     []*netprobepb.FlowAttributionEvent{oversized, normal},
		batchStart: now.Add(-time.Second),
		batchEnd:   now,
	}

	loop := &PushLoop{
		server:                  &Server{config: &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default", HostIP: "192.0.2.10"}},
		logger:                  logger.NewTestLogger(),
		flowAttributionDelivery: flowAttributionDeliveryQueue{pending: pending},
	}
	loop.SetEdgeMetricsSpool(sp)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentFlowAttributionGrant(t)}, now)

	require.True(t, loop.pushFlowAttribution(context.Background()))
	require.Equal(t, uint64(1), loop.server.deliveryTelemetry.flowAttributionQuarantined.Load())
	require.Equal(t, uint64(1), loop.server.deliveryTelemetry.flowAttributionForwarded.Load())

	var dropMetrics strings.Builder
	require.NoError(t, loop.server.edgeProducerDrops.write(&dropMetrics))
	require.Contains(t, dropMetrics.String(), `agent_edge_record_dropped_samples_total{producer="flow_attribution",reason="invalid_record"} 1`)

	_, batches := spooledFlowAttributionRecords(t, sp)
	require.Len(t, batches, 1)
	require.Len(t, batches[0].GetEvents(), 1)
	require.Equal(t, uint32(9001), batches[0].GetEvents()[0].GetPid())
}
