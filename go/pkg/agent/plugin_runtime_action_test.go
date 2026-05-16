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
	actionFixtureAssignmentID = "action-fixture-1"
	actionFixturePluginID     = "hello-wasm-action"
	actionFixtureObjectKey    = "hello_wasm.wasm"
	actionFixtureInvocationID = "018f2fd1-f0ff-7cf0-9dc0-000000000001"
)

func TestPluginManagerRunActionWithFixtureWasm(t *testing.T) {
	wasmPath := locateActionFixtureWasm(t)
	if wasmPath == "" {
		t.Skip("hello_wasm.wasm fixture not found; run with Bazel target //go/pkg/agent:plugin_runtime_action_test")
	}

	wasm, err := os.ReadFile(wasmPath)
	if err != nil {
		t.Fatalf("read wasm fixture: %v", err)
	}

	localStore := t.TempDir()
	if err := os.WriteFile(filepath.Join(localStore, actionFixtureObjectKey), wasm, 0o600); err != nil {
		t.Fatalf("stage wasm fixture: %v", err)
	}

	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: localStore,
	})
	defer manager.Stop()

	assignment := newPluginAssignment(&proto.PluginAssignmentConfig{
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
	}, logger.NewTestLogger())

	runner := newPluginRunner(manager, assignment)
	close(runner.done)

	manager.mu.Lock()
	manager.runners[actionFixtureAssignmentID] = runner
	manager.mu.Unlock()

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

func locateActionFixtureWasm(t *testing.T) string {
	t.Helper()

	if override := strings.TrimSpace(os.Getenv("SERVICERADAR_ACTION_WASM_PATH")); override != "" {
		if _, err := os.Stat(override); err == nil {
			return override
		}
		t.Fatalf("SERVICERADAR_ACTION_WASM_PATH points to missing file %q", override)
	}

	if manifest := strings.TrimSpace(os.Getenv("RUNFILES_MANIFEST_FILE")); manifest != "" {
		if found := findActionFixtureInManifest(t, manifest); found != "" {
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
			candidate := filepath.Join(testSrcDir, workspace, "build", "wasm_plugins", actionFixtureObjectKey)
			if _, err := os.Stat(candidate); err == nil {
				return candidate
			}
		}
	}

	return ""
}

func findActionFixtureInManifest(t *testing.T, manifestPath string) string {
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
		if strings.HasSuffix(runfile, "build/wasm_plugins/"+actionFixtureObjectKey) {
			if _, err := os.Stat(target); err == nil {
				return target
			}
		}
	}

	return ""
}
