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
	"github.com/carverauto/serviceradar/pkg/srql/parser"
	"github.com/carverauto/serviceradar/proto"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/sdk/resource"
	"go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.31.0"
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

	// Create root context for lifecycle management with tracing
	ctx := context.Background()
	
	// Initialize OpenTelemetry SDK
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName("serviceradar-core"),
			semconv.ServiceVersion("1.0.0"),
		),
	)
	if err != nil {
		return err
	}
	
	// Create a TracerProvider with the resource
	tp := trace.NewTracerProvider(
		trace.WithResource(res),
	)
	otel.SetTracerProvider(tp)
	
	// Create a root trace span for the core service
	tracer := otel.Tracer("serviceradar-core")
	ctx, rootSpan := tracer.Start(ctx, "core.main")
	defer rootSpan.End()
	
	// Debug: Check if we have a valid span context
	spanCtx := rootSpan.SpanContext()
	if spanCtx.IsValid() {
		log.Printf("DEBUG: Created span with trace_id=%s span_id=%s", 
			spanCtx.TraceID().String(), spanCtx.SpanID().String())
	} else {
		log.Printf("DEBUG: Span context is not valid!")
	}

	// Initialize logger for main process (now with trace context)
	mainLogger, err := lifecycle.CreateComponentLogger(ctx, "core-main", cfg.Logging)
	if err != nil {
		return err
	}

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
		api.WithDBService(server.DB),
		api.WithDeviceRegistry(server.DeviceRegistry),
		api.WithDatabaseType(parser.Proton),
		api.WithLogger(mainLogger),
	)

	server.SetAPIServer(ctx, apiServer)

	// Log message about Swagger documentation
	mainLogger.Info().
		Str("swagger_url", "http://"+cfg.ListenAddr+"/swagger/index.html").
		Msg("API server will include Swagger documentation")

	// Start HTTP API server in background
	errCh := make(chan error, 1)

	go func() {
		mainLogger.Info().
			Str("listen_addr", cfg.ListenAddr).
			Msg("Starting HTTP API server")

		if err := apiServer.Start(cfg.ListenAddr); err != nil {
			select {
			case errCh <- err:
			default:
				mainLogger.Error().Err(err).Msg("HTTP API server error")
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
