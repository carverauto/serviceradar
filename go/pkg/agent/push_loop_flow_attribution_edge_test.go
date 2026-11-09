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
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func currentFlowAttributionGrant(t *testing.T) *proto.EdgeOutputGrant {
	t.Helper()
	return currentRowBoundedGrant(t, rowBoundedGrantSpec{
		contractID:       edgerecord.FlowAttributionContractID,
		contractVersion:  edgerecord.FlowAttributionContractVersion,
		packageID:        "serviceradar.agent.flow_attribution",
		digestSeed:       "synthetic-flow-attribution-contract",
		maxRows:          edgerecord.FlowAttributionMaxRows,
		writeBytesPerRow: edgerecord.FlowAttributionWriteBytesPerRow,
	})
}

func spooledEdgeRecordsWithBody[T gproto.Message](
	t *testing.T,
	sp *RecordSpool,
	validate func(*edgev1.EdgeRecordV1) error,
	newBody func() T,
) ([]*edgev1.EdgeRecordV1, []T) {
	t.Helper()
	stored, err := sp.Unresolved()
	require.NoError(t, err)
	records := make([]*edgev1.EdgeRecordV1, 0, len(stored))
	bodies := make([]T, 0, len(stored))
	for _, s := range stored {
		record := &edgev1.EdgeRecordV1{}
		require.NoError(t, gproto.Unmarshal(s.Body, record))
		require.NoError(t, validate(record))
		require.Nil(t, record.GetSourceAuthorization())
		body := newBody()
		require.NoError(t, gproto.Unmarshal(recordBody(t, record), body))
		records = append(records, record)
		bodies = append(bodies, body)
	}
	return records, bodies
}

func spooledFlowAttributionRecords(t *testing.T, sp *RecordSpool) ([]*edgev1.EdgeRecordV1, []*netprobepb.FlowAttributionEventBatch) {
	t.Helper()
	return spooledEdgeRecordsWithBody(t, sp, edgerecord.ValidateFlowAttributionRecord, func() *netprobepb.FlowAttributionEventBatch {
		return &netprobepb.FlowAttributionEventBatch{}
	})
}

func TestFlowAttributionWithGrantSpoolsEdgeRecord(t *testing.T) {
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

	loop := &PushLoop{
		server:                  &Server{config: &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default", HostIP: "192.0.2.10"}},
		logger:                  logger.NewTestLogger(),
		flowAttributionDelivery: flowAttributionDeliveryQueue{pending: pending},
	}
	loop.SetEdgeMetricsSpool(sp)
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentFlowAttributionGrant(t)}, now)

	require.True(t, loop.pushFlowAttribution())
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

// Without a flow attribution grant nothing is sent anywhere: the drained batch
// stays pending, the wait is counted, and the batch spools once a grant is held.
func TestFlowAttributionWithoutGrantHoldsBatchUntilGrant(t *testing.T) {
	sp := openTestEdgeSpool(t)
	now := time.Now().UTC()
	pending := &flowAttributionPendingBatch{
		events:     sampleFlowAttributionEvents(2),
		batchStart: now.Add(-time.Second),
		batchEnd:   now,
	}

	loop := &PushLoop{
		server:                  &Server{config: &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default", HostIP: "192.0.2.10"}},
		logger:                  logger.NewTestLogger(),
		flowAttributionDelivery: flowAttributionDeliveryQueue{pending: pending},
	}
	loop.SetEdgeMetricsSpool(sp)

	require.False(t, loop.pushFlowAttribution())
	require.Same(t, pending, loop.flowAttributionDelivery.pending, "the held batch must not be dropped or replaced")
	records, _ := spooledFlowAttributionRecords(t, sp)
	require.Empty(t, records)
	var metrics strings.Builder
	require.NoError(t, loop.server.edgeProducerDrops.write(&metrics))
	require.Contains(t, metrics.String(), `agent_edge_record_grant_holds_total{producer="flow_attribution"} 1`)

	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentFlowAttributionGrant(t)}, now)
	require.True(t, loop.pushFlowAttribution())
	require.Nil(t, loop.flowAttributionDelivery.pending)
	records, batches := spooledFlowAttributionRecords(t, sp)
	require.Len(t, records, 1)
	require.Len(t, batches[0].GetEvents(), 2)
}

func TestFlowAttributionRetryableSpoolRefusalRetainsBuiltEventIDAcrossGrantWithdrawal(t *testing.T) {
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
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentFlowAttributionGrant(t)}, now)

	require.False(t, loop.pushFlowAttribution())
	require.NotNil(t, loop.flowAttributionDelivery.pending)
	require.Zero(t, loop.flowAttributionDelivery.droppedAcked.Load())
	require.NotNil(t, loop.flowAttributionDelivery.edgePending)
	cachedEventID := append([]byte(nil), loop.flowAttributionDelivery.edgePending.built.record.GetEventId()...)
	require.Len(t, cachedEventID, 16)

	// A grant withdrawn while the record waits keeps the built record and its
	// batch; nothing is sent elsewhere.
	roomy := openTestEdgeSpool(t)
	loop.SetEdgeMetricsSpool(roomy)
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, nil, now)
	require.False(t, loop.pushFlowAttribution())
	require.NotNil(t, loop.flowAttributionDelivery.edgePending)
	require.NotNil(t, loop.flowAttributionDelivery.pending)

	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentFlowAttributionGrant(t)}, now)
	require.True(t, loop.pushFlowAttribution())
	require.Nil(t, loop.flowAttributionDelivery.pending)
	require.Nil(t, loop.flowAttributionDelivery.edgePending)
	require.Equal(t, uint64(7), loop.flowAttributionDelivery.droppedAcked.Load())

	records, _ := spooledFlowAttributionRecords(t, roomy)
	require.Len(t, records, 1)
	require.Equal(t, cachedEventID, records[0].GetEventId(), "retryable spool refusal must retry the exact same event_id")
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
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentFlowAttributionGrant(t)}, now)

	require.True(t, loop.pushFlowAttribution())
	require.Equal(t, uint64(1), loop.server.deliveryTelemetry.flowAttributionQuarantined.Load())
	poisonItems, _ := loop.server.deliveryTelemetry.poisonDropTotals(poisonReasonPayloadTooLarge)
	require.Equal(t, uint64(1), poisonItems)
	require.Equal(t, uint64(1), loop.server.deliveryTelemetry.flowAttributionForwarded.Load())

	var dropMetrics strings.Builder
	require.NoError(t, loop.server.edgeProducerDrops.write(&dropMetrics))
	require.Contains(t, dropMetrics.String(), `agent_edge_record_dropped_samples_total{producer="flow_attribution",reason="invalid_record"} 1`)

	_, batches := spooledFlowAttributionRecords(t, sp)
	require.Len(t, batches, 1)
	require.Len(t, batches[0].GetEvents(), 1)
	require.Equal(t, uint32(9001), batches[0].GetEvents()[0].GetPid())
}
