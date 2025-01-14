// cmd/checkers/dusk/main.go
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health/grpc_health_v1"
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
	config        Config
	ws            *websocket.Conn
	sessionID     string
	lastBlock     time.Time
	mu            sync.RWMutex
	done          chan struct{}
	pingTicker    *time.Ticker
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

func (s *HealthServer) Check(ctx context.Context, req *grpc_health_v1.HealthCheckRequest) (*grpc_health_v1.HealthCheckResponse, error) {
	s.checker.mu.RLock()
	defer s.checker.mu.RUnlock()

	// Give 30 seconds grace period during startup
	if time.Since(s.startTime) < 30*time.Second {
		log.Printf("Health check during startup grace period (%v elapsed)", time.Since(s.startTime))
		return &grpc_health_v1.HealthCheckResponse{
			Status: grpc_health_v1.HealthCheckResponse_SERVING,
		}, nil
	}

	if s.checker.ws == nil {
		return &grpc_health_v1.HealthCheckResponse{
			Status: grpc_health_v1.HealthCheckResponse_NOT_SERVING,
		}, fmt.Errorf("no websocket connection established")
	}

	if s.checker.lastBlock.IsZero() {
		log.Printf("Health check warning: Connected but no blocks received yet. Session ID: %s", s.checker.sessionID)
		return &grpc_health_v1.HealthCheckResponse{
			Status: grpc_health_v1.HealthCheckResponse_NOT_SERVING,
		}, nil
	}

	timeSinceLastBlock := time.Since(s.checker.lastBlock)
	if timeSinceLastBlock > s.checker.config.Timeout {
		log.Printf("Health check failed: No blocks received in %v. Last block at: %v",
			timeSinceLastBlock, s.checker.lastBlock.Format(time.RFC3339))
		return &grpc_health_v1.HealthCheckResponse{
			Status: grpc_health_v1.HealthCheckResponse_NOT_SERVING,
		}, nil
	}

	log.Printf("Health check passed: Last block #%d received %v ago",
		s.checker.lastBlockData.Height,
		timeSinceLastBlock)

	return &grpc_health_v1.HealthCheckResponse{
		Status: grpc_health_v1.HealthCheckResponse_SERVING,
	}, nil
}

func main() {
	log.Printf("Starting Dusk checker...")

	configFile := flag.String("config", "/etc/homemon/checkers/dusk.json", "Path to config file")
	flag.Parse()

	log.Printf("Loading config from: %s", *configFile)
	config, err := loadConfig(*configFile)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}
	log.Printf("Loaded config: %+v", config)

	checker := &DuskChecker{
		config: config,
		done:   make(chan struct{}),
	}

	// Start monitoring Dusk node
	log.Printf("Starting monitoring...")
	if err := checker.startMonitoring(); err != nil {
		log.Fatalf("Failed to start monitoring: %v", err)
	}

	// Start gRPC server
	log.Printf("Starting gRPC server on %s", config.ListenAddr)
	lis, err := net.Listen("tcp", config.ListenAddr)
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}

	grpcServer := grpc.NewServer()
	healthServer := NewHealthServer(checker)
	grpc_health_v1.RegisterHealthServer(grpcServer, healthServer)
	log.Printf("Registered health server")

	// Handle shutdown gracefully
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigCh
		log.Printf("Received signal %v, shutting down", sig)
		close(checker.done)
		grpcServer.GracefulStop()
	}()

	log.Printf("Dusk checker is ready")
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("Failed to serve: %v", err)
	}
}

func (d *DuskChecker) startMonitoring() error {
	// First establish WebSocket connection
	log.Printf("Connecting to Dusk node at %s", d.config.NodeAddress)
	u := url.URL{Scheme: "ws", Host: d.config.NodeAddress, Path: "/on"}
	conn, _, err := websocket.DefaultDialer.Dial(u.String(), nil)
	if err != nil {
		return fmt.Errorf("websocket dial failed: %w", err)
	}
	d.ws = conn

	// Read session ID
	_, message, err := d.ws.ReadMessage()
	if err != nil {
		d.ws.Close()
		return fmt.Errorf("failed to read session ID: %w", err)
	}
	d.sessionID = string(message)
	log.Printf("Received session ID: %s", d.sessionID)

	// Create HTTP client for subscription
	client := &http.Client{}

	// Prepare subscription request according to RUES spec
	subscribeURL := fmt.Sprintf("http://%s/on/blocks/accepted", d.config.NodeAddress)
	req, err := http.NewRequest("GET", subscribeURL, nil)
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
	defer d.ws.Close()

	for {
		select {
		case <-d.done:
			return
		default:
			messageType, data, err := d.ws.ReadMessage()
			if err != nil {
				log.Printf("Websocket error: %v", err)
				return
			}

			if messageType == websocket.BinaryMessage {
				// Skip the first 4 bytes (length prefix)
				if len(data) < 4 {
					log.Printf("Received message too short: %d bytes", len(data))
					continue
				}
				jsonData := data[4:] // Skip length prefix

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
				if len(d.blockHistory) >= 100 {
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

func loadConfig(path string) (Config, error) {
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
