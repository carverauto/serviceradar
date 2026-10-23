package agent

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/gorilla/websocket"
)

// Live dusk-checker contract, exercised through the agent Wasm host against a
// disposable RUES stand-in. The oracle is the check deadline: an 8s cap stays
// under the 10s assignment deadline, a positive sub-millisecond step must not
// be expanded to that assignment deadline, a refused dial is CRITICAL, and a
// failure after the socket is up is WARNING with the stage that failed.
// A wrong plugin would wait out 30s or the 10s host deadline, report CRITICAL
// after a successful connect, or return OK without a block.

const (
	duskRuntimeSessionID   = "rues-session-live"
	duskRuntimeBlockHeight = 4242
	duskAssignmentTimeout  = 10 * time.Second
)

func TestDuskCheckerWasmRuntime(t *testing.T) {
	wasm := loadDuskCheckerWasm(t)
	manager := NewPluginManager(context.Background(), PluginManagerConfig{
		Logger: logger.NewTestLogger(),
	})
	defer manager.Stop()

	t.Run("accepted block reports ok under capped budget", func(t *testing.T) {
		server := newDuskRUESServer(t, duskRUESBlock)
		defer server.Close()

		started := time.Now()
		result := runDuskCheckerWasm(t, manager, wasm, server.hostPort(), "30s")
		elapsed := time.Since(started)

		if result.Status != "OK" {
			t.Fatalf("status = %s, summary = %q, details = %q", result.Status, result.Summary, result.Details)
		}
		if !strings.Contains(result.Summary, "Block height: 4242") {
			t.Fatalf("summary = %q", result.Summary)
		}
		details := decodeDuskDetails(t, result.Details)
		if details.Timeout != "8s" {
			t.Fatalf("timeout = %q, want the 8s cap applied to a 30s config", details.Timeout)
		}
		if details.SessionID != duskRuntimeSessionID {
			t.Fatalf("session_id = %q", details.SessionID)
		}
		if details.BlockHeight != duskRuntimeBlockHeight {
			t.Fatalf("block_height = %d", details.BlockHeight)
		}
		if !strings.Contains(result.Details, "read_next_block") {
			t.Fatalf("details = %q, want completed read_next_block", result.Details)
		}
		if elapsed >= duskAssignmentTimeout {
			t.Fatalf("check took %s, which reaches the %s Wasm assignment deadline", elapsed, duskAssignmentTimeout)
		}
		t.Logf("DUSK_RUNTIME accepted-block status=%s timeout=%s elapsed=%s", result.Status, details.Timeout, elapsed)
	})

	t.Run("subscribe failure after connect is warning", func(t *testing.T) {
		server := newDuskRUESServer(t, duskRUESSubscribeFail)
		defer server.Close()

		result := runDuskCheckerWasm(t, manager, wasm, server.hostPort(), "8s")
		details := decodeDuskDetails(t, result.Details)
		if result.Status != "WARNING" {
			t.Fatalf("status = %s, want WARNING after connect; summary = %q", result.Status, result.Summary)
		}
		if details.FailedStage != "subscribe_blocks" {
			t.Fatalf("failed_stage = %q, details = %q", details.FailedStage, result.Details)
		}
		if details.SessionID != duskRuntimeSessionID {
			t.Fatalf("session_id = %q", details.SessionID)
		}
		if server.subscribeSession != duskRuntimeSessionID {
			t.Fatalf("Rusk-Session-Id = %q", server.subscribeSession)
		}
		t.Logf("DUSK_RUNTIME subscribe-fail status=%s stage=%s", result.Status, details.FailedStage)
	})

	t.Run("refused node is critical before connect", func(t *testing.T) {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("listen: %v", err)
		}
		addr := ln.Addr().String()
		if err := ln.Close(); err != nil {
			t.Fatalf("close listener: %v", err)
		}

		started := time.Now()
		result := runDuskCheckerWasm(t, manager, wasm, addr, "8s")
		elapsed := time.Since(started)
		details := decodeDuskDetails(t, result.Details)
		if result.Status != "CRITICAL" {
			t.Fatalf("status = %s, want CRITICAL; summary = %q", result.Status, result.Summary)
		}
		if details.FailedStage != "websocket_connect" {
			t.Fatalf("failed_stage = %q", details.FailedStage)
		}
		if details.NodeAddress != addr {
			t.Fatalf("node_address = %q, want %q", details.NodeAddress, addr)
		}
		if elapsed >= 3*time.Second {
			t.Fatalf("refused dial took %s; handshake steps are capped at 2s", elapsed)
		}
		t.Logf("DUSK_RUNTIME refused status=%s stage=%s elapsed=%s", result.Status, details.FailedStage, elapsed)
	})

	t.Run("submillisecond budget does not expand to assignment deadline", func(t *testing.T) {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("listen: %v", err)
		}
		defer ln.Close()

		held := make(chan time.Duration, 1)
		go func() {
			conn, acceptErr := ln.Accept()
			if acceptErr != nil {
				return
			}
			held <- peerHold(conn)
		}()

		started := time.Now()
		result := runDuskCheckerWasm(t, manager, wasm, ln.Addr().String(), "500us")
		elapsed := time.Since(started)

		var hold time.Duration
		select {
		case hold = <-held:
		case <-time.After(2 * time.Second):
			t.Fatal("blackhole peer was never accepted")
		}
		// Host websocket timeouts are whole milliseconds. 0ms is rewritten to the
		// 10s assignment deadline and blocks the read or dial for that long.
		if hold >= 500*time.Millisecond {
			t.Fatalf("blackhole held for %s; a 500us step was expanded toward the %s assignment deadline", hold, duskAssignmentTimeout)
		}
		if result.Status != "CRITICAL" && result.Status != "WARNING" {
			t.Fatalf("status = %s, want a bounded failure; summary = %q", result.Status, result.Summary)
		}
		details := decodeDuskDetails(t, result.Details)
		if details.FailedStage == "" {
			t.Fatalf("details = %q, want a failed stage", result.Details)
		}
		if elapsed >= duskAssignmentTimeout {
			t.Fatalf("check took %s, reaching the assignment deadline", elapsed)
		}
		t.Logf("DUSK_RUNTIME subms status=%s stage=%s hold=%s elapsed=%s timeout=%s", result.Status, details.FailedStage, hold, elapsed, details.Timeout)
	})

	t.Run("configured thirty seconds waits only the remaining eight second cap", func(t *testing.T) {
		server := newDuskRUESServer(t, duskRUESNoBlock)
		defer server.Close()

		started := time.Now()
		result := runDuskCheckerWasm(t, manager, wasm, server.hostPort(), "30s")
		elapsed := time.Since(started)
		hold := server.waitHold(t)

		details := decodeDuskDetails(t, result.Details)
		if result.Status != "WARNING" {
			t.Fatalf("status = %s, want WARNING when no block arrives; summary = %q", result.Status, result.Summary)
		}
		if details.FailedStage != "read_next_block" {
			t.Fatalf("failed_stage = %q, details = %q", details.FailedStage, result.Details)
		}
		if details.Timeout != "8s" {
			t.Fatalf("timeout = %q, want 8s cap", details.Timeout)
		}
		if details.SessionID != duskRuntimeSessionID {
			t.Fatalf("session_id = %q", details.SessionID)
		}
		// Dusk accepted blocks are about 10s apart. The wait is whatever remains
		// of the capped check deadline, and that remainder must finish before
		// the 10s Wasm assignment deadline. A 5s ceiling returns early.
		if hold < 6500*time.Millisecond || hold >= 9500*time.Millisecond {
			t.Fatalf("block wait held the socket for %s; want the time left on the 8s deadline and below the 10s assignment deadline", hold)
		}
		if elapsed >= duskAssignmentTimeout+time.Second {
			t.Fatalf("check took %s, past the Wasm assignment deadline", elapsed)
		}
		t.Logf("DUSK_RUNTIME no-block status=%s hold=%s elapsed=%s", result.Status, hold, elapsed)
	})

	t.Run("missing node address is unknown", func(t *testing.T) {
		result := runDuskCheckerWasm(t, manager, wasm, "", "")
		if result.Status != "UNKNOWN" {
			t.Fatalf("status = %s, summary = %q", result.Status, result.Summary)
		}
		if !strings.Contains(result.Summary, "node_address") {
			t.Fatalf("summary = %q", result.Summary)
		}
		t.Logf("DUSK_RUNTIME missing-address status=%s summary=%s", result.Status, result.Summary)
	})
}

