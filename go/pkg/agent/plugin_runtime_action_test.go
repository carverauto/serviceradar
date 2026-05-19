package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const (
	actionFixtureAssignmentID           = "action-fixture-1"
	actionFixturePluginID               = "hello-wasm-action"
	actionFixtureObjectKey              = "hello_wasm.wasm"
	actionFixtureInvocationID           = "018f2fd1-f0ff-7cf0-9dc0-000000000001"
	sampleNorthboundFixtureAssignmentID = "sample-northbound-action"
	sampleNorthboundFixturePluginID     = "sample-northbound-nms"
	sampleNorthboundFixtureObjectKey    = "sample_northbound.wasm"
)

func TestPluginManagerRunActionWithFixtureWasm(t *testing.T) {
	manager := newActionFixtureManager(t, actionFixtureObjectKey, &proto.PluginAssignmentConfig{
		AssignmentId:  actionFixtureAssignmentID,
		PluginId:      actionFixturePluginID,
		PackageId:     "fixture-package",
		Name:          "Hello Wasm Action",
		Entrypoint:    "run_check",
		Runtime:       "wasi-preview1",
		Enabled:       true,
		TimeoutSec:    5,
		WasmObjectKey: actionFixtureObjectKey,
		Capabilities:  []string{"get_config", "log", "submit_result"},
		ParamsJson:    []byte(`{"plugin_setting":"base-config"}`),
	})
	defer manager.Stop()

	payload := json.RawMessage(`{
		"invocation_id":"` + actionFixtureInvocationID + `",
		"descriptor_id":"fixture.hello.run",
		"targets":[{"kind":"device","device_uid":"sr:device-1","device_ip":"192.0.2.10"}],
		"input_values":{"reason":"integration-test"}
	}`)

	result, err := manager.RunAction(t.Context(), actionFixtureAssignmentID, payload, 10*time.Second)
	if err != nil {
		t.Fatalf("RunAction returned error: %v", err)
	}

	var decoded map[string]interface{}
	if err := json.Unmarshal(result, &decoded); err != nil {
		t.Fatalf("decode action result: %v\npayload: %s", err, result)
	}

	if got := decoded["status"]; got != "OK" {
		t.Fatalf("status = %v, want OK; payload: %s", got, result)
	}
	if got := decoded["summary"]; got != "hello from wasm (config received)" {
		t.Fatalf("summary = %v, want fixture config confirmation; payload: %s", got, result)
	}
	if queued := manager.DrainResults(1); len(queued) != 0 {
		t.Fatalf("action result should not be queued as scheduled output, got %d queued result(s)", len(queued))
	}
}

func TestPluginManagerRunActionWithSampleNorthboundWasm(t *testing.T) {
	manager := newActionFixtureManager(t, sampleNorthboundFixtureObjectKey, &proto.PluginAssignmentConfig{
		AssignmentId:  sampleNorthboundFixtureAssignmentID,
		PluginId:      sampleNorthboundFixturePluginID,
		PackageId:     "sample-northbound-package",
		Name:          "Sample Northbound NMS",
		Entrypoint:    "run_check",
		Runtime:       "wasi-preview1",
		Enabled:       true,
		TimeoutSec:    5,
		WasmObjectKey: sampleNorthboundFixtureObjectKey,
		Capabilities:  []string{"get_config", "log", "submit_result"},
		ParamsJson: []byte(`{
			"api_base_url": "mock://lab-nms",
			"inventory_prefix": "lab",
			"interface_default_vlan": 410
		}`),
	})
	defer manager.Stop()

	deviceResult := runFixtureAction(t, manager, json.RawMessage(`{
		"schema": "serviceradar.northbound_action_invocation.v1",
		"invocation_id": "inv-device-1",
		"action_id": "sample.device.lookup",
		"targets": [{
			"kind": "device",
			"device_uid": "sr:device-1",
			"device_name": "edge-sw01",
			"device_ip": "192.0.2.10",
			"model": "EX4300"
		}],
		"input_values": {
			"query_mode": "full",
			"include_neighbors": true
		}
	}`))

	if got := deviceResult["status"]; got != "succeeded" {
		t.Fatalf("device status = %v, want succeeded; payload: %#v", got, deviceResult)
	}

	deviceTarget := firstTargetResult(t, deviceResult)
	deviceTargetResult := targetResultMap(t, deviceTarget)

	if got := deviceTargetResult["api_query"]; got != "GET /devices/192.0.2.10?mode=full" {
		t.Fatalf("device api query = %v", got)
	}
	if got := deviceTargetResult["external_inventory_id"]; got != "lab-sr-device-1" {
		t.Fatalf("device inventory id = %v", got)
	}
	if got := deviceTargetResult["neighbors_included"]; got != true {
		t.Fatalf("device neighbors_included = %v", got)
	}

	interfaceResult := runFixtureAction(t, manager, json.RawMessage(`{
		"schema": "serviceradar.northbound_action_invocation.v1",
		"invocation_id": "inv-interface-1",
		"action_id": "sample.interface.audit",
		"targets": [{
			"kind": "interface",
			"device_uid": "sr:device-2",
			"device_ip": "198.51.100.20",
			"interface_uid": "if-2",
			"if_name": "Gi1/0/12",
			"if_admin_status": "up",
			"if_oper_status": "down"
		}],
		"input_values": {
			"operation": "simulate_remediation",
			"dry_run": true,
			"change_ticket": "CHG-123"
		}
	}`))

	if got := interfaceResult["status"]; got != "succeeded" {
		t.Fatalf("interface status = %v, want succeeded; payload: %#v", got, interfaceResult)
	}

	interfaceTarget := firstTargetResult(t, interfaceResult)
	interfaceTargetResult := targetResultMap(t, interfaceTarget)

	if got := interfaceTargetResult["api_query"]; got != "POST /devices/198.51.100.20/interfaces/Gi1/0/12/actions/simulate_remediation" {
		t.Fatalf("interface api query = %v", got)
	}
	if got := interfaceTargetResult["vlan"]; got != float64(410) {
		t.Fatalf("interface vlan = %v", got)
	}
	if got := interfaceTargetResult["remediation_preview"]; got != "would run simulate_remediation for Gi1/0/12" {
		t.Fatalf("interface remediation preview = %v", got)
	}

	if queued := manager.DrainResults(1); len(queued) != 0 {
		t.Fatalf("action results should not be queued as scheduled output, got %d queued result(s)", len(queued))
	}
}

