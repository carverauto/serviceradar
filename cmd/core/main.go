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

// @title ServiceRadar API
// @version 1.0
// @description API for monitoring and managing service pollers in the ServiceRadar system
// @termsOfService https://serviceradar.cloud/terms/

// @contact.name API Support
// @contact.url https://serviceradar.cloud/support
// @contact.email support@serviceradar.cloud

// @license.name Apache 2.0
// @license.url http://www.apache.org/licenses/LICENSE-2.0.html

// Multiple server configurations
// @servers.url https://demo.serviceradar.cloud
// @servers.description ServiceRadar Demo Cloud Server

// @servers.url http://{hostname}:{port}
// @servers.description ServiceRadar API Server
// @servers.variables.hostname.default localhost
// @servers.variables.port.default 8080

// @BasePath /
// @schemes http https

// @securityDefinitions.apikey ApiKeyAuth
// @in header
// @name Authorization

package main

import (
	"context"
	"flag"
	"log"

	"github.com/carverauto/serviceradar/cmd/core/app"
)

type coreFlags struct {
	ConfigPath     string
	Backfill       bool
	BackfillDryRun bool
	BackfillSeedKV bool
	BackfillIPs    bool
}

func parseFlags() coreFlags {
	configPath := flag.String("config", "/etc/serviceradar/core.json", "Path to core config file")
	backfill := flag.Bool("backfill-identities", false, "Run one-time identity backfill (Armis/NetBox) and exit")
	backfillDryRun := flag.Bool("backfill-dry-run", false, "If set with --backfill-identities, only log actions without writing")
	backfillSeedKV := flag.Bool("seed-kv-only", false, "Seed canonical identity map without emitting tombstones")
	backfillIPs := flag.Bool("backfill-ips", true, "Also backfill sweep-only device IDs by IP aliasing into canonical identities")
	flag.Parse()

	return coreFlags{
		ConfigPath:     *configPath,
		Backfill:       *backfill,
		BackfillDryRun: *backfillDryRun,
		BackfillSeedKV: *backfillSeedKV,
		BackfillIPs:    *backfillIPs,
	}
}

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	opts := parseFlags()
	appOptions := app.Options{
		ConfigPath:        opts.ConfigPath,
		BackfillEnabled:   opts.Backfill,
		BackfillDryRun:    opts.BackfillDryRun,
		BackfillSeedKV:    opts.BackfillSeedKV,
		BackfillIPs:       opts.BackfillIPs,
		BackfillNamespace: "",
	}

	return app.Run(context.Background(), appOptions)
}
