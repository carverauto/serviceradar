// Package main implements the dusk-checker WASM plugin for ServiceRadar.
// It monitors Dusk blockchain nodes via their WebSocket API.
package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/sdk"
)

// Config holds the plugin configuration.
type Config struct {
	NodeAddress string `json:"node_address"`
	Timeout     string `json:"timeout"`
}

// JSONRPCRequest represents a JSON-RPC 2.0 request.
type JSONRPCRequest struct {
	JSONRPC string      `json:"jsonrpc"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params,omitempty"`
	ID      int         `json:"id"`
}

// JSONRPCResponse represents a JSON-RPC 2.0 response.
type JSONRPCResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *JSONRPCError   `json:"error,omitempty"`
	ID      int             `json:"id"`
}

// JSONRPCError represents a JSON-RPC 2.0 error.
type JSONRPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// BlockHeightResult holds the block height response.
type BlockHeightResult struct {
	Height int64 `json:"height"`
}

// PeerCountResult holds the peer count response.
type PeerCountResult struct {
	Count int `json:"count"`
}

//export run_check
func run_check() {
	_ = sdk.Execute(func() (*sdk.Result, error) {
		// TinyGo workaround: explicitly unmarshal to include reflection metadata.
		// Without this, TinyGo's linker optimizes away the reflection data needed
		// for json.Unmarshal to work with our Config struct.
		var initCfg Config
		_ = json.Unmarshal([]byte(`{"node_address":"x","timeout":"1s"}`), &initCfg)

		// Load configuration from host
		cfg := Config{}
		if err := sdk.LoadConfig(&cfg); err != nil {
			sdk.Log.Warn("Failed to load config: " + err.Error())
		}

		if cfg.NodeAddress == "" {
			return sdk.Unknown("Configuration error: node_address is required"), nil
		}

		// Parse timeout
		timeout := 30 * time.Second
		if cfg.Timeout != "" {
			if parsed, err := time.ParseDuration(cfg.Timeout); err == nil {
				timeout = parsed
			}
		}

		// Build WebSocket URL
		wsURL := cfg.NodeAddress
		if !strings.HasPrefix(wsURL, "ws://") && !strings.HasPrefix(wsURL, "wss://") {
			wsURL = "ws://" + wsURL
		}
		if !strings.Contains(wsURL, "/ws") {
			wsURL = wsURL + "/ws"
		}

		sdk.Log.Debug("Connecting to Dusk node at " + wsURL)

		// Connect to WebSocket
		conn, err := sdk.WebSocketConnect(wsURL, timeout)
		if err != nil {
			return sdk.Critical(fmt.Sprintf("Failed to connect to Dusk node: %v", err)), nil
		}
		defer conn.Close()

		// Query block height
		blockHeight, err := queryBlockHeight(conn, timeout)
		if err != nil {
			return sdk.Critical(fmt.Sprintf("Failed to query block height: %v", err)), nil
		}

		// Query peer count
		peerCount, err := queryPeerCount(conn, timeout)
		if err != nil {
			// Peer count is optional - log warning but don't fail
			sdk.Log.Warn("Failed to query peer count: " + err.Error())
			peerCount = -1
		}

		// Build result summary
		// Note: We avoid using WithLabel/WithMetric due to TinyGo map serialization issues.
		// All information is included in the summary text instead.
		var summary string
		if peerCount >= 0 {
			summary = fmt.Sprintf("Block height: %d, peers: %d", blockHeight, peerCount)
		} else {
			summary = fmt.Sprintf("Block height: %d", blockHeight)
		}

		// Determine status based on metrics
		status := sdk.StatusOK
		if peerCount == 0 {
			status = sdk.StatusWarning
			summary = summary + " (no peers)"
		}

		result := sdk.NewResult().
			WithStatus(status).
			WithSummary(summary)

		return result, nil
	})
}

func queryBlockHeight(conn *sdk.WebSocketConn, timeout time.Duration) (int64, error) {
	req := JSONRPCRequest{
		JSONRPC: "2.0",
		Method:  "chain_getBlockHeight",
		ID:      1,
	}

	reqData, err := json.Marshal(req)
	if err != nil {
		return 0, fmt.Errorf("marshal request: %w", err)
	}

	if err := conn.Send(reqData, timeout); err != nil {
		return 0, fmt.Errorf("write request: %w", err)
	}

	buf := make([]byte, 4096)
	n, err := conn.Recv(buf, timeout)
	if err != nil {
		return 0, fmt.Errorf("read response: %w", err)
	}
	respData := buf[:n]

	var resp JSONRPCResponse
	if err := json.Unmarshal(respData, &resp); err != nil {
		return 0, fmt.Errorf("unmarshal response: %w", err)
	}

	if resp.Error != nil {
		return 0, fmt.Errorf("RPC error %d: %s", resp.Error.Code, resp.Error.Message)
	}

	// Try to parse as a simple number first
	var height int64
	if err := json.Unmarshal(resp.Result, &height); err != nil {
		// Try as an object with height field
		var result BlockHeightResult
		if err := json.Unmarshal(resp.Result, &result); err != nil {
			return 0, fmt.Errorf("parse block height: %w", err)
		}
		height = result.Height
	}

	return height, nil
}

func queryPeerCount(conn *sdk.WebSocketConn, timeout time.Duration) (int, error) {
	req := JSONRPCRequest{
		JSONRPC: "2.0",
		Method:  "net_peerCount",
		ID:      2,
	}

	reqData, err := json.Marshal(req)
	if err != nil {
		return 0, fmt.Errorf("marshal request: %w", err)
	}

	if err := conn.Send(reqData, timeout); err != nil {
		return 0, fmt.Errorf("write request: %w", err)
	}

	buf := make([]byte, 4096)
	n, err := conn.Recv(buf, timeout)
	if err != nil {
		return 0, fmt.Errorf("read response: %w", err)
	}
	respData := buf[:n]

	var resp JSONRPCResponse
	if err := json.Unmarshal(respData, &resp); err != nil {
		return 0, fmt.Errorf("unmarshal response: %w", err)
	}

	if resp.Error != nil {
		return 0, fmt.Errorf("RPC error %d: %s", resp.Error.Code, resp.Error.Message)
	}

	// Try to parse as a simple number first
	var count int
	if err := json.Unmarshal(resp.Result, &count); err != nil {
		// Try as an object with count field
		var result PeerCountResult
		if err := json.Unmarshal(resp.Result, &result); err != nil {
			return 0, fmt.Errorf("parse peer count: %w", err)
		}
		count = result.Count
	}

	return count, nil
}

func main() {}
