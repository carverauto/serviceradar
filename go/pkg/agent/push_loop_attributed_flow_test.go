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

// End-to-end coverage for the FlowAttributionEvent push pipeline (Option A):
//
//  1. A real *agentnetprobe.Sidecar with no attached netprobe client yields
//     an empty drain, so pushFlowAttribution has nothing to load.
//  2. A drained slice of the shape DrainFlowAttributionEvents emits is
//     spooled under the flow attribution grant, and the record's
//     FlowAttributionEventBatch carries every event field intact, the batch
//     window, and the sidecar's dropped_since_last count.
package agent

import (
	"testing"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

// buildSyntheticFlowAttributionDrain produces the slice shape that
// Sidecar.DrainFlowAttributionEvents emits after the sidecar's
// forwardEvents goroutine fans the netprobe client's FlowAttributionEvents
// channel into the bounded internal queue. Every event field defined in
// proto/agent/netprobe/v1/netprobe.proto is populated so a round-trip
// regression on any field shows up as a test failure.
func buildSyntheticFlowAttributionDrain(n int, baseNano int64) []*netprobepb.FlowAttributionEvent {
	out := make([]*netprobepb.FlowAttributionEvent, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, &netprobepb.FlowAttributionEvent{
			LocalIp:            "192.0.2.5",
			LocalPort:          uint32(49152 + i),
			RemoteIp:           "198.51.100.8",
			RemotePort:         uint32(443),
			TransportProtocol:  "tcp",
			Pid:                uint32(1000 + i),
			Tgid:               uint32(1000 + i),
			Uid:                1000,
			Gid:                1000,
			Comm:               "curl",
			RedactedCmdline:    []string{"curl", "[REDACTED]"},
			ContainerId:        "ctr-abcdef0123",
			ObservedAtUnixNano: baseNano + int64(i)*1_000_000,
			SocketAddress:      0xdeadbeef_00000000 + uint64(i),
			EventKind:          1,
			OldState:           2,
			NewState:           4,
			Source:             "ebpf",
			ExternalFlowId:     uint64(0xfeed0000 + i),
		})
	}
	return out
}

// TestSidecarDrainFlowAttribution_EmptyWhenUnattached pins the
// observable behaviour of Sidecar.DrainFlowAttributionEvents on a fresh
// Sidecar that has never had a netprobe client connect. The drain MUST
// return an empty slice (not nil-panic), so pushFlowAttribution loads no
// pending batch.
func TestSidecarDrainFlowAttribution_EmptyWhenUnattached(t *testing.T) {
	t.Parallel()

	sidecar := agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{})
	if sidecar == nil {
		t.Fatal("NewSidecar returned nil")
	}

	events := sidecar.DrainFlowAttributionEvents(1000)
	if events == nil {
		t.Fatal("DrainFlowAttributionEvents returned nil; want non-nil empty slice")
	}
	if got := len(events); got != 0 {
		t.Fatalf("DrainFlowAttributionEvents(1000) returned %d events, want 0 (no attached client)", got)
	}

	// The clamp behaviour for max <= 0 falls back to the internal default
	// — assert that path also yields empty.
	events = sidecar.DrainFlowAttributionEvents(0)
	if got := len(events); got != 0 {
		t.Fatalf("DrainFlowAttributionEvents(0) returned %d events, want 0", got)
	}
}

// TestPushFlowAttribution_DrainedBatchReachesEdgeRecord spools a synthetic
// drained slice under the flow attribution grant and decodes the record body:
// every event field, the batch window and dropped_since_last survive intact.
func TestPushFlowAttribution_DrainedBatchReachesEdgeRecord(t *testing.T) {
	baseNano := time.Now().UTC().UnixNano()
	drained := buildSyntheticFlowAttributionDrain(4, baseNano)
	batchStart := time.Unix(0, baseNano-1_000_000_000).UTC()
	batchEnd := time.Unix(0, baseNano+10_000_000).UTC()

	sp := openTestEdgeSpool(t)
	loop := &PushLoop{
		server: &Server{config: &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default", HostIP: "192.0.2.10"}},
		logger: logger.NewTestLogger(),
		flowAttributionDelivery: flowAttributionDeliveryQueue{pending: &flowAttributionPendingBatch{
			// Its own backing array: admission clears the spooled prefix.
			events:              append([]*netprobepb.FlowAttributionEvent(nil), drained...),
			batchStart:          batchStart,
			batchEnd:            batchEnd,
			cumulativeDropped:   17,
			dropped:             17,
			dropBaselinePending: true,
		}},
	}
	loop.SetEdgeMetricsSpool(sp)
	loop.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{currentFlowAttributionGrant(t)}, time.Now())

	if !loop.pushFlowAttribution() {
		t.Fatal("pushFlowAttribution under a grant spooled nothing")
	}

	_, batches := spooledFlowAttributionRecords(t, sp)
	if len(batches) != 1 {
		t.Fatalf("spooled %d batches, want 1", len(batches))
	}
	decoded := batches[0]
	if got, want := len(decoded.GetEvents()), len(drained); got != want {
		t.Fatalf("decoded event count = %d, want %d", got, want)
	}
	if got, want := decoded.GetBatchStartUnixNano(), batchStart.UnixNano(); got != want {
		t.Errorf("BatchStartUnixNano = %d, want %d", got, want)
	}
	if got, want := decoded.GetBatchEndUnixNano(), batchEnd.UnixNano(); got != want {
		t.Errorf("BatchEndUnixNano = %d, want %d", got, want)
	}
	if got := decoded.GetDroppedSinceLast(); got != 17 {
		t.Errorf("DroppedSinceLast = %d, want 17", got)
	}

	for i, want := range drained {
		assertFlowAttributionEventMatches(t, i, decoded.GetEvents()[i], want)
	}
}