type duskCheckPayload struct {
	Status  string `json:"status"`
	Summary string `json:"summary"`
	Details string `json:"details"`
}

type duskCheckDetails struct {
	NodeAddress string `json:"node_address"`
	SessionID   string `json:"session_id"`
	FailedStage string `json:"failed_stage"`
	Timeout     string `json:"timeout"`
	BlockHeight uint64 `json:"block_height"`
}

func decodeDuskDetails(t *testing.T, raw string) duskCheckDetails {
	t.Helper()
	if strings.TrimSpace(raw) == "" {
		t.Fatal("expected check details")
	}
	var details duskCheckDetails
	if err := json.Unmarshal([]byte(raw), &details); err != nil {
		t.Fatalf("details JSON: %v raw=%s", err, raw)
	}
	return details
}

func runDuskCheckerWasm(t *testing.T, manager *PluginManager, wasm []byte, nodeAddress, timeout string) duskCheckPayload {
	t.Helper()

	config := map[string]string{}
	if nodeAddress != "" {
		config["node_address"] = nodeAddress
	}
	if timeout != "" {
		config["timeout"] = timeout
	}
	configJSON, err := json.Marshal(config)
	if err != nil {
		t.Fatalf("marshal config: %v", err)
	}

	host, port := splitHostPort(t, nodeAddress)
	permissions := pluginPermissions{}
	if host != "" {
		permissions.AllowedDomains = []string{host}
		permissions.AllowedNetworks = []string{host + "/32"}
		permissions.AllowedPorts = []int{port}
	}
	permissions.normalize()

	assignment := &pluginAssignment{
		AssignmentID: "dusk-checker-" + strings.ReplaceAll(t.Name(), "/", "-"),
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
		Permissions: permissions,
		Resources: pluginResources{
			RequestedMemoryMB:  128,
			MaxOpenConnections: 4,
		},
		Timeout: duskAssignmentTimeout,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := manager.executeWithWasm(ctx, assignment, pluginModule{wasm: wasm}); err != nil {
		t.Fatalf("executeWithWasm: %v", err)
	}

	results := manager.DrainResults(8)
	if len(results) != 1 {
		t.Fatalf("plugin results = %d, want 1", len(results))
	}
	var payload duskCheckPayload
	if err := json.Unmarshal(results[0].Payload, &payload); err != nil {
		t.Fatalf("plugin payload: %v raw=%s", err, results[0].Payload)
	}
	return payload
}

func splitHostPort(t *testing.T, address string) (string, int) {
	t.Helper()
	if address == "" {
		return "", 0
	}
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatalf("split host port %q: %v", address, err)
	}
	port, err := net.LookupPort("tcp", portText)
	if err != nil {
		t.Fatalf("port %q: %v", portText, err)
	}
	return host, port
}

