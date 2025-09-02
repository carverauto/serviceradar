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
	"os"

	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/config/kvgrpc"
	coregrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
    "github.com/carverauto/serviceradar/pkg/models"
    "github.com/carverauto/serviceradar/pkg/sync"
    "github.com/carverauto/serviceradar/proto"
    "encoding/json"
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/sync.json", "Path to config file")
	flag.Parse()

	ctx := context.Background()

	// Step 1: Load config
    cfgLoader := config.NewConfig(nil)
    if os.Getenv("CONFIG_SOURCE") == "kv" && os.Getenv("KV_ADDRESS") != "" {
        if kvStore := dialKVFromEnv(); kvStore != nil {
            cfgLoader.SetKVStore(kvStore)
            defer func(){ _ = kvStore.Close() }()
        }
    }

	var cfg sync.Config

    if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
        log.Fatalf("Failed to load config: %v", err)
    }
    if os.Getenv("KV_ADDRESS") != "" {
        _ = cfgLoader.OverlayFromKV(ctx, *configPath, &cfg)
    }

    // Bootstrap service-level default into KV if missing
    if os.Getenv("KV_ADDRESS") != "" {
        if kvStore := dialKVFromEnv(); kvStore != nil {
            defer func(){ _ = kvStore.Close() }()
            if data, _ := json.Marshal(cfg); data != nil {
                if _, found, _ := kvStore.Get(ctx, "config/sync.json"); !found {
                    _ = kvStore.Put(ctx, "config/sync.json", data, 0)
                }
            }
        }
    }


	// Step 2: Create logger from config
	logger, err := lifecycle.CreateComponentLogger(ctx, "sync", cfg.Logging)
	if err != nil {
		log.Fatalf("Failed to initialize logger: %v", err)
	}

	// Step 3: Create config loader with proper logger for any future config operations
	_ = config.NewConfig(logger)

	syncer, err := sync.NewDefault(ctx, &cfg, logger)
	if err != nil {
		if shutdownErr := lifecycle.ShutdownLogger(); shutdownErr != nil {
			log.Printf("Failed to shutdown logger: %v", shutdownErr)
		}

		log.Fatalf("Failed to create syncer: %v", err)
	}

	// KV Watch: overlay and apply hot-reload on relevant changes
	if os.Getenv("CONFIG_SOURCE") == "kv" && os.Getenv("KV_ADDRESS") != "" {
		if kvStore := dialKVFromEnv(); kvStore != nil {
			prev := cfg
			config.StartKVWatchOverlay(ctx, kvStore, "config/sync.json", &cfg, logger, func(){
				triggers := map[string]bool{"reload": true, "rebuild": true}
				changed := config.FieldsChangedByTag(prev, cfg, "hot", triggers)
				if len(changed) > 0 {
					logger.Info().Strs("changed_fields", changed).Msg("Applying sync hot-reload")
					syncer.UpdateConfig(&cfg)
					prev = cfg
				}
			})
		}
	}

	registerServices := func(s *grpc.Server) error {
		proto.RegisterAgentServiceServer(s, syncer)
		return nil
	}

	opts := &lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		ServiceName:          "sync",
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerServices},
		Service:              syncer,
		EnableHealthCheck:    true,
		Security:             cfg.Security,
		Logger:               logger,
	}

	// Start server and handle shutdown
	serverErr := lifecycle.RunServer(ctx, opts)

	// Always shutdown logger before exiting
	if err := lifecycle.ShutdownLogger(); err != nil {
		log.Printf("Failed to shutdown logger: %v", err)
	}

	if serverErr != nil {
		log.Fatalf("Sync service failed: %v", serverErr)
	}
}


// dialKVFromEnv creates a KV adapter from environment variables.
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
