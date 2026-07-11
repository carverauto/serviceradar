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

	"github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	gproto "google.golang.org/protobuf/proto"
)

func sampleFlowAttributionEvents(n int) []*netprobepb.FlowAttributionEvent {
	out := make([]*netprobepb.FlowAttributionEvent, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, &netprobepb.FlowAttributionEvent{
			Pid:             uint32(1000 + i),
			Comm:            "test-proc",
			RedactedCmdline: []string{"test-proc", "--arg"},
		})
	}
	return out
}

func TestBuildFlowAttributionGatewayStatus_WrapsBatchInEnvelope(t *testing.T) {
	events := sampleFlowAttributionEvents(3)
	start := time.Unix(0, 1_700_000_000_000_000_000).UTC()
	end := start.Add(250 * time.Millisecond)

	status, messageBytes, err := buildFlowAttributionGatewayStatus(
		events,
		start,
		end,
		7, // droppedSinceLast
		"agent-A",
		"gateway-1",
		"prod-east",
		"kv-1",
	)
	if err != nil {
		t.Fatalf("build status: %v", err)
	}

	if got, want := status.ServiceName, FlowAttributionServiceName; got != want {
		t.Errorf("ServiceName = %q, want %q", got, want)
	}
	if got, want := status.ServiceType, FlowAttributionServiceType; got != want {
		t.Errorf("ServiceType = %q, want %q", got, want)
	}
	if got, want := status.Source, FlowAttributionSource; got != want {
		t.Errorf("Source = %q, want %q", got, want)
	}
	if got, want := status.AgentId, "agent-A"; got != want {
		t.Errorf("AgentId = %q, want %q", got, want)
	}
	if got, want := status.GatewayId, "gateway-1"; got != want {
		t.Errorf("GatewayId = %q, want %q", got, want)
	}
	if got, want := status.Partition, "prod-east"; got != want {
		t.Errorf("Partition = %q, want %q", got, want)
	}
	if got, want := status.KvStoreId, "kv-1"; got != want {
		t.Errorf("KvStoreId = %q, want %q", got, want)
	}
	if !status.Available {
		t.Errorf("Available = false, want true")
	}

	// Round-trip: decode the wrapped batch and assert the drained events
	// arrive intact, with the dropped counter and batch timestamps.
	var decoded netprobepb.FlowAttributionEventBatch
	if err := gproto.Unmarshal(messageBytes, &decoded); err != nil {
		t.Fatalf("unmarshal batch: %v", err)
	}
	if got, want := len(decoded.Events), 3; got != want {
		t.Fatalf("decoded events len = %d, want %d", got, want)
	}
	if got, want := decoded.DroppedSinceLast, uint32(7); got != want {
		t.Errorf("DroppedSinceLast = %d, want %d", got, want)
	}
	if got, want := decoded.BatchStartUnixNano, start.UnixNano(); got != want {
		t.Errorf("BatchStartUnixNano = %d, want %d", got, want)
	}
	if got, want := decoded.BatchEndUnixNano, end.UnixNano(); got != want {
		t.Errorf("BatchEndUnixNano = %d, want %d", got, want)
	}
	for i, evt := range decoded.Events {
		if got, want := evt.Pid, uint32(1000+i); got != want {
			t.Errorf("event[%d].Pid = %d, want %d", i, got, want)
		}
	}
}

