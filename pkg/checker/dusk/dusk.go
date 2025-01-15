package dusk

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/metadata"
)

const (
	lengthPrefixSize = 4 // 4
	blockHistorySize = 100
)

type Config struct {
	NodeAddress string        `json:"node_address"`
	Timeout     time.Duration `json:"timeout"` // Keep as time.Duration
	ListenAddr  string        `json:"listen_addr"`
}

type BlockData struct {
	Height    uint64    `json:"height"`
	Hash      string    `json:"hash"`
	Timestamp time.Time `json:"timestamp"`
	LastSeen  time.Time `json:"last_seen"`
}

type DuskChecker struct {
	Config        Config
	ws            *websocket.Conn
	sessionID     string
	lastBlock     time.Time
	mu            sync.RWMutex
	Done          chan struct{}
	lastBlockData BlockData
	blockHistory  []BlockData // Keep last N blocks
}

type HealthServer struct {
	grpc_health_v1.UnimplementedHealthServer
	checker   *DuskChecker
	startTime time.Time
}

func NewHealthServer(checker *DuskChecker) *HealthServer {
	return &HealthServer{
		checker:   checker,
		startTime: time.Now(),
	}
}

func (c *Config) UnmarshalJSON(data []byte) error {
	type Alias Config // Create alias to avoid recursion

	aux := &struct {
		Timeout string `json:"timeout"`
		*Alias
	}{
		Alias: (*Alias)(c),
	}

	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}

	// Parse the timeout string into a duration
	if aux.Timeout != "" {
		duration, err := time.ParseDuration(aux.Timeout)
		if err != nil {
			return fmt.Errorf("invalid timeout format: %w", err)
		}

		c.Timeout = duration
	}

	return nil
}

func (d *DuskChecker) StartMonitoring() error {
	// First establish WebSocket connection
	log.Printf("Connecting to Dusk node at %s", d.Config.NodeAddress)

	u := url.URL{Scheme: "ws", Host: d.Config.NodeAddress, Path: "/on"}

	conn, _, err := websocket.DefaultDialer.Dial(u.String(), nil)
	if err != nil {
		return fmt.Errorf("websocket dial failed: %w", err)
	}

	d.ws = conn

	// Read session ID
	_, message, err := d.ws.ReadMessage()
	if err != nil {
		if err = d.ws.Close(); err != nil {
			return err
		}

		return fmt.Errorf("failed to read session ID: %w", err)
	}

	d.sessionID = string(message)
	log.Printf("Received session ID: %s", d.sessionID)

	// Create HTTP client for subscription
	client := &http.Client{}

	// Prepare subscription request according to RUES spec
	subscribeURL := fmt.Sprintf("http://%s/on/blocks/accepted", d.Config.NodeAddress) //+nolint: gosec

	req, err := http.NewRequest(http.MethodGet, subscribeURL, http.NoBody)
	if err != nil {
		return fmt.Errorf("failed to create subscription request: %w", err)
	}

	// Add required headers as per RUES spec
	req.Header.Set("Rusk-Version", "1.0")
	req.Header.Set("Rusk-Session-Id", d.sessionID)

	log.Printf("Sending subscription request to: %s", subscribeURL)
	log.Printf("With headers: %v", req.Header)

	// Send subscription request
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("subscription request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("subscription failed with status %d: %s", resp.StatusCode, string(body))
	}

	log.Printf("Successfully subscribed to block events")

	// Start listening for events
	go d.listenForEvents()

	return nil
}

