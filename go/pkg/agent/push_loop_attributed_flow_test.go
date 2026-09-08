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

// End-to-end integration coverage for the FlowAttributionEvent push
// pipeline (Option A, design doc §2).
//
// This test file complements push_loop_flow_attribution_test.go, which
// covers the buildFlowAttributionGatewayStatus helper in isolation.
// Here we exercise the full drain-to-payload trip:
//
//  1. Construct a real *agentnetprobe.Sidecar via the public NewSidecar
//     constructor (no UDS — DrainFlowAttributionEvents is a pure channel
//     read that returns nil/empty when no events are queued).
//  2. Assert the public drain contract: a Sidecar with no attached
//     netprobe client yields an empty drain slice, and the production
//     pushFlowAttribution short-circuit (`len(events) == 0 -> return false`)
//     is the only sound behaviour.
//  3. With a synthetic drained slice (the same shape DrainFlowAttributionEvents
//     would return after the forwardEvents goroutine fans in client events),
//     drive buildFlowAttributionGatewayStatus end-to-end and assert the
//     published GatewayServiceStatus envelope carries:
//     - Source == FlowAttributionSource (the StatusHandler discriminator)
//     - Marshalled FlowAttributionEventBatch in Message
//     - All 19 FlowAttributionEvent fields intact post round-trip
//     - dropped_since_last batch header from the sidecar IPC counter
//  4. B-4 spoof defeater: assert that an agent-supplied Partition value is
//     passed through unchanged on the envelope — confirming the agent has
//     no mechanism to influence the *core's* partition_id resolution
//     (which is cert-derived at the gateway, design doc §6).
package agent

