package agent

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
	"github.com/tetratelabs/wazero/sys"
)

func TestPluginDownloadUsesHeaderToken(t *testing.T) {
	t.Parallel()

	const expectedToken = "plugin-token-123"
	expectedBody := []byte("wasm-binary")

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("expected POST, got %s", r.Method)
		}
		if got := r.Header.Get("X-ServiceRadar-Plugin-Token"); got != expectedToken {
			t.Fatalf("expected plugin token header %q, got %q", expectedToken, got)
		}
		_, _ = w.Write(expectedBody)
	}))
	defer server.Close()

	manager := NewPluginManager(context.Background(), PluginManagerConfig{
		Logger: logger.NewTestLogger(),
	})
	defer manager.Stop()

	data, err := manager.downloadWasm(context.Background(), &pluginAssignment{
		DownloadURL:   server.URL,
		DownloadToken: expectedToken,
	})
	if err != nil {
		t.Fatalf("downloadWasm returned error: %v", err)
	}
	if string(data) != string(expectedBody) {
		t.Fatalf("unexpected body: %q", string(data))
	}
}

func TestExecuteWithWasmHarness(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping: WASM execution is too slow for short mode")
	}

	wasmPath := os.Getenv("WASM_PATH")
	if wasmPath == "" {
		_, thisFile, _, ok := runtime.Caller(0)
		if !ok {
			t.Skip("unable to resolve repo root; set WASM_PATH to a wasm file")
		}
		repoRoot := filepath.Dir(filepath.Dir(filepath.Dir(thisFile)))
		wasmPath = filepath.Join(repoRoot, "tools", "wasm-plugin-harness", "dist", "plugin.wasm")
	}

	if _, err := os.Stat(wasmPath); err != nil {
		t.Skipf("wasm file not found at %s (run tools/wasm-plugin-harness/build.sh or set WASM_PATH)", wasmPath)
	}

	wasm, err := os.ReadFile(wasmPath)
	if err != nil {
		t.Fatalf("read wasm: %v", err)
	}

	manager := NewPluginManager(context.Background(), PluginManagerConfig{
		Logger: logger.NewTestLogger(),
	})
	defer manager.Stop()

	assignment := &pluginAssignment{
		AssignmentID: "local-harness",
		PluginID:     "local-harness",
		Name:         "local-harness",
		Entrypoint:   "run_check",
		Runtime:      "wasi-preview1",
		Capabilities: map[string]bool{
			"get_config":    true,
			"log":           true,
			"submit_result": true,
		},
		Resources: pluginResources{
			RequestedMemoryMB: 64,
		},
		Timeout: 5 * time.Second,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := manager.executeWithWasm(ctx, assignment, wasm); err != nil {
		t.Fatalf("executeWithWasm: %v", err)
	}

	results := manager.DrainResults(1)
	if len(results) == 0 {
		t.Fatalf("expected plugin result, got none")
	}
	t.Logf("Plugin result: %s", string(results[0].Payload))
}

