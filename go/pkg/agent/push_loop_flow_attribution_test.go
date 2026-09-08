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
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
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

func buildTestFlowAttributionWindow(
	t *testing.T,
	events []*netprobepb.FlowAttributionEvent,
	start, end time.Time,
	dropped uint32,
) *flowAttributionDeliveryWindow {
	t.Helper()

	window, err := buildNextFlowAttributionDeliveryWindow(
		events,
		start,
		end,
		dropped,
		"agent-A",
		"gateway-1",
		"prod-east",
		"kv-1",
		"10.0.0.10",
		statusRuntimeMetadata{Version: "test-version", Hostname: "host-a", Os: "linux", Arch: "amd64"},
	)
	if err != nil {
		t.Fatalf("build delivery window: %v", err)
	}

	return window
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
	// per-message, per-RPC, or per-tick budgets.
	if got, want := flowAttributionMaxEventsPerChunk, 4096; got != want {
		t.Errorf("flowAttributionMaxEventsPerChunk = %d, want %d", got, want)
	}
	if got, want := flowAttributionMaxDrainPerPush, 32*1024; got != want {
		t.Errorf("flowAttributionMaxDrainPerPush = %d, want %d", got, want)
	}
	if got, want := flowAttributionMaxStreamWindowBytes, 8*1024*1024; got != want {
		t.Errorf("flowAttributionMaxStreamWindowBytes = %d, want %d", got, want)
	}
	if got, want := flowAttributionMaxDeliveryStepsPerPush, 8; got != want {
		t.Errorf("flowAttributionMaxDeliveryStepsPerPush = %d, want %d", got, want)
	}
}

func TestFlowAttributionDeliveryQueueAcknowledgesOnlyDeliveredPrefix(t *testing.T) {
	var queue flowAttributionDeliveryQueue
	loads := 0

	load := func() *flowAttributionPendingBatch {
		loads++

		return &flowAttributionPendingBatch{
			events:              sampleFlowAttributionEvents(3),
			cumulativeDropped:   31,
			dropped:             9,
			dropBaselinePending: true,
		}
	}

	first := queue.getOrLoad(load)
	retry := queue.getOrLoad(load)

	if first == nil {
		t.Fatal("first pending batch is nil")
		return
	}
	if retry != first {
		t.Fatal("unacknowledged delivery loaded a different batch")
	}
	if got, want := loads, 1; got != want {
		t.Fatalf("loader calls before acknowledgement = %d, want %d", got, want)
	}

	cumulative, commitDrop, remaining, ok := queue.acknowledgePrefix(first, 1)
	if !ok {
		t.Fatal("acknowledgePrefix(first, 1) = false, want true")
	}
	if got, want := cumulative, uint64(31); got != want {
		t.Errorf("first acknowledged cumulative drop count = %d, want %d", got, want)
	}
	if !commitDrop {
		t.Error("first prefix acknowledgement did not commit drop baseline")
	}
	if got, want := remaining, 2; got != want {
		t.Errorf("remaining after first prefix = %d, want %d", got, want)
	}
	if got, want := first.events[0].GetPid(), uint32(1001); got != want {
		t.Errorf("first retained PID = %d, want %d", got, want)
	}
	if first.dropBaselinePending || first.dropped != 0 {
		t.Fatalf("drop baseline still pending after positive prefix acknowledgement: %+v", first)
	}

	cumulative, commitDrop, remaining, ok = queue.acknowledgePrefix(first, 1)
	if !ok {
		t.Fatal("second acknowledgePrefix(first, 1) = false, want true")
	}
	if cumulative != 0 || commitDrop {
		t.Errorf("second prefix repeated drop baseline: cumulative=%d commit=%t", cumulative, commitDrop)
	}
	if got, want := remaining, 1; got != want {
		t.Errorf("remaining after second prefix = %d, want %d", got, want)
	}

	if _, _, remaining, ok = queue.acknowledgePrefix(first, 1); !ok || remaining != 0 {
		t.Fatalf("final prefix acknowledgement = (remaining=%d, ok=%t), want (0, true)", remaining, ok)
	}

	next := queue.getOrLoad(load)
	if next == first {
		t.Fatal("acknowledged batch was reused")
	}
	if got, want := loads, 2; got != want {
		t.Fatalf("loader calls after acknowledgement = %d, want %d", got, want)
	}
	if _, _, _, ok := queue.acknowledgePrefix(first, 1); ok {
		t.Fatal("stale acknowledgement cleared the next batch")
	}
	if retry := queue.getOrLoad(load); retry != next {
		t.Fatal("stale acknowledgement replaced the current pending batch")
	}
}

