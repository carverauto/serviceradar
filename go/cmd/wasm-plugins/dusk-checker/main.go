// Package main implements the dusk-checker WASM plugin for ServiceRadar.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

const (
	defaultTimeout          = 30 * time.Second
	defaultWebSocketPath    = "/on"
	defaultSubscriptionPath = "/on/blocks/accepted"
	lengthPrefixSize        = 4
)

var (
	duskHTTP = &sdk.HTTPClient{MaxResponseBytes: sdk.MaxHTTPResponseBytes}

	duskWebSocketDial = func(rawURL string, timeout time.Duration) (webSocketConn, error) {
		return sdk.WebSocketConnect(rawURL, timeout)
	}
)

// Config holds the plugin configuration.
type Config struct {
	NodeAddress      string `json:"node_address"`
	Timeout          string `json:"timeout"`
	WebSocketPath    string `json:"websocket_path,omitempty"`
	SubscriptionPath string `json:"subscription_path,omitempty"`
}

type webSocketConn interface {
	Recv([]byte, time.Duration) (int, error)
	Close() error
}

type httpDoer interface {
	Do(sdk.HTTPRequest) (*sdk.HTTPResponse, error)
}

type blockData struct {
	Height    uint64
	Hash      string
	Timestamp time.Time
	LastSeen  time.Time
}

//export run_check
func run_check() {
	_ = sdk.Execute(func() (*sdk.Result, error) {
		// TinyGo workaround: explicitly unmarshal to include reflection metadata.
		var initCfg Config
		_ = json.Unmarshal([]byte(`{"node_address":"localhost:8080","timeout":"1s","websocket_path":"/on","subscription_path":"/on/blocks/accepted"}`), &initCfg)

		cfg := Config{}
		if err := sdk.LoadConfig(&cfg); err != nil {
			sdk.Log.Warn("Failed to load config: " + err.Error())
		}

		result := runDuskCheck(cfg, duskWebSocketDial, duskHTTP)
		return result, nil
	})
}

func runDuskCheck(cfg Config, dial func(string, time.Duration) (webSocketConn, error), client httpDoer) *sdk.Result {
	if strings.TrimSpace(cfg.NodeAddress) == "" {
		return sdk.Unknown("Configuration error: node_address is required")
	}

	timeout := parseTimeout(cfg.Timeout)
	wsURL, subscribeURL, err := duskURLs(cfg)
	if err != nil {
		return sdk.Unknown("Configuration error: " + err.Error())
	}

	sdk.Log.Debug("Connecting to Dusk RUES stream at " + wsURL)

	conn, err := dial(wsURL, timeout)
	if err != nil {
		return sdk.Critical(fmt.Sprintf("Failed to connect to Dusk node: %v", err))
	}
	defer conn.Close()

	sessionID, err := readSessionID(conn, timeout)
	if err != nil {
		return sdk.Critical(fmt.Sprintf("Failed to read Dusk RUES session id: %v", err))
	}

	if err := subscribeToBlocks(client, subscribeURL, sessionID, timeout); err != nil {
		return sdk.Critical(fmt.Sprintf("Failed to subscribe to Dusk accepted blocks: %v", err))
	}

	block, err := readNextBlock(conn, timeout)
	if err != nil {
		return sdk.Critical(fmt.Sprintf("Failed to read Dusk accepted block: %v", err))
	}

	age := time.Since(block.Timestamp)
	if age < 0 {
		age = 0
	}

	summary := fmt.Sprintf(
		"Block height: %d, hash: %s, timestamp: %s, age: %.1fs",
		block.Height,
		shortHash(block.Hash),
		block.Timestamp.UTC().Format(time.RFC3339),
		age.Seconds(),
	)

	return sdk.NewResult().
		WithStatus(sdk.StatusOK).
		WithSummary(summary)
}

func parseTimeout(raw string) time.Duration {
	timeout := defaultTimeout
	if strings.TrimSpace(raw) == "" {
		return timeout
	}
	if parsed, err := time.ParseDuration(strings.TrimSpace(raw)); err == nil && parsed > 0 {
		return parsed
	}
	return timeout
}

