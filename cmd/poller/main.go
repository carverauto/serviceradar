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
    "fmt"
    "log"
    "os"

    "google.golang.org/grpc"

    "github.com/carverauto/serviceradar/pkg/config"
    "github.com/carverauto/serviceradar/pkg/config/kvgrpc"
    coregrpc "github.com/carverauto/serviceradar/pkg/grpc"
    "github.com/carverauto/serviceradar/pkg/lifecycle"
    "github.com/carverauto/serviceradar/pkg/logger"
    "github.com/carverauto/serviceradar/pkg/poller"
    "github.com/carverauto/serviceradar/pkg/models"
    "github.com/carverauto/serviceradar/proto"
    "encoding/json"
)

var (
	errFailedToLoadConfig = fmt.Errorf("failed to load config")
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/poller.json", "Path to poller config file")
	flag.Parse()

	// Setup a context we can use for loading the config and running the server
	ctx := context.Background()

	// Step 1: Load configuration
    cfgLoader := config.NewConfig(nil)
    // Optional: configure KV as config source using env
    if os.Getenv("CONFIG_SOURCE") == "kv" && os.Getenv("KV_ADDRESS") != "" {
        if kvStore := dialKVFromEnv(); kvStore != nil {
            cfgLoader.SetKVStore(kvStore)
            defer func(){ _ = kvStore.Close() }()
        }
    }

	var cfg poller.Config

    if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
        return fmt.Errorf("%w: %w", errFailedToLoadConfig, err)
    }
    if os.Getenv("KV_ADDRESS") != "" {
        _ = cfgLoader.OverlayFromKV(ctx, *configPath, &cfg)
    }


    // Bootstrap service-level default into KV if missing
    if os.Getenv("KV_ADDRESS") != "" {
        if kvStore := dialKVFromEnv(); kvStore != nil {
            defer func(){ _ = kvStore.Close() }()
            if data, _ := json.Marshal(cfg); data != nil {
                if _, found, _ := kvStore.Get(ctx, "config/poller.json"); !found {
                    _ = kvStore.Put(ctx, "config/poller.json", data, 0)
                }
            }
        }
    }

	// Step 2: Create logger from loaded config
	logConfig := cfg.Logging
	if logConfig == nil {
		// Use default config if not specified
		logConfig = &logger.Config{
			Level:  "info",
			Output: "stdout",
		}
	}

	pollerLogger, err := lifecycle.CreateComponentLogger(ctx, "poller", logConfig)
	if err != nil {
		return fmt.Errorf("failed to initialize logger: %w", err)
	}

    // Create poller instance with a real clock for production
    p, err := poller.New(ctx, &cfg, nil, pollerLogger) // nil clock defaults to realClock in poller.New
    if err != nil {
        return err
    }

    // KV Watch: overlay and apply hot-reload on relevant changes
    if os.Getenv("CONFIG_SOURCE") == "kv" && os.Getenv("KV_ADDRESS") != "" {
        if kvStore := dialKVFromEnv(); kvStore != nil {
            prev := cfg
            config.StartKVWatchOverlay(ctx, kvStore, "config/poller.json", &cfg, pollerLogger, func(){
                triggers := map[string]bool{"reload": true, "rebuild": true}
                changed := config.FieldsChangedByTag(prev, cfg, "hot", triggers)
                if len(changed) > 0 {
                    pollerLogger.Info().Strs("changed_fields", changed).Msg("Applying poller hot-reload")
                    _ = p.UpdateConfig(ctx, &cfg)
                    prev = cfg
                }
            })
        }
    }

	// No gRPC services to register - simplified architecture
	registerServices := func(_ *grpc.Server) error {
		return nil
	}

	// Run poller with lifecycle management
	return lifecycle.RunServer(ctx, &lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		ServiceName:          cfg.ServiceName,
		Service:              p,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerServices},
		EnableHealthCheck:    true,
		Security:             cfg.Security,
	})
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
    sec := &models.SecurityConfig{ Mode: "mtls", TLS: models.TLSConfig{CertFile: cert, KeyFile: key, CAFile: ca}, ServerName: serverName, Role: models.RolePoller }
    provider, err := coregrpc.NewSecurityProvider(ctx, sec, nil)
    if err != nil { return nil }
    client, err := coregrpc.NewClient(ctx, coregrpc.ClientConfig{ Address: addr, SecurityProvider: provider })
    if err != nil { _ = provider.Close(); return nil }
    kvClient := proto.NewKVServiceClient(client.GetConnection())
    return kvgrpc.New(kvClient, func() error { _ = provider.Close(); return client.Close() })
}
