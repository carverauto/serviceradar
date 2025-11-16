package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

type migrateConfig struct {
	host              string
	port              int
	database          string
	username          string
	password          string
	passwordFile      string
	sslMode           string
	certDir           string
	caFile            string
	certFile          string
	keyFile           string
	appName           string
	statementTimeout  time.Duration
	healthCheckPeriod time.Duration
	maxConns          int
	minConns          int
	debug             bool
	runtimeParams     map[string]string
}

var (
	errTLSFilesIncomplete      = errors.New("cnpg tls: --ca-file, --cert-file, and --key-file must be provided together")
	errNoCNPGConfiguration     = errors.New("no CNPG configuration provided")
	errCNPGHostRequired        = errors.New("cnpg host is required")
	errCNPGDatabaseRequired    = errors.New("cnpg database is required")
	errInvalidCNPGPort         = errors.New("invalid cnpg port")
	errInvalidRuntimeParameter = errors.New("invalid runtime parameter format")
	errRuntimeParamKeyEmpty    = errors.New("runtime parameter key cannot be empty")
)

func main() {
	cfg := parseFlags()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	err := run(ctx, cfg)
	cancel()

	if err != nil {
		log.Fatalf("cnpg-migrate: %v", err)
	}
}

func run(ctx context.Context, cfg *migrateConfig) error {
	if err := cfg.validate(); err != nil {
		return err
	}
	if err := cfg.resolvePassword(); err != nil {
		return err
	}

	logCfg := &logger.Config{
		Level:  "info",
		Debug:  cfg.debug,
		Output: "stdout",
	}

	appLogger, err := lifecycle.CreateComponentLogger(ctx, "cnpg-migrate", logCfg)
	if err != nil {
		return fmt.Errorf("initialize logger: %w", err)
	}

	cnpg := &models.CNPGDatabase{
		Host:            cfg.host,
		Port:            cfg.port,
		Database:        cfg.database,
		Username:        cfg.username,
		Password:        cfg.password,
		SSLMode:         cfg.sslMode,
		ApplicationName: cfg.appName,
		CertDir:         cfg.certDir,
	}

	if len(cfg.runtimeParams) > 0 {
		cnpg.ExtraRuntimeParams = make(map[string]string, len(cfg.runtimeParams))
		for key, value := range cfg.runtimeParams {
			cnpg.ExtraRuntimeParams[key] = value
		}
	}

	if cfg.maxConns > 0 {
		cnpg.MaxConnections = int32(cfg.maxConns)
	}
	if cfg.minConns > 0 {
		cnpg.MinConnections = int32(cfg.minConns)
	}
	if cfg.statementTimeout > 0 {
		cnpg.StatementTimeout = models.Duration(cfg.statementTimeout)
	}
	if cfg.healthCheckPeriod > 0 {
		cnpg.HealthCheckPeriod = models.Duration(cfg.healthCheckPeriod)
	}

	if cfg.caFile != "" || cfg.certFile != "" || cfg.keyFile != "" {
		if cfg.caFile == "" || cfg.certFile == "" || cfg.keyFile == "" {
			return errTLSFilesIncomplete
		}

		cnpg.TLS = &models.TLSConfig{
			CertFile: cfg.certFile,
			KeyFile:  cfg.keyFile,
			CAFile:   cfg.caFile,
		}
	}

	pool, err := db.NewCNPGPool(ctx, cnpg, appLogger)
	if err != nil {
		return fmt.Errorf("connect to CNPG: %w", err)
	}
	if pool == nil {
		return errNoCNPGConfiguration
	}
	defer pool.Close()

	appLogger.Info().Msg("applying CNPG migrations")
	if err := db.RunCNPGMigrations(ctx, pool, appLogger); err != nil {
		return fmt.Errorf("apply migrations: %w", err)
	}
	appLogger.Info().Msg("CNPG migrations finished successfully")

	return nil
}

func (cfg *migrateConfig) validate() error {
	if strings.TrimSpace(cfg.host) == "" {
		return errCNPGHostRequired
	}
	if strings.TrimSpace(cfg.database) == "" {
		return errCNPGDatabaseRequired
	}
	if cfg.port <= 0 || cfg.port > 65535 {
		return fmt.Errorf("%w: %d", errInvalidCNPGPort, cfg.port)
	}

	return nil
}