func peerHold(conn net.Conn) time.Duration {
	start := time.Now()
	defer conn.Close()
	_ = conn.SetDeadline(start.Add(15 * time.Second))
	buf := make([]byte, 1024)
	for {
		if _, err := conn.Read(buf); err != nil {
			return time.Since(start)
		}
	}
}

type duskRUESMode int

const (
	duskRUESBlock duskRUESMode = iota
	duskRUESNoBlock
	duskRUESSubscribeFail
)

type duskRUESServer struct {
	*httptest.Server
	mode             duskRUESMode
	hold             chan time.Duration
	subscribeSession string
}

func newDuskRUESServer(t *testing.T, mode duskRUESMode) *duskRUESServer {
	t.Helper()
	server := &duskRUESServer{mode: mode, hold: make(chan time.Duration, 1)}
	mux := http.NewServeMux()
	mux.HandleFunc("/on", server.serveSocket)
	mux.HandleFunc("/on/blocks/accepted", server.serveSubscribe)
	server.Server = httptest.NewServer(mux)
	return server
}

func (s *duskRUESServer) hostPort() string {
	return s.Listener.Addr().String()
}

func (s *duskRUESServer) serveSubscribe(w http.ResponseWriter, r *http.Request) {
	s.subscribeSession = r.Header.Get("Rusk-Session-Id")
	if s.mode == duskRUESSubscribeFail {
		http.Error(w, "subscription unavailable", http.StatusServiceUnavailable)
		return
	}
	if r.Header.Get("Rusk-Version") != "1.0" || s.subscribeSession == "" {
		http.Error(w, "missing rues session", http.StatusBadRequest)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (s *duskRUESServer) serveSocket(w http.ResponseWriter, r *http.Request) {
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()
	opened := time.Now()
	defer func() {
		s.hold <- time.Since(opened)
	}()

	if s.mode == duskRUESSubscribeFail || s.mode == duskRUESBlock || s.mode == duskRUESNoBlock {
		if err := conn.WriteMessage(websocket.TextMessage, []byte(duskRuntimeSessionID)); err != nil {
			return
		}
	}
	if s.mode == duskRUESBlock {
		if err := conn.WriteMessage(websocket.BinaryMessage, duskAcceptedBlockFrame()); err != nil {
			return
		}
	}
	_ = conn.SetReadDeadline(time.Now().Add(20 * time.Second))
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			return
		}
	}
}