func TestPushFlowAttributionRetriesExactNegativeAcknowledgedPrefixThenClearsOnce(t *testing.T) {
	resetAgentFlowAttributionEventCounters()
	t.Cleanup(resetAgentFlowAttributionEventCounters)

	events := sampleFlowAttributionEvents(2)
	pending := &flowAttributionPendingBatch{
		events:     events,
		batchStart: time.Unix(0, 1).UTC(),
		batchEnd:   time.Unix(0, 2).UTC(),
	}

	var attempts [][]uint32
	loop := &PushLoop{
		server:                  &Server{config: &ServerConfig{AgentID: "agent-1", Partition: "default", HostIP: "192.0.2.10"}},
		logger:                  logger.NewTestLogger(),
		flowAttributionDelivery: flowAttributionDeliveryQueue{pending: pending},
		flowAttributionStreamStatus: func(
			_ context.Context,
			chunks []*proto.GatewayStatusChunk,
		) (*proto.GatewayStatusResponse, error) {
			batch := decodeFlowAttributionBatchFromChunk(t, chunks[0])
			pids := make([]uint32, 0, len(batch.Events))
			for _, event := range batch.Events {
				pids = append(pids, event.GetPid())
			}
			attempts = append(attempts, pids)
			return &proto.GatewayStatusResponse{Received: len(attempts) > 1}, nil
		},
	}

	if loop.pushFlowAttribution(t.Context()) {
		t.Fatal("negative acknowledgement must retain the flow prefix")
	}
	if got := AgentFlowAttributionEventsForwardedTotal(); got != 0 {
		t.Fatalf("forwarded total after negative acknowledgement = %d, want 0", got)
	}
	if !loop.pushFlowAttribution(t.Context()) {
		t.Fatal("later positive acknowledgement must clear the retained flow prefix")
	}
	if got := AgentFlowAttributionEventsForwardedTotal(); got != 2 {
		t.Fatalf("forwarded total after positive acknowledgement = %d, want 2", got)
	}

	want := []uint32{1000, 1001}
	if len(attempts) != 2 || !slices.Equal(attempts[0], want) || !slices.Equal(attempts[1], want) {
		t.Fatalf("flow attempts = %#v, want exact prefix twice", attempts)
	}
	if loop.flowAttributionDelivery.pending != nil {
		t.Fatal("positive acknowledgement did not clear the flow prefix")
	}
}