func newActionFixtureManager(t *testing.T, objectKey string, cfg *proto.PluginAssignmentConfig) *PluginManager {
	t.Helper()

	wasmPath := locateActionFixtureWasm(t, objectKey)
	if wasmPath == "" {
		t.Skipf("%s fixture not found; run with Bazel target //go/pkg/agent:plugin_runtime_action_test", objectKey)
	}

	wasm, err := os.ReadFile(wasmPath)
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}

	localStore := t.TempDir()
	if err := os.WriteFile(filepath.Join(localStore, objectKey), wasm, 0o600); err != nil {
		t.Fatalf("stage wasm fixture: %v", err)
	}

	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: localStore,
	})

	assignment := newPluginAssignment(cfg, logger.NewTestLogger())
	runner := newPluginRunner(manager, assignment)
	close(runner.done)

	manager.mu.Lock()
	manager.runners[cfg.AssignmentId] = runner
	manager.mu.Unlock()

	return manager
}

func runFixtureAction(t *testing.T, manager *PluginManager, payload json.RawMessage) map[string]interface{} {
	t.Helper()

	result, err := manager.RunAction(t.Context(), sampleNorthboundFixtureAssignmentID, payload, 10*time.Second)
	if err != nil {
		t.Fatalf("RunAction returned error: %v", err)
	}

	var decoded map[string]interface{}
	if err := json.Unmarshal(result, &decoded); err != nil {
		t.Fatalf("decode action result: %v\npayload: %s", err, result)
	}

	return decoded
}

func firstTargetResult(t *testing.T, decoded map[string]interface{}) map[string]interface{} {
	t.Helper()

	targets, ok := decoded["targets"].([]interface{})
	if !ok || len(targets) != 1 {
		t.Fatalf("targets = %#v, want one target result", decoded["targets"])
	}

	target, ok := targets[0].(map[string]interface{})
	if !ok {
		t.Fatalf("target result = %#v, want map", targets[0])
	}

	return target
}

func targetResultMap(t *testing.T, target map[string]interface{}) map[string]interface{} {
	t.Helper()

	result, ok := target["result"].(map[string]interface{})
	if !ok {
		t.Fatalf("target result payload = %#v, want map", target["result"])
	}

	return result
}

func locateActionFixtureWasm(t *testing.T, objectKey string) string {
	t.Helper()

	if override := strings.TrimSpace(os.Getenv("SERVICERADAR_ACTION_WASM_PATH")); override != "" {
		if _, err := os.Stat(override); err == nil {
			return override
		}
		t.Fatalf("SERVICERADAR_ACTION_WASM_PATH points to missing file %q", override)
	}

	if manifest := strings.TrimSpace(os.Getenv("RUNFILES_MANIFEST_FILE")); manifest != "" {
		if found := findActionFixtureInManifest(t, manifest, objectKey); found != "" {
			return found
		}
	}

	if testSrcDir := strings.TrimSpace(os.Getenv("TEST_SRCDIR")); testSrcDir != "" {
		for _, workspace := range []string{
			strings.TrimSpace(os.Getenv("TEST_WORKSPACE")),
			"_main",
		} {
			if workspace == "" {
				continue
			}
			candidate := filepath.Join(testSrcDir, workspace, "build", "wasm_plugins", objectKey)
			if _, err := os.Stat(candidate); err == nil {
				return candidate
			}
		}
	}

	return ""
}

func findActionFixtureInManifest(t *testing.T, manifestPath, objectKey string) string {
	t.Helper()

	data, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatalf("read Bazel runfiles manifest: %v", err)
	}

	for _, line := range strings.Split(string(data), "\n") {
		runfile, target, ok := strings.Cut(line, " ")
		if !ok {
			continue
		}
		if strings.HasSuffix(runfile, "build/wasm_plugins/"+objectKey) {
			if _, err := os.Stat(target); err == nil {
				return target
			}
		}
	}

	return ""
}