func (s *duskRUESServer) waitHold(t *testing.T) time.Duration {
	t.Helper()
	select {
	case hold := <-s.hold:
		return hold
	case <-time.After(25 * time.Second):
		t.Fatal("rues socket did not close")
		return 0
	}
}

func duskAcceptedBlockFrame() []byte {
	payload := `{"Content-Location":"/on/blocks/accepted"}{"header":{"height":4242,"hash":"abcdef0123456789","timestamp":1778270000}}`
	return append([]byte{0, 0, 0, 42}, []byte(payload)...)
}

func loadDuskCheckerWasm(t *testing.T) []byte {
	t.Helper()
	path := locateDuskCheckerWasm(t)
	if path == "" {
		t.Fatal("dusk_checker.wasm not in runfiles; run //go/pkg/agent:dusk_checker_runtime_test")
	}
	wasm, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read wasm: %v", err)
	}
	if len(wasm) < 8 || string(wasm[:4]) != "\x00asm" {
		t.Fatalf("wasm magic missing in %s (%d bytes)", path, len(wasm))
	}
	return wasm
}

func locateDuskCheckerWasm(t *testing.T) string {
	t.Helper()
	const objectKey = "dusk_checker.wasm"
	if manifest := strings.TrimSpace(os.Getenv("RUNFILES_MANIFEST_FILE")); manifest != "" {
		data, err := os.ReadFile(manifest)
		if err != nil {
			t.Fatalf("read runfiles manifest: %v", err)
		}
		for _, line := range strings.Split(string(data), "\n") {
			runfile, target, ok := strings.Cut(line, " ")
			if !ok || !strings.HasSuffix(runfile, "build/wasm_plugins/"+objectKey) {
				continue
			}
			if _, err := os.Stat(target); err == nil {
				return target
			}
		}
	}
	if testSrcDir := strings.TrimSpace(os.Getenv("TEST_SRCDIR")); testSrcDir != "" {
		for _, workspace := range []string{strings.TrimSpace(os.Getenv("TEST_WORKSPACE")), "_main"} {
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
