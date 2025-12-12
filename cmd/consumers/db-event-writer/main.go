package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/config"
	cfgbootstrap "github.com/carverauto/serviceradar/pkg/config/bootstrap"
	dbeventwriter "github.com/carverauto/serviceradar/pkg/consumers/db-event-writer"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/edgeonboarding"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	ErrCNPGPasswordRequired = errors.New("CNPG password is required; set it in config or provide CNPG_PASSWORD_FILE from a mounted secret")
	ErrCNPGPasswordEmpty    = errors.New("CNPG password file is empty")
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/consumers/db-event-writer.json", "Path to config file")
	_ = flag.String("onboarding-token", "", "Edge onboarding token (if provided, triggers edge onboarding)")
	_ = flag.String("kv-endpoint", "", "KV service endpoint (required for edge onboarding)")
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

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

	var cfg dbeventwriter.DBEventWriterConfig
	desc, ok := config.ServiceDescriptorFor("db-event-writer")
	if !ok {
		log.Fatalf("Failed to load configuration: service descriptor missing")
	}
	bootstrapResult, err := cfgbootstrap.Service(ctx, desc, &cfg, cfgbootstrap.ServiceOptions{
		Role:         models.RoleCore,
		ConfigPath:   *configPath,
		DisableWatch: true,
	})
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}
	defer func() { _ = bootstrapResult.Close() }()

	// Explicitly normalize paths after loading
	if cfg.Security != nil && cfg.Security.CertDir != "" {
		config.NormalizeTLSPaths(&cfg.Security.TLS, cfg.Security.CertDir)
	}

	if cfg.CNPG != nil && cfg.CNPG.TLS != nil && cfg.CNPG.CertDir != "" {
		config.NormalizeTLSPaths(cfg.CNPG.TLS, cfg.CNPG.CertDir)
	}

	if err := applyCNPGPassword(&cfg); err != nil {
		_ = bootstrapResult.Close()
		log.Fatalf("DB event writer config validation failed: %v", err) //nolint:gocritic // Close is explicitly called before Fatalf
	}

	if err := cfg.Validate(); err != nil {
		_ = bootstrapResult.Close()
		log.Fatalf("DB event writer config validation failed: %v", err)
	}

	dbConfig := &models.CoreServiceConfig{
		CNPG: cfg.CNPG,
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

	bootstrapResult.StartWatch(ctx, serviceLogger, &cfg, func() {
		if err := applyCNPGPassword(&cfg); err != nil {
			serviceLogger.Error().Err(err).Msg("Skipping config update; CNPG password unavailable")
			return
		}
		_ = svc.UpdateConfig(ctx, &cfg)
	})

	go watchCNPGPassword(ctx, &cfg, dbConfig, dbLogger, svc, serviceLogger)

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
		log.Fatalf("Server failed: %v", err)
	}
}

// applyCNPGPassword ensures the CNPG password is sourced from a mounted secret file, not env.
func applyCNPGPassword(cfg *dbeventwriter.DBEventWriterConfig) error {
	if cfg == nil || cfg.CNPG == nil {
		return nil
	}

	if pwPath := os.Getenv("CNPG_PASSWORD_FILE"); pwPath != "" {
		pwd, err := readCNPGPasswordFile(pwPath)
		if err != nil {
			return err
		}

		cfg.CNPG.Password = pwd
		return nil
	}

	if cfg.CNPG.Password == "" {
		return ErrCNPGPasswordRequired
	}

	return nil
}

func readCNPGPasswordFile(path string) (string, error) {
	if path == "" {
		return "", ErrCNPGPasswordRequired
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read CNPG password file: %w", err)
	}

	pwd := strings.TrimSpace(string(data))
	if pwd == "" {
		return "", fmt.Errorf("%w: %s", ErrCNPGPasswordEmpty, path)
	}

	return pwd, nil
}

func watchCNPGPassword(
	ctx context.Context,
	cfg *dbeventwriter.DBEventWriterConfig,
	dbConfig *models.CoreServiceConfig,
	dbLogger logger.Logger,
	svc *dbeventwriter.Service,
	log logger.Logger,
) {
	if ctx == nil || cfg == nil || cfg.CNPG == nil || svc == nil {
		return
	}

	pwPath := os.Getenv("CNPG_PASSWORD_FILE")
	if pwPath == "" {
		return
	}

	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			pwd, err := readCNPGPasswordFile(pwPath)
			if err != nil {
				if log != nil {
					log.Warn().Err(err).Msg("CNPG password refresh skipped")
				}
				continue
			}

			if cfg.CNPG.Password == pwd {
				continue
			}

			if log != nil {
				log.Warn().Msg("CNPG password changed; rebuilding CNPG pool")
			}

			cfg.CNPG.Password = pwd

			newDB, err := db.New(context.Background(), dbConfig, dbLogger)
			if err != nil {
				if log != nil {
					log.Error().Err(err).Msg("Failed to rebuild CNPG pool after password change")
				}
				continue
			}

			if err := svc.ReloadDatabase(ctx, newDB); err != nil {
				_ = newDB.Close()
				if log != nil {
					log.Error().Err(err).Msg("Failed to reload db-event-writer after password change")
				}
				continue
			}

			if log != nil {
				log.Info().Msg("Reloaded db-event-writer after CNPG password change")
			}
		}
	}
}
