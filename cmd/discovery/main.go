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
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/pkg/discovery"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/models"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"

	googlegrpc "google.golang.org/grpc"
)

var (
	configFile   = flag.String("config", "/etc/serviceradar/discovery-checker.json", "Path to this discovery checker's config file")
	listenAddr   = flag.String("listen", ":50056", "Address for this discovery checker to listen on")
	securityMode = flag.String("security", "none", "Security mode for this checker (none, tls, mtls)")
	certDir      = flag.String("cert-dir", "/etc/serviceradar/certs/discovery-checker", "Directory for this checker's certificates")
)

func main() {
	flag.Parse()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigChan

		log.Printf("Received signal %v, initiating shutdown for discovery checker", sig)
		cancel()
	}()

	log.Printf("Starting ServiceRadar Discovery Checker Plugin...")

	// Load the specific configuration for this discovery checker plugin
	// This config (`discovery.Config`) will dictate how the discovery engine operates.
	discoveryEngineConfig, err := loadDiscoveryConfig()
	if err != nil {
		log.Fatalf("Failed to load discovery checker configuration: %v", err)
	}

	// The discovery engine itself does not publish directly to a DB in this model.
	// It might publish results to a stream or a queue if that's part of its design,
	// but for now, we'll assume it makes results available via its gRPC GetDiscoveryResults.
	// A 'nil' publisher might be acceptable if the engine is purely pull-based via gRPC.
	// Or, if it *does* publish (e.g., to NATS, not Proton), that publisher would be initialized here.
	// For simplicity, let's assume a nil publisher or a no-op publisher.
	var publisher discovery.Publisher // = discovery.NewNoOpPublisher() or similar if needed

	// Initialize the discovery engine.
	// The engine implements lifecycle.Service (Start/Stop).
	engine, err := discovery.NewSnmpDiscoveryEngine(discoveryEngineConfig, publisher)
	if err != nil {
		log.Fatalf("Failed to initialize discovery engine: %v", err)
	}

	// Create the gRPC service implementation using the engine.
	// This is what the agent will call.
	grpcDiscoveryService := discovery.NewGRPCDiscoveryService(engine)

	// Configure and run the gRPC server for this checker plugin
	serverOptions := &lifecycle.ServerOptions{
		ListenAddr:  *listenAddr,
		ServiceName: "discovery_checker", // Differentiate from agent/poller/core services
		Service:     engine,              // The discovery engine itself is the main service managed by lifecycle
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(server *googlegrpc.Server) error {
				// Register the DiscoveryService implementation
				discoverypb.RegisterDiscoveryServiceServer(server, grpcDiscoveryService)
				log.Printf("Registered DiscoveryServiceServer for the discovery checker.")
				return nil
			},
		},
		EnableHealthCheck: true,
		Security:          createCheckerSecurityConfig(),
	}

	if err := lifecycle.RunServer(ctx, serverOptions); err != nil {
		log.Fatalf("Discovery checker server error: %v", err)
	}

	log.Println("ServiceRadar Discovery Checker Plugin stopped")
}

// loadDiscoveryConfig loads the configuration for the discovery engine itself.
// This is different from the agent's or poller's main config.
func loadDiscoveryConfig() (*discovery.Config, error) {
	if *configFile == "" {
		log.Println("No config file specified for discovery checker, using default in-memory config.")
		// Return a default discovery.Config if no file is provided
		return &discovery.Config{
			Workers:         10, // Default worker count
			Timeout:         30 * time.Second,
			Retries:         3,
			MaxActiveJobs:   10,
			ResultRetention: 1 * time.Hour,
			DefaultCredentials: discovery.SNMPCredentials{
				Version:   discovery.SNMPVersion2c,
				Community: "public",
			},
			// StreamConfig might not be used if not publishing directly.
			// If the agent pulls results, StreamConfig here might be for configuring
			// how results are stored/formatted locally by the engine.
			StreamConfig: discovery.StreamConfig{
				// AgentID and PollerID here would be specific to this checker's identity if needed,
				// or perhaps taken from its operational environment if the engine uses them.
				// For a checker plugin, these might be set via its own config file or env vars.
				// AgentID:  "discovery-checker-agent-01", // Example
				// PollerID: "discovery-checker-poller-01", // Example
			},
			OIDs: map[discovery.DiscoveryType][]string{
				discovery.DiscoveryTypeBasic: {
					".1.3.6.1.2.1.1.1.0", // sysDescr
					".1.3.6.1.2.1.1.5.0", // sysName
				},
				// Add other OID mappings as needed
			},
		}, nil
	}

	// Load from the specified file for the discovery checker
	config, err := discovery.LoadConfigFromFile(*configFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load discovery checker config from file '%s': %w", *configFile, err)
	}
	log.Printf("Successfully loaded discovery checker config from %s", *configFile)
	return config, nil
}

// createCheckerSecurityConfig creates a security configuration specifically for this checker plugin's gRPC server.
func createCheckerSecurityConfig() *models.SecurityConfig {
	// The role here is "checker" because this binary IS a checker plugin.
	// The ServerName should be specific to this service if using mTLS with SNI.
	return &models.SecurityConfig{
		Mode:       models.SecurityMode(*securityMode),
		CertDir:    *certDir,
		Role:       models.RoleChecker,        // This service IS a checker
		ServerName: "discovery.checker.local", // Example, adjust as needed for your certs
		TLS: models.TLSConfig{
			CertFile:     "server.crt", // Relative to CertDir
			KeyFile:      "server.key", // Relative to CertDir
			CAFile:       "ca.crt",     // CA used to issue client certs (e.g., agent's cert) for mTLS
			ClientCAFile: "ca.crt",     // For mTLS, server validates client cert against this CA
		},
	}
}