func (d *DuskChecker) listenForEvents() {
	log.Printf("Starting event listener for websocket connection")
	defer func(ws *websocket.Conn) {
		err := ws.Close()
		if err != nil {
			log.Printf("Error closing websocket connection: %v", err)
		}
	}(d.ws)

	for {
		select {
		case <-d.Done:
			return
		default:
			messageType, data, err := d.ws.ReadMessage()
			if err != nil {
				log.Printf("Websocket error: %v", err)
				return
			}

			if messageType == websocket.BinaryMessage {
				// Skip the first 4 bytes (length prefix)
				if len(data) < lengthPrefixSize {
					log.Printf("Received message too short: %d bytes", len(data))
					continue
				}

				jsonData := data[lengthPrefixSize:] // Skip length prefix

				// First try to find the boundary between the two JSON objects
				var firstObj struct {
					ContentLocation string `json:"Content-Location"`
				}

				decoder := json.NewDecoder(strings.NewReader(string(jsonData)))

				if err := decoder.Decode(&firstObj); err != nil {
					log.Printf("Error parsing content location: %v", err)
					continue
				}

				// Now decode the block data
				var blockData struct {
					Header struct {
						Height    uint64 `json:"height"`
						Hash      string `json:"hash"`
						Timestamp int64  `json:"timestamp"`
					} `json:"header"`
				}

				if err := decoder.Decode(&blockData); err != nil {
					log.Printf("Error parsing block data: %v", err)
					continue
				}

				d.mu.Lock()
				d.lastBlock = time.Now()
				d.lastBlockData = BlockData{
					Height:    blockData.Header.Height,
					Hash:      blockData.Header.Hash,
					Timestamp: time.Unix(blockData.Header.Timestamp, 0),
					LastSeen:  time.Now(),
				}

				// Keep last 100 blocks
				if len(d.blockHistory) >= blockHistorySize {
					d.blockHistory = d.blockHistory[1:]
				}

				d.blockHistory = append(d.blockHistory, d.lastBlockData)
				d.mu.Unlock()

				log.Printf("Block processed: Height=%d Hash=%s Timestamp=%v",
					blockData.Header.Height,
					blockData.Header.Hash,
					time.Unix(blockData.Header.Timestamp, 0))
			}
		}
	}
}

func (s *HealthServer) Check(ctx context.Context, _ *grpc_health_v1.HealthCheckRequest) (*grpc_health_v1.HealthCheckResponse, error) {
	s.checker.mu.RLock()
	defer s.checker.mu.RUnlock()

	if s.checker.ws == nil {
		return &grpc_health_v1.HealthCheckResponse{
			Status: grpc_health_v1.HealthCheckResponse_NOT_SERVING,
		}, fmt.Errorf("no websocket connection established")
	}

	// Create block details structure
	blockData := map[string]interface{}{
		"height":    s.checker.lastBlockData.Height,
		"hash":      s.checker.lastBlockData.Hash,
		"timestamp": s.checker.lastBlockData.Timestamp,
		"last_seen": s.checker.lastBlockData.LastSeen,
		"history":   s.checker.blockHistory,
	}

	// Convert to JSON
	blockDetailsJSON, err := json.Marshal(blockData)
	if err != nil {
		log.Printf("Error marshaling block details: %v", err)
	} else {
		// Create new outgoing metadata
		md := metadata.Pairs("block-details", string(blockDetailsJSON))

		// Send metadata back as header
		err := grpc.SetHeader(ctx, md)
		if err != nil {
			return nil, err
		}
	}

	if s.checker.lastBlock.IsZero() {
		log.Printf("Health check warning: Connected but no blocks received yet. Session ID: %s", s.checker.sessionID)

		return &grpc_health_v1.HealthCheckResponse{
			Status: grpc_health_v1.HealthCheckResponse_NOT_SERVING,
		}, nil
	}

	timeSinceLastBlock := time.Since(s.checker.lastBlock)
	if timeSinceLastBlock > s.checker.Config.Timeout {
		log.Printf("Health check failed: No blocks received in %v. Last block at: %v",
			timeSinceLastBlock, s.checker.lastBlock.Format(time.RFC3339))

		return &grpc_health_v1.HealthCheckResponse{
			Status: grpc_health_v1.HealthCheckResponse_NOT_SERVING,
		}, nil
	}

	return &grpc_health_v1.HealthCheckResponse{
		Status: grpc_health_v1.HealthCheckResponse_SERVING,
	}, nil
}

func LoadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("failed to read config: %w", err)
	}

	var config Config
	if err := json.Unmarshal(data, &config); err != nil {
		return Config{}, fmt.Errorf("failed to parse config: %w", err)
	}

	log.Printf("Loaded config with timeout: %v", config.Timeout)

	return config, nil
}

func (d *DuskChecker) GetStatusData() json.RawMessage {
	d.mu.RLock()
	defer d.mu.RUnlock()

	data, _ := json.Marshal(d.lastBlock)

	return data
}
