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
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	gproto "google.golang.org/protobuf/proto"
)

const provenanceTestWasmObject = "example-check.wasm"

const provenanceTestVersion = "2.0.0"

// A rollout gate trusts a result as evidence about a package only if the host,
// not the plugin, says which assignment, package and module produced it. The
// plugin here claims another identity everywhere its payload can reach.
func TestPluginResultProvenanceIsHostStampedAndUnforgeable(t *testing.T) {
	forgedHash := strings.Repeat("0", 64)
	payload := []byte(`{"status":"OK","summary":"example check passed",` +
		`"labels":{"assignment_id":"forged-assignment","plugin_package_id":"forged-package",` +
		`"content_hash":"` + forgedHash + `"},` +
		`"plugin_provenance":{"assignment_id":"forged-assignment","plugin_package_id":"forged-package",` +
		`"plugin_version":"9.9.9","content_hash":"` + forgedHash + `"}}`)
	module := writeProvenanceTestModule(t, payload)

	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: filepath.Dir(module.path),
	})
	t.Cleanup(manager.Stop)

	manager.ApplyConfig(&proto.PluginConfig{
		Assignments: []*proto.PluginAssignmentConfig{
			provenanceTestAssignment("assignment-scheduled-1", module.hex, "submit_result"),
			provenanceTestAssignment(
				"assignment-action-1",
				module.hex,
				"submit_result",
				pluginCapabilityActionOnly,
				pluginCapabilityActionResultIngest,
			),
		},
	})

	// The scheduled runner executes once immediately on start.
	scheduled := receivePluginResult(t, manager)

	if _, err := manager.RunAction(t.Context(), "assignment-action-1", json.RawMessage(`{}`), 5*time.Second); err != nil {
		t.Fatalf("RunAction: %v", err)
	}
	action := receivePluginResult(t, manager)

	loop := &PushLoop{logger: logger.NewTestLogger()}
	for _, result := range []PluginResult{scheduled, action} {
		status := loop.buildPluginGatewayStatus(result, "agent-1", "default", "")
		want := &proto.PluginResultProvenance{
			AssignmentId:    result.AssignmentID,
			PluginId:        "example-check",
			PluginPackageId: "example-check-package-2",
			PluginVersion:   provenanceTestVersion,
			ContentHash:     module.hex,
		}
		if !gproto.Equal(status.GetPluginProvenance(), want) {
			t.Fatalf("%s provenance = %v, want %v", result.AssignmentID, status.GetPluginProvenance(), want)
		}
	}
	if scheduled.AssignmentID != "assignment-scheduled-1" || action.AssignmentID != "assignment-action-1" {
		t.Fatalf("result assignments = %q, %q", scheduled.AssignmentID, action.AssignmentID)
	}
}

// Assignments of one plugin owned by different credential rules reach the
// agent together. Each one runs as its own scheduled instance, and its results
// carry its own assignment id.
func TestPluginManagerRunsOneScheduledInstancePerAssignmentOfOnePlugin(t *testing.T) {
	module := writeProvenanceTestModule(t, []byte(`{"status":"OK","summary":"example check passed"}`))

	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: filepath.Dir(module.path),
	})
	t.Cleanup(manager.Stop)

	first := provenanceTestAssignment("assignment-owner-a", module.hex, "submit_result")
	first.ParamsJson = []byte(`{"base_url":"https://controller-a.example.com"}`)
	second := provenanceTestAssignment("assignment-owner-b", module.hex, "submit_result")
	second.ParamsJson = []byte(`{"base_url":"https://controller-b.example.com"}`)

	manager.ApplyConfig(&proto.PluginConfig{Assignments: []*proto.PluginAssignmentConfig{first, second}})

	// Each scheduled runner executes once immediately on start.
	got := map[string]bool{}
	for range 2 {
		result := receivePluginResult(t, manager)
		if result.PluginID != "example-check" {
			t.Fatalf("result plugin = %q, want example-check", result.PluginID)
		}
		got[result.AssignmentID] = true
	}
	if !got["assignment-owner-a"] || !got["assignment-owner-b"] {
		t.Fatalf("results came from assignments %v, want both owners", got)
	}
}

