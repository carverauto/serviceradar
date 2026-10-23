package main

import (
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

type fakeWS struct {
	messages [][]byte
	closed   bool
}

func (f *fakeWS) Recv(_ []byte, _ time.Duration) (int, error) {
	return 0, errors.New("test fake must use recvInto")
}

func (f *fakeWS) Close() error {
	f.closed = true
	return nil
}

func (f *fakeWS) recvInto(buf []byte, _ time.Duration) (int, error) {
	if len(f.messages) == 0 {
		return 0, errors.New("no more messages")
	}
	msg := f.messages[0]
	f.messages = f.messages[1:]
	copy(buf, msg)
	return len(msg), nil
}

type testWS struct {
	*fakeWS
}

func (t testWS) Recv(buf []byte, timeout time.Duration) (int, error) {
	return t.fakeWS.recvInto(buf, timeout)
}

type fakeHTTP struct {
	requests []sdk.HTTPRequest
	status   int
	body     []byte
	err      error
}

func (f *fakeHTTP) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	f.requests = append(f.requests, req)
	if f.err != nil {
		return nil, f.err
	}
	status := f.status
	if status == 0 {
		status = http.StatusOK
	}
	return &sdk.HTTPResponse{Status: status, Body: f.body}, nil
}

func TestDuskURLsDefaultRUESPaths(t *testing.T) {
	wsURL, subscribeURL, err := duskURLs(Config{NodeAddress: "localhost:8080"})
	if err != nil {
		t.Fatalf("duskURLs returned error: %v", err)
	}

	if wsURL != "ws://localhost:8080/on" {
		t.Fatalf("wsURL = %q", wsURL)
	}
	if subscribeURL != "http://localhost:8080/on/blocks/accepted" {
		t.Fatalf("subscribeURL = %q", subscribeURL)
	}
}

func TestDuskURLsPreserveExplicitSecureEndpoint(t *testing.T) {
	wsURL, subscribeURL, err := duskURLs(Config{
		NodeAddress:      "https://node.example:9000/custom",
		SubscriptionPath: "events/accepted",
	})
	if err != nil {
		t.Fatalf("duskURLs returned error: %v", err)
	}

	if wsURL != "wss://node.example:9000/custom" {
		t.Fatalf("wsURL = %q", wsURL)
	}
	if subscribeURL != "https://node.example:9000/events/accepted" {
		t.Fatalf("subscribeURL = %q", subscribeURL)
	}
}

func TestParseBlockMessage(t *testing.T) {
	message := append([]byte{0, 0, 0, 42}, []byte(`{"Content-Location":"/on/blocks/accepted"}`+
		`{"header":{"height":12345,"hash":"abcdef0123456789","timestamp":1778270000}}`)...)

	block, err := parseBlockMessage(message)
	if err != nil {
		t.Fatalf("parseBlockMessage returned error: %v", err)
	}

	if block.Height != 12345 {
		t.Fatalf("height = %d", block.Height)
	}
	if block.Hash != "abcdef0123456789" {
		t.Fatalf("hash = %q", block.Hash)
	}
	if got := block.Timestamp.Unix(); got != 1778270000 {
		t.Fatalf("timestamp = %d", got)
	}
}

func TestRunDuskCheckUsesRUESHandshakeAndSubscription(t *testing.T) {
	blockMessage := append([]byte{0, 0, 0, 42}, []byte(`{"Content-Location":"/on/blocks/accepted"}`+
		`{"header":{"height":99,"hash":"abcdef0123456789fedcba","timestamp":1778270000}}`)...)
	ws := &fakeWS{messages: [][]byte{[]byte("session-123"), blockMessage}}
	httpClient := &fakeHTTP{}

	var dialURL string
	result := runDuskCheck(
		Config{NodeAddress: "localhost:8080", Timeout: "2s"},
		func(rawURL string, _ time.Duration) (webSocketConn, error) {
			dialURL = rawURL
			return testWS{ws}, nil
		},
		httpClient,
	)

	if dialURL != "ws://localhost:8080/on" {
		t.Fatalf("dialURL = %q", dialURL)
	}
	if len(httpClient.requests) != 1 {
		t.Fatalf("expected one subscription request, got %d", len(httpClient.requests))
	}
	req := httpClient.requests[0]
	if req.URL != "http://localhost:8080/on/blocks/accepted" {
		t.Fatalf("subscription URL = %q", req.URL)
	}
	if req.Headers["Rusk-Version"] != "1.0" {
		t.Fatalf("Rusk-Version = %q", req.Headers["Rusk-Version"])
	}
	if req.Headers["Rusk-Session-Id"] != "session-123" {
		t.Fatalf("Rusk-Session-Id = %q", req.Headers["Rusk-Session-Id"])
	}
	if !ws.closed {
		t.Fatal("websocket was not closed")
	}
	if result.Status != sdk.StatusOK {
		t.Fatalf("status = %s", result.Status)
	}
	if !strings.Contains(result.Summary, "Block height: 99") {
		t.Fatalf("summary = %q", result.Summary)
	}
}

