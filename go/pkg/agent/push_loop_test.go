package agent

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const (
	testCapabilityEnabled     = "enabled"
	testCapabilityUnavailable = "unavailable"
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
		{Name: "netprobe", State: "running", Pid: 1234, RestartCount: 1},
	}

	resp := buildAgentCapabilityStatusResponse(
		[]string{capabilityHostNetworkVisibility, capabilityHostNetworkVisibilityFingerprintEnabled},
		sidecars,
		true,
		agentnetprobe.CorpusRevisions{
			P0f:               "p0f-rev",
			Recog:             "recog-rev",
			Satori:            "satori-rev",
			RecogCorpusLoaded: true,
		},
		capabilityStatusPayload{Status: capabilityStatusAvailable},
	)

	if !resp.GetAvailable() {
		t.Fatal("agent capability status should be available")
	}
	if got := resp.GetSidecars(); len(got) != 0 {
		t.Fatalf("proto sidecars = %#v, want sidecars only in capability payload", got)
	}

	var payload agentCapabilityStatusPayload
	if err := json.Unmarshal(resp.GetMessage(), &payload); err != nil {
		t.Fatalf("failed to decode capability payload: %v", err)
	}

	if payload.HostNetworkVisibility.Fingerprint != testCapabilityEnabled {
		t.Fatalf("fingerprint = %q, want %s", payload.HostNetworkVisibility.Fingerprint, testCapabilityEnabled)
	}
	if !payload.HostNetworkVisibility.RunningAsRoot {
		t.Fatal("running_as_root = false, want true")
	}
	if payload.HostNetworkVisibility.CorpusRevisions == nil ||
		payload.HostNetworkVisibility.CorpusRevisions.Recog != "recog-rev" ||
		!payload.HostNetworkVisibility.CorpusRevisions.RecogCorpusLoaded {
		t.Fatalf("corpus revisions = %#v, want recog revision and loaded flag", payload.HostNetworkVisibility.CorpusRevisions)
	}
	if payload.HostNetworkVisibility.DPI != testCapabilityUnavailable ||
		payload.HostNetworkVisibility.FlowAttribution != testCapabilityUnavailable ||
		payload.HostNetworkVisibility.ProcessSnapshot != testCapabilityUnavailable {
		t.Fatalf("unexpected unavailable surfaces: %#v", payload.HostNetworkVisibility)
	}
	if payload.Sweep.BannerGrab.Status != capabilityStatusAvailable || payload.Sweep.BannerGrab.Reason != "" {
		t.Fatalf("banner grab capability = %#v, want available", payload.Sweep.BannerGrab)
	}

	if len(payload.Sidecars) != 1 || payload.Sidecars[0].GetName() != "netprobe" {
		t.Fatalf("payload sidecars = %#v, want netprobe status", payload.Sidecars)
	}
}

func TestBuildAgentCapabilityStatusResponseMarksFingerprintUnavailable(t *testing.T) {
	resp := buildAgentCapabilityStatusResponse(
		[]string{capabilityHostNetworkVisibility, capabilityHostNetworkVisibilityFingerprintUnavailable},
		[]*proto.SidecarStatus{{Name: "netprobe", State: "circuit_open"}},
		false,
		agentnetprobe.CorpusRevisions{},
		capabilityStatusPayload{
			Status: capabilityStatusUnavailable,
			Reason: capabilityReasonNetprobeUnavailable,
		},
	)

	var payload agentCapabilityStatusPayload
	if err := json.Unmarshal(resp.GetMessage(), &payload); err != nil {
		t.Fatalf("failed to decode capability payload: %v", err)
	}

	if payload.HostNetworkVisibility.Fingerprint != testCapabilityUnavailable {
		t.Fatalf("fingerprint = %q, want %s", payload.HostNetworkVisibility.Fingerprint, testCapabilityUnavailable)
	}
	if containsCapability(payload.Capabilities, capabilityHostNetworkVisibilityFingerprintEnabled) {
		t.Fatalf("capabilities unexpectedly advertised enabled fingerprint: %#v", payload.Capabilities)
	}
	if payload.Sweep.BannerGrab.Status != capabilityStatusUnavailable ||
		payload.Sweep.BannerGrab.Reason != capabilityReasonNetprobeUnavailable {
		t.Fatalf("banner grab capability = %#v, want unavailable/netprobe reason", payload.Sweep.BannerGrab)
	}
}

