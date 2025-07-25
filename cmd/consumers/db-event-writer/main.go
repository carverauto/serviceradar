package main

import (
	"context"
	"log"

	"github.com/carverauto/serviceradar/pkg/config"
	dbeventwriter "github.com/carverauto/serviceradar/pkg/consumers/db-event-writer"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	monitoringpb "github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

func main() {
	ctx := context.Background()
	cfgLoader := config.NewConfig(nil)

	configPath := "/etc/serviceradar/consumers/db-event-writer.json"

	var cfg dbeventwriter.DBEventWriterConfig

	if err := cfgLoader.LoadAndValidate(ctx, configPath, &cfg); err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	// Explicitly normalize paths after loading
	if cfg.Security != nil && cfg.Security.CertDir != "" {
		config.NormalizeTLSPaths(&cfg.Security.TLS, cfg.Security.CertDir)
	}

	if cfg.DBSecurity != nil && cfg.DBSecurity.CertDir != "" {
		config.NormalizeTLSPaths(&cfg.DBSecurity.TLS, cfg.DBSecurity.CertDir)
	}

	if err := cfg.Validate(); err != nil {
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
		log.Fatalf("Failed to initialize logger: %v", err)
	}

	// Initialize logger for service
	serviceLogger, err := lifecycle.CreateComponentLogger(ctx, "db-writer-service", loggerConfig)
	if err != nil {
		log.Fatalf("Failed to initialize service logger: %v", err)
	}

	dbService, err := db.New(ctx, dbConfig, dbLogger)
	if err != nil {
		log.Fatalf("Failed to initialize database service: %v", err)
	}

	svc, err := dbeventwriter.NewService(&cfg, dbService, serviceLogger)
	if err != nil {
		log.Fatalf("Failed to initialize event writer service: %v", err)
	}

	agentService := dbeventwriter.NewAgentService(svc)

	opts := &lifecycle.ServerOptions{
		ListenAddr:        cfg.ListenAddr,
		ServiceName:       "db-event-writer",
		Service:           svc,
		EnableHealthCheck: true,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(s *grpc.Server) error {
				monitoringpb.RegisterAgentServiceServer(s, agentService)
				return nil
			},
		},
		Security: cfg.Security,
	}

	if err := lifecycle.RunServer(ctx, opts); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
