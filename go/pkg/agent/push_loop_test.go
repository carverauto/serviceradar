package agent

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

func TestMarshalJSONLimited(t *testing.T) {
	payload := map[string]string{"status": "ok"}

	data, err := marshalJSONLimited(payload, 1024)
	if err != nil {
		t.Fatalf("expected marshal to fit under limit: %v", err)
	}
	if string(data) != `{"status":"ok"}` {
		t.Fatalf("unexpected JSON payload: %s", data)
	}
}

func TestMarshalJSONLimitedRejectsOversizedPayload(t *testing.T) {
	payload := map[string]string{"status": strings.Repeat("x", 1024)}

	_, err := marshalJSONLimited(payload, 64)
	if !errors.Is(err, errJSONPayloadTooLarge) {
		t.Fatalf("expected payload limit error, got %v", err)
	}
}

func TestHashStatusMessageScrubsResponseTime(t *testing.T) {
	messageA := []byte(`{"state":"ok","response_time":123,"nested":{"response_time_ns":456,"value":1}}`)
	messageB := []byte(`{"nested":{"value":1,"response_time_ns":999},"response_time":999,"state":"ok"}`)

	hashA := hashStatusMessage(messageA)
	hashB := hashStatusMessage(messageB)

	if hashA == "" || hashB == "" {
		t.Fatalf("expected non-empty hashes, got %q and %q", hashA, hashB)
	}
	if hashA != hashB {
		t.Fatalf("expected hashes to match after scrubbing response_time fields, got %q and %q", hashA, hashB)
	}
}

func TestBuildStatusSignatureDetectsAvailabilityChange(t *testing.T) {
	message := []byte(`{"state":"ok"}`)

	statusesA := []*proto.GatewayServiceStatus{
		{
			ServiceName: "sweep",
			ServiceType: "sweep",
			Source:      "status",
			Available:   true,
			Message:     message,
		},
	}
	statusesB := []*proto.GatewayServiceStatus{
		{
			ServiceName: "sweep",
			ServiceType: "sweep",
			Source:      "status",
			Available:   false,
			Message:     message,
		},
	}

	signatureA := buildStatusSignature(statusesA)
	signatureB := buildStatusSignature(statusesB)

	if signatureA == signatureB {
		t.Fatalf("expected signatures to differ when availability changes")
	}
}

func TestBuildAgentCapabilityStatusResponseIncludesVisibilitySurfacesAndSidecars(t *testing.T) {
	sidecars := []*proto.SidecarStatus{
		{Name: "netprobe", State: "healthy", Pid: 1234, RestartCount: 1},
	}

	resp := buildAgentCapabilityStatusResponse(
		[]string{capabilityHostNetworkVisibility, capabilityHostNetworkVisibilityFingerprintEnabled},
		sidecars,
	)

	if !resp.GetAvailable() {
		t.Fatal("agent capability status should be available")
	}
	if got := resp.GetSidecars(); len(got) != 1 || got[0].GetName() != "netprobe" {
		t.Fatalf("sidecars = %#v, want netprobe status", got)
	}

	var payload agentCapabilityStatusPayload
	if err := json.Unmarshal(resp.GetMessage(), &payload); err != nil {
		t.Fatalf("failed to decode capability payload: %v", err)
	}

	if payload.HostNetworkVisibility.Fingerprint != "enabled" {
		t.Fatalf("fingerprint = %q, want enabled", payload.HostNetworkVisibility.Fingerprint)
	}
	if payload.HostNetworkVisibility.DPI != "unavailable" ||
		payload.HostNetworkVisibility.FlowAttribution != "unavailable" ||
		payload.HostNetworkVisibility.ProcessSnapshot != "unavailable" {
		t.Fatalf("unexpected unavailable surfaces: %#v", payload.HostNetworkVisibility)
	}
	if len(payload.Sidecars) != 1 || payload.Sidecars[0].GetName() != "netprobe" {
		t.Fatalf("payload sidecars = %#v, want netprobe status", payload.Sidecars)
	}
}

func TestBuildAgentCapabilityStatusResponseMarksFingerprintUnavailable(t *testing.T) {
	resp := buildAgentCapabilityStatusResponse(
		[]string{capabilityHostNetworkVisibility, capabilityHostNetworkVisibilityFingerprintUnavailable},
		[]*proto.SidecarStatus{{Name: "netprobe", State: "circuit_open"}},
	)

	var payload agentCapabilityStatusPayload
	if err := json.Unmarshal(resp.GetMessage(), &payload); err != nil {
		t.Fatalf("failed to decode capability payload: %v", err)
	}

	if payload.HostNetworkVisibility.Fingerprint != "unavailable" {
		t.Fatalf("fingerprint = %q, want unavailable", payload.HostNetworkVisibility.Fingerprint)
	}
	if containsCapability(payload.Capabilities, capabilityHostNetworkVisibilityFingerprintEnabled) {
		t.Fatalf("capabilities unexpectedly advertised enabled fingerprint: %#v", payload.Capabilities)
	}
}

