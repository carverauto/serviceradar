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

// @title ServiceRadar API
// @version 1.0
// @description API for monitoring and managing service pollers in the ServiceRadar system
// @termsOfService https://serviceradar.cloud/terms/

// @contact.name API Support
// @contact.url https://serviceradar.cloud/support
// @contact.email support@serviceradar.cloud

// @license.name Apache 2.0
// @license.url http://www.apache.org/licenses/LICENSE-2.0.html

// Multiple server configurations
// @servers.url https://demo.serviceradar.cloud
// @servers.description ServiceRadar Demo Cloud Server

// @servers.url http://{hostname}:{port}
// @servers.description ServiceRadar API Server
// @servers.variables.hostname.default localhost
// @servers.variables.port.default 8080

// @BasePath /
// @schemes http https

// @securityDefinitions.apikey ApiKeyAuth
// @in header
// @name Authorization

package main

import (
	"context"
	"flag"
	"log"

	"github.com/carverauto/serviceradar/pkg/core"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"

	_ "github.com/carverauto/serviceradar/pkg/swagger"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/core.json", "Path to core config file")
	flag.Parse()

	// Load configuration
	cfg, err := core.LoadConfig(*configPath)
	if err != nil {
		return err
	}

	// Create root context for lifecycle management
	ctx := context.Background()

	// Create core server
	server, err := core.NewServer(ctx, &cfg)
	if err != nil {
		return err
	}

	// Create API server with Swagger support
	apiServer := api.NewAPIServer(
		cfg.CORS,
		api.WithMetricsManager(server.GetMetricsManager()),
		api.WithSNMPManager(server.GetSNMPManager()),
		api.WithAuthService(server.GetAuth()),
		api.WithRperfManager(server.GetRperfManager()),
		api.WithQueryExecutor(server.DB),
	)

	server.SetAPIServer(ctx, apiServer)

	// Log message about Swagger documentation
	log.Printf("API server will include Swagger documentation at http://%s/swagger/index.html", cfg.ListenAddr)

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
		proto.RegisterPollerServiceServer(s, server)
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
