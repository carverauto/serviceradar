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
	"log"

	"github.com/carverauto/serviceradar/pkg/cloud"
	"github.com/carverauto/serviceradar/pkg/cloud/api"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/proto"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/cloud.json", "Path to cloud config file")
	flag.Parse()

	// Load configuration
	cfg, err := cloud.LoadConfig(*configPath)
	if err != nil {
		return err
	}

	// Create root context for lifecycle management
	ctx := context.Background()

	// Create cloud server
	server, err := cloud.NewServer(ctx, &cfg)
	if err != nil {
		return err
	}

	apiServer := api.NewAPIServer(
		api.WithMetricsManager(server.GetMetricsManager()),
		api.WithSNMPManager(server.GetSNMPManager()),
	)

	server.SetAPIServer(apiServer)

	// Start HTTP API server in background
	errCh := make(chan error, 1)

	go func() {
		log.Printf("Starting HTTP API server on %s", cfg.ListenAddr)

		if err := apiServer.Start(cfg.ListenAddr); err != nil {
			select {
			case errCh <- err:
			default:
				log.Printf("HTTP API server error: %v", err)
			}
		}
	}()

	// Create gRPC service registrar
	registerService := func(s *grpc.Server) error {
		proto.RegisterPollerServiceServer(s.GetGRPCServer(), server)
		return nil
	}

	// Run server with lifecycle management
	return lifecycle.RunServer(ctx, &lifecycle.ServerOptions{
		ListenAddr:           cfg.GrpcAddr,
		Service:              server,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerService},
		EnableHealthCheck:    true,
		Security:             cfg.Security,
	})
}
