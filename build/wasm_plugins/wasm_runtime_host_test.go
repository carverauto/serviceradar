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

// wasmHTTPRequest is the env.http_request payload decoded by the test host.
type wasmHTTPRequest struct {
	Method              string                   `json:"method"`
	URL                 string                   `json:"url"`
	Headers             map[string]string        `json:"headers,omitempty"`
	Body                string                   `json:"body,omitempty"`
	BodyBase64          string                   `json:"body_base64,omitempty"`
	ResponseMode        string                   `json:"response_mode"`
	FollowRedirects     *bool                    `json:"follow_redirects,omitempty"`
	CredentialInjection *wasmCredentialInjection `json:"credential_injection"`
}
type wasmHTTPHopTrace struct {
	URL                    string `json:"url"`
	Status                 int    `json:"status"`
	DNSDurationNS          int64  `json:"dns_duration_ns"`
	ConnectDurationNS      int64  `json:"connect_duration_ns"`
	TLSHandshakeDurationNS int64  `json:"tls_handshake_duration_ns"`
	TTFBDurationNS         int64  `json:"ttfb_duration_ns"`
	RemoteAddr             string `json:"remote_addr,omitempty"`
}

type wasmHTTPTrace struct {
	DNSDurationNS          int64              `json:"dns_duration_ns"`
	ConnectDurationNS      int64              `json:"connect_duration_ns"`
	TLSHandshakeDurationNS int64              `json:"tls_handshake_duration_ns"`
	TTFBDurationNS         int64              `json:"ttfb_duration_ns"`
	TransferDurationNS     int64              `json:"transfer_duration_ns"`
	TotalDurationNS        int64              `json:"total_duration_ns"`
	ConnectionReused       bool               `json:"connection_reused"`
	RedirectCount          int                `json:"redirect_count"`
	FinalURL               string             `json:"final_url"`
	Protocol               string             `json:"protocol,omitempty"`
	RemoteAddr             string             `json:"remote_addr,omitempty"`
	Hops                   []wasmHTTPHopTrace `json:"hops,omitempty"`
}

type wasmHTTPTLSInfo struct {
	Version           string `json:"version,omitempty"`
	CipherSuite       string `json:"cipher_suite,omitempty"`
	ALPN              string `json:"alpn,omitempty"`
	LeafSubjectCN     string `json:"leaf_subject_cn,omitempty"`
	LeafIssuerCN      string `json:"leaf_issuer_cn,omitempty"`
	LeafNotAfterUnix  *int64 `json:"leaf_not_after_unix,omitempty"`
	LeafDaysRemaining *int   `json:"leaf_days_remaining,omitempty"`
}

