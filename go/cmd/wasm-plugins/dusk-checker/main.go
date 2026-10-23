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
	defaultTimeout          = 8 * time.Second
	maxTimeout              = 8 * time.Second
	maxHandshakeStepTimeout = 2 * time.Second
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

type checkDetails struct {
	NodeAddress    string   `json:"node_address"`
	WebSocketURL   string   `json:"websocket_url"`
	SubscribeURL   string   `json:"subscribe_url"`
	SessionID      string   `json:"session_id,omitempty"`
	CompletedSteps []string `json:"completed_steps,omitempty"`
	FailedStage    string   `json:"failed_stage,omitempty"`
	Error          string   `json:"error,omitempty"`
	Timeout        string   `json:"timeout"`
	BlockHeight    uint64   `json:"block_height,omitempty"`
	BlockHash      string   `json:"block_hash,omitempty"`
	BlockTimestamp string   `json:"block_timestamp,omitempty"`
	BlockAgeSec    float64  `json:"block_age_seconds,omitempty"`
}

func encodeCheckDetails(details checkDetails) string {
	data, err := json.Marshal(details)
	if err != nil {
		return ""
	}
	return string(data)
}

func runDuskCheck(cfg Config, dial func(string, time.Duration) (webSocketConn, error), client httpDoer) *sdk.Result {
	if strings.TrimSpace(cfg.NodeAddress) == "" {
		return sdk.Unknown("Configuration error: node_address is required")
	}

	totalTimeout := parseTimeout(cfg.Timeout)
	wsURL, subscribeURL, err := duskURLs(cfg)
	if err != nil {
		return sdk.Unknown("Configuration error: " + err.Error())
	}

	deadline := time.Now().Add(totalTimeout)
	details := checkDetails{
		NodeAddress:  strings.TrimSpace(cfg.NodeAddress),
		WebSocketURL: wsURL,
		SubscribeURL: subscribeURL,
		Timeout:      totalTimeout.String(),
	}

	sdk.Log.Debug("Connecting to Dusk RUES stream at " + wsURL)

	dialTimeout, err := boundedStepTimeout(deadline, totalTimeout, 3, maxHandshakeStepTimeout)
	if err != nil {
		details.FailedStage = "websocket_connect"
		details.Error = err.Error()
		return sdk.Critical(fmt.Sprintf("Failed to connect to Dusk node: %v", err)).
			WithDetails(encodeCheckDetails(details))
	}

	conn, err := dial(wsURL, hostStepTimeout(dialTimeout))
	if err != nil {
		details.FailedStage = "websocket_connect"
		details.Error = err.Error()
		return sdk.Critical(fmt.Sprintf("Failed to connect to Dusk node: %v", err)).
			WithDetails(encodeCheckDetails(details))
	}
	defer conn.Close()
	details.CompletedSteps = append(details.CompletedSteps, "websocket_connect")

	sessionTimeout, err := boundedStepTimeout(deadline, totalTimeout, 3, maxHandshakeStepTimeout)
	if err != nil {
		details.FailedStage = "read_session_id"
		details.Error = err.Error()
		return sdk.Warning(fmt.Sprintf("Dusk RUES connected, but reading session id timed out: %v", err)).
			WithDetails(encodeCheckDetails(details))
	}

	sessionID, err := readSessionID(conn, sessionTimeout)
	if err != nil {
		details.FailedStage = "read_session_id"
		details.Error = err.Error()
		return sdk.Warning(fmt.Sprintf("Dusk RUES connected, but failed to read session id: %v", err)).
			WithDetails(encodeCheckDetails(details))
	}
	details.SessionID = sessionID
	details.CompletedSteps = append(details.CompletedSteps, "read_session_id")

	subTimeout, err := boundedStepTimeout(deadline, totalTimeout, 3, maxHandshakeStepTimeout)
	if err != nil {
		details.FailedStage = "subscribe_blocks"
		details.Error = err.Error()
		return sdk.Warning(fmt.Sprintf("Dusk RUES session established, but block subscription timed out: %v", err)).
			WithDetails(encodeCheckDetails(details))
	}

	if err := subscribeToBlocks(client, subscribeURL, sessionID, subTimeout); err != nil {
		details.FailedStage = "subscribe_blocks"
		details.Error = err.Error()
		return sdk.Warning(fmt.Sprintf("Dusk RUES session established, but failed to subscribe to accepted blocks: %v", err)).
			WithDetails(encodeCheckDetails(details))
	}
	details.CompletedSteps = append(details.CompletedSteps, "subscribe_blocks")

	blockWaitTimeout, err := boundedBlockWaitTimeout(deadline, totalTimeout)
	if err != nil {
		details.FailedStage = "read_next_block"
		details.Error = err.Error()
		return sdk.Warning(fmt.Sprintf("Dusk RUES subscribed, but no accepted block arrived within check window: %v", err)).
			WithDetails(encodeCheckDetails(details))
	}

	block, err := readNextBlock(conn, blockWaitTimeout)
	if err != nil {
		details.FailedStage = "read_next_block"
		details.Error = err.Error()
		return sdk.Warning(fmt.Sprintf("Dusk RUES subscribed, but no accepted block arrived within check window: %v", err)).
			WithDetails(encodeCheckDetails(details))
	}
	details.CompletedSteps = append(details.CompletedSteps, "read_next_block")

	age := time.Since(block.Timestamp)
	if age < 0 {
		age = 0
	}

	details.BlockHeight = block.Height
	details.BlockHash = block.Hash
	details.BlockTimestamp = block.Timestamp.UTC().Format(time.RFC3339)
	details.BlockAgeSec = age.Seconds()

	summary := fmt.Sprintf(
		"Block height: %d, hash: %s, timestamp: %s, age: %.1fs",
		block.Height,
		shortHash(block.Hash),
		block.Timestamp.UTC().Format(time.RFC3339),
		age.Seconds(),
	)

	return sdk.NewResult().
		WithStatus(sdk.StatusOK).
		WithSummary(summary).
		WithDetails(encodeCheckDetails(details))
}

func parseTimeout(raw string) time.Duration {
	timeout := defaultTimeout
	if trimmed := strings.TrimSpace(raw); trimmed != "" {
		if parsed, err := time.ParseDuration(trimmed); err == nil && parsed > 0 {
			timeout = parsed
		}
	}
	if timeout > maxTimeout {
		return maxTimeout
	}
	return timeout
}

func boundedStepTimeout(deadline time.Time, totalTimeout time.Duration, divisor time.Duration, capTimeout time.Duration) (time.Duration, error) {
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return 0, fmt.Errorf("check budget exhausted (%s)", totalTimeout)
	}

	limit := totalTimeout / divisor
	if limit <= 0 {
		limit = remaining
	}
	if capTimeout > 0 && limit > capTimeout {
		limit = capTimeout
	}
	if remaining < limit {
		limit = remaining
	}
	return limit, nil
}

func boundedBlockWaitTimeout(deadline time.Time, totalTimeout time.Duration) (time.Duration, error) {
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return 0, fmt.Errorf("check budget exhausted (%s)", totalTimeout)
	}
	return remaining, nil
}

func hostStepTimeout(timeout time.Duration) time.Duration {
	if timeout > 0 && timeout < time.Millisecond {
		return time.Millisecond
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
	n, err := conn.Recv(buf, hostStepTimeout(timeout))
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
		TimeoutMS: int(hostStepTimeout(timeout).Milliseconds()),
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
		n, err := conn.Recv(buf, hostStepTimeout(remaining))
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