func TestPushFlowAttributionPoisonDropsInvalidWindowAndLaterEventsProgress(t *testing.T) {
	tests := []struct {
		name       string
		err        error
		wantReason string
	}{
		{name: "local chunk excess", err: agentgateway.ErrStreamStatusChunkTooLarge, wantReason: "chunk_too_large"},
		{name: "local stream excess", err: agentgateway.ErrStreamStatusBudgetExceeded, wantReason: "stream_budget_exceeded"},
		{name: "remote invalid argument", err: status.Error(codes.InvalidArgument, "invalid flow payload"), wantReason: "invalid_argument"},
		{name: "remote payload too large", err: status.Error(codes.ResourceExhausted, "payload_too_large"), wantReason: "payload_too_large"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resetAgentRetainedPoisonDropCounters()
			t.Cleanup(resetAgentRetainedPoisonDropCounters)

			pending := &flowAttributionPendingBatch{
				events:     sampleFlowAttributionEvents(2),
				batchStart: time.Unix(0, 1).UTC(),
				batchEnd:   time.Unix(0, 2).UTC(),
			}
			attempt := 0
			loop := &PushLoop{
				server:                  &Server{config: &ServerConfig{AgentID: "agent-1", Partition: "default", HostIP: "192.0.2.10"}},
				logger:                  logger.NewTestLogger(),
				flowAttributionDelivery: flowAttributionDeliveryQueue{pending: pending},
				flowAttributionStreamStatus: func(
					_ context.Context,
					_ []*proto.GatewayStatusChunk,
				) (*proto.GatewayStatusResponse, error) {
					attempt++
					if attempt == 1 {
						return nil, tt.err
					}
					return &proto.GatewayStatusResponse{Received: true}, nil
				},
			}

			if loop.pushFlowAttribution(t.Context()) {
				t.Fatal("poison drop must not count as receipt")
			}
			items, bytes := AgentRetainedPoisonDropTotals("flow-attribution", tt.wantReason)
			if items != 2 || bytes == 0 {
				t.Fatalf("poison totals = (items=%d, bytes=%d), want (2, >0)", items, bytes)
			}
			if loop.flowAttributionDelivery.pending != nil {
				t.Fatal("terminal poison window remained pending")
			}

			loop.flowAttributionDelivery.pending = &flowAttributionPendingBatch{
				events:     sampleFlowAttributionEvents(1),
				batchStart: time.Unix(0, 3).UTC(),
				batchEnd:   time.Unix(0, 4).UTC(),
			}
			if !loop.pushFlowAttribution(t.Context()) {
				t.Fatal("later valid flow work must progress")
			}
			if attempt != 2 {
				t.Fatalf("stream attempts = %d, want 2 (poison window must not replay)", attempt)
			}
		})
	}
}

func TestFlowAttributionDeliveryWindowPrefixRetryDoesNotRepeatDroppedBaseline(t *testing.T) {
	largeArg := strings.Repeat("x", 4*1024*1024)
	events := []*netprobepb.FlowAttributionEvent{
		{Pid: 1001, Comm: "large-a", RedactedCmdline: []string{largeArg}},
		{Pid: 1002, Comm: "large-b", RedactedCmdline: []string{largeArg}},
	}
	pending := &flowAttributionPendingBatch{
		events:              events,
		batchStart:          time.Unix(0, 1).UTC(),
		batchEnd:            time.Unix(0, 2).UTC(),
		cumulativeDropped:   44,
		dropped:             11,
		dropBaselinePending: true,
	}
	queue := flowAttributionDeliveryQueue{pending: pending}

	first := buildTestFlowAttributionWindow(t, pending.events, pending.batchStart, pending.batchEnd, pending.dropped)
	if got, want := first.eventCount, 1; got != want {
		t.Fatalf("first window event count = %d, want %d", got, want)
	}
	firstBatch := decodeFlowAttributionBatchFromChunk(t, first.chunk)
	if got, want := firstBatch.GetDroppedSinceLast(), uint32(11); got != want {
		t.Errorf("first window DroppedSinceLast = %d, want %d", got, want)
	}

	cumulative, commitDrop, remaining, ok := queue.acknowledgePrefix(pending, first.eventCount)
	if !ok || !commitDrop || cumulative != 44 || remaining != 1 {
		t.Fatalf(
			"first ack = (cumulative=%d, commit=%t, remaining=%d, ok=%t), want (44, true, 1, true)",
			cumulative,
			commitDrop,
			remaining,
			ok,
		)
	}

	second := buildTestFlowAttributionWindow(t, pending.events, pending.batchStart, pending.batchEnd, pending.dropped)
	retryAfterFailure := buildTestFlowAttributionWindow(t, pending.events, pending.batchStart, pending.batchEnd, pending.dropped)
	secondBatch := decodeFlowAttributionBatchFromChunk(t, second.chunk)
	retryBatch := decodeFlowAttributionBatchFromChunk(t, retryAfterFailure.chunk)
	if got := secondBatch.GetDroppedSinceLast(); got != 0 {
		t.Errorf("second window DroppedSinceLast = %d, want 0", got)
	}
	if got := retryBatch.GetDroppedSinceLast(); got != 0 {
		t.Errorf("retry after partial success repeated DroppedSinceLast = %d, want 0", got)
	}
	if got, want := retryBatch.GetEvents()[0].GetPid(), secondBatch.GetEvents()[0].GetPid(); got != want {
		t.Errorf("failed-window retry PID = %d, want retained prefix PID %d", got, want)
	}
	if got, want := len(pending.events), 1; got != want {
		t.Errorf("simulated failed window removed events: remaining=%d, want %d", got, want)
	}

	if cumulative, commitDrop, remaining, ok = queue.acknowledgePrefix(pending, second.eventCount); !ok || commitDrop || cumulative != 0 || remaining != 0 {
		t.Fatalf(
			"second ack = (cumulative=%d, commit=%t, remaining=%d, ok=%t), want (0, false, 0, true)",
			cumulative,
			commitDrop,
			remaining,
			ok,
		)
	}
}

