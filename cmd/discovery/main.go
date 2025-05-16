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

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/discovery"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	configFile   = flag.String("config", "/etc/serviceradar/discovery.json", "Path to config file")
	listenAddr   = flag.String("listen", ":50056", "Address to listen on")
	securityMode = flag.String("security", "none", "Security mode (none, tls, mtls)")
	certDir      = flag.String("cert-dir", "/etc/serviceradar/certs", "Directory for certificates")
	protonAddr   = flag.String("proton", "localhost:8463", "Proton connection address")
	protonDB     = flag.String("proton-db", "serviceradar", "Proton database name")
	protonUser   = flag.String("proton-user", "admin", "Proton username")
	protonPass   = flag.String("proton-pass", "admin", "Proton password")
	agentID      = flag.String("agent-id", "", "Agent ID")
	pollerID     = flag.String("poller-id", "", "Poller ID")
	workers      = flag.Int("workers", 10, "Number of worker goroutines")
)

func main() {
	flag.Parse()

	// Setup context with cancellation for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Set up signal handling for graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigChan
		log.Printf("Received signal %v, initiating shutdown", sig)
		cancel()
	}()

	log.Printf("Starting ServiceRadar SNMP Discovery Engine...")

	// Load configuration
	config, err := loadConfig()
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	// Initialize DB service (for publishing to Proton)
	dbService, err := initDBService(ctx)
	if err != nil {
		log.Fatalf("Failed to initialize DB service: %v", err)
	}

	// Initialize publisher
	publisher, err := discovery.NewProtonPublisher(dbService, config.StreamConfig)
	if err != nil {
		log.Fatalf("Failed to initialize publisher: %v", err)
	}

	// Initialize discovery engine
	engine, err := discovery.NewSnmpDiscoveryEngine(config, publisher)
	if err != nil {
		log.Fatalf("Failed to initialize discovery engine: %v", err)
	}

	// Create gRPC service
	grpcService := discovery.NewGRPCDiscoveryService(engine)

	// Start the service
	options := &lifecycle.ServerOptions{
		ListenAddr:  *listenAddr,
		ServiceName: "discovery",
		Service:     engine,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(server *proto.Server) error {
				proto.RegisterDiscoveryServiceServer(server, grpcService)
				return nil
			},
		},
		EnableHealthCheck: true,
		Security:          createSecurityConfig(),
	}

	if err := lifecycle.RunServer(ctx, options); err != nil {
		log.Fatalf("Server error: %v", err)
	}

	log.Println("ServiceRadar SNMP Discovery Engine stopped")
}

// loadConfig loads the discovery engine configuration from a file
func loadConfig() (*discovery.Config, error) {
	if *configFile != "" {
		config, err := discovery.LoadConfigFromFile(*configFile)
		if err != nil {
			return nil, fmt.Errorf("failed to load config from file: %w", err)
		}

		// Override with command-line arguments if provided
		if *agentID != "" {
			config.StreamConfig.AgentID = *agentID
		}

		if *pollerID != "" {
			config.StreamConfig.PollerID = *pollerID
		}

		if *workers > 0 {
			config.Workers = *workers
		}

		return config, nil
	}

	// Create default config
	return &discovery.Config{
		Workers:         *workers,
		Timeout:         30 * time.Second,
		Retries:         3,
		MaxActiveJobs:   100,
		ResultRetention: 24 * time.Hour,
		DefaultCredentials: discovery.SNMPCredentials{
			Version:   discovery.SNMPVersion2c,
			Community: "public",
		},
		StreamConfig: discovery.StreamConfig{
			DeviceStream:         "sweep_results",
			InterfaceStream:      "discovered_interfaces",
			TopologyStream:       "topology_discovery_events",
			AgentID:              *agentID,
			PollerID:             *pollerID,
			PublishBatchSize:     100,
			PublishRetries:       3,
			PublishRetryInterval: 5 * time.Second,
		},
		OIDs: map[discovery.DiscoveryType][]string{
			discovery.DiscoveryTypeBasic: {
				".1.3.6.1.2.1.1.1.0", // sysDescr
				".1.3.6.1.2.1.1.2.0", // sysObjectID
				".1.3.6.1.2.1.1.5.0", // sysName
				".1.3.6.1.2.1.1.4.0", // sysContact
				".1.3.6.1.2.1.1.6.0", // sysLocation
				".1.3.6.1.2.1.1.3.0", // sysUpTime
			},
			discovery.DiscoveryTypeInterfaces: {
				".1.3.6.1.2.1.2.2.1",    // ifTable
				".1.3.6.1.2.1.31.1.1.1", // ifXTable
				".1.3.6.1.2.1.4.20.1",   // ipAddrTable
			},
			discovery.DiscoveryTypeTopology: {
				".1.0.8802.1.1.2.1",     // LLDP
				".1.3.6.1.4.1.9.9.23.1", // CDP (Cisco)
			},
		},
	}, nil
}

// initDBService initializes the database service
func initDBService(ctx context.Context) (db.Service, error) {
	dbConfig := &db.Config{
		DBAddr: *protonAddr,
		DBName: *protonDB,
		DBUser: *protonUser,
		DBPass: *protonPass,
	}

	dbService, err := db.NewService(ctx, dbConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create DB service: %w", err)
	}

	return dbService, nil
}

// createSecurityConfig creates a security configuration
func createSecurityConfig() *models.SecurityConfig {
	return &models.SecurityConfig{
		Mode:       models.SecurityMode(*securityMode),
		CertDir:    *certDir,
		Role:       models.RoleChecker,
		ServerName: "discovery",
		TLS: models.TLSConfig{
			CertFile:     "server.crt",
			KeyFile:      "server.key",
			CAFile:       "ca.crt",
			ClientCAFile: "ca.crt",
		},
	}
}
