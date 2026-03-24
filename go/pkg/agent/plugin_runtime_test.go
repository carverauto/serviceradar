package agent

import (
	"context"
	"encoding/json"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const unknownStatus = "UNKNOWN"

func TestAdmitAssignmentsEnforcesLimits(t *testing.T) {
	mgr := &PluginManager{logger: logger.NewTestLogger()}

	assignments := []*pluginAssignment{
		{
			AssignmentID: "a",
			Resources: pluginResources{
				RequestedMemoryMB:  60,
				RequestedCPUMS:     100,
				MaxOpenConnections: 1,
			},
		},
		{
			AssignmentID: "b",
			Resources: pluginResources{
				RequestedMemoryMB:  50,
				RequestedCPUMS:     100,
				MaxOpenConnections: 1,
			},
		},
		{
			AssignmentID: "c",
			Resources: pluginResources{
				RequestedMemoryMB:  10,
				RequestedCPUMS:     100,
				MaxOpenConnections: 1,
			},
		},
	}

	limits := pluginEngineLimits{
		MaxMemoryMB:        100,
		MaxCPUMS:           300,
		MaxConcurrent:      2,
		MaxOpenConnections: 2,
	}

	admitted, rejected, usage := mgr.admitAssignments(assignments, limits)

	if len(admitted) != 2 {
		t.Fatalf("expected 2 admitted assignments, got %d", len(admitted))
	}
	if len(rejected) != 1 {
		t.Fatalf("expected 1 rejected assignment, got %d", len(rejected))
	}
	if rejected[0].AssignmentID != "b" {
		t.Fatalf("expected assignment b to be rejected, got %s", rejected[0].AssignmentID)
	}

	if usage.memoryMB != 70 || usage.cpuMS != 200 || usage.connections != 2 || usage.count != 2 {
		t.Fatalf("unexpected usage: %#v", usage)
	}
}

func TestNormalizeResources(t *testing.T) {
	res := normalizeResources(pluginResources{
		RequestedMemoryMB:  -1,
		RequestedCPUMS:     -5,
		MaxOpenConnections: -2,
	})

	if res.RequestedMemoryMB != 0 || res.RequestedCPUMS != 0 || res.MaxOpenConnections != 0 {
		t.Fatalf("expected negative resource values to be clamped to 0, got %#v", res)
	}
}

func TestPluginAssignmentClassifiesCameraMediaStreamingCapability(t *testing.T) {
	assignment := newPluginAssignment(
		&proto.PluginAssignmentConfig{
			AssignmentId: "streaming-1",
			PluginId:     "camera-streamer",
			Entrypoint:   "stream_camera",
			Capabilities: []string{pluginCapabilityCameraMediaStream, "log"},
		},
		logger.NewTestLogger(),
	)

	if !assignment.isStreaming() {
		t.Fatalf("expected camera media stream capability to classify assignment as streaming")
	}
}

func TestPluginManagerApplyConfigSeparatesStreamingAssignments(t *testing.T) {
	mgr := NewPluginManager(t.Context(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	defer mgr.Stop()

	mgr.ApplyConfig(&proto.PluginConfig{
		Assignments: []*proto.PluginAssignmentConfig{
			{
				AssignmentId: "scheduled-1",
				PluginId:     "http-check",
				Entrypoint:   "run_check",
				Enabled:      true,
				IntervalSec:  3600,
				TimeoutSec:   5,
				Capabilities: []string{"submit_result"},
			},
			{
				AssignmentId: "streaming-1",
				PluginId:     "camera-streamer",
				Entrypoint:   "stream_camera",
				Enabled:      true,
				IntervalSec:  3600,
				TimeoutSec:   5,
				Capabilities: []string{pluginCapabilityCameraMediaStream, "log"},
			},
		},
	})

	mgr.mu.RLock()
	defer mgr.mu.RUnlock()

	if len(mgr.runners) != 1 {
		t.Fatalf("expected 1 scheduled runner, got %d", len(mgr.runners))
	}
	if len(mgr.streams) != 1 {
		t.Fatalf("expected 1 streaming assignment, got %d", len(mgr.streams))
	}
	if _, ok := mgr.runners["scheduled-1"]; !ok {
		t.Fatalf("expected scheduled assignment to start a runner")
	}
	if _, ok := mgr.streams["streaming-1"]; !ok {
		t.Fatalf("expected streaming assignment to be cataloged separately")
	}
}

func TestPluginManagerStreamingAssignmentSnapshot(t *testing.T) {
	mgr := NewPluginManager(t.Context(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	defer mgr.Stop()

	mgr.ApplyConfig(&proto.PluginConfig{
		Assignments: []*proto.PluginAssignmentConfig{
			{
				AssignmentId: "streaming-1",
				PluginId:     "camera-streamer",
				Name:         "Camera Streamer",
				Entrypoint:   "stream_camera",
				Runtime:      "wasi-preview1",
				Enabled:      true,
				Capabilities: []string{"log", pluginCapabilityCameraMediaStream},
			},
		},
	})

	snapshot, ok := mgr.StreamingAssignment("streaming-1")
	if !ok {
		t.Fatalf("expected streaming assignment lookup to succeed")
	}
	if snapshot.AssignmentID != "streaming-1" {
		t.Fatalf("unexpected assignment id: %s", snapshot.AssignmentID)
	}
	if snapshot.Entrypoint != "stream_camera" {
		t.Fatalf("unexpected entrypoint: %s", snapshot.Entrypoint)
	}
	if len(snapshot.Capabilities) != 2 {
		t.Fatalf("expected 2 capabilities in snapshot, got %d", len(snapshot.Capabilities))
	}
}

func TestPluginManagerOpenCameraRelayStreamUsesStreamingBridge(t *testing.T) {
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: t.TempDir(),
	})
	defer manager.Stop()

	wasmPath := filepath.Join(manager.localStoreDir, "camera-streamer.wasm")
	if err := os.WriteFile(wasmPath, []byte("not-real-wasm"), 0o600); err != nil {
		t.Fatalf("write wasm fixture: %v", err)
	}

	assignment := newPluginAssignment(
		&proto.PluginAssignmentConfig{
			AssignmentId:  "streaming-1",
			PluginId:      "camera-streamer",
			Name:          "Camera Streamer",
			Entrypoint:    "stream_camera",
			Runtime:       "wasi-preview1",
			Enabled:       true,
			WasmObjectKey: "camera-streamer.wasm",
			Capabilities:  []string{pluginCapabilityCameraMediaStream, "log"},
		},
		logger.NewTestLogger(),
	)

	manager.mu.Lock()
	manager.streams["streaming-1"] = assignment
	manager.mu.Unlock()

	manager.streamExecutor = func(
		ctx context.Context,
		assignment *pluginAssignment,
		wasm []byte,
		configJSON []byte,
		bridge *pluginCameraMediaBridge,
	) error {
		if assignment.AssignmentID != "streaming-1" {
			t.Fatalf("unexpected assignment id: %s", assignment.AssignmentID)
		}
		if len(wasm) == 0 {
			t.Fatal("expected wasm bytes to be loaded")
		}
		if len(configJSON) == 0 {
			t.Fatal("expected streaming config json")
		}

		handle, err := bridge.Open(ctx, pluginCameraMediaOpenRequest{
			TrackID:       "video",
			Codec:         "h264",
			PayloadFormat: "annexb",
		})
		if err != nil {
			return err
		}
		if _, err := bridge.Write(ctx, handle, []byte("abc"), pluginCameraMediaChunkMetadata{
			TrackID:       "video",
			Sequence:      1,
			Codec:         "h264",
			PayloadFormat: "annexb",
			IsFinal:       true,
		}); err != nil {
			return err
		}
		return bridge.Close(handle, "done")
	}

	stream, err := manager.OpenCameraRelayStream(t.Context(), "streaming-1", cameraRelaySessionSpec{
		RelaySessionID:     "relay-1",
		AgentID:            "agent-1",
		GatewayID:          "gateway-1",
		CameraSourceID:     "camera-1",
		StreamProfileID:    "main",
		LeaseToken:         "lease-1",
		PluginAssignmentID: "streaming-1",
	})
	if err != nil {
		t.Fatalf("OpenCameraRelayStream returned error: %v", err)
	}

	chunk, err := stream.Recv(t.Context())
	if err != nil {
		t.Fatalf("Recv returned error: %v", err)
	}
	if string(chunk.Payload) != "abc" {
		t.Fatalf("unexpected payload: %q", string(chunk.Payload))
	}
	if !chunk.IsFinal {
		t.Fatalf("expected final chunk")
	}

	if _, err := stream.Recv(t.Context()); err == nil || err != io.EOF {
		t.Fatalf("expected io.EOF after final chunk, got %v", err)
	}
}

func TestPluginManagerOpenCameraRelayStreamWithWazeroPlugin(t *testing.T) {
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: t.TempDir(),
	})
	defer manager.Stop()

	wasmFixture, err := os.ReadFile(filepath.Join("testdata", "camera_stream_plugin.wasm"))
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}

	wasmPath := filepath.Join(manager.localStoreDir, "camera-streamer.wasm")
	if err := os.WriteFile(wasmPath, wasmFixture, 0o600); err != nil {
		t.Fatalf("write wasm fixture: %v", err)
	}

	assignment := newPluginAssignment(
		&proto.PluginAssignmentConfig{
			AssignmentId:  "streaming-1",
			PluginId:      "camera-streamer",
			Name:          "Camera Streamer",
			Entrypoint:    "stream_camera",
			Runtime:       "wasi-preview1",
			Enabled:       true,
			WasmObjectKey: "camera-streamer.wasm",
			Capabilities: []string{
				pluginCapabilityCameraMediaStream,
				"get_config",
			},
		},
		logger.NewTestLogger(),
	)

	manager.mu.Lock()
	manager.streams["streaming-1"] = assignment
	manager.mu.Unlock()

	stream, err := manager.OpenCameraRelayStream(t.Context(), "streaming-1", cameraRelaySessionSpec{
		RelaySessionID:     "relay-1",
		AgentID:            "agent-1",
		GatewayID:          "gateway-1",
		CameraSourceID:     "camera-1",
		StreamProfileID:    "main",
		LeaseToken:         "lease-1",
		PluginAssignmentID: "streaming-1",
	})
	if err != nil {
		t.Fatalf("OpenCameraRelayStream returned error: %v", err)
	}

	chunk, err := stream.Recv(t.Context())
	if err != nil {
		t.Fatalf("Recv returned error: %v", err)
	}
	if string(chunk.Payload) != string([]byte{0x00, 0x00, 0x01, 0x09, 0x10}) {
		t.Fatalf("unexpected payload: %#v", chunk.Payload)
	}
	if chunk.TrackID != "video" {
		t.Fatalf("unexpected track id: %s", chunk.TrackID)
	}
	if chunk.Codec != "h264" {
		t.Fatalf("unexpected codec: %s", chunk.Codec)
	}
	if chunk.PayloadFormat != "annexb" {
		t.Fatalf("unexpected payload format: %s", chunk.PayloadFormat)
	}
	if !chunk.Keyframe {
		t.Fatalf("expected keyframe")
	}

	if _, err := stream.Recv(t.Context()); err == nil || err != io.EOF {
		t.Fatalf("expected io.EOF after close, got %v", err)
	}

	if results := manager.DrainResults(1); len(results) != 0 {
		t.Fatalf("expected no plugin_result payloads for live media, got %d", len(results))
	}
}

