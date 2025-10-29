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
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	"google.golang.org/grpc"
	grpcstats "google.golang.org/grpc/stats"

	"github.com/carverauto/serviceradar/pkg/core"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/spireadmin"
	_ "github.com/carverauto/serviceradar/pkg/swagger"
	"github.com/carverauto/serviceradar/proto"
)

type coreFlags struct {
	ConfigPath     string
	Backfill       bool
	BackfillDryRun bool
	BackfillSeedKV bool
	BackfillIPs    bool
}

func parseFlags() coreFlags {
	configPath := flag.String("config", "/etc/serviceradar/core.json", "Path to core config file")
	backfill := flag.Bool("backfill-identities", false, "Run one-time identity backfill (Armis/NetBox) and exit")
	backfillDryRun := flag.Bool("backfill-dry-run", false, "If set with --backfill-identities, only log actions without writing")
	backfillSeedKV := flag.Bool("seed-kv-only", false, "Seed canonical identity map without emitting tombstones")
	backfillIPs := flag.Bool("backfill-ips", true, "Also backfill sweep-only device IDs by IP aliasing into canonical identities")
	flag.Parse()

	return coreFlags{
		ConfigPath:     *configPath,
		Backfill:       *backfill,
		BackfillDryRun: *backfillDryRun,
		BackfillSeedKV: *backfillSeedKV,
		BackfillIPs:    *backfillIPs,
	}
}

func runBackfill(ctx context.Context, server *core.Server, mainLogger logger.Logger, opts coreFlags) error {
	startMsg := "Starting identity backfill (Armis/NetBox) ..."
	if opts.BackfillDryRun {
		startMsg = "Starting identity backfill (Armis/NetBox) in DRY-RUN mode ..."
	}
	mainLogger.Info().Msg(startMsg)

	backfillOpts := core.BackfillOptions{
		DryRun:     opts.BackfillDryRun,
		SeedKVOnly: opts.BackfillSeedKV,
	}

	if err := core.BackfillIdentityTombstones(ctx, server.DB, server.IdentityKVClient(), mainLogger, backfillOpts); err != nil {
		return err
	}

	if opts.BackfillIPs {
		ipMsg := "Starting IP alias backfill ..."
		if opts.BackfillDryRun {
			ipMsg = "Starting IP alias backfill (DRY-RUN) ..."
		} else if opts.BackfillSeedKV {
			ipMsg = "Starting IP alias backfill (KV seeding only) ..."
		}
		mainLogger.Info().Msg(ipMsg)

		if err := core.BackfillIPAliasTombstones(ctx, server.DB, server.IdentityKVClient(), mainLogger, backfillOpts); err != nil {
			return err
		}
	}

	completionMsg := "Backfill completed. Exiting."
	if opts.BackfillDryRun {
		completionMsg = "Backfill DRY-RUN completed. Exiting."
	} else if opts.BackfillSeedKV {
		completionMsg = "Backfill KV seeding completed. Exiting."
	}
	mainLogger.Info().Msg(completionMsg)
	return nil
}

func initSpireAdminClient(ctx context.Context, cfg *models.CoreServiceConfig, mainLogger logger.Logger) (spireadmin.Client, error) {
	if cfg.SpireAdmin == nil || !cfg.SpireAdmin.Enabled {
		return nil, nil
	}

	spireCfg := spireadmin.Config{
		WorkloadSocket: cfg.SpireAdmin.WorkloadSocket,
		ServerAddress:  cfg.SpireAdmin.ServerAddress,
		ServerSPIFFEID: cfg.SpireAdmin.ServerSPIFFEID,
	}

	if spireCfg.ServerAddress == "" || spireCfg.ServerSPIFFEID == "" {
		mainLogger.Warn().Msg("SPIRE admin config enabled but server address or SPIFFE ID missing; disabling admin client")
		return nil, nil
	}

	client, err := spireadmin.New(ctx, spireCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to initialize SPIRE admin client: %w", err)
	}

	return client, nil
}