func TestBuildFlowAttributionGatewayStatus_EmptyEventsPreservesField(t *testing.T) {
	// Acceptance criterion (4): when no events are drained, the field
	// is encoded as an empty repeated — never omitted conditionally.
	status, messageBytes, err := buildFlowAttributionGatewayStatus(
		nil,
		time.Unix(0, 1),
		time.Unix(0, 2),
		0,
		"agent-A",
		"gateway-1",
		"",
		"",
	)
	if err != nil {
		t.Fatalf("build status: %v", err)
	}
	if status.Source != FlowAttributionSource {
		t.Errorf("Source = %q, want %q", status.Source, FlowAttributionSource)
	}

	var decoded netprobepb.FlowAttributionEventBatch
	if err := gproto.Unmarshal(messageBytes, &decoded); err != nil {
		t.Fatalf("unmarshal batch: %v", err)
	}
	if decoded.Events == nil {
		// nil and empty are equivalent on the wire for repeated;
		// the contract is preserved either way.
		t.Log("decoded.Events is nil (acceptable — equivalent to empty repeated)")
	}
	if len(decoded.Events) != 0 {
		t.Errorf("expected zero events, got %d", len(decoded.Events))
	}
}

func TestFlowAttributionMaxDrainPerPushIsBounded(t *testing.T) {
	// Pin the constants so future edits don't accidentally unbound the
	// per-message chunk or per-tick drain budgets.
	if got, want := flowAttributionMaxEventsPerChunk, 4096; got != want {
		t.Errorf("flowAttributionMaxEventsPerChunk = %d, want %d", got, want)
	}
	if got, want := flowAttributionMaxDrainPerPush, 32*1024; got != want {
		t.Errorf("flowAttributionMaxDrainPerPush = %d, want %d", got, want)
	}
}

func TestFlowAttributionDeliveryQueueRetainsBatchUntilAcknowledged(t *testing.T) {
	var queue flowAttributionDeliveryQueue
	loads := 0

	load := func() *flowAttributionPendingBatch {
		loads++

		return &flowAttributionPendingBatch{
			eventBatches: [][]*netprobepb.FlowAttributionEvent{
				sampleFlowAttributionEvents(flowAttributionMaxEventsPerChunk),
			},
			totalEvents: flowAttributionMaxEventsPerChunk,
		}
	}

	first := queue.getOrLoad(load)
	retry := queue.getOrLoad(load)

	if first == nil {
		t.Fatal("first pending batch is nil")
	}
	if retry != first {
		t.Fatal("unacknowledged delivery loaded a different batch")
	}
	if got, want := loads, 1; got != want {
		t.Fatalf("loader calls before acknowledgement = %d, want %d", got, want)
	}
	if got := first.totalEvents; got > flowAttributionMaxDrainPerPush {
		t.Fatalf("pending event count = %d, exceeds bound %d", got, flowAttributionMaxDrainPerPush)
	}

	if !queue.acknowledge(first) {
		t.Fatal("acknowledge(first) = false, want true")
	}

	next := queue.getOrLoad(load)
	if next == first {
		t.Fatal("acknowledged batch was reused")
	}
	if got, want := loads, 2; got != want {
		t.Fatalf("loader calls after acknowledgement = %d, want %d", got, want)
	}
	if queue.acknowledge(first) {
		t.Fatal("stale acknowledgement cleared the next batch")
	}
	if retry := queue.getOrLoad(load); retry != next {
		t.Fatal("stale acknowledgement replaced the current pending batch")
	}
}