func TestPluginManagerOpenCameraRelayStreamRespectsConcurrentLimit(t *testing.T) {
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: t.TempDir(),
	})
	defer manager.Stop()

	manager.setLimits(pluginEngineLimits{MaxConcurrent: 1})

	wasmPath := filepath.Join(manager.localStoreDir, "camera-streamer.wasm")
	if err := os.WriteFile(wasmPath, []byte("not-real-wasm"), 0o600); err != nil {
		t.Fatalf("write wasm fixture: %v", err)
	}

	assignment := newPluginAssignment(
		&proto.PluginAssignmentConfig{
			AssignmentId:  "streaming-1",
			PluginId:      "camera-streamer",
			Name:          "Camera Streamer",
			Entrypoint:    "stream_camera",
			Runtime:       "wasi-preview1",
			Enabled:       true,
			WasmObjectKey: "camera-streamer.wasm",
			Capabilities:  []string{pluginCapabilityCameraMediaStream},
		},
		logger.NewTestLogger(),
	)

	manager.mu.Lock()
	manager.streams["streaming-1"] = assignment
	manager.mu.Unlock()

	blocked := make(chan struct{})
	manager.streamExecutor = func(
		ctx context.Context,
		assignment *pluginAssignment,
		wasm []byte,
		configJSON []byte,
		bridge *pluginCameraMediaBridge,
	) error {
		handle, err := bridge.Open(ctx, pluginCameraMediaOpenRequest{TrackID: "video"})
		if err != nil {
			return err
		}

		select {
		case <-ctx.Done():
			return bridge.Close(handle, "cancelled")
		case <-blocked:
			return bridge.Close(handle, "done")
		}
	}

	stream, err := manager.OpenCameraRelayStream(t.Context(), "streaming-1", cameraRelaySessionSpec{
		RelaySessionID:     "relay-1",
		AgentID:            "agent-1",
		GatewayID:          "gateway-1",
		CameraSourceID:     "camera-1",
		StreamProfileID:    "main",
		LeaseToken:         "lease-1",
		PluginAssignmentID: "streaming-1",
	})
	if err != nil {
		t.Fatalf("first OpenCameraRelayStream returned error: %v", err)
	}
	defer func() {
		close(blocked)
		_ = stream.Close()
	}()

	_, err = manager.OpenCameraRelayStream(t.Context(), "streaming-1", cameraRelaySessionSpec{
		RelaySessionID:     "relay-2",
		AgentID:            "agent-1",
		GatewayID:          "gateway-1",
		CameraSourceID:     "camera-2",
		StreamProfileID:    "main",
		LeaseToken:         "lease-2",
		PluginAssignmentID: "streaming-1",
	})
	if err == nil || !strings.Contains(err.Error(), "admission denied") {
		t.Fatalf("expected admission denied error, got %v", err)
	}
}

