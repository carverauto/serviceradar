package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/bazelbuild/rules_go/go/runfiles"
	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
	"github.com/tetratelabs/wazero/imports/wasi_snapshot_preview1"
)

type wasmCredentialInjection struct {
	Mode                string `json:"mode"`
	Name                string `json:"name"`
	Scheme              string `json:"scheme"`
	GrantID             string `json:"grant_id"`
	CredentialSecretRef string `json:"credential_secret_ref"`
}

// wasmHTTPRequest is the subset of the env.http_request payload the fixtures route on.
type wasmHTTPRequest struct {
	Method              string                   `json:"method"`
	URL                 string                   `json:"url"`
	Headers             map[string]string        `json:"headers"`
	Body                string                   `json:"body"`
	BodyBase64          string                   `json:"body_base64"`
	ResponseMode        string                   `json:"response_mode"`
	CredentialInjection *wasmCredentialInjection `json:"credential_injection"`
}

type wasmHTTPEnvelopeResponse struct {
	Status    int               `json:"status"`
	Headers   map[string]string `json:"headers,omitempty"`
	Body      []byte            `json:"-"`
	HTTPTrace map[string]any    `json:"httptrace,omitempty"`
}

// wasmHost stands in for the agent's env host module. A host call the guest
// makes that the fixture did not provide fails the test.
type wasmHost struct {
	config []byte
	// http answers env.http_request; the status and body are written back in
	// the "status_body" response mode the SDK requests by default. A negative
	// status is returned as that host-call error code instead, the way the
	// agent reports a denied, failed or timed-out request.
	http func(t *testing.T, req wasmHTTPRequest) (status int, body []byte)
	// httpEnvelope answers env.http_request in "envelope" mode with headers and optional httptrace.
	httpEnvelope func(t *testing.T, req wasmHTTPRequest) wasmHTTPEnvelopeResponse
	// tcpDial opens a TCP connection handle for tcp_connect/tcp_read/tcp_write/tcp_close.
	tcpDial func(t *testing.T, host string, port uint16, timeout time.Duration) (net.Conn, int32)

	conns      map[uint32]net.Conn
	nextHandle uint32

	results   []map[string]any
	telemetry [][]byte
	httpCalls int
	tcpCalls  int
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
		for _, conn := range h.conns {
			_ = conn.Close()
		}
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
		importName := name
		builder.NewFunctionBuilder().WithGoModuleFunction(api.GoModuleFunc(func(_ context.Context, module api.Module, stack []uint64) {
			h.call(t, importName, module, stack)
		}), definition.ParamTypes(), definition.ResultTypes()).Export(importName)
	}
	if _, err := builder.Instantiate(ctx); err != nil {
		t.Fatal(err)
	}
	module, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithStartFunctions().WithSysWalltime().WithSysNanotime().WithRandSource(rand.Reader))
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
		if size == 0 {
			return nil
		}
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
		if h.http == nil && h.httpEnvelope == nil {
			t.Fatal("unexpected HTTP request")
		}
		h.httpCalls++
		var request wasmHTTPRequest
		if err := json.Unmarshal(read(stack[0], stack[1]), &request); err != nil {
			t.Fatal(err)
		}
		if h.httpEnvelope != nil {
			envResp := h.httpEnvelope(t, request)
			if envResp.Status < 0 {
				stack[0] = api.EncodeI32(int32(envResp.Status))
				return
			}
			var response []byte
			if strings.EqualFold(strings.TrimSpace(request.ResponseMode), "status_body") {
				response = append([]byte(fmt.Sprintf("%d\n", envResp.Status)), envResp.Body...)
			} else {
				wire := map[string]any{
					"status":        envResp.Status,
					"headers":       envResp.Headers,
					"body_base64":   base64.StdEncoding.EncodeToString(envResp.Body),
					"body_encoding": "base64",
				}
				if envResp.HTTPTrace != nil {
					wire["httptrace"] = envResp.HTTPTrace
				}
				encoded, err := json.Marshal(wire)
				if err != nil {
					t.Fatal(err)
				}
				response = encoded
			}
			if uint64(len(response)) > stack[3] || !module.Memory().Write(uint32(stack[2]), response) {
				t.Fatal("response exceeds guest buffer")
			}
			stack[0] = uint64(len(response))
			return
		}
		status, body := h.http(t, request)
		if status < 0 {
			stack[0] = api.EncodeI32(int32(status))
			return
		}
		response := append([]byte(fmt.Sprintf("%d\n", status)), body...)
		if uint64(len(response)) > stack[3] || !module.Memory().Write(uint32(stack[2]), response) {
			t.Fatal("response exceeds guest buffer")
		}
		stack[0] = uint64(len(response))
	case "tcp_connect":
		if h.tcpDial == nil {
			t.Fatal("unexpected tcp_connect")
		}
		h.tcpCalls++
		host := strings.TrimSpace(string(read(stack[0], stack[1])))
		port := uint16(stack[2])
		timeout := time.Duration(uint32(stack[3])) * time.Millisecond
		conn, errCode := h.tcpDial(t, host, port, timeout)
		if errCode < 0 {
			stack[0] = api.EncodeI32(errCode)
			return
		}
		if h.conns == nil {
			h.conns = make(map[uint32]net.Conn)
		}
		if h.nextHandle == 0 {
			h.nextHandle = 1
		}
		handle := h.nextHandle
		h.nextHandle++
		h.conns[handle] = conn
		stack[0] = uint64(handle)
	case "tcp_read":
		handle := uint32(stack[0])
		bufPtr := uint32(stack[1])
		bufLen := uint32(stack[2])
		timeout := time.Duration(uint32(stack[3])) * time.Millisecond
		conn := h.conns[handle]
		if conn == nil {
			stack[0] = api.EncodeI32(-7)
			return
		}
		if timeout > 0 {
			_ = conn.SetReadDeadline(time.Now().Add(timeout))
		}
		buf := make([]byte, bufLen)
		n, err := conn.Read(buf)
		if err != nil && !errors.Is(err, io.EOF) {
			stack[0] = api.EncodeI32(-5)
			return
		}
		if n > 0 && !module.Memory().Write(bufPtr, buf[:n]) {
			t.Fatal("tcp_read write exceeds guest memory")
		}
		stack[0] = uint64(uint32(n))
	case "tcp_write":
		handle := uint32(stack[0])
		data := read(stack[1], stack[2])
		timeout := time.Duration(uint32(stack[3])) * time.Millisecond
		conn := h.conns[handle]
		if conn == nil {
			stack[0] = api.EncodeI32(-7)
			return
		}
		if timeout > 0 {
			_ = conn.SetWriteDeadline(time.Now().Add(timeout))
		}
		n, err := conn.Write(data)
		if err != nil {
			stack[0] = api.EncodeI32(-5)
			return
		}
		stack[0] = uint64(uint32(n))
	case "tcp_close":
		handle := uint32(stack[0])
		if conn := h.conns[handle]; conn != nil {
			_ = conn.Close()
			delete(h.conns, handle)
		}
		stack[0] = 0
	default:
		t.Fatalf("unexpected host call %s", name)
	}
}
