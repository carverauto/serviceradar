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
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/sync"
)

func main() {
	configPath := flag.String("config", "/etc/serviceradar/sync.json", "Path to config file")
	flag.Parse()

	ctx := context.Background()
	cfgLoader := config.NewConfig()

	var cfg sync.Config

	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	syncer, err := sync.NewDefault(ctx, &cfg)
	if err != nil {
		log.Fatalf("Failed to create syncer: %v", err)
	}

	opts := &lifecycle.ServerOptions{
		ListenAddr:        "localhost:0",
		ServiceName:       "sync",
		Service:           syncer,
		EnableHealthCheck: false,
		Security:          cfg.Security,
	}

	if err := lifecycle.RunServer(ctx, opts); err != nil {
		log.Fatalf("Sync service failed: %v", err)
	}
}
