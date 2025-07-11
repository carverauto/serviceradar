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

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/kv"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/proto"
	ggrpc "google.golang.org/grpc"
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/kv.json", "Path to config file")
	flag.Parse()

	ctx := context.Background()

	cfgLoader := config.NewConfigWithDefaults()

	var cfg kv.Config
	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	if err := cfg.Validate(); err != nil {
		log.Fatalf("Invalid configuration: %v", err)
	}

	server, err := kv.NewServer(ctx, &cfg)
	if err != nil {
		log.Fatalf("Failed to create KV server: %v", err)
	}

	cfgLoader.SetKVStore(server.Store())

	opts := &lifecycle.ServerOptions{
		ListenAddr:        cfg.ListenAddr,
		ServiceName:       "kv",
		Service:           server,
		EnableHealthCheck: true,
		Security:          cfg.Security,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(srv *ggrpc.Server) error {
				proto.RegisterKVServiceServer(srv, server)
				return nil
			},
		},
	}

	if err := lifecycle.RunServer(ctx, opts); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