type slowStreamWS struct {
	sessionID    string
	sessionDelay time.Duration
	sentSession  bool
	hostDeadline time.Time
	recvTimeouts []time.Duration
	closed       bool
}

func (s *slowStreamWS) Recv(buf []byte, timeout time.Duration) (int, error) {
	s.recvTimeouts = append(s.recvTimeouts, timeout)
	if !s.sentSession {
		s.sentSession = true
		if err := sleepWithinHostDeadline(s.sessionDelay, timeout, s.hostDeadline); err != nil {
			return 0, err
		}
		copy(buf, s.sessionID)
		return len(s.sessionID), nil
	}

	// Simulate an accepted-block stream that produces no block within the call's timeout.
	if err := sleepWithinHostDeadline(timeout, timeout, s.hostDeadline); err != nil {
		return 0, err
	}
	return 0, errors.New("websocket_recv: i/o timeout")
}

func (s *slowStreamWS) Close() error {
	s.closed = true
	return nil
}

func sleepWithinHostDeadline(stepDelay, callTimeout time.Duration, hostDeadline time.Time) error {
	wait := stepDelay
	if callTimeout > 0 && callTimeout < wait {
		wait = callTimeout
	}
	remainingHost := time.Until(hostDeadline)
	if wait >= remainingHost {
		if remainingHost > 0 {
			time.Sleep(remainingHost)
		}
		return errors.New("module closed with context deadline exceeded")
	}
	if wait > 0 {
		time.Sleep(wait)
	}
	return nil
}

func TestRunDuskCheckSlowDependencyProducesTimelyWarningWithDetails(t *testing.T) {
	hostTimeout := 160 * time.Millisecond
	hostDeadline := time.Now().Add(hostTimeout)

	ws := &slowStreamWS{
		sessionID:    "session-slow-456",
		sessionDelay: 25 * time.Millisecond,
		hostDeadline: hostDeadline,
	}

	var dialTimeout time.Duration
	var subTimeout time.Duration
	httpClient := &fakeHTTP{}

	start := time.Now()
	result := runDuskCheck(
		Config{NodeAddress: "localhost:8080", Timeout: "120ms"},
		func(_ string, timeout time.Duration) (webSocketConn, error) {
			dialTimeout = timeout
			if err := sleepWithinHostDeadline(25*time.Millisecond, timeout, hostDeadline); err != nil {
				return nil, err
			}
			return ws, nil
		},
		slowHTTPDoerFunc(func(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
			subTimeout = time.Duration(req.TimeoutMS) * time.Millisecond
			if err := sleepWithinHostDeadline(25*time.Millisecond, subTimeout, hostDeadline); err != nil {
				return nil, err
			}
			return httpClient.Do(req)
		}),
	)
	elapsed := time.Since(start)

	if elapsed >= hostTimeout || strings.Contains(result.Summary, "module closed with context deadline exceeded") {
		t.Fatalf("runDuskCheck exceeded host deadline (%v >= %v): status=%s summary=%q", elapsed, hostTimeout, result.Status, result.Summary)
	}
	if got := parseTimeout(""); got >= 10*time.Second {
		t.Fatalf("default timeout %v must stay below the 10s Wasm plugin deadline", got)
	}
	if got := parseTimeout("30s"); got >= 10*time.Second {
		t.Fatalf("configured 30s timeout %v must be capped below the 10s Wasm plugin deadline", got)
	}
	if dialTimeout <= 0 || dialTimeout >= 120*time.Millisecond {
		t.Fatalf("dial timeout %v was not bounded below total check budget", dialTimeout)
	}
	if subTimeout <= 0 || subTimeout >= 120*time.Millisecond {
		t.Fatalf("subscribe timeout %v was not bounded below total check budget", subTimeout)
	}
	for i, rt := range ws.recvTimeouts {
		if rt <= 0 || rt >= 120*time.Millisecond {
			t.Fatalf("recv[%d] timeout %v was not bounded below total check budget", i, rt)
		}
	}
	if !ws.closed {
		t.Fatal("websocket was not closed")
	}
	if result.Status != sdk.StatusWarning {
		t.Fatalf("status = %s, want %s (summary=%q)", result.Status, sdk.StatusWarning, result.Summary)
	}
	if strings.TrimSpace(result.Details) == "" {
		t.Fatal("expected partial failure details to be populated")
	}
	if !strings.Contains(result.Details, "session-slow-456") {
		t.Fatalf("expected details to include RUES session context, got %q", result.Details)
	}
}

type slowHTTPDoerFunc func(sdk.HTTPRequest) (*sdk.HTTPResponse, error)

func (f slowHTTPDoerFunc) Do(req sdk.HTTPRequest) (*sdk.HTTPResponse, error) {
	return f(req)
}

type recordingWS struct {
	messages [][]byte
	timeouts []time.Duration
	closed   bool
}