func TestBuildAgentCapabilityGatewayStatusUsesSidecarProvider(t *testing.T) {
	pl := NewPushLoop(
		&Server{
			config: &ServerConfig{AgentID: "agent-1", Partition: "default"},
			sidecarStatus: fakeSidecarStatusProvider{
				statuses: []sidecar.Status{{Name: "netprobe", State: sidecar.StateHealthy, PID: 4321}},
			},
		},
		nil,
		30*time.Second,
		logger.NewTestLogger(),
	)

	status := pl.buildAgentCapabilityGatewayStatus(pl.server.config, pl.server.sidecarStatus)
	if status == nil {
		t.Fatal("expected agent capability gateway status")
	}
	if status.GetServiceName() != agentCapabilityServiceName {
		t.Fatalf("service_name = %q, want %q", status.GetServiceName(), agentCapabilityServiceName)
	}
	if status.GetAgentId() != "agent-1" {
		t.Fatalf("agent_id = %q, want agent-1", status.GetAgentId())
	}

	var payload agentCapabilityStatusPayload
	if err := json.Unmarshal(status.GetMessage(), &payload); err != nil {
		t.Fatalf("failed to decode capability payload: %v", err)
	}
	if len(payload.Sidecars) != 1 || payload.Sidecars[0].GetName() != "netprobe" {
		t.Fatalf("payload sidecars = %#v, want netprobe status", payload.Sidecars)
	}
	if payload.HostNetworkVisibility.Fingerprint != "enabled" {
		t.Fatalf("fingerprint = %q, want enabled", payload.HostNetworkVisibility.Fingerprint)
	}
	if !containsCapability(payload.Capabilities, capabilityHostNetworkVisibilityFingerprintEnabled) {
		t.Fatalf("capabilities missing enabled fingerprint: %#v", payload.Capabilities)
	}
}

func TestEvaluateStatusPushHeartbeat(t *testing.T) {
	pl := NewPushLoop(nil, nil, 30*time.Second, logger.NewTestLogger())
	statuses := []*proto.GatewayServiceStatus{
		{
			ServiceName: "sweep",
			ServiceType: "sweep",
			Source:      "status",
			Available:   true,
			Message:     []byte(`{"state":"ok"}`),
		},
	}

	start := time.Now()
	initial := pl.evaluateStatusPush(statuses, start)
	if !initial.shouldPush || initial.reason != statusPushReasonInitial {
		t.Fatalf("expected initial push, got %+v", initial)
	}
	pl.recordStatusPush(initial.signature, start)

	beforeHeartbeat := pl.evaluateStatusPush(statuses, start.Add(pl.getStatusHeartbeatInterval()/2))
	if beforeHeartbeat.shouldPush {
		t.Fatalf("expected no push before heartbeat, got %+v", beforeHeartbeat)
	}

	afterHeartbeat := pl.evaluateStatusPush(statuses, start.Add(pl.getStatusHeartbeatInterval()+time.Second))
	if !afterHeartbeat.shouldPush || afterHeartbeat.reason != statusPushReasonHeartbeat {
		t.Fatalf("expected heartbeat push, got %+v", afterHeartbeat)
	}
}

type fakeSidecarStatusProvider struct {
	statuses []sidecar.Status
}

func (f fakeSidecarStatusProvider) Status() []sidecar.Status {
	return f.statuses
}

func TestBuildResultsStatusChunksForAgentIncludesRuntimeMetadata(t *testing.T) {
	metadata := currentRuntimeMetadata()
	chunks := buildResultsStatusChunksForAgent(
		[]*proto.ResultsChunk{
			{
				Data:        []byte(`{"ok":true}`),
				IsFinal:     true,
				ChunkIndex:  0,
				TotalChunks: 1,
				Timestamp:   time.Now().UnixNano(),
			},
		},
		"sysmon",
		"sysmon",
		"agent-1",
		"default",
		"gateway-1",
	)

	if len(chunks) != 1 {
		t.Fatalf("expected 1 chunk, got %d", len(chunks))
	}

	chunk := chunks[0]
	if chunk.Version != metadata.Version {
		t.Fatalf("expected version %q, got %q", metadata.Version, chunk.Version)
	}
	if chunk.Hostname != metadata.Hostname {
		t.Fatalf("expected hostname %q, got %q", metadata.Hostname, chunk.Hostname)
	}
	if chunk.Os != metadata.Os {
		t.Fatalf("expected os %q, got %q", metadata.Os, chunk.Os)
	}
	if chunk.Arch != metadata.Arch {
		t.Fatalf("expected arch %q, got %q", metadata.Arch, chunk.Arch)
	}
}

func TestBuildResultsStatusChunksForAgentFramesEachStatusStream(t *testing.T) {
	chunks := buildResultsStatusChunksForAgent(
		[]*proto.ResultsChunk{
			{
				Data:        []byte(`{"page":1}`),
				IsFinal:     false,
				ChunkIndex:  42,
				TotalChunks: 0,
				Timestamp:   time.Now().UnixNano(),
			},
			{
				Data:        []byte(`{"page":1,"part":2}`),
				IsFinal:     false,
				ChunkIndex:  43,
				TotalChunks: 0,
				Timestamp:   time.Now().UnixNano(),
			},
		},
		"sync",
		"sync",
		"agent-1",
		"default",
		"gateway-1",
	)

	if len(chunks) != 2 {
		t.Fatalf("expected 2 chunks, got %d", len(chunks))
	}

	for idx, chunk := range chunks {
		if chunk.ChunkIndex != int32(idx) {
			t.Fatalf("chunk %d index = %d", idx, chunk.ChunkIndex)
		}
		if chunk.TotalChunks != int32(len(chunks)) {
			t.Fatalf("chunk %d total_chunks = %d", idx, chunk.TotalChunks)
		}
		if chunk.IsFinal != (idx == len(chunks)-1) {
			t.Fatalf("chunk %d is_final = %t", idx, chunk.IsFinal)
		}
	}
}