func TestDuskCheckerWithConfig(t *testing.T) {
	wasmPath := os.Getenv("WASM_PATH")
	if wasmPath == "" {
		t.Skip("set WASM_PATH to dusk-checker plugin.wasm")
	}

	if _, err := os.Stat(wasmPath); err != nil {
		t.Skipf("wasm file not found at %s", wasmPath)
	}

	wasm, err := os.ReadFile(wasmPath)
	if err != nil {
		t.Fatalf("read wasm: %v", err)
	}

	manager := NewPluginManager(context.Background(), PluginManagerConfig{
		Logger: logger.NewTestLogger(),
	})
	defer manager.Stop()

	// Provide config with node_address to test WebSocket path
	config := map[string]interface{}{
		"node_address": "localhost:9999", // Non-existent server
		"timeout":      "5s",
	}
	configJSON, _ := json.Marshal(config)

	assignment := &pluginAssignment{
		AssignmentID: "dusk-checker-test",
		PluginID:     "dusk-checker",
		Name:         "Dusk Checker",
		Entrypoint:   "run_check",
		Runtime:      "wasi-preview1",
		ParamsJSON:   configJSON,
		Capabilities: map[string]bool{
			"get_config":        true,
			"log":               true,
			"submit_result":     true,
			"http_request":      true,
			"websocket_connect": true,
			"websocket_send":    true,
			"websocket_recv":    true,
			"websocket_close":   true,
		},
		Permissions: pluginPermissions{
			AllowedDomains: []string{"*"},
			AllowedPorts:   []int{9999},
		},
		Resources: pluginResources{
			RequestedMemoryMB:  64,
			MaxOpenConnections: 1,
		},
		Timeout: 10 * time.Second,
	}
	assignment.Permissions.normalize()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := manager.executeWithWasm(ctx, assignment, wasm); err != nil {
		t.Fatalf("executeWithWasm: %v", err)
	}

	results := manager.DrainResults(1)
	if len(results) == 0 {
		t.Fatalf("expected plugin result, got none")
	}

	t.Logf("Plugin result: %s", string(results[0].Payload))

	// Parse result to check status
	var result map[string]interface{}
	if err := json.Unmarshal(results[0].Payload, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	status, _ := result["status"].(string)
	summary, _ := result["summary"].(string)
	t.Logf("Status: %s, Summary: %s", status, summary)

	// Expect CRITICAL because we can't connect to the fake server
	const expectedStatus = "CRITICAL"
	if status != expectedStatus {
		t.Logf("Expected %s status (no server), got %s", expectedStatus, status)
	}
}

func TestAlienVaultOTXWasmRuntimeFetchesAndEmitsThreatIntel(t *testing.T) {
	wasmPath := os.Getenv("OTX_WASM_PATH")
	if wasmPath == "" {
		t.Skip("set OTX_WASM_PATH to alienvault-otx plugin.wasm")
	}

	if _, err := os.Stat(wasmPath); err != nil {
		t.Skipf("wasm file not found at %s", wasmPath)
	}

	const apiKey = "runtime-test-api-key"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/pulses/subscribed" {
			t.Fatalf("unexpected OTX path: %s", r.URL.Path)
		}
		if got := r.Header.Get("X-OTX-API-KEY"); got != apiKey {
			t.Fatalf("unexpected OTX API key header: %q", got)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"count": 1,
			"next": null,
			"previous": null,
			"results": [{
				"id": "pulse-runtime-1",
				"name": "Runtime Pulse",
				"author_name": "serviceradar-test",
				"TLP": "white",
				"tags": ["runtime"],
				"references": ["https://example.invalid/pulse-runtime-1"],
				"created": "2026-04-27T10:00:00.000000",
				"modified": "2026-04-27T11:00:00.000000",
				"indicators": [
					{"indicator": "198.51.100.25", "type": "IPv4", "title": "C2 host"},
					{"indicator": "203.0.113.0/24", "type": "CIDR", "title": "Scanner range"},
					{"indicator": "example.invalid", "type": "domain", "title": "Skipped domain"}
				]
			}]
		}`))
	}))
	defer server.Close()

	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("parse test server URL: %v", err)
	}
	port, err := strconv.Atoi(serverURL.Port())
	if err != nil {
		t.Fatalf("parse test server port: %v", err)
	}

	configJSON, err := json.Marshal(map[string]interface{}{
		"base_url":       server.URL,
		"api_key":        apiKey,
		"limit":          10,
		"page":           1,
		"timeout_ms":     5000,
		"max_indicators": 10,
	})
	if err != nil {
		t.Fatalf("marshal plugin config: %v", err)
	}

	wasm, err := os.ReadFile(wasmPath)
	if err != nil {
		t.Fatalf("read wasm: %v", err)
	}

	manager := NewPluginManager(context.Background(), PluginManagerConfig{
		Logger: logger.NewTestLogger(),
	})
	defer manager.Stop()

	assignment := &pluginAssignment{
		AssignmentID: "otx-runtime-test",
		PluginID:     "alienvault-otx-threat-intel",
		Name:         "AlienVault OTX Threat Intel",
		Entrypoint:   "run_check",
		Runtime:      "wasi-preview1",
		ParamsJSON:   configJSON,
		Capabilities: map[string]bool{
			"get_config":    true,
			"log":           true,
			"submit_result": true,
			"http_request":  true,
		},
		Permissions: pluginPermissions{
			AllowedDomains: []string{serverURL.Hostname()},
			AllowedPorts:   []int{port},
		},
		Resources: pluginResources{
			RequestedMemoryMB:  64,
			MaxOpenConnections: 1,
		},
		Timeout: 10 * time.Second,
	}
	assignment.Permissions.normalize()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if err := manager.executeWithWasm(ctx, assignment, wasm); err != nil {
		t.Fatalf("executeWithWasm: %v", err)
	}

	results := manager.DrainResults(1)
	if len(results) == 0 {
		t.Fatalf("expected OTX plugin result, got none")
	}

	var result map[string]interface{}
	if err := json.Unmarshal(results[0].Payload, &result); err != nil {
		t.Fatalf("unmarshal plugin result: %v\n%s", err, string(results[0].Payload))
	}
	if result["status"] != "OK" {
		t.Fatalf("status = %v, want OK; payload=%s", result["status"], string(results[0].Payload))
	}
	if got, _ := result["summary"].(string); !strings.Contains(got, "2 indicators") {
		t.Fatalf("summary = %q, want indicator count", got)
	}

	detailsRaw, _ := result["details"].(string)
	if detailsRaw == "" {
		t.Fatalf("missing threat-intel details in payload: %s", string(results[0].Payload))
	}

	var details map[string]interface{}
	if err := json.Unmarshal([]byte(detailsRaw), &details); err != nil {
		t.Fatalf("unmarshal details: %v\n%s", err, detailsRaw)
	}

	threatIntel, ok := details["threat_intel"].(map[string]interface{})
	if !ok {
		t.Fatalf("missing threat_intel page: %#v", details)
	}

	indicators, ok := threatIntel["indicators"].([]interface{})
	if !ok || len(indicators) != 2 {
		t.Fatalf("indicators = %#v, want two normalized IP/CIDR indicators", threatIntel["indicators"])
	}

	payloadText := string(results[0].Payload)
	if strings.Contains(payloadText, apiKey) {
		t.Fatalf("plugin result leaked API key: %s", payloadText)
	}
}

// instantiateEnvModule creates stub implementations of the "env" host module
// functions required by the plugin WASM.
// Signatures from serviceradar-sdk-go/sdk/host_tinygo.go:
//   - get_config(ptr, size uint32) int32
//   - submit_result(ptr, size uint32) int32
//   - log(level, ptr, size uint32)
//   - http_request(reqPtr, reqLen, respPtr, respLen uint32) int32
func instantiateEnvModule(ctx context.Context, rt wazero.Runtime) error {
	_, err := rt.NewHostModuleBuilder("env").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, ptr, size uint32) int32 { return 0 }).
		Export("get_config").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, ptr, size uint32) int32 { return 0 }).
		Export("submit_result").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, level, ptr, size uint32) {}).
		Export("log").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, reqPtr, reqLen, respPtr, respLen uint32) int32 { return -1 }).
		Export("http_request").
		Instantiate(ctx)
	return err
}

// runWasmClockTest is a helper that tests WASI clock functions with the given runtime config.
// It instantiates a WASM module and calls its run_check entrypoint.
func runWasmClockTest(t *testing.T, runtimeCfg wazero.RuntimeConfig, moduleName string) {
	t.Helper()

	wasmPath := os.Getenv("WASM_PATH")
	if wasmPath == "" {
		t.Skip("set WASM_PATH to a wasm file that uses time.Now()")
	}

	wasmBytes, err := os.ReadFile(wasmPath)
	if err != nil {
		t.Fatalf("read wasm: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	rt := wazero.NewRuntimeWithConfig(ctx, runtimeCfg)
	defer func() { _ = rt.Close(ctx) }()

	if err := instantiateEnvModule(ctx, rt); err != nil {
		t.Fatalf("instantiate env module: %v", err)
	}

	wasi, err := wasi_snapshot_preview1.Instantiate(ctx, rt)
	if err != nil {
		t.Fatalf("instantiate wasi: %v", err)
	}
	defer func() { _ = wasi.Close(ctx) }()

	// Create module config with walltime enabled.
	// IMPORTANT: Use WithStartFunctions() with NO arguments to prevent _start from being called.
	// TinyGo's _start calls proc_exit(0) which closes the module and clears Sys, preventing
	// subsequent function calls from working.
	modConfig := wazero.NewModuleConfig().
		WithName(moduleName).
		WithSysWalltime().
		WithSysNanotime().
		WithSysNanosleep().
		WithStartFunctions() // Disable automatic _start call

	module, err := rt.InstantiateWithConfig(ctx, wasmBytes, modConfig)
	if err != nil {
		t.Fatalf("instantiate module: %v", err)
	}
	defer func() { _ = module.Close(ctx) }()

	entrypoint := module.ExportedFunction("run_check")
	if entrypoint == nil {
		t.Fatalf("entrypoint 'run_check' not found")
	}

	t.Logf("Calling entrypoint with %s...", moduleName)
	_, err = entrypoint.Call(ctx)
	if err != nil {
		t.Logf("entrypoint.Call error: %v", err)
		var exitErr *sys.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 0 {
			t.Log("Clean exit with code 0")
		} else {
			t.Fatalf("entrypoint failed: %v", err)
		}
	}
	t.Log("Entrypoint completed successfully")
}

// TestWasmClockInterpreter tests WASI clock functions using the interpreter engine
// to help diagnose if the issue is specific to the compiler (wazevo) engine.
func TestWasmClockInterpreter(t *testing.T) {
	runWasmClockTest(t, wazero.NewRuntimeConfigInterpreter(), "test-interpreter")
}

// TestWasmClockCompiler tests WASI clock functions using the compiler (wazevo) engine.
func TestWasmClockCompiler(t *testing.T) {
	runWasmClockTest(t, wazero.NewRuntimeConfigCompiler(), "test-compiler")
}

// Ensure api.Module is used (imported for potential future use in test assertions).
var _ api.Module = nil