// Engine telemetry tells a rollout which module each assignment actually
// loaded, and why a candidate that never loaded failed.
func TestPluginEngineTelemetryReportsPerAssignmentModuleLoad(t *testing.T) {
	module := writeProvenanceTestModule(t, []byte(`{"status":"OK","summary":"example check passed"}`))
	wrongHash := strings.Repeat("ab", 32)

	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: filepath.Dir(module.path),
	})
	t.Cleanup(manager.Stop)

	manager.ApplyConfig(&proto.PluginConfig{
		Assignments: []*proto.PluginAssignmentConfig{
			provenanceTestAssignment("assignment-loaded-1", module.hex, "submit_result", pluginCapabilityActionOnly),
			provenanceTestAssignment("assignment-mismatch-1", wrongHash, "submit_result", pluginCapabilityActionOnly),
		},
	})

	if got := telemetryAssignmentLoads(t, manager); got["assignment-loaded-1"]["status"] != pluginLoadStatusPending {
		t.Fatalf("load status before any run = %v, want pending", got["assignment-loaded-1"])
	}

	if _, err := manager.RunAction(t.Context(), "assignment-loaded-1", json.RawMessage(`{}`), 5*time.Second); err != nil {
		t.Fatalf("RunAction loaded: %v", err)
	}
	if _, err := manager.RunAction(
		t.Context(), "assignment-mismatch-1", json.RawMessage(`{}`), 5*time.Second,
	); !errors.Is(err, errContentHashMismatch) {
		t.Fatalf("RunAction mismatch error = %v, want content hash mismatch", err)
	}

	loads := telemetryAssignmentLoads(t, manager)
	loaded := loads["assignment-loaded-1"]
	if loaded["status"] != pluginLoadStatusLoaded ||
		loaded["content_hash"] != module.hex ||
		loaded["plugin_package_id"] != "example-check-package-2" ||
		loaded["plugin_version"] != provenanceTestVersion {
		t.Fatalf("loaded assignment telemetry = %v", loaded)
	}
	failed := loads["assignment-mismatch-1"]
	if failed["status"] != pluginLoadStatusFailed ||
		failed["reason"] != "content_hash_mismatch" ||
		failed["content_hash"] != "" {
		t.Fatalf("mismatched assignment telemetry = %v", failed)
	}
}

// A load outcome describes one config generation. Re-applying an assignment
// with a new package version over the same module bytes must not inherit the
// old generation's "loaded" status, and a load that completes for a superseded
// or removed generation must not overwrite or resurrect state.
func TestPluginAssignmentLoadIsBoundToConfigGeneration(t *testing.T) {
	module := writeProvenanceTestModule(t, []byte(`{"status":"OK","summary":"example check passed"}`))
	const assignmentID = "assignment-rollout-1"

	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: filepath.Dir(module.path),
	})
	t.Cleanup(manager.Stop)

	applyVersion := func(version string) *pluginAssignment {
		t.Helper()
		config := provenanceTestAssignment(assignmentID, module.hex, "submit_result", pluginCapabilityActionOnly)
		config.Version = version
		manager.ApplyConfig(&proto.PluginConfig{Assignments: []*proto.PluginAssignmentConfig{config}})
		for _, item := range manager.configuredAssignments() {
			if item.assignment.AssignmentID == assignmentID {
				return item.assignment
			}
		}
		t.Fatalf("assignment %s not configured after ApplyConfig", assignmentID)
		return nil
	}

	first := applyVersion(provenanceTestVersion)
	if _, err := manager.RunAction(t.Context(), assignmentID, json.RawMessage(`{}`), 5*time.Second); err != nil {
		t.Fatalf("RunAction 2.0.0: %v", err)
	}
	if got := telemetryAssignmentLoads(t, manager)[assignmentID]; got["status"] != pluginLoadStatusLoaded ||
		got["plugin_version"] != provenanceTestVersion || got["content_hash"] != module.hex {
		t.Fatalf("telemetry after 2.0.0 load = %v", got)
	}

	second := applyVersion("2.1.0")
	if first.generation == second.generation {
		t.Fatalf("re-applied config kept generation %q; test cannot distinguish generations", first.generation)
	}
	if got := telemetryAssignmentLoads(t, manager)[assignmentID]; got["status"] != pluginLoadStatusPending ||
		got["plugin_version"] != "2.1.0" || got["content_hash"] != "" {
		t.Fatalf("telemetry after re-apply = %v, want pending 2.1.0 with no hash", got)
	}

	// A prefetch for the superseded generation completes late.
	manager.recordAssignmentLoad(first, pluginModule{contentHash: module.hex}, nil)
	if got := telemetryAssignmentLoads(t, manager)[assignmentID]; got["status"] != pluginLoadStatusPending {
		t.Fatalf("stale completion changed current generation telemetry: %v", got)
	}

	if _, err := manager.RunAction(t.Context(), assignmentID, json.RawMessage(`{}`), 5*time.Second); err != nil {
		t.Fatalf("RunAction 2.1.0: %v", err)
	}
	if got := telemetryAssignmentLoads(t, manager)[assignmentID]; got["status"] != pluginLoadStatusLoaded ||
		got["plugin_version"] != "2.1.0" || got["content_hash"] != module.hex {
		t.Fatalf("telemetry after 2.1.0 load = %v", got)
	}

	// A failure that completes late for the superseded generation must not
	// overwrite the current generation's success either.
	manager.recordAssignmentLoad(first, pluginModule{}, errContentHashMismatch)
	if got := telemetryAssignmentLoads(t, manager)[assignmentID]; got["status"] != pluginLoadStatusLoaded {
		t.Fatalf("stale failure overwrote current generation telemetry: %v", got)
	}

	// Once the assignment is removed, a late completion must not recreate state.
	manager.ApplyConfig(&proto.PluginConfig{})
	manager.recordAssignmentLoad(second, pluginModule{contentHash: module.hex}, nil)
	manager.stateMu.Lock()
	_, resurrected := manager.states[assignmentID]
	manager.stateMu.Unlock()
	if resurrected {
		t.Fatalf("late load for removed assignment recreated its state")
	}
}