func buildAPIServerOptions(cfg *models.CoreServiceConfig, mainLogger logger.Logger, spireAdminClient spireadmin.Client) []func(*api.APIServer) {
	var apiOptions []func(*api.APIServer)

	if kvAddr := os.Getenv("KV_ADDRESS"); kvAddr != "" {
		apiOptions = append(apiOptions, api.WithKVAddress(kvAddr))
	}

	if cfg.Security != nil {
		apiOptions = append(apiOptions, api.WithKVSecurity(cfg.Security))
	}

	if len(cfg.KVEndpoints) > 0 {
		eps := make(map[string]*api.KVEndpoint, len(cfg.KVEndpoints))
		for _, e := range cfg.KVEndpoints {
			eps[e.ID] = &api.KVEndpoint{
				ID:       e.ID,
				Name:     e.Name,
				Address:  e.Address,
				Domain:   e.Domain,
				Type:     e.Type,
				Security: cfg.Security,
			}
		}
		apiOptions = append(apiOptions, api.WithKVEndpoints(eps))
	}

	if cfg.SpireAdmin != nil && cfg.SpireAdmin.Enabled {
		if spireAdminClient == nil {
			mainLogger.Warn().Msg("SPIRE admin config enabled but admin client unavailable; admin APIs disabled")
		} else {
			apiOptions = append(apiOptions, api.WithSpireAdmin(spireAdminClient, cfg.SpireAdmin))
		}
	}

	return apiOptions
}

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	opts := parseFlags()

	cfg, err := core.LoadConfig(opts.ConfigPath)
	if err != nil {
		return err
	}

	// Create root context for lifecycle management
	ctx := context.Background()

	// Initialize basic logger first (without trace context)
	basicLogger, err := lifecycle.CreateComponentLogger(ctx, "core-main", cfg.Logging)
	if err != nil {
		return err
	}

	// Initialize OpenTelemetry tracing with logger
	tp, ctx, rootSpan, err := logger.InitializeTracing(ctx, logger.TracingConfig{
		ServiceName:    "serviceradar-core",
		ServiceVersion: "1.0.0",
		Debug:          true,
		Logger:         basicLogger,
		OTel:           &cfg.Logging.OTel,
	})
	if err != nil {
		return err
	}

	defer func() {
		if err = tp.Shutdown(context.Background()); err != nil {
			basicLogger.Error().Err(err).Msg("Error shutting down tracer provider")
		}

		rootSpan.End()
	}()

	// Create trace-aware logger (this will have trace_id and span_id)
	mainLogger, err := lifecycle.CreateComponentLogger(ctx, "core-main", cfg.Logging)
	if err != nil {
		return err
	}

	if cfg.Logging != nil {
		if _, metricsErr := logger.InitializeMetrics(ctx, logger.MetricsConfig{
			ServiceName:    "serviceradar-core",
			ServiceVersion: "1.0.0",
			OTel:           &cfg.Logging.OTel,
		}); metricsErr != nil && !errors.Is(metricsErr, logger.ErrOTelMetricsDisabled) {
			return metricsErr
		}
	}

	defer func() {
		shutdownErr := lifecycle.ShutdownLogger()
		if shutdownErr != nil {
			mainLogger.Error().Err(shutdownErr).Msg("Error shutting down logger")
		}
	}()

	spireAdminClient, err := initSpireAdminClient(ctx, &cfg, mainLogger)
	if err != nil {
		return err
	}
	if spireAdminClient != nil {
		defer func() {
			if err := spireAdminClient.Close(); err != nil {
				mainLogger.Warn().Err(err).Msg("error closing SPIRE admin client")
			}
		}()
	}

	// Create core server
	server, err := core.NewServer(ctx, &cfg, spireAdminClient)
	if err != nil {
		return err
	}

	if opts.Backfill {
		return runBackfill(ctx, server, mainLogger, opts)
	}

	apiOptions := buildAPIServerOptions(&cfg, mainLogger, spireAdminClient)

	allOptions := []func(server *api.APIServer){
		api.WithMetricsManager(server.GetMetricsManager()),
		api.WithSNMPManager(server.GetSNMPManager()),
		api.WithAuthService(server.GetAuth()),
		api.WithRperfManager(server.GetRperfManager()),
		api.WithQueryExecutor(server.DB),
		api.WithDBService(server.DB),
		api.WithDeviceRegistry(server.DeviceRegistry),
		api.WithLogger(mainLogger),
	}
	if cfg.Auth != nil {
		allOptions = append(allOptions, api.WithRBACConfig(&cfg.Auth.RBAC))
	}
	if edgeSvc := server.EdgeOnboardingService(); edgeSvc != nil {
		allOptions = append(allOptions, api.WithEdgeOnboarding(edgeSvc))
	}
	allOptions = append(allOptions, apiOptions...)

	apiServer := api.NewAPIServer(cfg.CORS, allOptions...)

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
		proto.RegisterCoreServiceServer(s, server)
		return nil
	}

	// Run server with lifecycle management
	return lifecycle.RunServer(ctx, &lifecycle.ServerOptions{
		ListenAddr:           cfg.GrpcAddr,
		Service:              server,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerService},
		EnableHealthCheck:    true,
		Security:             cfg.Security,
		TelemetryFilter: func(info *grpcstats.RPCTagInfo) bool {
			return !strings.HasPrefix(info.FullMethodName, "/proto.KVService/")
		},
	})
}