func (cfg *migrateConfig) resolvePassword() error {
	if cfg.password != "" || cfg.passwordFile == "" {
		return nil
	}

	data, err := os.ReadFile(cfg.passwordFile)
	if err != nil {
		return fmt.Errorf("read password file: %w", err)
	}

	cfg.password = strings.TrimSpace(string(data))
	return nil
}

func parseFlags() *migrateConfig {
	cfg := &migrateConfig{
		runtimeParams: make(map[string]string),
	}

	flag.StringVar(&cfg.host, "host", envString("CNPG_HOST", "127.0.0.1"), "CNPG host or IP address")
	flag.IntVar(&cfg.port, "port", envInt("CNPG_PORT", 5432), "CNPG port")
	flag.StringVar(&cfg.database, "database", envString("CNPG_DATABASE", "telemetry"), "Target database name")
	flag.StringVar(&cfg.username, "username", envStringAny([]string{"CNPG_USERNAME", "CNPG_USER"}, "postgres"), "Database username")
	flag.StringVar(&cfg.password, "password", envString("CNPG_PASSWORD", ""), "Database password (prefer env or --password-file)")
	flag.StringVar(&cfg.passwordFile, "password-file", envString("CNPG_PASSWORD_FILE", ""), "Path to a file that contains the database password")
	flag.StringVar(&cfg.sslMode, "sslmode", envString("CNPG_SSLMODE", "disable"), "Postgres sslmode")
	flag.StringVar(&cfg.certDir, "cert-dir", envString("CNPG_CERT_DIR", ""), "Directory that contains TLS files (optional)")
	flag.StringVar(&cfg.caFile, "ca-file", envString("CNPG_CA_FILE", ""), "Path to the CNPG CA bundle")
	flag.StringVar(&cfg.certFile, "cert-file", envString("CNPG_CERT_FILE", ""), "Path to the CNPG client certificate")
	flag.StringVar(&cfg.keyFile, "key-file", envString("CNPG_KEY_FILE", ""), "Path to the CNPG client private key")
	flag.StringVar(&cfg.appName, "app-name", envString("CNPG_APP_NAME", "serviceradar-migrator"), "Application name recorded in pg_stat_activity")
	flag.DurationVar(&cfg.statementTimeout, "statement-timeout", envDuration("CNPG_STATEMENT_TIMEOUT", 0), "Optional statement timeout (e.g. 30s)")
	flag.DurationVar(&cfg.healthCheckPeriod, "health-check-period", envDuration("CNPG_HEALTH_CHECK_PERIOD", 0), "Optional pgx pool health check period")
	flag.IntVar(&cfg.maxConns, "max-conns", envInt("CNPG_MAX_CONNS", 4), "Maximum pgx connections")
	flag.IntVar(&cfg.minConns, "min-conns", envInt("CNPG_MIN_CONNS", 0), "Minimum pgx connections")
	flag.BoolVar(&cfg.debug, "debug", envBool("CNPG_MIGRATE_DEBUG", false), "Enable debug logging")
	flag.Func("runtime-param", "Additional runtime parameter in key=value form (repeatable)", func(value string) error {
		value = strings.TrimSpace(value)
		if value == "" {
			return nil
		}

		parts := strings.SplitN(value, "=", 2)
		if len(parts) != 2 {
			return fmt.Errorf("%w: %q", errInvalidRuntimeParameter, value)
		}

		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])
		if key == "" {
			return errRuntimeParamKeyEmpty
		}

		cfg.runtimeParams[key] = val
		return nil
	})

	flag.Parse()
	return cfg
}

func envString(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func envStringAny(keys []string, fallback string) string {
	for _, key := range keys {
		if value := os.Getenv(key); value != "" {
			return value
		}
	}
	return fallback
}

func envInt(key string, fallback int) int {
	if value := os.Getenv(key); value != "" {
		if parsed, err := strconv.Atoi(value); err == nil {
			return parsed
		}
	}
	return fallback
}

func envDuration(key string, fallback time.Duration) time.Duration {
	if value := os.Getenv(key); value != "" {
		if parsed, err := time.ParseDuration(value); err == nil {
			return parsed
		}
	}
	return fallback
}

func envBool(key string, fallback bool) bool {
	if value := os.Getenv(key); value != "" {
		switch strings.ToLower(value) {
		case "1", "true", "yes", "on":
			return true
		case "0", "false", "no", "off":
			return false
		}
	}
	return fallback
}