type provenanceTestModule struct {
	path string
	hex  string
}

func writeProvenanceTestModule(t *testing.T, payload []byte) provenanceTestModule {
	t.Helper()

	wasm := submitResultTestModule(payload)
	path := filepath.Join(t.TempDir(), provenanceTestWasmObject)
	if err := os.WriteFile(path, wasm, 0o600); err != nil {
		t.Fatalf("write test module: %v", err)
	}
	sum := sha256.Sum256(wasm)

	return provenanceTestModule{path: path, hex: hex.EncodeToString(sum[:])}
}

func provenanceTestAssignment(assignmentID, contentHash string, capabilities ...string) *proto.PluginAssignmentConfig {
	return &proto.PluginAssignmentConfig{
		AssignmentId:  assignmentID,
		PluginId:      "example-check",
		PackageId:     "example-check-package-2",
		Version:       provenanceTestVersion,
		Name:          "Example Check",
		Entrypoint:    "run_check",
		Enabled:       true,
		IntervalSec:   3600,
		TimeoutSec:    5,
		Capabilities:  capabilities,
		WasmObjectKey: provenanceTestWasmObject,
		ContentHash:   contentHash,
	}
}

func receivePluginResult(t *testing.T, manager *PluginManager) PluginResult {
	t.Helper()

	select {
	case result := <-manager.results:
		return result
	case <-time.After(5 * time.Second):
		t.Fatal("no plugin result queued within 5s")
		return PluginResult{}
	}
}

func telemetryAssignmentLoads(t *testing.T, manager *PluginManager) map[string]map[string]any {
	t.Helper()

	data, _ := buildPluginTelemetryPayload(manager.Snapshot(), "agent-1", "default")
	var decoded struct {
		AssignmentLoads []map[string]any `json:"assignment_loads"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("decode telemetry: %v", err)
	}

	loads := make(map[string]map[string]any, len(decoded.AssignmentLoads))
	for _, load := range decoded.AssignmentLoads {
		id, _ := load["assignment_id"].(string)
		loads[id] = load
	}

	return loads
}

// submitResultTestModule returns a Wasm module whose run_check entrypoint hands
// payload to the host submit_result function.
func submitResultTestModule(payload []byte) []byte {
	section := func(id byte, content []byte) []byte {
		return append(append([]byte{id}, wasmULEB128(uint32(len(content)))...), content...)
	}
	name := func(value string) []byte {
		return append(wasmULEB128(uint32(len(value))), value...)
	}

	types := []byte{
		0x02,
		0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // submit_result: (i32, i32) -> i32
		0x60, 0x00, 0x00, // run_check: () -> ()
	}

	imports := append([]byte{0x01}, name("env")...)
	imports = append(imports, name("submit_result")...)
	imports = append(imports, 0x00, 0x00) // function import of type 0

	functions := []byte{0x01, 0x01}    // one function of type 1
	memory := []byte{0x01, 0x00, 0x01} // one memory, min one page

	exports := append([]byte{0x02}, name("memory")...)
	exports = append(exports, 0x02, 0x00)
	exports = append(exports, name("run_check")...)
	exports = append(exports, 0x00, 0x01) // function index 1 (after the import)

	body := make([]byte, 0, 16)
	body = append(body, 0x00, 0x41, 0x00, 0x41) // no locals; i32.const 0; i32.const len
	body = append(body, wasmSLEB128(int32(len(payload)))...)
	body = append(body, 0x10, 0x00, 0x1a, 0x0b) // call submit_result; drop; end
	code := append([]byte{0x01}, wasmULEB128(uint32(len(body)))...)
	code = append(code, body...)

	data := make([]byte, 0, 10+len(payload))
	data = append(data, 0x01, 0x00, 0x41, 0x00, 0x0b) // active segment at offset 0
	data = append(data, wasmULEB128(uint32(len(payload)))...)
	data = append(data, payload...)

	module := []byte{0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00}
	for _, s := range [][]byte{
		section(1, types),
		section(2, imports),
		section(3, functions),
		section(5, memory),
		section(7, exports),
		section(10, code),
		section(11, data),
	} {
		module = append(module, s...)
	}

	return module
}

func wasmULEB128(value uint32) []byte {
	var out []byte
	for {
		b := byte(value & 0x7f)
		value >>= 7
		if value == 0 {
			return append(out, b)
		}
		out = append(out, b|0x80)
	}
}

func wasmSLEB128(value int32) []byte {
	var out []byte
	for {
		b := byte(value & 0x7f)
		value >>= 7
		if (value == 0 && b&0x40 == 0) || (value == -1 && b&0x40 != 0) {
			return append(out, b)
		}
		out = append(out, b|0x80)
	}
}