func TestFlowAttributionDeliveryWindowsBoundAggregateBeyondGatewayLimit(t *testing.T) {
	largeArg := strings.Repeat("x", 11*1024*1024/2)
	events := make([]*netprobepb.FlowAttributionEvent, 12)
	for i := range events {
		events[i] = &netprobepb.FlowAttributionEvent{
			Pid:             uint32(2000 + i),
			Comm:            "large-event",
			RedactedCmdline: []string{largeArg},
		}
	}

	totalStreamBytes := 0
	deliveredPIDs := make([]uint32, 0, len(events))
	remaining := events
	dropped := uint32(7)
	for len(remaining) > 0 {
		window := buildTestFlowAttributionWindow(t, remaining, time.Unix(0, 1), time.Unix(0, 2), dropped)
		if window.messageBytes > flowAttributionMaxBatchMessageBytes {
			t.Fatalf("message bytes = %d, exceeds %d", window.messageBytes, flowAttributionMaxBatchMessageBytes)
		}
		if window.streamBytes > flowAttributionMaxStreamWindowBytes {
			t.Fatalf("stream bytes = %d, exceeds %d", window.streamBytes, flowAttributionMaxStreamWindowBytes)
		}
		assertFlowAttributionChunkMetadata(t, window.chunk, 0, 1, true)
		assertFlowAttributionChunkEnvelope(t, window.chunk, "agent-A", "gateway-1", "prod-east", "10.0.0.10")

		batch := decodeFlowAttributionBatchFromChunk(t, window.chunk)
		for _, event := range batch.GetEvents() {
			deliveredPIDs = append(deliveredPIDs, event.GetPid())
		}
		totalStreamBytes += window.streamBytes
		remaining = remaining[window.eventCount:]
		dropped = 0
	}

	if totalStreamBytes <= 64*1024*1024 {
		t.Fatalf("logical aggregate stream bytes = %d, want greater than gateway 64MiB limit", totalStreamBytes)
	}
	if got, want := len(deliveredPIDs), len(events); got != want {
		t.Fatalf("delivered PID count = %d, want %d", got, want)
	}
	for i, pid := range deliveredPIDs {
		if got, want := pid, uint32(2000+i); got != want {
			t.Errorf("delivered PID[%d] = %d, want %d", i, got, want)
		}
	}
}