func duskURLs(cfg Config) (string, string, error) {
	rawAddress := strings.TrimSpace(cfg.NodeAddress)
	if rawAddress == "" {
		return "", "", fmt.Errorf("node_address is required")
	}

	if !strings.Contains(rawAddress, "://") {
		rawAddress = "ws://" + rawAddress
	}

	parsed, err := url.Parse(rawAddress)
	if err != nil {
		return "", "", fmt.Errorf("invalid node_address: %w", err)
	}
	if parsed.Host == "" {
		return "", "", fmt.Errorf("node_address must include a host")
	}

	switch parsed.Scheme {
	case "ws", "wss":
	case "http":
		parsed.Scheme = "ws"
	case "https":
		parsed.Scheme = "wss"
	default:
		return "", "", fmt.Errorf("unsupported node_address scheme %q", parsed.Scheme)
	}

	if parsed.Path == "" || parsed.Path == "/" {
		parsed.Path = cleanPluginPath(cfg.WebSocketPath, defaultWebSocketPath)
	}
	wsURL := parsed.String()

	subscribe := *parsed
	if parsed.Scheme == "wss" {
		subscribe.Scheme = "https"
	} else {
		subscribe.Scheme = "http"
	}
	subscribe.Path = cleanPluginPath(cfg.SubscriptionPath, defaultSubscriptionPath)
	subscribe.RawQuery = ""
	subscribe.Fragment = ""

	return wsURL, subscribe.String(), nil
}

func cleanPluginPath(raw, fallback string) string {
	path := strings.TrimSpace(raw)
	if path == "" {
		path = fallback
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	return path
}

func readSessionID(conn webSocketConn, timeout time.Duration) (string, error) {
	buf := make([]byte, 4096)
	n, err := conn.Recv(buf, timeout)
	if err != nil {
		return "", err
	}
	sessionID := strings.TrimSpace(string(buf[:n]))
	if sessionID == "" {
		return "", fmt.Errorf("empty RUES session id")
	}
	return sessionID, nil
}

func subscribeToBlocks(client httpDoer, subscribeURL, sessionID string, timeout time.Duration) error {
	resp, err := client.Do(sdk.HTTPRequest{
		Method: http.MethodGet,
		URL:    subscribeURL,
		Headers: map[string]string{
			"Rusk-Version":    "1.0",
			"Rusk-Session-Id": sessionID,
		},
		TimeoutMS: int(timeout.Milliseconds()),
	})
	if err != nil {
		return err
	}
	if resp == nil {
		return fmt.Errorf("empty subscription response")
	}
	if resp.Status != http.StatusOK {
		body := strings.TrimSpace(string(resp.Body))
		if body == "" {
			body = http.StatusText(resp.Status)
		}
		return fmt.Errorf("subscription returned HTTP %d: %s", resp.Status, body)
	}
	return nil
}

func readNextBlock(conn webSocketConn, timeout time.Duration) (blockData, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error

	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			if lastErr != nil {
				return blockData{}, lastErr
			}
			return blockData{}, fmt.Errorf("timed out waiting for accepted block")
		}

		buf := make([]byte, 64*1024)
		n, err := conn.Recv(buf, remaining)
		if err != nil {
			return blockData{}, err
		}

		block, err := parseBlockMessage(buf[:n])
		if err == nil {
			return block, nil
		}
		lastErr = err
		sdk.Log.Warn("Failed to parse Dusk block event: " + err.Error())
	}
}

func parseBlockMessage(data []byte) (blockData, error) {
	if len(data) < lengthPrefixSize {
		return blockData{}, fmt.Errorf("message too short: %d bytes", len(data))
	}

	decoder := json.NewDecoder(bytes.NewReader(data[lengthPrefixSize:]))

	var envelope struct {
		ContentLocation string `json:"Content-Location"`
	}
	if err := decoder.Decode(&envelope); err != nil {
		return blockData{}, fmt.Errorf("parse content location: %w", err)
	}

	var payload struct {
		Header struct {
			Height    uint64 `json:"height"`
			Hash      string `json:"hash"`
			Timestamp int64  `json:"timestamp"`
		} `json:"header"`
	}
	if err := decoder.Decode(&payload); err != nil {
		return blockData{}, fmt.Errorf("parse block payload: %w", err)
	}
	if payload.Header.Height == 0 {
		return blockData{}, fmt.Errorf("block height missing")
	}

	return blockData{
		Height:    payload.Header.Height,
		Hash:      payload.Header.Hash,
		Timestamp: time.Unix(payload.Header.Timestamp, 0),
		LastSeen:  time.Now(),
	}, nil
}

func shortHash(hash string) string {
	hash = strings.TrimSpace(hash)
	if len(hash) <= 16 {
		return hash
	}
	return hash[:16]
}

func main() {}
