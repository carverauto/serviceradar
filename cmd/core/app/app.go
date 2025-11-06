package app

import (
	"context"
	"errors"
	"strings"

	"google.golang.org/grpc"
	grpcstats "google.golang.org/grpc/stats"

	"github.com/carverauto/serviceradar/pkg/core"
	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/core/bootstrap"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	_ "github.com/carverauto/serviceradar/pkg/swagger"
	"github.com/carverauto/serviceradar/proto"
)

// Options contains runtime configuration derived from CLI flags.
type Options struct {
	ConfigPath        string
	BackfillEnabled   bool
	BackfillDryRun    bool
	BackfillSeedKV    bool
	BackfillIPs       bool
	BackfillNamespace string
}

// Run boots the core service using the provided options.
func Run(ctx context.Context, opts Options) error {
	if ctx == nil {
		ctx = context.Background()
	}

	cfg, err := core.LoadConfig(opts.ConfigPath)
	if err != nil {
		return err
	}

	// Initialize basic logger first (without trace context)
	basicLogger, err := lifecycle.CreateComponentLogger(ctx, "core-main", cfg.Logging)
	if err != nil {
		return err
	}

	// Initialize OpenTelemetry tracing with logger
	tp, ctxWithTrace, rootSpan, err := logger.InitializeTracing(ctx, logger.TracingConfig{
		ServiceName:    "serviceradar-core",
		ServiceVersion: "1.0.0",
		Debug:          true,
		Logger:         basicLogger,
		OTel:           &cfg.Logging.OTel,
	})
	if err != nil {
		return err
	}
	ctx = ctxWithTrace

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

	spireAdminClient, err := bootstrap.InitSpireAdminClient(ctx, &cfg, mainLogger)
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

	if opts.BackfillEnabled {
		backfillOpts := core.BackfillOptions{
			DryRun:     opts.BackfillDryRun,
			SeedKVOnly: opts.BackfillSeedKV,
			Namespace:  opts.BackfillNamespace,
		}
		return runBackfill(ctx, server, mainLogger, backfillOpts, opts.BackfillIPs)
	}

	apiOptions := bootstrap.BuildAPIServerOptions(&cfg, mainLogger, spireAdminClient)

	allOptions := []func(server *api.APIServer){
		api.WithMetricsManager(server.GetMetricsManager()),
		api.WithSNMPManager(server.GetSNMPManager()),
		api.WithAuthService(server.GetAuth()),
		api.WithRperfManager(server.GetRperfManager()),
		api.WithQueryExecutor(server.DB),
		api.WithDBService(server.DB),
		api.WithDeviceRegistry(server.DeviceRegistry),
		api.WithServiceRegistry(server.ServiceRegistry),
		api.WithLogger(mainLogger),
		api.WithEventPublisher(server.EventPublisher()),
	}
	if planner := server.DeviceSearchPlanner(); planner != nil {
		allOptions = append(allOptions, api.WithDeviceSearchPlanner(planner))
	}
	if digest := server.LogDigest(); digest != nil {
		allOptions = append(allOptions, api.WithLogDigest(digest))
	}
	if stats := server.DeviceStats(); stats != nil {
		allOptions = append(allOptions, api.WithDeviceStats(stats))
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
	go func() {
		mainLogger.Info().
			Str("listen_addr", cfg.ListenAddr).
			Msg("Starting HTTP API server")

		if err := apiServer.Start(cfg.ListenAddr); err != nil {
			mainLogger.Error().Err(err).Msg("HTTP API server error")
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

func runBackfill(ctx context.Context, server *core.Server, mainLogger logger.Logger, opts core.BackfillOptions, includeIPs bool) error {
	startMsg := "Starting identity backfill (Armis/NetBox) ..."
	if opts.DryRun {
		startMsg = "Starting identity backfill (Armis/NetBox) in DRY-RUN mode ..."
	}
	mainLogger.Info().Msg(startMsg)

	if err := core.BackfillIdentityTombstones(ctx, server.DB, server.IdentityKVClient(), mainLogger, opts); err != nil {
		return err
	}

	if includeIPs {
		ipMsg := "Starting IP alias backfill ..."
		if opts.DryRun {
			ipMsg = "Starting IP alias backfill (DRY-RUN) ..."
		} else if opts.SeedKVOnly {
			ipMsg = "Starting IP alias backfill (KV seeding only) ..."
		}
		mainLogger.Info().Msg(ipMsg)

		if err := core.BackfillIPAliasTombstones(ctx, server.DB, server.IdentityKVClient(), mainLogger, opts); err != nil {
			return err
		}
	}

	completionMsg := "Backfill completed. Exiting."
	if opts.DryRun {
		completionMsg = "Backfill DRY-RUN completed. Exiting."
	} else if opts.SeedKVOnly {
		completionMsg = "Backfill KV seeding completed. Exiting."
	}
	mainLogger.Info().Msg(completionMsg)
	return nil
}
