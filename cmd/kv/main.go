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
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/kv"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
)

const (
	defaultTTL = 24 * time.Hour
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/kv.json", "Path to config file")
	natsURL := flag.String("nats-url", "nats://localhost:4222", "NATS server URL")
	flag.Parse()

	ctx := context.Background()

	// Load KV service config
	cfgLoader := config.NewConfig()

	var cfg kv.Config

	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// Create NATS JetStream KV store
	store, err := kv.NewNatsStore(ctx, *natsURL, "serviceradar-config", defaultTTL)
	if err != nil {
		log.Fatalf("Failed to create NATS KV store: %v", err)
	}

	// Set KV store for config package
	cfgLoader.SetKVStore(store)

	// Create KV server
	server, err := kv.NewServer(cfg, store)
	if err != nil {
		log.Fatalf("Failed to create KV server: %v", err)
	}

	// Run with lifecycle management
	opts := &lifecycle.ServerOptions{
		ListenAddr:        cfg.ListenAddr,
		ServiceName:       "kv",
		Service:           server,
		EnableHealthCheck: true,
		Security:          cfg.Security,
	}

	if err := lifecycle.RunServer(ctx, opts); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