type wasmHTTPEnvelopeResponse struct {
	// ErrCode, when negative, is returned as the host-call error code.
	ErrCode    int32             `json:"-"`
	Status     int               `json:"status"`
	Headers    map[string]string `json:"headers,omitempty"`
	SetCookies []string          `json:"set_cookies,omitempty"`
	Body       []byte            `json:"-"`
	HTTPTrace  map[string]any    `json:"httptrace,omitempty"`
	Trace      *wasmHTTPTrace    `json:"trace,omitempty"`
	TLS        *wasmHTTPTLSInfo  `json:"tls,omitempty"`
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
	// httpEnvelope answers env.http_request in "envelope" mode (and in any
	// mode when http is nil) with headers, Set-Cookie, httptrace, trace and TLS.
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
		envelopeMode := strings.EqualFold(strings.TrimSpace(request.ResponseMode), "envelope")
		if h.httpEnvelope != nil && (envelopeMode || h.http == nil) {
			envResp := h.httpEnvelope(t, request)
			if envResp.ErrCode < 0 {
				stack[0] = api.EncodeI32(envResp.ErrCode)
				return
			}
			if envResp.Status < 0 {
				stack[0] = api.EncodeI32(int32(envResp.Status))
				return
			}
			var response []byte
			if strings.EqualFold(strings.TrimSpace(request.ResponseMode), "status_body") {
				response = append([]byte(fmt.Sprintf("%d\n", envResp.Status)), envResp.Body...)
			} else {
				encoded, err := json.Marshal(struct {
					Status       int               `json:"status"`
					Headers      map[string]string `json:"headers,omitempty"`
					SetCookies   []string          `json:"set_cookies,omitempty"`
					BodyBase64   string            `json:"body_base64"`
					BodyEncoding string            `json:"body_encoding,omitempty"`
					HTTPTrace    map[string]any    `json:"httptrace,omitempty"`
					Trace        *wasmHTTPTrace    `json:"trace,omitempty"`
					TLS          *wasmHTTPTLSInfo  `json:"tls,omitempty"`
				}{
					Status:       envResp.Status,
					Headers:      envResp.Headers,
					SetCookies:   envResp.SetCookies,
					BodyBase64:   base64.StdEncoding.EncodeToString(envResp.Body),
					BodyEncoding: "base64",
					HTTPTrace:    envResp.HTTPTrace,
					Trace:        envResp.Trace,
					TLS:          envResp.TLS,
				})
				if err != nil {
					t.Fatal(err)
				}
				response = encoded
			}
			if uint64(len(response)) > stack[3] || !module.Memory().Write(uint32(stack[2]), response) {
				t.Fatal("envelope response exceeds guest buffer")
			}
			stack[0] = uint64(len(response))
			return
		}
		if h.http == nil {
			t.Fatal("unexpected HTTP request")
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

func TestWasmHostHTTPEnvelopeCallback(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rt := wazero.NewRuntime(ctx)
	defer func() { _ = rt.Close(ctx) }()

	mod, err := rt.Instantiate(ctx, []byte{
		0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
		0x05, 0x03, 0x01, 0x00, 0x01,
		0x07, 0x0a, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
	})
	if err != nil {
		t.Fatal(err)
	}

	reqJSON := []byte(`{"method":"GET","url":"https://app.example.test/login","response_mode":"envelope","follow_redirects":false}`)
	const (
		reqPtr  = uint32(0)
		respPtr = uint32(4096)
		respLen = uint32(8192)
	)
	if !mod.Memory().Write(reqPtr, reqJSON) {
		t.Fatal("write request")
	}

	daysZero := 0
	var capturedFollowRedirects *bool
	host := &wasmHost{
		httpEnvelope: func(t *testing.T, req wasmHTTPRequest) wasmHTTPEnvelopeResponse {
			capturedFollowRedirects = req.FollowRedirects
			return wasmHTTPEnvelopeResponse{
				Status:     302,
				Headers:    map[string]string{"Location": "/callback"},
				SetCookies: []string{"sid=alpha; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/; Secure"},
				Body:       []byte(`{"step":"redirect"}`),
				Trace: &wasmHTTPTrace{
					TotalDurationNS: 4_200_000,
					FinalURL:        "https://app.example.test/login",
					Protocol:        "HTTP/2.0",
					Hops: []wasmHTTPHopTrace{
						{URL: "https://app.example.test/login", Status: 302, TTFBDurationNS: 3_000_000},
					},
				},
				TLS: &wasmHTTPTLSInfo{
					Version:           "TLS1.3",
					LeafDaysRemaining: &daysZero,
				},
			}
		},
	}

	stack := []uint64{uint64(reqPtr), uint64(len(reqJSON)), uint64(respPtr), uint64(respLen)}
	host.call(t, "http_request", mod, stack)

	if capturedFollowRedirects == nil || *capturedFollowRedirects {
		t.Fatalf("follow_redirects = %v, want false", capturedFollowRedirects)
	}
	n := uint32(stack[0])
	raw, ok := mod.Memory().Read(respPtr, n)
	if !ok {
		t.Fatal("read response")
	}
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["status"] != float64(302) {
		t.Fatalf("status = %v, want 302", decoded["status"])
	}
	cookies, _ := decoded["set_cookies"].([]any)
	if len(cookies) != 1 {
		t.Fatalf("set_cookies = %v, want 1 entry", decoded["set_cookies"])
	}
	tlsObj, _ := decoded["tls"].(map[string]any)
	if tlsObj == nil || tlsObj["leaf_days_remaining"] != float64(0) {
		t.Fatalf("tls = %v, want leaf_days_remaining=0", decoded["tls"])
	}
}
