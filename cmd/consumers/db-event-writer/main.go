package main

import (
    "context"
    "log"
    "os"

    "google.golang.org/grpc"

    "github.com/carverauto/serviceradar/pkg/config"
    "github.com/carverauto/serviceradar/pkg/config/kvgrpc"
    coregrpc "github.com/carverauto/serviceradar/pkg/grpc"
	dbeventwriter "github.com/carverauto/serviceradar/pkg/consumers/db-event-writer"
    "github.com/carverauto/serviceradar/pkg/db"
    "github.com/carverauto/serviceradar/pkg/lifecycle"
    "github.com/carverauto/serviceradar/pkg/logger"
    "github.com/carverauto/serviceradar/pkg/models"
    monitoringpb "github.com/carverauto/serviceradar/proto"
    "github.com/carverauto/serviceradar/proto"
    "encoding/json"
)

func main() {
	ctx := context.Background()
    cfgLoader := config.NewConfig(nil)
    if os.Getenv("CONFIG_SOURCE") == "kv" && os.Getenv("KV_ADDRESS") != "" {
        if kvStore := dialKVFromEnv(); kvStore != nil {
            cfgLoader.SetKVStore(kvStore)
            defer func(){ _ = kvStore.Close() }()
        }
    }

	configPath := "/etc/serviceradar/consumers/db-event-writer.json"

	var cfg dbeventwriter.DBEventWriterConfig

    if err := cfgLoader.LoadAndValidate(ctx, configPath, &cfg); err != nil {
        log.Fatalf("Failed to load configuration: %v", err)
    }
    if os.Getenv("KV_ADDRESS") != "" {
        _ = cfgLoader.OverlayFromKV(ctx, configPath, &cfg)
    }

    // Bootstrap service-level default into KV if missing
    if os.Getenv("KV_ADDRESS") != "" {
        if kvStore := dialKVFromEnv(); kvStore != nil {
            defer func(){ _ = kvStore.Close() }()
            if data, _ := json.Marshal(cfg); data != nil {
                if _, found, _ := kvStore.Get(ctx, "config/db-event-writer.json"); !found {
                    _ = kvStore.Put(ctx, "config/db-event-writer.json", data, 0)
                }
            }
        }
    }

    // KV Watch setup will be done after service initialization

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

	// KV Watch: overlay and apply hot-reload on relevant changes
	if os.Getenv("CONFIG_SOURCE") == "kv" && os.Getenv("KV_ADDRESS") != "" {
		if kvStore := dialKVFromEnv(); kvStore != nil {
			prev := cfg
			config.StartKVWatchOverlay(ctx, kvStore, "config/db-event-writer.json", &cfg, serviceLogger, func(){
				triggers := map[string]bool{"reload": true, "rebuild": true}
				changed := config.FieldsChangedByTag(prev, cfg, "hot", triggers)
				if len(changed) > 0 {
					serviceLogger.Info().Strs("changed_fields", changed).Msg("Applying DB event writer hot-reload")
					_ = svc.UpdateConfig(ctx, &cfg)
					prev = cfg
				}
			})
		}
	}

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

func dialKVFromEnv() *kvgrpc.Client {
    addr := os.Getenv("KV_ADDRESS")
    if addr == "" { return nil }
    secMode := os.Getenv("KV_SEC_MODE")
    cert := os.Getenv("KV_CERT_FILE")
    key := os.Getenv("KV_KEY_FILE")
    ca := os.Getenv("KV_CA_FILE")
    serverName := os.Getenv("KV_SERVER_NAME")
    if secMode != "mtls" || cert == "" || key == "" || ca == "" { return nil }
    ctx := context.Background()
    sec := &models.SecurityConfig{ Mode: "mtls", TLS: models.TLSConfig{CertFile: cert, KeyFile: key, CAFile: ca}, ServerName: serverName, Role: models.RoleCore }
    provider, err := coregrpc.NewSecurityProvider(ctx, sec, nil)
    if err != nil { return nil }
    client, err := coregrpc.NewClient(ctx, coregrpc.ClientConfig{ Address: addr, SecurityProvider: provider })
    if err != nil { _ = provider.Close(); return nil }
    kvClient := proto.NewKVServiceClient(client.GetConnection())
    return kvgrpc.New(kvClient, func() error { _ = provider.Close(); return client.Close() })
}
