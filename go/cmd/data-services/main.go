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
	_ "embed"
	"flag"
	"log"
	"os"

	ggrpc "google.golang.org/grpc"
	grpcstats "google.golang.org/grpc/stats"

	"github.com/carverauto/serviceradar/go/pkg/config"
	cfgbootstrap "github.com/carverauto/serviceradar/go/pkg/config/bootstrap"
	"github.com/carverauto/serviceradar/go/pkg/datasvc"
	"github.com/carverauto/serviceradar/go/pkg/lifecycle"
	"github.com/carverauto/serviceradar/go/pkg/nats/accounts"
	"github.com/carverauto/serviceradar/proto"
)

//go:embed config.json
var defaultConfig []byte

// untracedMethods lists high-frequency gRPC methods whose OTel spans are pure
// noise and are excluded from datasvc tracing. proto.KVService/Put fires on
// every KV write and would otherwise dominate span volume. Add further methods
// here (e.g. "/proto.KVService/Get") if they become equally noisy.
//nolint:gochecknoglobals // a small, immutable allowlist; a package-level slice is the clearest form
var untracedMethods = []string{
	"/proto.KVService/Put",
}

// datasvcTelemetryFilter reports whether an RPC should emit a span. It drops the
// methods listed in untracedMethods while tracing everything else. Health and
// reflection chatter is already filtered by the shared gRPC server.
func datasvcTelemetryFilter(info *grpcstats.RPCTagInfo) bool {
	if info == nil {
		return true
	}

	for _, method := range untracedMethods {
		if info.FullMethodName == method {
			return false
		}
	}

	return true
}

func main() {
	configPath := flag.String("config", "/etc/serviceradar/datasvc.json", "Path to config file")
	flag.Parse()

	ctx := context.Background()

	var cfg datasvc.Config
	desc, ok := config.ServiceDescriptorFor("datasvc")
	if !ok {
		log.Fatalf("datasvc descriptor missing")
	}
	bootstrapResult, err := cfgbootstrap.ServiceWithTemplateRegistration(ctx, desc, &cfg, defaultConfig, cfgbootstrap.ServiceOptions{
		ConfigPath:   *configPath,
		DisableWatch: true,
	})
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}
	defer func() { _ = bootstrapResult.Close() }()

	server, err := datasvc.NewServer(ctx, &cfg)
	if err != nil {
		_ = bootstrapResult.Close()
		log.Fatalf("Failed to create data service server: %v", err) //nolint:gocritic // Close is explicitly called before Fatalf
	}

	// Initialize NATS account service
	// This service is stateless - it only holds the operator key for signing operations.
	// Account state (seeds, JWTs) is stored by Elixir in CNPG with AshCloak encryption.
	// The service can start without an operator and bootstrap later via gRPC.
	var natsAccountServer *datasvc.NATSAccountServer
	if cfg.NATSOperator != nil {
		operator, opErr := accounts.NewOperator(cfg.NATSOperator)
		if opErr != nil {
			// Operator not available yet - that's okay, bootstrap will be called later
			log.Printf("NATS account service starting without operator (will bootstrap later): %v", opErr)
			natsAccountServer = datasvc.NewNATSAccountServer(nil)
		} else {
			natsAccountServer = datasvc.NewNATSAccountServer(operator)
			log.Printf("NATS account service initialized with operator %s", operator.Name())
		}

		natsAccountServer.SetAllowedClientIdentities(cfg.NATSOperator.AllowedClientIdentities)
		if len(cfg.NATSOperator.AllowedClientIdentities) == 0 {
			log.Printf("Warning: no allowed client identities configured for NATS account service; requests will be rejected")
		} else {
			log.Printf("NATS account service allowed identities: %v", cfg.NATSOperator.AllowedClientIdentities)
		}

		// Configure resolver paths for file-based JWT resolver
		// Priority: environment variables > config file
		operatorConfigPath := cfg.NATSOperator.OperatorConfigPath
		if envPath := os.Getenv("NATS_OPERATOR_CONFIG_PATH"); envPath != "" {
			operatorConfigPath = envPath
		}

		resolverPath := cfg.NATSOperator.ResolverPath
		if envPath := os.Getenv("NATS_RESOLVER_PATH"); envPath != "" {
			resolverPath = envPath
		}

		if operatorConfigPath != "" || resolverPath != "" {
			natsAccountServer.SetResolverPaths(operatorConfigPath, resolverPath)
			log.Printf("NATS resolver paths configured: operator=%s resolver=%s", operatorConfigPath, resolverPath)

			// If operator is already initialized, write the config now
			// This ensures config files exist even when datasvc restarts with an existing operator
			if operator != nil {
				if err := natsAccountServer.WriteOperatorConfig(); err != nil {
					log.Printf("Warning: failed to write initial operator config: %v", err)
				} else {
					log.Printf("Wrote initial operator config to %s", operatorConfigPath)
				}
			}
		}

		systemCredsFile := cfg.NATSOperator.SystemAccountCredsFile
		if envPath := os.Getenv("NATS_SYSTEM_ACCOUNT_CREDS_FILE"); envPath != "" {
			systemCredsFile = envPath
		}
		if systemCredsFile == "" {
			log.Printf("Warning: no system account creds configured; PushAccountJWT will fail")
		} else {
			natsAccountServer.SetResolverClient(cfg.NATSURL, cfg.NATSSecurity, systemCredsFile)
			log.Printf("NATS resolver client configured with system creds at %s", systemCredsFile)
		}
	}

	opts := &lifecycle.ServerOptions{
		ListenAddr:        cfg.ListenAddr,
		ServiceName:       "datasvc",
		Service:           server,
		EnableHealthCheck: true,
		Security:          cfg.Security,
		// Pass the logging config (logging.otel) so RunServer's logger
		// initialization stands up the process-wide TracerProvider via
		// EnsureTracing. Without it the otelgrpc server handler below would
		// run against the global no-op tracer and datasvc would emit zero
		// spans even though telemetry is enabled.
		LoggerConfig: cfg.Logging,
		// Telemetry enabled so web-ng -> core-elx -> datasvc traces compose
		// end-to-end. Span volume rides the parent sampling decision
		// (health/reflection chatter is already filtered by the lifecycle
		// infra filter). The TelemetryFilter below additionally drops
		// high-frequency KV write spans (proto.KVService/Put) that are pure
		// noise.
		DisableTelemetry: false,
		TelemetryFilter:  datasvcTelemetryFilter,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(srv *ggrpc.Server) error {
				proto.RegisterKVServiceServer(srv, server)
				proto.RegisterDataServiceServer(srv, server)
				// Register NATS account service if configured
				if natsAccountServer != nil {
					proto.RegisterNATSAccountServiceServer(srv, natsAccountServer)
				}
				return nil
			},
		},
	}

	if err := lifecycle.RunServer(ctx, opts); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