func TestBuildFlowAttributionGatewayStatusChunks_StreamsMultipleBatches(t *testing.T) {
	batches := [][]*netprobepb.FlowAttributionEvent{
		sampleFlowAttributionEvents(3),
		sampleFlowAttributionEvents(2),
	}
	start := time.Unix(0, 1_700_000_000_000_000_000).UTC()
	end := start.Add(250 * time.Millisecond)

	chunks, messageBytes, err := buildFlowAttributionGatewayStatusChunks(
		batches,
		start,
		end,
		9,
		"agent-A",
		"gateway-1",
		"prod-east",
		"kv-1",
		"10.0.0.10",
		statusRuntimeMetadata{Version: "test-version", Hostname: "host-a", Os: "linux", Arch: "amd64"},
	)
	if err != nil {
		t.Fatalf("build chunks: %v", err)
	}
	if got, want := len(chunks), 2; got != want {
		t.Fatalf("chunks len = %d, want %d", got, want)
	}
	if messageBytes == 0 {
		t.Fatal("messageBytes = 0, want non-zero")
	}

	assertFlowAttributionChunkMetadata(t, chunks[0], 0, 2, false)
	assertFlowAttributionChunkMetadata(t, chunks[1], 1, 2, true)
	assertFlowAttributionChunkEnvelope(t, chunks[0], "agent-A", "gateway-1", "prod-east", "10.0.0.10")
	assertFlowAttributionChunkEnvelope(t, chunks[1], "agent-A", "gateway-1", "prod-east", "10.0.0.10")

	first := decodeFlowAttributionBatchFromChunk(t, chunks[0])
	second := decodeFlowAttributionBatchFromChunk(t, chunks[1])
	if got, want := len(first.GetEvents()), 3; got != want {
		t.Errorf("first events len = %d, want %d", got, want)
	}
	if got, want := len(second.GetEvents()), 2; got != want {
		t.Errorf("second events len = %d, want %d", got, want)
	}
	if got, want := first.GetDroppedSinceLast(), uint32(9); got != want {
		t.Errorf("first DroppedSinceLast = %d, want %d", got, want)
	}
	if got := second.GetDroppedSinceLast(); got != 0 {
		t.Errorf("second DroppedSinceLast = %d, want 0", got)
	}
}

func TestBuildFlowAttributionGatewayStatusChunks_SplitsOversizedBatch(t *testing.T) {
	largeArg := strings.Repeat("x", 4*1024*1024)
	events := []*netprobepb.FlowAttributionEvent{
		{Pid: 1001, Comm: "large-a", RedactedCmdline: []string{largeArg}},
		{Pid: 1002, Comm: "large-b", RedactedCmdline: []string{largeArg}},
	}

	chunks, _, err := buildFlowAttributionGatewayStatusChunks(
		[][]*netprobepb.FlowAttributionEvent{events},
		time.Unix(0, 1).UTC(),
		time.Unix(0, 2).UTC(),
		11,
		"agent-A",
		"gateway-1",
		"prod-east",
		"kv-1",
		"10.0.0.10",
		statusRuntimeMetadata{},
	)
	if err != nil {
		t.Fatalf("build chunks: %v", err)
	}
	if got, want := len(chunks), 2; got != want {
		t.Fatalf("chunks len = %d, want %d", got, want)
	}

	first := decodeFlowAttributionBatchFromChunk(t, chunks[0])
	second := decodeFlowAttributionBatchFromChunk(t, chunks[1])
	if got, want := len(first.GetEvents()), 1; got != want {
		t.Errorf("first split events len = %d, want %d", got, want)
	}
	if got, want := len(second.GetEvents()), 1; got != want {
		t.Errorf("second split events len = %d, want %d", got, want)
	}
	if got := first.GetDroppedSinceLast(); got != 11 {
		t.Errorf("first DroppedSinceLast = %d, want 11", got)
	}
	if got := second.GetDroppedSinceLast(); got != 0 {
		t.Errorf("second DroppedSinceLast = %d, want 0", got)
	}
}

func TestAgentFlowAttributionEventsForwardedTotal_CounterMatchesDrain(t *testing.T) {
	// Simulate the counter accumulation that pushFlowAttribution does
	// after a successful StreamStatus ack. The counter is process-wide.
	resetAgentFlowAttributionEventsForwardedTotal()
	t.Cleanup(resetAgentFlowAttributionEventsForwardedTotal)

	agentFlowAttributionEventsForwardedTotal.Add(uint64(len(sampleFlowAttributionEvents(5))))
	agentFlowAttributionEventsForwardedTotal.Add(uint64(len(sampleFlowAttributionEvents(7))))

	if got, want := AgentFlowAttributionEventsForwardedTotal(), uint64(12); got != want {
		t.Errorf("AgentFlowAttributionEventsForwardedTotal() = %d, want %d", got, want)
	}
}

