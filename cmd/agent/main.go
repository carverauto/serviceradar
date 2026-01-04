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
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/pkg/agent"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
)

//go:embed config.json
var defaultConfig []byte

// Version is set at build time via ldflags
//
//nolint:gochecknoglobals // Required for build-time ldflags injection
var Version = "dev"

var errConfigFileMissing = errors.New("config file not found")
var errConfigTrailingData = errors.New("config has trailing data")
var errShutdownTimeout = errors.New("shutdown timed out")

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

	// Ensure the agent package reports the same build version during enrollment.
	agent.Version = Version

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
			if os.Getenv("SR_ALLOW_EMBEDDED_DEFAULT_CONFIG") != "true" {
				return nil, fmt.Errorf(
					"%w at %s (set SR_ALLOW_EMBEDDED_DEFAULT_CONFIG=true to use embedded defaults)",
					errConfigFileMissing,
					configPath,
				)
			}
			// Fall back to embedded default config (explicitly allowed)
			data = defaultConfig
		} else {
			return nil, fmt.Errorf("failed to read config file: %w", err)
		}
	}

	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}
	if err := dec.Decode(&struct{}{}); err == nil {
		return nil, fmt.Errorf("failed to parse config: %w", errConfigTrailingData)
	} else if !errors.Is(err, io.EOF) {
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

	// Create gateway client (PushLoop handles connect/enroll/config polling)
	gatewayClient := agent.NewGatewayClient(cfg.GatewayAddr, cfg.GatewaySecurity, log)
	defer func() {
		if err := gatewayClient.Disconnect(); err != nil {
			log.Warn().Err(err).Msg("Error disconnecting from gateway")
		}
	}()

	// Create push loop
	interval := time.Duration(cfg.PushInterval)
	if interval <= 0 {
		// Let NewPushLoop apply its default interval
		interval = 0
	} else {
		// Safety bounds against misconfiguration
		const (
			minPushInterval = 1 * time.Second
			maxPushInterval = 1 * time.Hour
		)
		if interval < minPushInterval {
			interval = minPushInterval
		} else if interval > maxPushInterval {
			interval = maxPushInterval
		}
	}
	pushLoop := agent.NewPushLoop(server, gatewayClient, interval, log)

	// Create a cancellable context for the push loop
	pushCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Start the server's services (checkers, sweep, etc.)
	if err := server.Start(pushCtx); err != nil {
		return fmt.Errorf("failed to start agent services: %w", err)
	}

	// Handle shutdown signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigChan)

	// Start push loop in a goroutine
	errChan := make(chan error, 1)
	go func() {
		errChan <- pushLoop.Start(pushCtx)
	}()

	// Wait for shutdown signal or error
	select {
	case sig := <-sigChan:
		log.Info().Str("signal", sig.String()).Msg("Received shutdown signal")

		// Bound shutdown so the process can't hang forever (includes pushLoop.Stop()).
		const shutdownTimeout = 10 * time.Second
		shutdownDone := make(chan struct{})

		go func() {
			defer close(shutdownDone)

			cancel()
			pushLoop.Stop()
			<-errChan

			stopCtx, stopCancel := context.WithTimeout(context.Background(), shutdownTimeout)
			defer stopCancel()
			if err := server.Stop(stopCtx); err != nil {
				log.Error().Err(err).Msg("Error stopping agent services")
			}
		}()

		timer := time.NewTimer(shutdownTimeout)
		defer timer.Stop()

		select {
		case <-shutdownDone:
		case <-timer.C:
			return fmt.Errorf("%w after %s", errShutdownTimeout, shutdownTimeout)
		}

	case err := <-errChan:
		if err != nil && !errors.Is(err, context.Canceled) {
			stopCtx, stopCancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer stopCancel()
			if stopErr := server.Stop(stopCtx); stopErr != nil {
				log.Error().Err(stopErr).Msg("Error stopping agent services")
			}
			return fmt.Errorf("push loop error: %w", err)
		}

		stopCtx, stopCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer stopCancel()
		if stopErr := server.Stop(stopCtx); stopErr != nil {
			log.Error().Err(stopErr).Msg("Error stopping agent services")
		}
	}

	log.Info().Msg("Agent shutdown complete")
	return nil
}