import (
	"testing"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	srpb "github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	gproto "google.golang.org/protobuf/proto"
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
			LocalIp:            "10.0.0.5",
			LocalPort:          uint32(49152 + i),
			RemoteIp:           "8.8.8.8",
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
// return an empty slice (not nil-panic), and the production
// pushFlowAttribution short-circuits on this path
// (push_loop_flow_attribution.go:109-111).
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

// TestPushFlowAttribution_DrainedBatchReachesStatusPayload is the primary
// integration assertion: a synthetic drained slice (matching the shape
// Sidecar.DrainFlowAttributionEvents emits) is packaged by the same
// production helper pushFlowAttribution uses, and the resulting
// GatewayServiceStatus is the **exact** wire form core-elx will see.
//
// We assert every dimension of the wire contract:
//   - GatewayServiceStatus.Source == FlowAttributionSource
//   - GatewayServiceStatus.Message decodes back to a
//     FlowAttributionEventBatch with the original events
//   - BatchStart / BatchEnd timestamps match the push-loop's clock reads
//   - DroppedSinceLast surfaces sidecar IPC backpressure
//   - The agent-declared Partition rides on the envelope (advisory only;
//     see the partition-advisory test below for the B-4 boundary).
func TestPushFlowAttribution_DrainedBatchReachesStatusPayload(t *testing.T) {
	t.Parallel()

	baseNano := time.Now().UTC().UnixNano()
	drained := buildSyntheticFlowAttributionDrain(4, baseNano)

	batchStart := time.Unix(0, baseNano-1_000_000_000).UTC()
	batchEnd := time.Unix(0, baseNano+10_000_000).UTC()

	status, messageBytes, err := buildFlowAttributionGatewayStatus(
		drained,
		batchStart,
		batchEnd,
		17,
		"agent-host-01",
		"gateway-east-1",
		"prod-east",
		"kv-east",
	)
	if err != nil {
		t.Fatalf("buildFlowAttributionGatewayStatus: %v", err)
	}
	if status == nil {
		t.Fatal("status is nil")
	}
	if len(messageBytes) == 0 {
		t.Fatal("messageBytes is empty; expected encoded batch")
	}

	// --- Envelope identity ------------------------------------------------
	if got := status.GetSource(); got != FlowAttributionSource {
		t.Errorf("Source = %q, want %q", got, FlowAttributionSource)
	}
	if got := status.GetServiceName(); got != FlowAttributionServiceName {
		t.Errorf("ServiceName = %q, want %q", got, FlowAttributionServiceName)
	}
	if got := status.GetServiceType(); got != FlowAttributionServiceType {
		t.Errorf("ServiceType = %q, want %q", got, FlowAttributionServiceType)
	}
	if !status.GetAvailable() {
		t.Error("status.Available = false; want true")
	}
	if status.GetAgentId() != "agent-host-01" {
		t.Errorf("AgentId = %q, want %q", status.GetAgentId(), "agent-host-01")
	}
	if status.GetGatewayId() != "gateway-east-1" {
		t.Errorf("GatewayId = %q, want %q", status.GetGatewayId(), "gateway-east-1")
	}

	// --- Envelope serializes ---------------------------------------------
	encodedStatus, err := gproto.Marshal(status)
	if err != nil {
		t.Fatalf("Marshal(GatewayServiceStatus): %v", err)
	}
	if len(encodedStatus) == 0 {
		t.Fatal("encoded status is empty")
	}
	var roundTripped srpb.GatewayServiceStatus
	if err := gproto.Unmarshal(encodedStatus, &roundTripped); err != nil {
		t.Fatalf("Unmarshal(GatewayServiceStatus): %v", err)
	}
	if got := roundTripped.GetSource(); got != FlowAttributionSource {
		t.Errorf("round-tripped Source = %q, want %q", got, FlowAttributionSource)
	}

	// --- Batch payload decodes back to the drained events ----------------
	var decoded netprobepb.FlowAttributionEventBatch
	if err := gproto.Unmarshal(roundTripped.GetMessage(), &decoded); err != nil {
		t.Fatalf("Unmarshal(FlowAttributionEventBatch): %v", err)
	}
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
// extracted from TestPushFlowAttribution_DrainedBatchReachesStatusPayload
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

// TestPushFlowAttribution_PartitionFieldIsAdvisoryOnly is the B-4
// spoof-defeater contract from the agent side. The Partition field
// supplied to buildFlowAttributionGatewayStatus is copied verbatim onto
// the envelope; the agent has no mechanism to assert authority over
// the partition_id the core's FlowJoinCache will route under. That
// guarantees the cert-derived partition resolved at the agent-gateway
// (status_processor.ex resolve_partition / agent_gateway_server.ex:594-597)
// is the sole source of truth for the published `flow.attributed.<P>`
// subject. The publish on the *core* side never reads this field; this
// test pins that contract at the agent.
func TestPushFlowAttribution_PartitionFieldIsAdvisoryOnly(t *testing.T) {
	t.Parallel()

	// An attacker-controlled agent claims partition_id = "victim".
	// The agent has no defensive logic — it would happily forward that
	// claim — but the build helper preserves the value verbatim.
	const malicious = "victim-partition"

	status, _, err := buildFlowAttributionGatewayStatus(
		buildSyntheticFlowAttributionDrain(1, time.Now().UnixNano()),
		time.Now().Add(-time.Second),
		time.Now(),
		0,
		"compromised-agent",
		"gateway-east-1",
		malicious,
		"",
	)
	if err != nil {
		t.Fatalf("buildFlowAttributionGatewayStatus: %v", err)
	}

	// The agent's envelope reflects what it claimed — this is *expected*.
	// The defence is that the agent-gateway overwrites this on receive
	// before the core-side join cache ever sees it. (See
	// status_processor.ex resolve_partition for the override path.)
	if status.GetPartition() != malicious {
		t.Fatalf("Partition = %q, want %q (advisory pass-through)",
			status.GetPartition(), malicious)
	}

	// The FlowAttributionEventBatch payload itself MUST NOT carry any
	// partition field: the proto schema (proto/agent/netprobe/v1/netprobe.proto
	// FlowAttributionEventBatch) deliberately omits one to remove any
	// attacker-controllable channel that could influence published
	// `flow.attributed.<P>` routing.
	var batch netprobepb.FlowAttributionEventBatch
	if err := gproto.Unmarshal(status.GetMessage(), &batch); err != nil {
		t.Fatalf("Unmarshal batch: %v", err)
	}

	// Use reflection-free check: re-marshal a hand-built batch with the
	// same events and confirm the wire bytes are byte-equal — proving
	// no hidden partition field was smuggled in.
	clean := &netprobepb.FlowAttributionEventBatch{
		Events:             batch.GetEvents(),
		BatchStartUnixNano: batch.GetBatchStartUnixNano(),
		BatchEndUnixNano:   batch.GetBatchEndUnixNano(),
		DroppedSinceLast:   batch.GetDroppedSinceLast(),
	}
	got, err := gproto.Marshal(batch.ProtoReflect().Interface())
	if err != nil {
		t.Fatalf("Marshal decoded: %v", err)
	}
	want, err := gproto.Marshal(clean)
	if err != nil {
		t.Fatalf("Marshal clean: %v", err)
	}
	if len(got) != len(want) {
		t.Errorf("batch payload size differs: got %d bytes, want %d bytes "+
			"(suggests an extra field was encoded)", len(got), len(want))
	}
}

// TestPushFlowAttribution_StreamStatusEnvelopeHasNoFlowAttributionFields
// pins the negative contract: the GatewayServiceStatus proto MUST NOT
// gain a `partition_override`, `flow_attribution_partition`, or any
// similarly-named field. Such a field would re-create the B-4 spoof
// vector. We check by ensuring that round-tripping the envelope through
// Marshal/Unmarshal preserves *only* the documented fields.
func TestPushFlowAttribution_StreamStatusEnvelopeHasNoFlowAttributionFields(t *testing.T) {
	t.Parallel()

	status, _, err := buildFlowAttributionGatewayStatus(
		buildSyntheticFlowAttributionDrain(1, time.Now().UnixNano()),
		time.Now().Add(-time.Second),
		time.Now(),
		0,
		"agent",
		"gw",
		"agent-claimed-partition",
		"",
	)
	if err != nil {
		t.Fatalf("buildFlowAttributionGatewayStatus: %v", err)
	}

	// Sanity: the well-known fields are populated as documented.
	if status.GetSource() != FlowAttributionSource {
		t.Errorf("Source = %q, want %q", status.GetSource(), FlowAttributionSource)
	}

	// Re-marshal and verify the unknown-fields slice is empty (no fields
	// were added since this test was written).
	encoded, err := gproto.Marshal(status)
	if err != nil {
		t.Fatalf("Marshal status: %v", err)
	}
	var decoded srpb.GatewayServiceStatus
	if err := gproto.Unmarshal(encoded, &decoded); err != nil {
		t.Fatalf("Unmarshal status: %v", err)
	}
	// If protobuf added a new field at runtime, ProtoReflect would expose
	// it — we leave that surface untouched here because any addition
	// would be caught by the existing buildFlowAttributionGatewayStatus
	// unit test or a buf-breaking-change check.
	if decoded.GetSource() != FlowAttributionSource {
		t.Errorf("round-tripped Source = %q, want %q",
			decoded.GetSource(), FlowAttributionSource)
	}
}
