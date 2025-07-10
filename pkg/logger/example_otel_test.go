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

package logger_test

import (
	"os"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
)

func Example_otelConfiguration() {
	config := logger.Config{
		Level:      "debug",
		Debug:      true,
		Output:     "stdout",
		TimeFormat: "",
		OTel: logger.OTelConfig{
			Enabled:      true,
			Endpoint:     "localhost:4317",
			ServiceName:  "my-service",
			BatchTimeout: 5 * time.Second,
			Insecure:     true,
			Headers: map[string]string{
				"Authorization": "Bearer token123",
			},
		},
	}

	if config.OTel.Enabled {
		logger.Info().Msg("OTel logging is enabled")
	}
}

func Example_otelEnvironmentVariables() {
	os.Setenv("OTEL_LOGS_ENABLED", "true")
	os.Setenv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "localhost:4317")
	os.Setenv("OTEL_SERVICE_NAME", "serviceradar")
	os.Setenv("OTEL_EXPORTER_OTLP_LOGS_HEADERS", "Authorization=Bearer token123,X-API-Key=abc123")
	os.Setenv("OTEL_EXPORTER_OTLP_LOGS_INSECURE", "true")

	config := logger.DefaultConfig()

	err := logger.Init(config)
	if err != nil {
		panic(err)
	}

	defer logger.Shutdown()

	logger.Info().
		Str("user_id", "12345").
		Str("operation", "login").
		Msg("User authenticated successfully")

	logger.Error().
		Str("error", "connection timeout").
		Int("retry_count", 3).
		Msg("Failed to connect to database")
}

func Example_otelWithoutCollector() {
	config := logger.Config{
		Level:  "info",
		Output: "stdout",
		OTel: logger.OTelConfig{
			Enabled: false,
		},
	}

	err := logger.Init(config)
	if err != nil {
		panic(err)
	}

	logger.Info().Msg("This will only go to stdout, not to OTel collector")
}

func Example_otelGracefulShutdown() {
	defer func() {
		if err := logger.Shutdown(); err != nil {
			logger.Error().Err(err).Msg("Failed to shutdown logger")
		}
	}()

	config := logger.Config{
		Level:  "info",
		Output: "stdout",
		OTel: logger.OTelConfig{
			Enabled:     true,
			Endpoint:    "localhost:4317",
			ServiceName: "my-service",
			Insecure:    true,
		},
	}

	err := logger.Init(config)
	if err != nil {
		panic(err)
	}

	logger.Info().Msg("Application shutting down")
}