func TestPluginManagerOpenCameraRelayStreamReturnsErrorWhenPluginTerminatesWithoutOpening(t *testing.T) {
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: t.TempDir(),
	})
	defer manager.Stop()

	wasmPath := filepath.Join(manager.localStoreDir, "camera-streamer.wasm")
	if err := os.WriteFile(wasmPath, []byte("not-real-wasm"), 0o600); err != nil {
		t.Fatalf("write wasm fixture: %v", err)
	}

	assignment := newPluginAssignment(
		&proto.PluginAssignmentConfig{
			AssignmentId:  "streaming-1",
			PluginId:      "camera-streamer",
			Name:          "Camera Streamer",
			Entrypoint:    "stream_camera",
			Runtime:       "wasi-preview1",
			Enabled:       true,
			WasmObjectKey: "camera-streamer.wasm",
			Capabilities:  []string{pluginCapabilityCameraMediaStream},
		},
		logger.NewTestLogger(),
	)

	manager.mu.Lock()
	manager.streams["streaming-1"] = assignment
	manager.mu.Unlock()

	manager.streamExecutor = func(
		ctx context.Context,
		assignment *pluginAssignment,
		wasm []byte,
		configJSON []byte,
		bridge *pluginCameraMediaBridge,
	) error {
		return nil
	}

	stream, err := manager.OpenCameraRelayStream(t.Context(), "streaming-1", cameraRelaySessionSpec{
		RelaySessionID:     "relay-no-open-1",
		AgentID:            "agent-1",
		GatewayID:          "gateway-1",
		CameraSourceID:     "camera-1",
		StreamProfileID:    "main",
		LeaseToken:         "lease-1",
		PluginAssignmentID: "streaming-1",
	})
	if err != nil {
		t.Fatalf("OpenCameraRelayStream returned error: %v", err)
	}

	if _, err := stream.Recv(t.Context()); err == nil || !strings.Contains(err.Error(), "did not open") {
		t.Fatalf("expected missing-open terminal error, got %v", err)
	}
}

