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

	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/mapper"
	"github.com/carverauto/serviceradar/pkg/models"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"

	googlegrpc "google.golang.org/grpc"
)

// Config holds the command-line configuration options.
type Config struct {
	configFile   string
	listenAddr   string
	securityMode string
	certDir      string
}

// parseFlags parses command-line flags and returns a Config.
func parseFlags() Config {
	config := Config{}

	flag.StringVar(&config.configFile, "config", "/etc/serviceradar/mapper.json", "Path to mapper config file")
	flag.StringVar(&config.listenAddr, "listen", ":50056", "Address for mapper to listen on")
	flag.StringVar(&config.securityMode, "security", "none", "Security mode for this checker (none, tls, mtls)")
	flag.StringVar(&config.certDir, "cert-dir", "/etc/serviceradar/certs", "Directory for TLS certificates")
	flag.Parse()

	return config
}

func main() {
	config := parseFlags()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigChan

		log.Printf("Received signal %v, initiating shutdown for discovery checker", sig)

		cancel()
	}()

	log.Printf("Starting ServiceRadar Mapper Service...")

	// Load discovery configuration
	discoveryEngineConfig, err := loadDiscoveryConfig(config)
	if err != nil {
		log.Printf("Failed to load mapper configuration: %v", err)

		return // Deferred cancel() will run
	}

	// Initialize the discovery engine
	var publisher mapper.Publisher

	engine, err := mapper.NewSnmpDiscoveryEngine(discoveryEngineConfig, publisher)
	if err != nil {
		log.Printf("Failed to initialize discovery engine: %v", err)

		return // Deferred cancel() will run
	}

	// Create the gRPC service
	grpcDiscoveryService := mapper.NewGRPCDiscoveryService(engine)

	// Configure server options
	serverOptions := &lifecycle.ServerOptions{
		ListenAddr:  config.listenAddr,
		ServiceName: "discovery_checker",
		Service:     engine,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(server *googlegrpc.Server) error {
				discoverypb.RegisterDiscoveryServiceServer(server, grpcDiscoveryService)
				log.Printf("Registered DiscoveryServiceServer for the discovery checker.")
				return nil
			},
		},
		EnableHealthCheck: true,
		Security:          createCheckerSecurityConfig(config),
	}

	// Run the server
	if err := lifecycle.RunServer(ctx, serverOptions); err != nil {
		log.Printf("Mapper server error: %v", err)

		return // Deferred cancel() will run
	}

	log.Println("ServiceRadar Mapper stopped")
}

// loadDiscoveryConfig loads the configuration for the discovery engine.
func loadDiscoveryConfig(config Config) (*mapper.Config, error) {
	if config.configFile == "" {
		log.Println("No config file specified for discovery checker, using default in-memory config.")

		return &mapper.Config{
			Workers:         10,
			Timeout:         30 * time.Second,
			Retries:         3,
			MaxActiveJobs:   10,
			ResultRetention: 1 * time.Hour,
			DefaultCredentials: mapper.SNMPCredentials{
				Version:   mapper.SNMPVersion2c,
				Community: "public",
			},
			StreamConfig: mapper.StreamConfig{},
			OIDs: map[mapper.DiscoveryType][]string{
				mapper.DiscoveryTypeBasic: {
					".1.3.6.1.2.1.1.1.0", // sysDescr
					".1.3.6.1.2.1.1.5.0", // sysName
				},
			},
		}, nil
	}

	discoveryConfig, err := mapper.LoadConfigFromFile(config.configFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load discovery checker config from file '%s': %w", config.configFile, err)
	}

	log.Printf("Successfully loaded mapper config from %s", config.configFile)

	return discoveryConfig, nil
}

// createCheckerSecurityConfig creates a security configuration
func createCheckerSecurityConfig(config Config) *models.SecurityConfig {
	return &models.SecurityConfig{
		Mode:       models.SecurityMode(config.securityMode),
		CertDir:    config.certDir,
		Role:       models.RoleChecker,
		ServerName: "serviceradar.mapper",
		TLS: models.TLSConfig{
			CertFile:     "server.crt",
			KeyFile:      "server.key",
			CAFile:       "ca.crt",
			ClientCAFile: "ca.crt",
		},
	}
}