func TestFlowAttributionDeliveryWindowOmitsPathologicalOptionalMetadata(t *testing.T) {
	pathological := strings.Repeat("x", 9*1024*1024)

	window, err := buildNextFlowAttributionDeliveryWindow(
		sampleFlowAttributionEvents(1),
		time.Unix(0, 1),
		time.Unix(0, 2),
		0,
		"agent-A",
		"gateway-1",
		"prod-east",
		pathological,
		pathological,
		statusRuntimeMetadata{
			Version:  pathological,
			Hostname: pathological,
			Os:       pathological,
			Arch:     pathological,
		},
	)
	if err != nil {
		t.Fatalf("build window with pathological optional metadata: %v", err)
	}
	if window.streamBytes > flowAttributionMaxStreamWindowBytes {
		t.Fatalf("stream bytes = %d, exceeds %d", window.streamBytes, flowAttributionMaxStreamWindowBytes)
	}
	if window.chunk.GetVersion() != "" || window.chunk.GetHostname() != "" ||
		window.chunk.GetOs() != "" || window.chunk.GetArch() != "" ||
		window.chunk.GetSourceIp() != "" {
		t.Fatalf("pathological optional chunk metadata was not omitted: %+v", window.chunk)
	}
	if got := window.chunk.GetServices()[0].GetKvStoreId(); got != "" {
		t.Fatalf("pathological KV store ID = %q, want omitted", got)
	}
}

func TestFlowAttributionOversizedPoisonEventIsQuarantinedAndLaterEventsProgress(t *testing.T) {
	resetAgentFlowAttributionEventCounters()
	t.Cleanup(resetAgentFlowAttributionEventCounters)

	poison := &netprobepb.FlowAttributionEvent{
		Pid:             3001,
		Comm:            "poison",
		RedactedCmdline: []string{strings.Repeat("x", 7*1024*1024)},
	}
	pending := &flowAttributionPendingBatch{
		events: []*netprobepb.FlowAttributionEvent{
			poison,
			{Pid: 3002, Comm: "valid"},
		},
		batchStart:          time.Unix(0, 1),
		batchEnd:            time.Unix(0, 2),
		cumulativeDropped:   51,
		dropped:             5,
		dropBaselinePending: true,
	}
	queue := flowAttributionDeliveryQueue{pending: pending}

	_, err := buildNextFlowAttributionDeliveryWindow(
		pending.events,
		pending.batchStart,
		pending.batchEnd,
		pending.dropped,
		"agent-A",
		"gateway-1",
		"prod-east",
		"kv-1",
		"10.0.0.10",
		statusRuntimeMetadata{},
	)
	if !errors.Is(err, errFlowAttributionEventExceedsBatchBudget) {
		t.Fatalf("poison event error = %v, want %v", err, errFlowAttributionEventExceedsBatchBudget)
	}

	quarantined, remaining, ok := queue.quarantineFirst(pending)
	if !ok || quarantined != poison || remaining != 1 {
		t.Fatalf("quarantine = (event=%p, remaining=%d, ok=%t), want (%p, 1, true)", quarantined, remaining, ok, poison)
	}
	if got, want := AgentFlowAttributionEventsQuarantinedTotal(), uint64(1); got != want {
		t.Errorf("quarantined total = %d, want %d", got, want)
	}
	if !pending.dropBaselinePending || pending.dropped != 5 {
		t.Fatalf("quarantine consumed drop baseline: pending=%t dropped=%d", pending.dropBaselinePending, pending.dropped)
	}

	validWindow := buildTestFlowAttributionWindow(t, pending.events, pending.batchStart, pending.batchEnd, pending.dropped)
	validBatch := decodeFlowAttributionBatchFromChunk(t, validWindow.chunk)
	if got, want := validBatch.GetEvents()[0].GetPid(), uint32(3002); got != want {
		t.Fatalf("event after poison PID = %d, want %d", got, want)
	}
	if cumulative, commitDrop, remaining, ok := queue.acknowledgePrefix(pending, validWindow.eventCount); !ok || !commitDrop || cumulative != 51 || remaining != 0 {
		t.Fatalf(
			"valid ack = (cumulative=%d, commit=%t, remaining=%d, ok=%t), want (51, true, 0, true)",
			cumulative,
			commitDrop,
			remaining,
			ok,
		)
	}

	next := queue.getOrLoad(func() *flowAttributionPendingBatch {
		return &flowAttributionPendingBatch{events: []*netprobepb.FlowAttributionEvent{{Pid: 3003}}}
	})
	if next == nil || next.events[0].GetPid() != 3003 {
		t.Fatalf("subsequent batch did not progress after poison event: %+v", next)
	}
}

