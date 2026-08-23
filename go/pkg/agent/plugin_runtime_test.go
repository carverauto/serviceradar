package agent

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	metricpb "github.com/carverauto/serviceradar/proto/metric/v1"
	gproto "google.golang.org/protobuf/proto"
)

const (
	unknownStatus                 = "UNKNOWN"
	testPluginAssignmentID        = "assign-1"
	testPluginConsoleAssignmentID = "console-1"
	testPluginConsoleHostname     = "pve-1.example"
	testPluginConsoleIP           = "192.0.2.10"
	testQueuedAssignmentID        = "already-queued"
	testPluginPagePayload         = `{"page":2}`
)

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

func TestPluginExecutionSubmitScheduledResultWaitsForQueueAdmission(t *testing.T) {
	mgr := NewPluginManager(t.Context(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	defer mgr.Stop()

	mgr.results = make(chan PluginResult, 1)
	mgr.results <- PluginResult{AssignmentID: testQueuedAssignmentID}

	exec := newPluginExecution(mgr, &pluginAssignment{
		AssignmentID: testPluginAssignmentID,
		PluginID:     "alienvault-otx-threat-intel",
		Name:         "AlienVault OTX",
	})
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()

	done := make(chan int32, 1)
	go func() {
		done <- exec.submitScheduledResult(ctx, []byte(testPluginPagePayload))
	}()

	select {
	case code := <-done:
		t.Fatalf("submitScheduledResult returned %d before queue admission", code)
	case <-time.After(25 * time.Millisecond):
	}

	first := <-mgr.results
	if first.AssignmentID != testQueuedAssignmentID {
		t.Fatalf("first queued assignment = %q, want already-queued", first.AssignmentID)
	}

	select {
	case code := <-done:
		if code != pluginErrOK {
			t.Fatalf("submitScheduledResult returned %d, want %d", code, pluginErrOK)
		}
	case <-ctx.Done():
		t.Fatal("submitScheduledResult did not complete after queue capacity became available")
	}

	result := <-mgr.results
	if result.AssignmentID != testPluginAssignmentID || string(result.Payload) != testPluginPagePayload {
		t.Fatalf("unexpected admitted result: %#v", result)
	}
	if !exec.hasSubmitted() {
		t.Fatal("execution was not marked submitted after queue admission")
	}
}

func TestPluginExecutionSubmitScheduledResultReportsCanceledAdmission(t *testing.T) {
	mgr := NewPluginManager(t.Context(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	defer mgr.Stop()

	mgr.results = make(chan PluginResult, 1)
	mgr.results <- PluginResult{AssignmentID: testQueuedAssignmentID}
	exec := newPluginExecution(mgr, &pluginAssignment{AssignmentID: testPluginAssignmentID})

	ctx, cancel := context.WithCancel(t.Context())
	cancel()

	if code := exec.submitScheduledResult(ctx, []byte(testPluginPagePayload)); code != pluginErrInternal {
		t.Fatalf("submitScheduledResult returned %d, want %d", code, pluginErrInternal)
	}
	if exec.hasSubmitted() {
		t.Fatal("execution was marked submitted after canceled queue admission")
	}
	if got := len(mgr.results); got != 1 {
		t.Fatalf("queued results = %d, want 1", got)
	}
}

func TestPluginExecutionSubmitScheduledResultReportsAdmissionTimeout(t *testing.T) {
	mgr := NewPluginManager(t.Context(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	defer mgr.Stop()

	mgr.results = make(chan PluginResult, 1)
	mgr.results <- PluginResult{AssignmentID: testQueuedAssignmentID}
	exec := newPluginExecution(mgr, &pluginAssignment{AssignmentID: testPluginAssignmentID})

	ctx, cancel := context.WithTimeout(t.Context(), time.Nanosecond)
	defer cancel()
	<-ctx.Done()

	if code := exec.submitScheduledResult(ctx, []byte(testPluginPagePayload)); code != pluginErrTimeout {
		t.Fatalf("submitScheduledResult returned %d, want %d", code, pluginErrTimeout)
	}
	if exec.hasSubmitted() {
		t.Fatal("execution was marked submitted after queue admission timeout")
	}
}

func TestDecodePluginTelemetryBuildsTelemetryBatch(t *testing.T) {
	assignment := &pluginAssignment{
		AssignmentID: testPluginAssignmentID,
		PluginID:     "axis",
		Name:         "Axis Camera",
	}

	signal, err := decodePluginTelemetry([]byte(`{
		"source": {
			"source_type": "axis-camera",
			"source_instance": "front-door",
			"metadata": {"controller": "cam-1"}
		},
		"records": [{
			"event_id": "event-1",
			"payload_kind": "ocsf_event",
			"payload": {"id":"event-1","class_uid":1008},
			"metadata": {"serviceradar.signal_schema.schema_id": "com.carverauto.axis_camera.event_log"}
		}]
	}`), assignment)
	if err != nil {
		t.Fatalf("decodePluginTelemetry() error = %v", err)
	}

	if signal.AssignmentID != testPluginAssignmentID || signal.PluginID != "axis" || signal.PluginName != "Axis Camera" {
		t.Fatalf("unexpected signal identity: %#v", signal)
	}
	if signal.Batch.GetSource().GetSourceType() != "axis-camera" {
		t.Fatalf("source_type = %q, want axis-camera", signal.Batch.GetSource().GetSourceType())
	}
	if got := signal.Batch.GetSource().GetMetadata()["controller"]; got != "cam-1" {
		t.Fatalf("source metadata controller = %q, want cam-1", got)
	}
	if len(signal.Batch.GetRecords()) != 1 {
		t.Fatalf("records len = %d, want 1", len(signal.Batch.GetRecords()))
	}

	record := signal.Batch.GetRecords()[0]
	if record.GetPayloadKind() != addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT {
		t.Fatalf("payload_kind = %v, want OCSF_EVENT", record.GetPayloadKind())
	}
	if !json.Valid(record.GetPayload()) {
		t.Fatalf("payload is not JSON: %s", string(record.GetPayload()))
	}
	if record.GetObservedTimeUnixNano() == 0 || record.GetEventTimeUnixNano() == 0 {
		t.Fatalf("timestamps should be defaulted: %#v", record)
	}
}

func TestDecodePluginTelemetryAcceptsServiceRadarMetricBatch(t *testing.T) {
	assignment := &pluginAssignment{
		AssignmentID: testPluginAssignmentID,
		PluginID:     "metric-plugin",
		Name:         "Metric Plugin",
	}

	batch := &metricpb.MetricBatch{
		SchemaVersion: metricEnvelopeSchemaVersion,
		Resource:      &metricpb.MetricResource{AgentId: "agent-1"},
		Metrics: []*metricpb.Metric{
			{
				Name:       "temperature_c",
				MetricType: "plugin",
				Kind:       metricpb.MetricKind_METRIC_KIND_GAUGE,
				Points: []*metricpb.MetricPoint{
					{
						Value:              42.5,
						RawValue:           "42.5",
						RawValueType:       metricpb.MetricValueType_METRIC_VALUE_TYPE_DOUBLE,
						ObservedAtUnixNano: 123,
					},
				},
			},
		},
	}

	payload, err := gproto.Marshal(batch)
	if err != nil {
		t.Fatalf("marshal metric batch: %v", err)
	}

	wrapper, err := json.Marshal(map[string]any{
		"source": map[string]any{"source_type": "metric-plugin"},
		"records": []map[string]any{
			{
				"event_id":     "metric-event-1",
				"payload_kind": "serviceradar_metrics",
				"payload":      base64.StdEncoding.EncodeToString(payload),
			},
		},
	})
	if err != nil {
		t.Fatalf("marshal telemetry wrapper: %v", err)
	}

	signal, err := decodePluginTelemetry(wrapper, assignment)
	if err != nil {
		t.Fatalf("decodePluginTelemetry() error = %v", err)
	}

	record := signal.Batch.GetRecords()[0]
	if record.GetPayloadKind() != addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS {
		t.Fatalf("payload_kind = %v, want SERVICERADAR_METRICS", record.GetPayloadKind())
	}
	if string(record.GetPayload()) == base64.StdEncoding.EncodeToString(payload) {
		t.Fatal("expected host ABI wrapper to be decoded back to raw protobuf bytes")
	}

	var decoded metricpb.MetricBatch
	if err := gproto.Unmarshal(record.GetPayload(), &decoded); err != nil {
		t.Fatalf("unmarshal metric payload: %v", err)
	}
	if decoded.GetMetrics()[0].GetName() != "temperature_c" {
		t.Fatalf("metric name = %q, want temperature_c", decoded.GetMetrics()[0].GetName())
	}
}

func TestDecodePluginTelemetryRejectsJSONMetricPayload(t *testing.T) {
	assignment := &pluginAssignment{
		AssignmentID: testPluginAssignmentID,
		PluginID:     "metric-plugin",
		Name:         "Metric Plugin",
	}

	_, err := decodePluginTelemetry([]byte(`{
		"records": [{
			"event_id": "metric-event-1",
			"payload_kind": "serviceradar_metrics",
			"payload": {"metrics":[{"name":"temperature_c","value":42.5}]}
		}]
	}`), assignment)
	if err == nil {
		t.Fatal("expected JSON metric payload to be rejected")
	}
}

func TestTelemetryPayloadKindAcceptsServiceRadarMetricAliases(t *testing.T) {
	for _, value := range []string{
		"serviceradar_metrics",
		"serviceradar_metric",
		"serviceradar.metric.v1",
		"telemetry_payload_kind_serviceradar_metrics",
	} {
		got, err := telemetryPayloadKind(value)
		if err != nil {
			t.Fatalf("telemetryPayloadKind(%q) error = %v", value, err)
		}
		if got != addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS {
			t.Fatalf("telemetryPayloadKind(%q) = %v, want SERVICERADAR_METRICS", value, got)
		}
	}
}

func TestBuildPluginSignalGatewayStatusWrapsTelemetryBatch(t *testing.T) {
	signal := PluginSignalTelemetry{
		AssignmentID: testPluginAssignmentID,
		PluginID:     "axis",
		Batch: &addonpb.TelemetryBatch{
			Source: &addonpb.TelemetrySource{SourceType: "axis-camera", SourceInstance: "front-door"},
			Records: []*addonpb.TelemetryRecord{
				{
					EventId:     "event-1",
					PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
					Payload:     []byte(`{"id":"event-1"}`),
				},
			},
		},
	}

	status, size, err := buildPluginSignalGatewayStatus(signal, "agent-1", "gateway-1", "default", "kv")
	if err != nil {
		t.Fatalf("buildPluginSignalGatewayStatus() error = %v", err)
	}
	if size == 0 {
		t.Fatal("expected non-empty telemetry message")
	}
	if status.GetServiceName() != pluginSignalTelemetryServiceName {
		t.Fatalf("service_name = %q, want %q", status.GetServiceName(), pluginSignalTelemetryServiceName)
	}
	if status.GetSource() != "plugin:assign-1" {
		t.Fatalf("source = %q, want plugin:assign-1", status.GetSource())
	}

	var decoded addonpb.TelemetryBatch
	if err := gproto.Unmarshal(status.GetMessage(), &decoded); err != nil {
		t.Fatalf("unmarshal telemetry batch: %v", err)
	}
	if decoded.GetRecords()[0].GetEventId() != "event-1" {
		t.Fatalf("decoded event_id = %q, want event-1", decoded.GetRecords()[0].GetEventId())
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

func TestPluginAssignmentClassifiesActionOnlyCapability(t *testing.T) {
	assignment := newPluginAssignment(
		&proto.PluginAssignmentConfig{
			AssignmentId: "action-1",
			PluginId:     "example-inventory",
			Entrypoint:   "run_check",
			Capabilities: []string{pluginCapabilityActionOnly, pluginCapabilityActionResultIngest},
		},
		logger.NewTestLogger(),
	)

	if !assignment.isActionOnly() {
		t.Fatal("expected action-only capability to classify assignment as action-only")
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
			{
				AssignmentId: "action-1",
				PluginId:     "example-inventory",
				Entrypoint:   "run_check",
				Enabled:      true,
				IntervalSec:  60,
				TimeoutSec:   900,
				Capabilities: []string{pluginCapabilityActionOnly, pluginCapabilityActionResultIngest},
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
	if len(mgr.actions) != 1 {
		t.Fatalf("expected 1 action-only assignment, got %d", len(mgr.actions))
	}
	if _, ok := mgr.runners["scheduled-1"]; !ok {
		t.Fatalf("expected scheduled assignment to start a runner")
	}
	if _, ok := mgr.streams["streaming-1"]; !ok {
		t.Fatalf("expected streaming assignment to be cataloged separately")
	}
	if _, ok := mgr.actions["action-1"]; !ok {
		t.Fatal("expected action-only assignment to be cataloged without a runner")
	}
	if assignment, ok := mgr.lookupRunnerAssignment("action-1"); !ok || assignment.PluginID != "example-inventory" {
		t.Fatal("expected exact action lookup to find action-only assignment")
	}
}

func TestPluginManagerApplyConfigRefreshesDownloadTokenWithoutRestart(t *testing.T) {
	const rotatedDownloadToken = "token-new"

	mgr := NewPluginManager(t.Context(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	defer mgr.Stop()

	assignmentConfig := func(token string) *proto.PluginConfig {
		return &proto.PluginConfig{
			Assignments: []*proto.PluginAssignmentConfig{
				{
					AssignmentId:  "scheduled-1",
					PluginId:      "proxmox-inventory",
					Entrypoint:    "run_check",
					Enabled:       true,
					IntervalSec:   3600,
					TimeoutSec:    5,
					Capabilities:  []string{"submit_result"},
					DownloadUrl:   "https://plugins.example/download/pkg-1",
					DownloadToken: token,
				},
				{
					AssignmentId:  "streaming-1",
					PluginId:      "camera-streamer",
					Entrypoint:    "stream_camera",
					Enabled:       true,
					IntervalSec:   3600,
					TimeoutSec:    5,
					Capabilities:  []string{pluginCapabilityCameraMediaStream},
					DownloadUrl:   "https://plugins.example/download/pkg-2",
					DownloadToken: token,
				},
			},
		}
	}

	mgr.ApplyConfig(assignmentConfig("token-old"))

	mgr.mu.RLock()
	originalRunner := mgr.runners["scheduled-1"]
	mgr.mu.RUnlock()
	if originalRunner == nil {
		t.Fatal("expected scheduled runner after first apply")
	}

	// Same fingerprint, freshly minted token: must be adopted in place
	// without restarting the runner (download tokens rotate every config
	// generation and are excluded from the fingerprint).
	mgr.ApplyConfig(assignmentConfig(rotatedDownloadToken))

	mgr.mu.RLock()
	currentRunner := mgr.runners["scheduled-1"]
	streamAssignment := mgr.streams["streaming-1"]
	mgr.mu.RUnlock()

	if currentRunner != originalRunner {
		t.Fatal("expected runner to survive a download-token-only refresh")
	}

	if _, token := currentRunner.assignment.downloadCredentials(); token != rotatedDownloadToken {
		t.Fatalf("runner download token = %q, want %s", token, rotatedDownloadToken)
	}
	if streamAssignment == nil {
		t.Fatal("expected streaming assignment after apply")
	}
	if _, token := streamAssignment.downloadCredentials(); token != rotatedDownloadToken {
		t.Fatalf("stream download token = %q, want %s", token, rotatedDownloadToken)
	}
}

func TestPluginAssignmentSetDownloadCredentialsIgnoresEmptyURL(t *testing.T) {
	const rotatedDownloadToken = "token-new"

	assignment := &pluginAssignment{
		AssignmentID:  "a-1",
		DownloadURL:   "https://plugins.example/download/pkg-1",
		DownloadToken: "token-old",
	}

	assignment.setDownloadCredentials("", rotatedDownloadToken)

	downloadURL, token := assignment.downloadCredentials()
	if downloadURL != "https://plugins.example/download/pkg-1" || token != "token-old" {
		t.Fatalf("empty URL must not overwrite credentials, got url=%q token=%q", downloadURL, token)
	}

	assignment.setDownloadCredentials("https://plugins.example/download/pkg-1", rotatedDownloadToken)

	if _, token := assignment.downloadCredentials(); token != rotatedDownloadToken {
		t.Fatalf("download token = %q, want %s", token, rotatedDownloadToken)
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

func TestPluginManagerDebugSnapshotRedactsDownloadSecrets(t *testing.T) {
	mgr := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: t.TempDir(),
	})
	defer mgr.Stop()

	mgr.ApplyConfig(&proto.PluginConfig{
		Assignments: []*proto.PluginAssignmentConfig{
			{
				AssignmentId:  "scheduled-1",
				PluginId:      "proxmox-inventory",
				PackageId:     "pkg-1",
				Name:          "Proxmox Inventory",
				Entrypoint:    "run_check",
				Runtime:       "wasi-preview1",
				Enabled:       true,
				IntervalSec:   3600,
				TimeoutSec:    30,
				WasmObjectKey: "plugins/proxmox-inventory/0.1.0/pkg-1.wasm",
				ContentHash:   "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
				DownloadUrl:   "https://plugins.example/download/pkg-1?token=do-not-leak",
				DownloadToken: "secret-token",
				Capabilities:  []string{"http_request", "submit_result"},
				ParamsJson:    []byte(`{"api_token":"do-not-leak"}`),
			},
			{
				AssignmentId: "streaming-1",
				PluginId:     "camera-streamer",
				Name:         "Camera Streamer",
				Entrypoint:   "stream_camera",
				Runtime:      "wasi-preview1",
				Enabled:      true,
				Capabilities: []string{pluginCapabilityCameraMediaStream},
			},
		},
	})

	snapshot := mgr.DebugSnapshot()
	if snapshot.Engine.AssignmentsTotal != 2 || snapshot.Engine.AssignmentsAdmitted != 2 {
		t.Fatalf("unexpected engine counts: %#v", snapshot.Engine)
	}
	if len(snapshot.Assignments) != 2 {
		t.Fatalf("expected 2 assignments, got %d", len(snapshot.Assignments))
	}

	var scheduled PluginEngineAssignmentSnapshot
	for _, assignment := range snapshot.Assignments {
		if assignment.AssignmentID == "scheduled-1" {
			scheduled = assignment
		}
	}

	if scheduled.DownloadHost != "plugins.example" {
		t.Fatalf("expected redacted download host, got %q", scheduled.DownloadHost)
	}
	if !scheduled.DownloadTokenPresent {
		t.Fatalf("expected token presence flag")
	}
	if scheduled.Mode != string(pluginExecutionModeScheduled) {
		t.Fatalf("expected scheduled mode, got %q", scheduled.Mode)
	}

	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatalf("marshal debug snapshot: %v", err)
	}
	if strings.Contains(string(data), "do-not-leak") || strings.Contains(string(data), "secret-token") {
		t.Fatalf("debug snapshot leaked credential material: %s", string(data))
	}
}

func TestPluginConfigFromConfigJSONFallback(t *testing.T) {
	config := pluginConfigFromConfigJSON([]byte(`{
		"plugins": {
			"engine_limits": {
				"max_memory_mb": 256,
				"max_cpu_ms": 750,
				"max_concurrent": 3,
				"max_open_connections": 8
			},
			"assignments": [
				{
					"assignment_id": "assignment-1",
					"plugin_id": "sample-plugin",
					"package_id": "package-1",
					"version": "1.0.0",
					"name": "Sample Plugin",
					"entrypoint": "run_check",
					"runtime": "wasi-preview1",
					"outputs": "serviceradar.plugin_result.v1",
					"capabilities": ["get_config", "submit_result"],
					"params": {"endpoint": "https://api.example.test"},
					"permissions": {"allowed_domains": ["api.example.test"]},
					"resources": {"requested_memory_mb": 64},
					"enabled": true,
					"interval_sec": 60,
					"timeout_sec": 10,
					"wasm_object_key": "plugins/sample/1.0.0/package.wasm",
					"content_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
					"source_type": "first_party",
					"download_url": "https://demo-gw.serviceradar.cloud:50053/artifacts/plugins/package-1/blob/download",
					"download_token": "token"
				}
			]
		}
	}`))

	if config == nil {
		t.Fatal("expected plugin config fallback")
		return
	}
	if config.EngineLimits.GetMaxMemoryMb() != 256 ||
		config.EngineLimits.GetMaxCpuMs() != 750 ||
		config.EngineLimits.GetMaxConcurrent() != 3 ||
		config.EngineLimits.GetMaxOpenConnections() != 8 {
		t.Fatalf("unexpected engine limits: %#v", config.EngineLimits)
	}
	if len(config.Assignments) != 1 {
		t.Fatalf("expected 1 assignment, got %d", len(config.Assignments))
	}

	assignment := config.Assignments[0]
	if assignment.GetAssignmentId() != "assignment-1" ||
		assignment.GetPluginId() != "sample-plugin" ||
		assignment.GetDownloadUrl() == "" ||
		assignment.GetDownloadToken() != "token" {
		t.Fatalf("unexpected assignment: %#v", assignment)
	}
	if !json.Valid(assignment.GetParamsJson()) ||
		!strings.Contains(string(assignment.GetParamsJson()), "api.example.test") {
		t.Fatalf("params json was not preserved: %s", string(assignment.GetParamsJson()))
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

	if _, err := stream.Recv(t.Context()); err == nil || !errors.Is(err, io.EOF) {
		t.Fatalf("expected io.EOF after final chunk, got %v", err)
	}
}

func TestPluginManagerOpenCameraRelayStreamWithWazeroPlugin(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping Wazero camera stream integration in short mode")
	}

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

	if _, err := stream.Recv(t.Context()); err == nil || !errors.Is(err, io.EOF) {
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

func TestPluginManagerRevokesActiveStreamingExecutionOnRemovalOrGenerationChange(t *testing.T) {
	for _, tt := range []struct {
		name string
		next *proto.PluginConfig
	}{
		{name: "assignment removed", next: nil},
		{
			name: "assignment generation changed",
			next: &proto.PluginConfig{Assignments: []*proto.PluginAssignmentConfig{{
				AssignmentId:  "streaming-revocation",
				PluginId:      "camera-streamer",
				Name:          "Camera Streamer",
				Entrypoint:    "stream_camera",
				Runtime:       "wasi-preview1",
				Enabled:       true,
				WasmObjectKey: "camera-streamer.wasm",
				Capabilities:  []string{pluginCapabilityCameraMediaStream},
				ParamsJson:    []byte(`{"generation":2}`),
			}}},
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
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
					AssignmentId:  "streaming-revocation",
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
			manager.streams[assignment.AssignmentID] = assignment
			manager.mu.Unlock()

			started := make(chan struct{})
			cancelObserved := make(chan struct{})
			manager.streamExecutor = func(
				ctx context.Context,
				_assignment *pluginAssignment,
				_wasm []byte,
				_configJSON []byte,
				bridge *pluginCameraMediaBridge,
			) error {
				handle, err := bridge.Open(ctx, pluginCameraMediaOpenRequest{TrackID: "video"})
				if err != nil {
					return err
				}
				close(started)
				<-ctx.Done()
				close(cancelObserved)
				return bridge.Close(handle, "assignment revoked")
			}

			stream, err := manager.OpenCameraRelayStream(
				t.Context(),
				assignment.AssignmentID,
				cameraRelaySessionSpec{
					RelaySessionID:     "relay-revocation",
					AgentID:            "agent-1",
					GatewayID:          "gateway-1",
					CameraSourceID:     "camera-1",
					PluginAssignmentID: assignment.AssignmentID,
				},
			)
			if err != nil {
				t.Fatalf("OpenCameraRelayStream returned error: %v", err)
			}
			defer func() { _ = stream.Close() }()

			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("streaming execution did not start")
			}

			manager.ApplyConfig(tt.next)

			select {
			case <-cancelObserved:
			case <-time.After(time.Second):
				t.Fatal("revoked streaming assignment did not cancel its active execution")
			}
		})
	}
}

func TestPluginManagerOpenProxmoxConsoleStreamUsesStreamingBridge(t *testing.T) {
	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: t.TempDir(),
	})
	defer manager.Stop()

	wasmPath := filepath.Join(manager.localStoreDir, "proxmox-console.wasm")
	if err := os.WriteFile(wasmPath, []byte("not-real-wasm"), 0o600); err != nil {
		t.Fatalf("write wasm fixture: %v", err)
	}

	options := testConsoleAuthorityOptions()
	options.assignmentID = testPluginConsoleAssignmentID
	options.paramsJSON = `{
		"policy_id":"network-credential-rule:proxmox-rule-1:console_access",
		"policy_version":1,
		"credential_rule_id":"proxmox-rule-1",
		"credential_secret":"__SERVICERADAR_HOST_CREDENTIAL__"
	}`
	options.sshHostKeyPolicy = proxmoxSSHHostKeyPolicyKnownHosts
	options.methods = nil
	options.paths = nil
	options.ports = []int{22}
	assignment := newTestProxmoxHostAuthorityAssignment(t, options)
	assignment.Name = "Proxmox Console"
	assignment.Runtime = "wasi-preview1"
	assignment.WasmObject = "proxmox-console.wasm"

	manager.mu.Lock()
	manager.streams[testPluginConsoleAssignmentID] = assignment
	manager.mu.Unlock()

	observed := make(chan pluginProxmoxConsoleInputFrame, 2)
	manager.consoleExecutor = func(
		ctx context.Context,
		assignment *pluginAssignment,
		wasm []byte,
		configJSON []byte,
		bridge *pluginProxmoxConsoleBridge,
	) error {
		if assignment.AssignmentID != testPluginConsoleAssignmentID {
			t.Fatalf("unexpected assignment id: %s", assignment.AssignmentID)
		}
		if len(wasm) == 0 {
			t.Fatal("expected wasm bytes to be loaded")
		}

		var config map[string]any
		if err := json.Unmarshal(configJSON, &config); err != nil {
			t.Fatalf("decode console config: %v", err)
		}
		console, _ := config["console"].(map[string]any)
		if console["device_uid"] != testProxmoxControllerDeviceUID ||
			console["credential_rule_id"] != testProxmoxCredentialRuleID {
			t.Fatalf("unexpected console config: %#v", console)
		}
		target, _ := config["target"].(map[string]any)
		if target["hostname"] != testPluginConsoleHostname || target["ip"] != testPluginConsoleIP {
			t.Fatalf("unexpected console target: %#v", target)
		}

		handle, err := bridge.Open(ctx, pluginProxmoxConsoleOpenRequest{TerminalType: "xterm-256color"})
		if err != nil {
			return err
		}
		if _, err := bridge.WriteOutput(ctx, handle, []byte("login: ")); err != nil {
			return err
		}

		input, err := bridge.ReadInput(ctx, handle, time.Second)
		if err != nil {
			return err
		}
		observed <- input

		resize, err := bridge.ReadInput(ctx, handle, time.Second)
		if err != nil {
			return err
		}
		observed <- resize

		return bridge.CloseHandle(handle, "done")
	}

	spec := testProxmoxPVEConsoleSessionSpec()
	spec.SessionID = "session-1"
	spec.AgentID = "agent-1"
	spec.GatewayID = "gateway-1"
	spec.PluginAssignmentID = testPluginConsoleAssignmentID
	bindTestProxmoxSessionPolicy(t, &spec, assignment)
	spec.Target.Hostname = testPluginConsoleHostname
	spec.Target.IP = testPluginConsoleIP
	spec.Cols = 120
	spec.Rows = 40
	pty, err := manager.OpenProxmoxConsoleStream(t.Context(), spec)
	if err != nil {
		t.Fatalf("OpenProxmoxConsoleStream returned error: %v", err)
	}

	output, err := pty.Read(t.Context())
	if err != nil {
		t.Fatalf("Read returned error: %v", err)
	}
	if string(output) != "login: " {
		t.Fatalf("unexpected console output: %q", string(output))
	}

	if err := pty.Write([]byte("whoami\r")); err != nil {
		t.Fatalf("Write returned error: %v", err)
	}
	input := <-observed
	if input.FrameType != consoleFrameTypeData || string(input.Data) != "whoami\r" {
		t.Fatalf("unexpected input frame: %#v", input)
	}

	if err := pty.Resize(132, 43); err != nil {
		t.Fatalf("Resize returned error: %v", err)
	}
	resize := <-observed
	if resize.FrameType != consoleFrameTypeResize || resize.Cols != 132 || resize.Rows != 43 {
		t.Fatalf("unexpected resize frame: %#v", resize)
	}

	if _, err := pty.Read(t.Context()); err == nil || !errors.Is(err, io.EOF) {
		t.Fatalf("expected io.EOF after plugin close, got %v", err)
	}
}

func TestDecodeProxmoxConsoleOpenPayloadRequiresScopedAssignment(t *testing.T) {
	for name, data := range map[string]string{
		"both omitted":            `{"device_uid":"device-1"}`,
		"assignment omitted":      `{"device_uid":"device-1","credential_rule_id":"rule-1"}`,
		"credential rule omitted": `{"device_uid":"device-1","plugin_assignment_id":"console-1"}`,
	} {
		t.Run(name, func(t *testing.T) {
			_, err := decodeProxmoxConsoleOpenPayload(&proto.ConsoleFrame{
				SessionId: "session-1",
				FrameType: consoleFrameTypeOpen,
				Data:      []byte(data),
			})
			if !errors.Is(err, errProxmoxConsoleAssignmentScopeRequired) {
				t.Fatalf("expected scoped assignment error, got %v", err)
			}
		})
	}
}

func TestDecodeProxmoxConsoleOpenPayloadRequiresProtoPolicyBinding(t *testing.T) {
	fingerprint := strings.Repeat("a", 64)
	payload := []byte(`{
		"device_uid":"device-1",
		"credential_rule_id":"rule-1",
		"plugin_assignment_id":"console-1",
		"assignment_policy_version":99,
		"assignment_policy_fingerprint":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	}`)

	valid, err := decodeProxmoxConsoleOpenPayload(&proto.ConsoleFrame{
		SessionId:                   "session-1",
		FrameType:                   consoleFrameTypeOpen,
		Data:                        payload,
		AssignmentPolicyVersion:     7,
		AssignmentPolicyFingerprint: fingerprint,
	})
	if err != nil {
		t.Fatalf("valid protobuf policy binding was rejected: %v", err)
	}
	if valid.AssignmentPolicyVersion != 7 || valid.AssignmentPolicyFingerprint != fingerprint {
		t.Fatalf("decoded policy binding = %d %q", valid.AssignmentPolicyVersion, valid.AssignmentPolicyFingerprint)
	}

	for name, mutate := range map[string]func(*proto.ConsoleFrame){
		"missing version": func(frame *proto.ConsoleFrame) {
			frame.AssignmentPolicyVersion = 0
		},
		"missing fingerprint": func(frame *proto.ConsoleFrame) {
			frame.AssignmentPolicyFingerprint = ""
		},
		"malformed fingerprint": func(frame *proto.ConsoleFrame) {
			frame.AssignmentPolicyFingerprint = strings.Repeat("A", 64)
		},
	} {
		t.Run(name, func(t *testing.T) {
			frame := &proto.ConsoleFrame{
				SessionId:                   "session-1",
				FrameType:                   consoleFrameTypeOpen,
				Data:                        payload,
				AssignmentPolicyVersion:     7,
				AssignmentPolicyFingerprint: fingerprint,
			}
			mutate(frame)

			_, err := decodeProxmoxConsoleOpenPayload(frame)
			if !errors.Is(err, errProxmoxConsoleAssignmentPolicyBindingRequired) {
				t.Fatalf("policy binding error = %v", err)
			}
		})
	}
}

func TestNormalizePluginPayload(t *testing.T) {
	pl := &PushLoop{}
	observed := time.Date(2025, 1, 1, 10, 0, 0, 0, time.UTC)

	result := PluginResult{
		AssignmentID: testPluginAssignmentID,
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
	if labels["assignment_id"] != testPluginAssignmentID {
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

func TestNormalizePluginPayloadStripsLegacyMetricArrays(t *testing.T) {
	pl := &PushLoop{logger: logger.NewTestLogger()}
	result := PluginResult{
		Payload: []byte(`{"status":"ok","summary":"all good","metrics":[{"name":"latency_ms","value":3}]}`),
	}

	data, available, err := pl.normalizePluginPayload(result, "agent-1", "default")
	if err != nil {
		t.Fatalf("expected legacy metrics to be stripped, got error %v", err)
	}
	if !available {
		t.Fatalf("expected available=true for ok status")
	}

	var decoded map[string]interface{}
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("decode normalized payload: %v", err)
	}
	if _, ok := decoded["metrics"]; ok {
		t.Fatalf("expected legacy 'metrics' key to be dropped, still present")
	}
}

func TestNormalizePluginPayloadMapsFailedStatus(t *testing.T) {
	const expectedStatus = "CRITICAL"

	pl := &PushLoop{}
	result := PluginResult{
		Payload: []byte(`{"status":"failed","summary":"plugin execution failed"}`),
	}

	data, available, err := pl.normalizePluginPayload(result, "agent-1", "default")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if available {
		t.Fatalf("expected available=false for failed status")
	}

	var payload map[string]interface{}
	if err := json.Unmarshal(data, &payload); err != nil {
		t.Fatalf("failed to unmarshal payload: %v", err)
	}

	if payload["status"] != expectedStatus {
		t.Fatalf("expected %s status, got %#v", expectedStatus, payload["status"])
	}
}

func TestBuildPluginErrorPayload(t *testing.T) {
	pl := &PushLoop{}
	result := PluginResult{
		AssignmentID: testPluginAssignmentID,
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
	wsURL, headers, insecureSkipVerify, err := parseWebSocketConnectPayload([]byte("ws://camera.local/ws"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if wsURL != "ws://camera.local/ws" {
		t.Fatalf("unexpected ws url: %s", wsURL)
	}
	if headers != nil {
		t.Fatalf("expected nil headers for URL-only payload")
	}
	if insecureSkipVerify {
		t.Fatalf("expected insecure TLS to default false")
	}
}

func TestParseWebSocketConnectPayloadWithHeaders(t *testing.T) {
	raw := []byte(`{"url":"wss://camera.local/ws","headers":{"Authorization":"Basic abc","X-Test":"1"}}`)
	wsURL, headers, insecureSkipVerify, err := parseWebSocketConnectPayload(raw)
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
	if insecureSkipVerify {
		t.Fatalf("expected insecure TLS to default false")
	}
}

func TestParseWebSocketConnectPayloadInvalidJSON(t *testing.T) {
	_, _, _, err := parseWebSocketConnectPayload([]byte("{bad-json"))
	if err == nil {
		t.Fatalf("expected parse error for invalid JSON payload")
	}
}

func TestParseWebSocketConnectPayloadEmptyURL(t *testing.T) {
	_, _, _, err := parseWebSocketConnectPayload([]byte(`{"url":""}`))
	if err == nil {
		t.Fatalf("expected error for empty URL")
	}
}

func TestParseWebSocketConnectPayloadSkipsBlankHeaders(t *testing.T) {
	raw := []byte(`{"url":"ws://camera.local/ws","headers":{"":"x","  ":"y"}}`)
	wsURL, headers, insecureSkipVerify, err := parseWebSocketConnectPayload(raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if wsURL == "" {
		t.Fatalf("expected non-empty URL")
	}
	if len(headers) != 0 {
		t.Fatalf("expected blank headers to be omitted")
	}
	if insecureSkipVerify {
		t.Fatalf("expected insecure TLS to default false")
	}
}

func TestParseWebSocketConnectPayloadInsecureTLS(t *testing.T) {
	raw := []byte(`{"url":"wss://camera.local/ws","insecure_skip_verify":true}`)
	wsURL, headers, insecureSkipVerify, err := parseWebSocketConnectPayload(raw)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if wsURL != "wss://camera.local/ws" {
		t.Fatalf("unexpected ws url: %s", wsURL)
	}
	if headers != nil {
		t.Fatalf("expected nil headers")
	}
	if !insecureSkipVerify {
		t.Fatalf("expected insecure TLS flag to be preserved")
	}
}

// A wasm plugin must not be able to select the discovery payload kind.
//
// DISCOVERY_V1 carries device observations about OTHER hosts into the inventory
// pipeline. Plugins already have a scoped route there (`plugin-result` into
// DeviceDiscoveryIngestor); this one is for native add-ons and would let
// plugin-supplied bytes mint device identity.
func TestTelemetryPayloadKindRefusesDiscoveryFromPlugins(t *testing.T) {
	t.Parallel()

	for _, value := range []any{
		float64(addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1),
		"discovery_v1",
		"telemetry_payload_kind_discovery_v1",
	} {
		kind, err := telemetryPayloadKind(value)
		if err == nil {
			t.Fatalf("telemetryPayloadKind(%v) = %v, want an error", value, kind)
		}

		if kind != addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_UNSPECIFIED {
			t.Fatalf("telemetryPayloadKind(%v) = %v, want UNSPECIFIED on refusal", value, kind)
		}
	}
}
