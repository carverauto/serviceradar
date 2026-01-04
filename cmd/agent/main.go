/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/pkg/agent"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

//go:embed config.json
var defaultConfig []byte

// Version is set at build time via ldflags
//
//nolint:gochecknoglobals // Required for build-time ldflags injection
var Version = "dev"

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/agent.json", "Path to agent config file")
	flag.Parse()

	// Setup a context we can use for loading the config and running the server
	ctx := context.Background()

	// Load configuration from file (no KV dependency)
	cfg, err := loadConfig(*configPath)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Create logger from loaded config
	logConfig := cfg.Logging
	if logConfig == nil {
		logConfig = &logger.Config{
			Level:  "info",
			Output: "stdout",
		}
	}

	agentLogger, err := lifecycle.CreateComponentLogger(ctx, "agent", logConfig)
	if err != nil {
		return fmt.Errorf("failed to initialize logger: %w", err)
	}

	// Create agent server
	server, err := agent.NewServer(ctx, cfg.CheckersDir, cfg, agentLogger)
	if err != nil {
		if shutdownErr := lifecycle.ShutdownLogger(); shutdownErr != nil {
			log.Printf("Failed to shutdown logger: %v", shutdownErr)
		}
		return fmt.Errorf("failed to create server: %w", err)
	}

	// Gateway address is required - agents must push status to gateway
	if cfg.GatewayAddr == "" {
		return agent.ErrGatewayAddrRequired
	}

	return runPushMode(ctx, server, cfg, agentLogger)
}

// loadConfig loads agent configuration from file, falling back to embedded defaults.
func loadConfig(configPath string) (*agent.ServerConfig, error) {
	var cfg agent.ServerConfig

	// Try to read config file
	data, err := os.ReadFile(configPath)
	if err != nil {
		if os.IsNotExist(err) {
			// Fall back to embedded default config
			data = defaultConfig
		} else {
			return nil, fmt.Errorf("failed to read config file: %w", err)
		}
	}

	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	return &cfg, nil
}

// runPushMode runs the agent in push mode, pushing status to the gateway.
func runPushMode(ctx context.Context, server *agent.Server, cfg *agent.ServerConfig, log logger.Logger) error {
	log.Info().
		Str("gateway_addr", cfg.GatewayAddr).
		Str("agent_id", cfg.AgentID).
		Msg("Starting agent in push mode")

	// Create gateway client
	gatewayClient := agent.NewGatewayClient(cfg.GatewayAddr, cfg.GatewaySecurity, log)

	// Connect to gateway
	if err := gatewayClient.Connect(ctx); err != nil {
		return fmt.Errorf("failed to connect to gateway: %w", err)
	}
	defer func() {
		if err := gatewayClient.Disconnect(); err != nil {
			log.Warn().Err(err).Msg("Error disconnecting from gateway")
		}
	}()

	// Step 1: Send Hello to register with gateway
	hostname, _ := os.Hostname()
	helloReq := &proto.AgentHelloRequest{
		AgentId:       cfg.AgentID,
		Version:       Version,
		Capabilities:  getAgentCapabilities(server),
		Hostname:      hostname,
		Os:            runtime.GOOS,
		Arch:          runtime.GOARCH,
		Partition:     cfg.Partition,
		ConfigVersion: "", // Empty on first connect, will be populated after GetConfig
	}

	helloResp, err := gatewayClient.Hello(ctx, helloReq)
	if err != nil {
		return fmt.Errorf("failed to enroll agent: %w", err)
	}

	// Update config with tenant info from gateway if not already set
	if cfg.TenantID == "" && helloResp.TenantId != "" {
		cfg.TenantID = helloResp.TenantId
	}
	if cfg.TenantSlug == "" && helloResp.TenantSlug != "" {
		cfg.TenantSlug = helloResp.TenantSlug
	}

	// Step 2: Get configuration from gateway
	configReq := &proto.AgentConfigRequest{
		AgentId:       cfg.AgentID,
		ConfigVersion: "", // Empty to get full config
	}

	configResp, err := gatewayClient.GetConfig(ctx, configReq)
	if err != nil {
		log.Warn().Err(err).Msg("Failed to get config from gateway, using local config")
		// Continue with local config - this is not fatal
	} else if !configResp.NotModified {
		// TODO: Apply config from gateway (checks, intervals, etc.)
		// For now, just use the heartbeat interval from the config
		log.Info().
			Str("config_version", configResp.ConfigVersion).
			Int("checks_count", len(configResp.Checks)).
			Msg("Received configuration from gateway")
	}

	// Determine push interval (prefer gateway config, fall back to local)
	pushInterval := time.Duration(cfg.PushInterval)
	if helloResp.HeartbeatIntervalSec > 0 {
		pushInterval = time.Duration(helloResp.HeartbeatIntervalSec) * time.Second
	}
	if pushInterval <= 0 {
		pushInterval = 30 * time.Second
	}

	// Create push loop
	pushLoop := agent.NewPushLoop(server, gatewayClient, pushInterval, log)

	// Create a cancellable context for the push loop
	pushCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Start the server's services (checkers, sweep, etc.)
	if err := server.Start(pushCtx); err != nil {
		return fmt.Errorf("failed to start agent services: %w", err)
	}
	defer func() {
		if err := server.Stop(context.Background()); err != nil {
			log.Error().Err(err).Msg("Error stopping agent services")
		}
	}()

	// Handle shutdown signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Start push loop in a goroutine
	errChan := make(chan error, 1)
	go func() {
		errChan <- pushLoop.Start(pushCtx)
	}()

	// Wait for shutdown signal or error
	select {
	case sig := <-sigChan:
		log.Info().Str("signal", sig.String()).Msg("Received shutdown signal")
		cancel()
		// Wait for push loop to stop
		<-errChan

	case err := <-errChan:
		if err != nil && !errors.Is(err, context.Canceled) {
			return fmt.Errorf("push loop error: %w", err)
		}
	}

	log.Info().Msg("Agent shutdown complete")
	return nil
}

// getAgentCapabilities returns the capabilities of this agent based on configured services.
func getAgentCapabilities(server *agent.Server) []string {
	// Base capabilities that all agents have
	capabilities := []string{"status", "push"}

	// Add capabilities based on configured checkers/services
	// TODO: Query the server for its configured services and add their types
	// For now, return base capabilities

	return capabilities
}