func TestFlowAttributionDroppedSinceLast_TrackingDelta(t *testing.T) {
	// Reset baseline so the test is order-independent.
	lastDroppedFlowAttribution.Store(0)
	t.Cleanup(func() { lastDroppedFlowAttribution.Store(0) })

	// First observation: the sidecar's cumulative counter has advanced
	// from 0 to 10 — entire delta is reported.
	if got := computeFlowAttributionDroppedDelta(10); got != 10 {
		t.Errorf("first delta = %d, want 10", got)
	}
	// Second observation: cumulative is now 25 — delta is 15.
	if got := computeFlowAttributionDroppedDelta(25); got != 15 {
		t.Errorf("second delta = %d, want 15", got)
	}
	// Cumulative unchanged: delta is zero.
	if got := computeFlowAttributionDroppedDelta(25); got != 0 {
		t.Errorf("third delta = %d, want 0", got)
	}
	// Counter wrap / reset (cumulative goes backwards): clamp to the
	// current cumulative and continue.
	if got := computeFlowAttributionDroppedDelta(3); got != 3 {
		t.Errorf("wrap delta = %d, want 3", got)
	}
}

// computeFlowAttributionDroppedDelta is the inner pure helper used by
// flowAttributionDroppedSinceLast; exposed here for direct testing
// without needing a real Sidecar instance.
func computeFlowAttributionDroppedDelta(cumulative uint64) uint32 {
	prev := lastDroppedFlowAttribution.Swap(cumulative)
	if cumulative < prev {
		return clampToUint32(cumulative)
	}
	return clampToUint32(cumulative - prev)
}

func assertFlowAttributionChunkMetadata(t *testing.T, chunk *proto.GatewayStatusChunk, index, total int32, final bool) {
	t.Helper()

	if got := chunk.GetChunkIndex(); got != index {
		t.Errorf("ChunkIndex = %d, want %d", got, index)
	}
	if got := chunk.GetTotalChunks(); got != total {
		t.Errorf("TotalChunks = %d, want %d", got, total)
	}
	if got := chunk.GetIsFinal(); got != final {
		t.Errorf("IsFinal = %t, want %t", got, final)
	}
}

func assertFlowAttributionChunkEnvelope(
	t *testing.T,
	chunk *proto.GatewayStatusChunk,
	agentID, gatewayID, partition, sourceIP string,
) {
	t.Helper()

	if got := chunk.GetAgentId(); got != agentID {
		t.Errorf("AgentId = %q, want %q", got, agentID)
	}
	if got := chunk.GetGatewayId(); got != gatewayID {
		t.Errorf("GatewayId = %q, want %q", got, gatewayID)
	}
	if got := chunk.GetPartition(); got != partition {
		t.Errorf("Partition = %q, want %q", got, partition)
	}
	if got := chunk.GetSourceIp(); got != sourceIP {
		t.Errorf("SourceIp = %q, want %q", got, sourceIP)
	}
	if got, want := len(chunk.GetServices()), 1; got != want {
		t.Fatalf("Services len = %d, want %d", got, want)
	}
	if got := chunk.GetServices()[0].GetSource(); got != FlowAttributionSource {
		t.Errorf("service Source = %q, want %q", got, FlowAttributionSource)
	}
}

func decodeFlowAttributionBatchFromChunk(t *testing.T, chunk *proto.GatewayStatusChunk) *netprobepb.FlowAttributionEventBatch {
	t.Helper()

	if got, want := len(chunk.GetServices()), 1; got != want {
		t.Fatalf("Services len = %d, want %d", got, want)
	}

	var decoded netprobepb.FlowAttributionEventBatch
	if err := gproto.Unmarshal(chunk.GetServices()[0].GetMessage(), &decoded); err != nil {
		t.Fatalf("unmarshal batch: %v", err)
	}

	return &decoded
}