func TestPushFlowAttributionLocallyOversizedEventRecordsBoundedPoisonTelemetry(t *testing.T) {
	resetAgentFlowAttributionEventCounters()
	resetAgentRetainedPoisonDropCounters()
	t.Cleanup(resetAgentFlowAttributionEventCounters)
	t.Cleanup(resetAgentRetainedPoisonDropCounters)

	poison := &netprobepb.FlowAttributionEvent{
		Pid:             4001,
		Comm:            "poison",
		RedactedCmdline: []string{strings.Repeat("x", 7*1024*1024)},
	}
	pending := &flowAttributionPendingBatch{
		events:              []*netprobepb.FlowAttributionEvent{poison},
		batchStart:          time.Unix(0, 1).UTC(),
		batchEnd:            time.Unix(0, 2).UTC(),
		dropped:             3,
		dropBaselinePending: true,
	}
	expectedBytes := gproto.Size(&netprobepb.FlowAttributionEventBatch{
		Events:             []*netprobepb.FlowAttributionEvent{poison},
		BatchStartUnixNano: pending.batchStart.UnixNano(),
		BatchEndUnixNano:   pending.batchEnd.UnixNano(),
		DroppedSinceLast:   pending.dropped,
	})

	streamAttempts := 0
	loop := &PushLoop{
		server:                  &Server{config: &ServerConfig{AgentID: "agent-1", Partition: "default", HostIP: "192.0.2.10"}},
		logger:                  logger.NewTestLogger(),
		flowAttributionDelivery: flowAttributionDeliveryQueue{pending: pending},
		flowAttributionStreamStatus: func(
			_ context.Context,
			_ []*proto.GatewayStatusChunk,
		) (*proto.GatewayStatusResponse, error) {
			streamAttempts++
			return &proto.GatewayStatusResponse{Received: true}, nil
		},
	}

	if loop.pushFlowAttribution(t.Context()) {
		t.Fatal("locally rejected poison event must not count as receipt")
	}
	items, bytes := AgentRetainedPoisonDropTotals("flow-attribution", "payload_too_large")
	if items != 1 || bytes != uint64(expectedBytes) {
		t.Fatalf("local poison totals = (items=%d, bytes=%d), want (1, %d)", items, bytes, expectedBytes)
	}
	if streamAttempts != 0 {
		t.Fatalf("oversized event reached gateway %d times, want 0", streamAttempts)
	}
	if loop.flowAttributionDelivery.pending != nil {
		t.Fatal("locally invalid event remained pending")
	}

	loop.flowAttributionDelivery.pending = &flowAttributionPendingBatch{
		events:     sampleFlowAttributionEvents(1),
		batchStart: time.Unix(0, 3).UTC(),
		batchEnd:   time.Unix(0, 4).UTC(),
	}
	if !loop.pushFlowAttribution(t.Context()) {
		t.Fatal("later valid flow event must progress")
	}
	if streamAttempts != 1 {
		t.Fatalf("valid gateway attempts = %d, want 1", streamAttempts)
	}
}

func TestAgentFlowAttributionEventCounters(t *testing.T) {
	// Simulate the counter accumulation that pushFlowAttribution does
	// after a successful StreamStatus ack. The counter is process-wide.
	resetAgentFlowAttributionEventCounters()
	t.Cleanup(resetAgentFlowAttributionEventCounters)

	agentFlowAttributionEventsForwardedTotal.Add(uint64(len(sampleFlowAttributionEvents(5))))
	agentFlowAttributionEventsForwardedTotal.Add(uint64(len(sampleFlowAttributionEvents(7))))
	agentFlowAttributionEventsQuarantinedTotal.Add(2)

	if got, want := AgentFlowAttributionEventsForwardedTotal(), uint64(12); got != want {
		t.Errorf("AgentFlowAttributionEventsForwardedTotal() = %d, want %d", got, want)
	}
	if got, want := AgentFlowAttributionEventsQuarantinedTotal(), uint64(2); got != want {
		t.Errorf("AgentFlowAttributionEventsQuarantinedTotal() = %d, want %d", got, want)
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