func (r *recordingWS) Recv(buf []byte, timeout time.Duration) (int, error) {
	r.timeouts = append(r.timeouts, timeout)
	if len(r.messages) == 0 {
		return 0, errors.New("no more messages")
	}
	msg := r.messages[0]
	r.messages = r.messages[1:]
	copy(buf, msg)
	return len(msg), nil
}

func (r *recordingWS) Close() error {
	r.closed = true
	return nil
}

func acceptedBlockFrame(height string) []byte {
	payload := `{"Content-Location":"/on/blocks/accepted"}{"header":{"height":` + height +
		`,"hash":"abcdef0123456789","timestamp":1778270000}}`
	return append([]byte{0, 0, 0, 42}, []byte(payload)...)
}

func TestRunDuskCheckSubMillisecondBudgetStaysOneMillisecondOnHost(t *testing.T) {
	var dialTimeout time.Duration
	var sessionTimeout time.Duration
	gotDial := false
	gotSession := false

	for i := 0; i < 100 && (!gotDial || !gotSession); i++ {
		ws := &recordingWS{messages: [][]byte{[]byte("session-subms")}}
		_ = runDuskCheck(
			Config{NodeAddress: "127.0.0.1:8080", Timeout: "500us"},
			func(_ string, timeout time.Duration) (webSocketConn, error) {
				if !gotDial {
					dialTimeout = timeout
					gotDial = true
				}
				return ws, nil
			},
			&fakeHTTP{},
		)
		if len(ws.timeouts) > 0 && !gotSession {
			sessionTimeout = ws.timeouts[0]
			gotSession = true
		}
	}

	if !gotDial || !gotSession {
		t.Fatalf("500us budget never reached dial=%v session recv=%v", gotDial, gotSession)
	}
	// Host websocket timeouts are whole milliseconds. 0ms is rewritten to the
	// assignment deadline (10s), which overruns the Wasm module context.
	if dialTimeout != time.Millisecond {
		t.Fatalf("dial timeout = %v, want 1ms so the host does not expand it", dialTimeout)
	}
	if sessionTimeout != time.Millisecond {
		t.Fatalf("session recv timeout = %v, want 1ms so the host does not expand it", sessionTimeout)
	}
}

func TestReadNextBlockSubMillisecondRecvStaysOneMillisecond(t *testing.T) {
	frame := acceptedBlockFrame("7")
	var timeouts []time.Duration
	var block blockData
	var err error

	for i := 0; i < 50 && len(timeouts) < 2; i++ {
		ws := &recordingWS{messages: [][]byte{{0, 0}, frame}}
		block, err = readNextBlock(ws, 500*time.Microsecond)
		timeouts = ws.timeouts
	}

	if len(timeouts) < 2 {
		t.Fatal("parse-skip loop never issued a second recv inside a 500us budget")
	}
	for i, timeout := range timeouts {
		if timeout != time.Millisecond {
			t.Fatalf("recv[%d] timeout = %v, want 1ms so the host does not expand it", i, timeout)
		}
	}
	if err != nil {
		t.Fatalf("readNextBlock: %v", err)
	}
	if block.Height != 7 {
		t.Fatalf("height = %d", block.Height)
	}
}

func TestRunDuskCheckBlockWaitUsesRemainingCheckDeadline(t *testing.T) {
	ws := &recordingWS{messages: [][]byte{
		[]byte("session-block-wait"),
		acceptedBlockFrame("11"),
	}}
	httpClient := &fakeHTTP{}

	result := runDuskCheck(
		Config{NodeAddress: "127.0.0.1:8080", Timeout: "8s"},
		func(_ string, timeout time.Duration) (webSocketConn, error) {
			if timeout <= 0 || timeout > 2*time.Second {
				t.Fatalf("dial timeout = %v, want a handshake step of at most 2s", timeout)
			}
			return ws, nil
		},
		httpClient,
	)

	if result.Status != sdk.StatusOK {
		t.Fatalf("status = %s, summary = %q", result.Status, result.Summary)
	}
	if len(ws.timeouts) != 2 {
		t.Fatalf("recv timeouts = %v", ws.timeouts)
	}
	if ws.timeouts[0] <= 0 || ws.timeouts[0] > 2*time.Second {
		t.Fatalf("session timeout = %v, want a handshake step of at most 2s", ws.timeouts[0])
	}
	if len(httpClient.requests) != 1 {
		t.Fatalf("subscription requests = %d", len(httpClient.requests))
	}
	if got := httpClient.requests[0].TimeoutMS; got <= 0 || got > 2000 {
		t.Fatalf("subscribe TimeoutMS = %d, want a handshake step of at most 2000ms", got)
	}
	// Dusk accepted blocks are about 10s apart. The wait may use whatever is
	// left of the 8s check deadline; a 5s or three-quarter cap warns early.
	blockWait := ws.timeouts[1]
	if blockWait <= 6*time.Second || blockWait > 8*time.Second {
		t.Fatalf("block wait = %v, want the time still left on the 8s check deadline", blockWait)
	}
}