func TestBuildAgentCapabilityGatewayStatusUsesSidecarProvider(t *testing.T) {
	pl := NewPushLoop(
		&Server{
			config: &ServerConfig{AgentID: desktopConsoleAgentID, Partition: "default"},
			sidecarStatus: fakeSidecarStatusProvider{
				statuses: []sidecar.Status{{Name: "netprobe", State: sidecar.StateRunning, PID: 4321}},
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
	if status.GetAgentId() != desktopConsoleAgentID {
		t.Fatalf("agent_id = %q, want %s", status.GetAgentId(), desktopConsoleAgentID)
	}

	var payload agentCapabilityStatusPayload
	if err := json.Unmarshal(status.GetMessage(), &payload); err != nil {
		t.Fatalf("failed to decode capability payload: %v", err)
	}
	if len(payload.Sidecars) != 1 || payload.Sidecars[0].GetName() != "netprobe" {
		t.Fatalf("payload sidecars = %#v, want netprobe status", payload.Sidecars)
	}
	if payload.HostNetworkVisibility.Fingerprint != testCapabilityEnabled {
		t.Fatalf("fingerprint = %q, want %s", payload.HostNetworkVisibility.Fingerprint, testCapabilityEnabled)
	}
	if !containsCapability(payload.Capabilities, capabilityHostNetworkVisibilityFingerprintEnabled) {
		t.Fatalf("capabilities missing enabled fingerprint: %#v", payload.Capabilities)
	}
}

func TestSweepBannerGrabCapabilityStatusReasons(t *testing.T) {
	t.Parallel()

	runningSidecars := []*proto.SidecarStatus{{Name: "netprobe", State: string(sidecar.StateRunning)}}
	loadedCorpus := agentnetprobe.CorpusRevisions{RecogCorpusLoaded: true}

	noProfile := NewPushLoop(&Server{}, nil, 30*time.Second, logger.NewTestLogger()).
		sweepBannerGrabCapabilityStatus(runningSidecars, loadedCorpus)
	if noProfile.Status != capabilityStatusUnavailable ||
		noProfile.Reason != capabilityReasonNoEnabledSweepProfile {
		t.Fatalf("no-profile status = %#v", noProfile)
	}

	configuredServer := &Server{
		services: []Service{&bannerGrabConfigMockService{enabled: true}},
	}
	pl := NewPushLoop(configuredServer, nil, 30*time.Second, logger.NewTestLogger())

	noSidecar := pl.sweepBannerGrabCapabilityStatus(nil, loadedCorpus)
	if noSidecar.Status != capabilityStatusUnavailable ||
		noSidecar.Reason != capabilityReasonNetprobeUnavailable {
		t.Fatalf("no-sidecar status = %#v", noSidecar)
	}

	noCorpus := pl.sweepBannerGrabCapabilityStatus(runningSidecars, agentnetprobe.CorpusRevisions{})
	if noCorpus.Status != capabilityStatusUnavailable ||
		noCorpus.Reason != capabilityReasonRecogCorpusUnavailable {
		t.Fatalf("no-corpus status = %#v", noCorpus)
	}

	available := pl.sweepBannerGrabCapabilityStatus(runningSidecars, loadedCorpus)
	if available.Status != capabilityStatusAvailable || available.Reason != "" {
		t.Fatalf("available status = %#v", available)
	}
}

func TestSweepBannerGrabCapabilityAdvertisementTransitionsUnavailableWhenNetprobeStops(t *testing.T) {
	t.Parallel()

	cfg := &ServerConfig{AgentID: desktopConsoleAgentID, Partition: "default"}
	pl := NewPushLoop(
		&Server{
			config:   cfg,
			services: []Service{&bannerGrabConfigMockService{enabled: true}},
		},
		nil,
		30*time.Second,
		logger.NewTestLogger(),
	)
	loadedCorpus := agentnetprobe.CorpusRevisions{RecogCorpusLoaded: true}

	runningSidecars := []*proto.SidecarStatus{{Name: "netprobe", State: string(sidecar.StateRunning)}}
	availableStatus := pl.sweepBannerGrabCapabilityStatus(runningSidecars, loadedCorpus)
	availablePayload := decodeAgentCapabilityPayload(t, buildAgentCapabilityStatusResponse(
		agentCapabilitiesForStatusWithBannerGrab(cfg, runningSidecars, availableStatus.Status == capabilityStatusAvailable),
		runningSidecars,
		false,
		loadedCorpus,
		availableStatus,
	))

	if availablePayload.Sweep.BannerGrab.Status != capabilityStatusAvailable {
		t.Fatalf("available banner grab status = %#v", availablePayload.Sweep.BannerGrab)
	}
	if !containsCapability(availablePayload.Capabilities, capabilitySweepBannerGrabAvailable) {
		t.Fatalf("available capabilities missing banner grab availability: %#v", availablePayload.Capabilities)
	}

	stoppedSidecars := []*proto.SidecarStatus{{Name: "netprobe", State: string(sidecar.StateStopped)}}
	unavailableStatus := pl.sweepBannerGrabCapabilityStatus(stoppedSidecars, loadedCorpus)
	unavailablePayload := decodeAgentCapabilityPayload(t, buildAgentCapabilityStatusResponse(
		agentCapabilitiesForStatusWithBannerGrab(cfg, stoppedSidecars, unavailableStatus.Status == capabilityStatusAvailable),
		stoppedSidecars,
		false,
		loadedCorpus,
		unavailableStatus,
	))

	if unavailablePayload.Sweep.BannerGrab.Status != capabilityStatusUnavailable ||
		unavailablePayload.Sweep.BannerGrab.Reason != capabilityReasonNetprobeUnavailable {
		t.Fatalf("stopped banner grab status = %#v, want unavailable/netprobe reason", unavailablePayload.Sweep.BannerGrab)
	}
	if containsCapability(unavailablePayload.Capabilities, capabilitySweepBannerGrabAvailable) {
		t.Fatalf("stopped capabilities still advertise available banner grab: %#v", unavailablePayload.Capabilities)
	}
	if !containsCapability(unavailablePayload.Capabilities, capabilitySweepBannerGrabUnavailable) {
		t.Fatalf("stopped capabilities missing unavailable banner grab marker: %#v", unavailablePayload.Capabilities)
	}
}

type bannerGrabConfigMockService struct {
	mockService
	enabled bool
}

func (s *bannerGrabConfigMockService) BannerGrabEnabled() bool {
	return s.enabled
}

func decodeAgentCapabilityPayload(t *testing.T, resp *proto.StatusResponse) agentCapabilityStatusPayload {
	t.Helper()

	var payload agentCapabilityStatusPayload
	if err := json.Unmarshal(resp.GetMessage(), &payload); err != nil {
		t.Fatalf("failed to decode capability payload: %v", err)
	}

	return payload
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
		desktopConsoleAgentID,
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
		desktopConsoleAgentID,
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
