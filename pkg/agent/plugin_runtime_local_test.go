package agent

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
	"github.com/tetratelabs/wazero/sys"
)

func TestExecuteWithWasmHarness(t *testing.T) {
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

// TestWasmClockInterpreter tests WASI clock functions using the interpreter engine
// to help diagnose if the issue is specific to the compiler (wazevo) engine.
func TestWasmClockInterpreter(t *testing.T) {
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

	// Use the interpreter engine explicitly
	runtimeCfg := wazero.NewRuntimeConfigInterpreter()
	rt := wazero.NewRuntimeWithConfig(ctx, runtimeCfg)
	defer rt.Close(ctx)

	// Instantiate the "env" host module with stub functions
	if err := instantiateEnvModule(ctx, rt); err != nil {
		t.Fatalf("instantiate env module: %v", err)
	}

	// Instantiate WASI
	wasi, err := wasi_snapshot_preview1.Instantiate(ctx, rt)
	if err != nil {
		t.Fatalf("instantiate wasi: %v", err)
	}
	defer wasi.Close(ctx)

	// Create module config with walltime enabled
	// IMPORTANT: Use WithStartFunctions() with NO arguments to prevent _start from being called.
	// TinyGo's _start calls proc_exit(0) which closes the module and clears Sys, preventing
	// subsequent function calls from working.
	modConfig := wazero.NewModuleConfig().
		WithName("test-interpreter").
		WithSysWalltime().
		WithSysNanotime().
		WithSysNanosleep().
		WithStartFunctions() // Disable automatic _start call

	module, err := rt.InstantiateWithConfig(ctx, wasmBytes, modConfig)
	if err != nil {
		t.Fatalf("instantiate module: %v", err)
	}
	defer module.Close(ctx)

	entrypoint := module.ExportedFunction("run_check")
	if entrypoint == nil {
		t.Fatalf("entrypoint 'run_check' not found")
	}

	t.Log("Calling entrypoint with interpreter engine...")
	_, err = entrypoint.Call(ctx)
	if err != nil {
		// Check if it's a clean exit
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

// TestWasmClockCompiler tests WASI clock functions using the compiler (wazevo) engine.
func TestWasmClockCompiler(t *testing.T) {
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

	// Use the compiler engine explicitly
	runtimeCfg := wazero.NewRuntimeConfigCompiler()
	rt := wazero.NewRuntimeWithConfig(ctx, runtimeCfg)
	defer rt.Close(ctx)

	// Instantiate the "env" host module with stub functions
	if err := instantiateEnvModule(ctx, rt); err != nil {
		t.Fatalf("instantiate env module: %v", err)
	}

	// Instantiate WASI
	wasi, err := wasi_snapshot_preview1.Instantiate(ctx, rt)
	if err != nil {
		t.Fatalf("instantiate wasi: %v", err)
	}
	defer wasi.Close(ctx)

	// Create module config with walltime enabled
	// IMPORTANT: Use WithStartFunctions() with NO arguments to prevent _start from being called.
	// TinyGo's _start calls proc_exit(0) which closes the module and clears Sys, preventing
	// subsequent function calls from working.
	modConfig := wazero.NewModuleConfig().
		WithName("test-compiler").
		WithSysWalltime().
		WithSysNanotime().
		WithSysNanosleep().
		WithStartFunctions() // Disable automatic _start call

	module, err := rt.InstantiateWithConfig(ctx, wasmBytes, modConfig)
	if err != nil {
		t.Fatalf("instantiate module: %v", err)
	}
	defer module.Close(ctx)

	entrypoint := module.ExportedFunction("run_check")
	if entrypoint == nil {
		t.Fatalf("entrypoint 'run_check' not found")
	}

	t.Log("Calling entrypoint with compiler engine...")
	_, err = entrypoint.Call(ctx)
	if err != nil {
		t.Logf("entrypoint.Call error: %v", err)
		// Check if it's a clean exit
		var exitErr *sys.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 0 {
			t.Log("Clean exit with code 0")
		} else {
			t.Fatalf("entrypoint failed: %v", err)
		}
	}
	t.Log("Entrypoint completed successfully")
}
