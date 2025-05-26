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

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/mapper"
	monitoringpb "github.com/carverauto/serviceradar/proto"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
	"google.golang.org/grpc"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

var (
	errFailedToLoadMapperConfig    = fmt.Errorf("failed to load mapper configuration")
	errFailedToTypeCastEngine      = fmt.Errorf("failed to cast discovery engine to *mapper.DiscoveryEngine for health service")
	errFailedToInitDiscoveryEngine = fmt.Errorf("failed to initialize discovery engine")
)

func run() error {
	// Parse command line flags
	configFile := flag.String("config", "/etc/serviceradar/mapper.json", "Path to mapper config file")
	listenAddr := flag.String("listen", ":50056", "Address for mapper to listen on")

	flag.Parse()

	// Setup a context we can use for loading the config and running the server
	ctx := context.Background()

	// Initialize configuration loader
	cfgLoader := config.NewConfig()

	// Load configuration with context
	var cfg mapper.Config

	if err := cfgLoader.LoadAndValidate(ctx, *configFile, &cfg); err != nil {
		return fmt.Errorf("%w: %w", errFailedToLoadMapperConfig, err)
	}

	// Create discovery engine with a nil publisher for now
	// TODO: Create a proper publisher implementation
	var publisher mapper.Publisher

	engine, err := mapper.NewDiscoveryEngine(&cfg, publisher)
	if err != nil {
		return fmt.Errorf("%w: %w", errFailedToInitDiscoveryEngine, err)
	}

	// Create gRPC services
	grpcDiscoveryService := mapper.NewGRPCDiscoveryService(engine)

	snmpEngine, ok := engine.(*mapper.DiscoveryEngine)
	if !ok {
		return errFailedToTypeCastEngine
	}

	grpcMapperAgentService := mapper.NewMapperAgentService(snmpEngine)

	// Create server options
	opts := &lifecycle.ServerOptions{
		ListenAddr:        *listenAddr,
		ServiceName:       "serviceradar-mapper",
		Service:           engine,
		EnableHealthCheck: true,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(s *grpc.Server) error {
				discoverypb.RegisterDiscoveryServiceServer(s, grpcDiscoveryService)
				monitoringpb.RegisterAgentServiceServer(s, grpcMapperAgentService)
				return nil
			},
		},
		Security: cfg.Security,
	}

	log.Printf("Starting ServiceRadar Mapper Service on %s", *listenAddr)

	return lifecycle.RunServer(ctx, opts)
}
