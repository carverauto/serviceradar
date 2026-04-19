package agent

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

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
