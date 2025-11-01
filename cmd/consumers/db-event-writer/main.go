package main

import (
    "context"
    "flag"
    "log"

    "google.golang.org/grpc"

    "github.com/carverauto/serviceradar/pkg/config"
	dbeventwriter "github.com/carverauto/serviceradar/pkg/consumers/db-event-writer"
    "github.com/carverauto/serviceradar/pkg/db"
    "github.com/carverauto/serviceradar/pkg/edgeonboarding"
    "github.com/carverauto/serviceradar/pkg/lifecycle"
    "github.com/carverauto/serviceradar/pkg/logger"
    "github.com/carverauto/serviceradar/pkg/models"
    "github.com/carverauto/serviceradar/proto"
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/consumers/db-event-writer.json", "Path to config file")
	_ = flag.String("onboarding-token", "", "Edge onboarding token (if provided, triggers edge onboarding)")
	_ = flag.String("kv-endpoint", "", "KV service endpoint (required for edge onboarding)")
	flag.Parse()

	ctx := context.Background()

	// Try edge onboarding first (checks env vars if flags not set)
	onboardingResult, err := edgeonboarding.TryOnboard(ctx, models.EdgeOnboardingComponentTypeAgent, nil)
	if err != nil {
		log.Fatalf("Edge onboarding failed: %v", err)
	}

	// If onboarding was performed, use the generated config
	if onboardingResult != nil {
		*configPath = onboardingResult.ConfigPath
		log.Printf("Using edge-onboarded configuration from: %s", *configPath)
		log.Printf("SPIFFE ID: %s", onboardingResult.SPIFFEID)
	}

	// Step 1: Load config with KV support
	kvMgr := config.NewKVManagerFromEnv(ctx, models.RoleCore)

	cleanup := func() {
		if kvMgr != nil {
			_ = kvMgr.Close()
		}
	}

	cfgLoader := config.NewConfig(nil)
	if kvMgr != nil {
		kvMgr.SetupConfigLoader(cfgLoader)
	}

	var cfg dbeventwriter.DBEventWriterConfig

	config.LoadAndOverlayOrExit(ctx, kvMgr, cfgLoader, *configPath, &cfg, "Failed to load configuration")

	// Bootstrap service-level default into KV if missing
	if kvMgr != nil {
		kvMgr.BootstrapConfig(ctx, "config/db-event-writer.json", cfg)
	}

	// Explicitly normalize paths after loading
	if cfg.Security != nil && cfg.Security.CertDir != "" {
		config.NormalizeTLSPaths(&cfg.Security.TLS, cfg.Security.CertDir)
	}

	if cfg.DBSecurity != nil && cfg.DBSecurity.CertDir != "" {
		config.NormalizeTLSPaths(&cfg.DBSecurity.TLS, cfg.DBSecurity.CertDir)
	}

	if err := cfg.Validate(); err != nil {
		cleanup()
		log.Fatalf("DB event writer config validation failed: %v", err)
	}

	dbSecurity := cfg.Security
	if cfg.DBSecurity != nil {
		dbSecurity = cfg.DBSecurity
	}

	dbConfig := &models.CoreServiceConfig{
		DBAddr:   cfg.Database.Addresses[0],
		DBName:   cfg.Database.Name,
		DBUser:   cfg.Database.Username,
		DBPass:   cfg.Database.Password,
		Security: dbSecurity,
	}

	// Initialize logger configuration
	var loggerConfig *logger.Config
	if cfg.Logging != nil {
		loggerConfig = cfg.Logging
	} else {
		loggerConfig = logger.DefaultConfig()
	}

	// Initialize logger for database
	dbLogger, err := lifecycle.CreateComponentLogger(ctx, "db-writer-db", loggerConfig)
	if err != nil {
		cleanup()
		log.Fatalf("Failed to initialize logger: %v", err)
	}

	// Initialize logger for service
	serviceLogger, err := lifecycle.CreateComponentLogger(ctx, "db-writer-service", loggerConfig)
	if err != nil {
		cleanup()
		log.Fatalf("Failed to initialize service logger: %v", err)
	}

	dbService, err := db.New(ctx, dbConfig, dbLogger)
	if err != nil {
		cleanup()
		log.Fatalf("Failed to initialize database service: %v", err)
	}

	svc, err := dbeventwriter.NewService(&cfg, dbService, serviceLogger)
	if err != nil {
		cleanup()
		log.Fatalf("Failed to initialize event writer service: %v", err)
	}

	agentService := dbeventwriter.NewAgentService(svc)

	// KV Watch: overlay and apply hot-reload on relevant changes
	if kvMgr != nil {
		kvMgr.StartWatch(ctx, "config/db-event-writer.json", &cfg, serviceLogger, func() {
			_ = svc.UpdateConfig(ctx, &cfg)
		})
	}

	opts := &lifecycle.ServerOptions{
		ListenAddr:        cfg.ListenAddr,
		ServiceName:       "db-event-writer",
		Service:           svc,
		EnableHealthCheck: true,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(s *grpc.Server) error {
				proto.RegisterAgentServiceServer(s, agentService)
				return nil
			},
		},
		Security: cfg.Security,
	}

	if err := lifecycle.RunServer(ctx, opts); err != nil {
		cleanup()
		log.Fatalf("Server failed: %v", err)
	}
	
	cleanup()
}
