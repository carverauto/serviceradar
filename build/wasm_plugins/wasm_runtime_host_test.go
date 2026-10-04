package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
)

// wasmHTTPRequest is the subset of the env.http_request payload the fixtures route on.
type wasmHTTPRequest struct {
	Method       string `json:"method"`
	URL          string `json:"url"`
	ResponseMode string `json:"response_mode"`
}

// wasmHost stands in for the agent's env host module. A host call the guest
// makes that the fixture did not provide fails the test.
type wasmHost struct {
	config []byte
	// http answers env.http_request; the status and body are written back in
	// the "status_body" response mode the SDK requests by default.
	http func(t *testing.T, req wasmHTTPRequest) (status int, body []byte)

	results   []map[string]any
	telemetry [][]byte
	httpCalls int
}

func loadBuiltWasm(t *testing.T, name string) []byte {
	t.Helper()
	path, err := runfiles.Rlocation(filepath.Join(os.Getenv("TEST_WORKSPACE"), "build/wasm_plugins", name))
	if err != nil {
		t.Fatal(err)
	}
	wasm, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return wasm
}

// run calls one exported entrypoint the way the agent does: WASI is
// instantiated but _start never runs, so package initializers the guest
// depends on must already have been evaluated at build time.
func (h *wasmHost) run(t *testing.T, wasm []byte, export string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	runtime := wazero.NewRuntime(ctx)
	defer func() {
		if err := runtime.Close(ctx); err != nil {
			t.Error(err)
		}
	}()
	if _, err := wasi_snapshot_preview1.Instantiate(ctx, runtime); err != nil {
		t.Fatal(err)
	}
	compiled, err := runtime.CompileModule(ctx, wasm)
	if err != nil {
		t.Fatal(err)
	}
	builder := runtime.NewHostModuleBuilder("env")
	for _, definition := range compiled.ImportedFunctions() {
		module, name, _ := definition.Import()
		if module != "env" {
			continue
		}
		builder.NewFunctionBuilder().WithGoModuleFunction(api.GoModuleFunc(func(_ context.Context, module api.Module, stack []uint64) {
			h.call(t, name, module, stack)
		}), definition.ParamTypes(), definition.ResultTypes()).Export(name)
	}
	if _, err := builder.Instantiate(ctx); err != nil {
		t.Fatal(err)
	}
	module, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithStartFunctions().WithSysWalltime().WithSysNanotime())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := module.ExportedFunction(export).Call(ctx); err != nil {
		t.Fatal(fmt.Errorf("%s: %w", export, err))
	}
	if len(h.results) == 0 {
		t.Fatal("plugin did not submit a result")
	}
}

func (h *wasmHost) call(t *testing.T, name string, module api.Module, stack []uint64) {
	read := func(ptr, size uint64) []byte {
		raw, ok := module.Memory().Read(uint32(ptr), uint32(size))
		if !ok {
			t.Fatalf("%s: invalid guest pointer", name)
		}
		return append([]byte(nil), raw...)
	}
	switch name {
	case "get_config":
		if uint64(len(h.config)) > stack[1] || !module.Memory().Write(uint32(stack[0]), h.config) {
			t.Fatal("config exceeds guest buffer")
		}
		stack[0] = uint64(len(h.config))
	case "submit_result":
		var result map[string]any
		if err := json.Unmarshal(read(stack[0], stack[1]), &result); err != nil {
			t.Fatal(err)
		}
		h.results = append(h.results, result)
		stack[0] = 0
	case "emit_telemetry":
		h.telemetry = append(h.telemetry, read(stack[0], stack[1]))
		stack[0] = 0
	case "log":
	case "http_request":
		if h.http == nil {
			t.Fatal("unexpected HTTP request")
		}
		h.httpCalls++
		var request wasmHTTPRequest
		if err := json.Unmarshal(read(stack[0], stack[1]), &request); err != nil {
			t.Fatal(err)
		}
		status, body := h.http(t, request)
		response := append([]byte(fmt.Sprintf("%d\n", status)), body...)
		if uint64(len(response)) > stack[3] || !module.Memory().Write(uint32(stack[2]), response) {
			t.Fatal("response exceeds guest buffer")
		}
		stack[0] = uint64(len(response))
	default:
		t.Fatalf("unexpected host call %s", name)
	}
}
