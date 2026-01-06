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
// @description API for monitoring and managing service gateways in the ServiceRadar system
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
	"os"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/cmd/core/app"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	configPath := flag.String("config", "/etc/serviceradar/core.json", "Path to core config file")
	flag.Parse()

	watchEnabled := parseEnvBool("CONFIG_WATCH_ENABLED", true)
	appOptions := app.Options{
		ConfigPath:   *configPath,
		DisableWatch: !watchEnabled,
	}

	return app.Run(context.Background(), appOptions)
}

func parseEnvBool(key string, defaultVal bool) bool {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return defaultVal
	}
	if val, err := strconv.ParseBool(raw); err == nil {
		return val
	}
	return defaultVal
}