func TestPluginManagerOpenCameraRelayStreamCloseCancelsPluginAndReleasesSlot(t *testing.T) {
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: t.TempDir(),
	})
	defer manager.Stop()

	manager.setLimits(pluginEngineLimits{MaxConcurrent: 1})

	wasmPath := filepath.Join(manager.localStoreDir, "camera-streamer.wasm")
	if err := os.WriteFile(wasmPath, []byte("not-real-wasm"), 0o600); err != nil {
		t.Fatalf("write wasm fixture: %v", err)
	}

	assignment := newPluginAssignment(
		&proto.PluginAssignmentConfig{
			AssignmentId:  "streaming-1",
			PluginId:      "camera-streamer",
			Name:          "Camera Streamer",
			Entrypoint:    "stream_camera",
			Runtime:       "wasi-preview1",
			Enabled:       true,
			WasmObjectKey: "camera-streamer.wasm",
			Capabilities:  []string{pluginCapabilityCameraMediaStream},
		},
		logger.NewTestLogger(),
	)

	manager.mu.Lock()
	manager.streams["streaming-1"] = assignment
	manager.mu.Unlock()

	cancelObserved := make(chan struct{}, 1)
	manager.streamExecutor = func(
		ctx context.Context,
		assignment *pluginAssignment,
		wasm []byte,
		configJSON []byte,
		bridge *pluginCameraMediaBridge,
	) error {
		handle, err := bridge.Open(ctx, pluginCameraMediaOpenRequest{TrackID: "video"})
		if err != nil {
			return err
		}

		<-ctx.Done()
		cancelObserved <- struct{}{}
		return bridge.Close(handle, "cancelled")
	}

	stream, err := manager.OpenCameraRelayStream(t.Context(), "streaming-1", cameraRelaySessionSpec{
		RelaySessionID:     "relay-cancel-1",
		AgentID:            "agent-1",
		GatewayID:          "gateway-1",
		CameraSourceID:     "camera-1",
		StreamProfileID:    "main",
		LeaseToken:         "lease-1",
		PluginAssignmentID: "streaming-1",
	})
	if err != nil {
		t.Fatalf("OpenCameraRelayStream returned error: %v", err)
	}

	if err := stream.Close(); err != nil {
		t.Fatalf("Close returned error: %v", err)
	}

	select {
	case <-cancelObserved:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for plugin context cancellation")
	}

	deadline := time.Now().Add(3 * time.Second)
	for {
		_, err = manager.OpenCameraRelayStream(t.Context(), "streaming-1", cameraRelaySessionSpec{
			RelaySessionID:     "relay-cancel-2",
			AgentID:            "agent-1",
			GatewayID:          "gateway-1",
			CameraSourceID:     "camera-2",
			StreamProfileID:    "main",
			LeaseToken:         "lease-2",
			PluginAssignmentID: "streaming-1",
		})
		if err == nil {
			break
		}
		if !strings.Contains(err.Error(), "admission denied") {
			t.Fatalf("expected transient admission-denied during slot release, got %v", err)
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for streaming slot release: %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestNormalizePluginPayload(t *testing.T) {
	pl := &PushLoop{}
	observed := time.Date(2025, 1, 1, 10, 0, 0, 0, time.UTC)

	result := PluginResult{
		AssignmentID: "assign-1",
		PluginID:     "plugin-1",
		PluginName:   "HTTP Check",
		Payload:      []byte(`{"status":"ok","summary":"all good","labels":{"region":"iad"}}`),
		ObservedAt:   observed,
	}

	data, available, err := pl.normalizePluginPayload(result, "agent-1", "default")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !available {
		t.Fatalf("expected available=true for OK status")
	}

	var payload map[string]interface{}
	if err := json.Unmarshal(data, &payload); err != nil {
		t.Fatalf("failed to unmarshal payload: %v", err)
	}

	if payload["status"] != "OK" {
		t.Fatalf("expected status OK, got %#v", payload["status"])
	}
	if payload["summary"] != "all good" {
		t.Fatalf("unexpected summary: %#v", payload["summary"])
	}
	if payload["observed_at"] != observed.Format(time.RFC3339Nano) {
		t.Fatalf("unexpected observed_at: %#v", payload["observed_at"])
	}

	labels, _ := payload["labels"].(map[string]interface{})
	if labels["region"] != "iad" {
		t.Fatalf("expected region label to be preserved")
	}
	if labels["assignment_id"] != "assign-1" {
		t.Fatalf("expected assignment_id label to be set")
	}
	if labels["plugin_id"] != "plugin-1" {
		t.Fatalf("expected plugin_id label to be set")
	}
	if labels["plugin_name"] != "HTTP Check" {
		t.Fatalf("expected plugin_name label to be set")
	}
	if labels["agent_id"] != "agent-1" {
		t.Fatalf("expected agent_id label to be set")
	}
	if labels["partition"] != "default" {
		t.Fatalf("expected partition label to be set")
	}
}

func TestNormalizePluginPayloadRejectsInvalidStatus(t *testing.T) {
	pl := &PushLoop{}
	result := PluginResult{
		Payload: []byte(`{"status":"bad","summary":"oops"}`),
	}

	_, _, err := pl.normalizePluginPayload(result, "agent-1", "default")
	if err == nil {
		t.Fatalf("expected error for invalid status")
	}
}

func TestBuildPluginErrorPayload(t *testing.T) {
	pl := &PushLoop{}
	result := PluginResult{
		AssignmentID: "assign-1",
		PluginID:     "plugin-1",
		PluginName:   "HTTP Check",
	}

	data := pl.buildPluginErrorPayload(result, nil, "agent-1", "default")
	var payload map[string]interface{}
	if err := json.Unmarshal(data, &payload); err != nil {
		t.Fatalf("failed to unmarshal payload: %v", err)
	}

	if payload["status"] != unknownStatus {
		t.Fatalf("expected %s status", unknownStatus)
	}
	if _, ok := payload["summary"].(string); !ok {
		t.Fatalf("expected summary to be a string")
	}
}

func TestBuildPluginTelemetryPayload(t *testing.T) {
	snapshot := PluginEngineSnapshot{
		ObservedAt:          time.Date(2025, 1, 1, 10, 0, 0, 0, time.UTC),
		AssignmentsRejected: 1,
	}

	data, healthy := buildPluginTelemetryPayload(snapshot, "agent-1", "default")
	if healthy {
		t.Fatalf("expected unhealthy snapshot due to rejected assignments")
	}

	var payload map[string]interface{}
	if err := json.Unmarshal(data, &payload); err != nil {
		t.Fatalf("failed to unmarshal payload: %v", err)
	}

	if payload["schema"] != "serviceradar.plugin_engine_telemetry.v1" {
		t.Fatalf("unexpected schema: %#v", payload["schema"])
	}

	health, _ := payload["health"].(map[string]interface{})
	if health["status"] != "degraded" {
		t.Fatalf("expected degraded health status")
	}
	if health["reason"] != "admission_denied" {
		t.Fatalf("expected admission_denied reason")
	}
}

func TestPluginPermissionsAllowsDomain(t *testing.T) {
	perms := pluginPermissions{
		AllowedDomains: []string{"example.com", "*.svc.local"},
	}
	perms.normalize()

	if !perms.allowsDomain("example.com") {
		t.Fatalf("expected exact domain to be allowed")
	}
	if !perms.allowsDomain("Example.com.") {
		t.Fatalf("expected case-insensitive domain to be allowed")
	}
	if !perms.allowsDomain("api.svc.local") {
		t.Fatalf("expected wildcard suffix to be allowed")
	}
	if perms.allowsDomain("evil.com") {
		t.Fatalf("expected unknown domain to be denied")
	}
	if perms.allowsDomain("") {
		t.Fatalf("expected empty domain to be denied")
	}

	perms = pluginPermissions{AllowedDomains: []string{"*"}}
	perms.normalize()
	if !perms.allowsDomain("anything.example") {
		t.Fatalf("expected wildcard to allow any domain")
	}
}

func TestPluginPermissionsAllowsPort(t *testing.T) {
	perms := pluginPermissions{AllowedPorts: []int{80, 443}}
	perms.normalize()

	if !perms.allowsPort(80) {
		t.Fatalf("expected port 80 to be allowed")
	}
	if perms.allowsPort(22) {
		t.Fatalf("expected port 22 to be denied")
	}

	perms = pluginPermissions{}
	perms.normalize()
	if !perms.allowsPort(22) {
		t.Fatalf("expected empty port list to allow all ports")
	}
}

func TestPluginPermissionsAllowsAddress(t *testing.T) {
	perms := pluginPermissions{
		AllowedNetworks: []string{"10.0.0.0/24", "192.168.1.10/32"},
	}
	perms.normalize()

	if !perms.allowsAddress(netip.MustParseAddr("10.0.0.5")) {
		t.Fatalf("expected address within prefix to be allowed")
	}
	if !perms.allowsAddress(netip.MustParseAddr("192.168.1.10")) {
		t.Fatalf("expected single-host prefix to be allowed")
	}
	if perms.allowsAddress(netip.MustParseAddr("10.0.1.5")) {
		t.Fatalf("expected address outside prefixes to be denied")
	}
}

func TestParseWebSocketConnectPayloadURLOnly(t *testing.T) {
	wsURL, headers, err := parseWebSocketConnectPayload([]byte("ws://camera.local/ws"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if wsURL != "ws://camera.local/ws" {
		t.Fatalf("unexpected ws url: %s", wsURL)
	}
	if headers != nil {
		t.Fatalf("expected nil headers for URL-only payload")
	}
}

func TestParseWebSocketConnectPayloadWithHeaders(t *testing.T) {
	raw := []byte(`{"url":"wss://camera.local/ws","headers":{"Authorization":"Basic abc","X-Test":"1"}}`)
	wsURL, headers, err := parseWebSocketConnectPayload(raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if wsURL != "wss://camera.local/ws" {
		t.Fatalf("unexpected ws url: %s", wsURL)
	}
	if headers.Get("Authorization") != "Basic abc" {
		t.Fatalf("expected Authorization header to be set")
	}
	if headers.Get("X-Test") != "1" {
		t.Fatalf("expected X-Test header to be set")
	}
}

func TestParseWebSocketConnectPayloadInvalidJSON(t *testing.T) {
	_, _, err := parseWebSocketConnectPayload([]byte("{bad-json"))
	if err == nil {
		t.Fatalf("expected parse error for invalid JSON payload")
	}
}

func TestParseWebSocketConnectPayloadEmptyURL(t *testing.T) {
	_, _, err := parseWebSocketConnectPayload([]byte(`{"url":""}`))
	if err == nil {
		t.Fatalf("expected error for empty URL")
	}
}

func TestParseWebSocketConnectPayloadSkipsBlankHeaders(t *testing.T) {
	raw := []byte(`{"url":"ws://camera.local/ws","headers":{"":"x","  ":"y"}}`)
	wsURL, headers, err := parseWebSocketConnectPayload(raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if wsURL == "" {
		t.Fatalf("expected non-empty URL")
	}
	if len(headers) != 0 {
		t.Fatalf("expected blank headers to be omitted")
	}
}