// assertFlowAttributionEventMatches verifies a single decoded
// FlowAttributionEvent matches the synthetic one that was drained. It is
// extracted from TestPushFlowAttribution_DrainedBatchReachesEdgeRecord
// to keep that test's cyclomatic complexity manageable.
func assertFlowAttributionEventMatches(
	t *testing.T,
	i int,
	got, want *netprobepb.FlowAttributionEvent,
) {
	t.Helper()

	assertFlowAttributionFiveTuple(t, i, got, want)
	assertFlowAttributionIdentity(t, i, got, want)
	assertFlowAttributionProcessFields(t, i, got, want)
	assertFlowAttributionStateAndProvenance(t, i, got, want)
}

func assertFlowAttributionFiveTuple(
	t *testing.T,
	i int,
	got, want *netprobepb.FlowAttributionEvent,
) {
	t.Helper()

	if got.GetLocalIp() != want.GetLocalIp() ||
		got.GetLocalPort() != want.GetLocalPort() ||
		got.GetRemoteIp() != want.GetRemoteIp() ||
		got.GetRemotePort() != want.GetRemotePort() ||
		got.GetTransportProtocol() != want.GetTransportProtocol() {
		t.Errorf("event[%d] 5-tuple mismatch:\n got=%+v\nwant=%+v", i, got, want)
	}
}

func assertFlowAttributionIdentity(
	t *testing.T,
	i int,
	got, want *netprobepb.FlowAttributionEvent,
) {
	t.Helper()

	if got.GetPid() != want.GetPid() ||
		got.GetTgid() != want.GetTgid() ||
		got.GetUid() != want.GetUid() ||
		got.GetGid() != want.GetGid() {
		t.Errorf("event[%d] identity tuple mismatch: got=(%d,%d,%d,%d), want=(%d,%d,%d,%d)",
			i, got.GetPid(), got.GetTgid(), got.GetUid(), got.GetGid(),
			want.GetPid(), want.GetTgid(), want.GetUid(), want.GetGid())
	}
}

func assertFlowAttributionProcessFields(
	t *testing.T,
	i int,
	got, want *netprobepb.FlowAttributionEvent,
) {
	t.Helper()

	if got.GetComm() != want.GetComm() {
		t.Errorf("event[%d] comm = %q, want %q", i, got.GetComm(), want.GetComm())
	}
	if len(got.GetRedactedCmdline()) != len(want.GetRedactedCmdline()) {
		t.Errorf("event[%d] redacted_cmdline length = %d, want %d",
			i, len(got.GetRedactedCmdline()), len(want.GetRedactedCmdline()))
	}
	if got.GetContainerId() != want.GetContainerId() {
		t.Errorf("event[%d] container_id = %q, want %q",
			i, got.GetContainerId(), want.GetContainerId())
	}
	if got.GetObservedAtUnixNano() != want.GetObservedAtUnixNano() {
		t.Errorf("event[%d] observed_at = %d, want %d",
			i, got.GetObservedAtUnixNano(), want.GetObservedAtUnixNano())
	}
	if got.GetSocketAddress() != want.GetSocketAddress() {
		t.Errorf("event[%d] socket_address = %x, want %x",
			i, got.GetSocketAddress(), want.GetSocketAddress())
	}
}

func assertFlowAttributionStateAndProvenance(
	t *testing.T,
	i int,
	got, want *netprobepb.FlowAttributionEvent,
) {
	t.Helper()

	if got.GetEventKind() != want.GetEventKind() ||
		got.GetOldState() != want.GetOldState() ||
		got.GetNewState() != want.GetNewState() {
		t.Errorf("event[%d] state transition mismatch: got=(kind=%d,old=%d,new=%d), want=(kind=%d,old=%d,new=%d)",
			i, got.GetEventKind(), got.GetOldState(), got.GetNewState(),
			want.GetEventKind(), want.GetOldState(), want.GetNewState())
	}
	if got.GetSource() != want.GetSource() {
		t.Errorf("event[%d] source = %q, want %q", i, got.GetSource(), want.GetSource())
	}
	if got.GetExternalFlowId() != want.GetExternalFlowId() {
		t.Errorf("event[%d] external_flow_id = %d, want %d",
			i, got.GetExternalFlowId(), want.GetExternalFlowId())
	}
}
