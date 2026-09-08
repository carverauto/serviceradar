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
