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

package logger

import (
	"os"
	"strings"
	"time"
)

func DefaultConfig() *Config {
	return &Config{
		Level:      getEnvOrDefault("LOG_LEVEL", "info"),
		Debug:      getEnvBoolOrDefault("DEBUG", false),
		Output:     getEnvOrDefault("LOG_OUTPUT", "stdout"),
		TimeFormat: getEnvOrDefault("LOG_TIME_FORMAT", ""),
		OTel:       DefaultOTelConfig(),
	}
}

func DefaultOTelConfig() OTelConfig {
	headers := make(map[string]string)

	if headerStr := os.Getenv("OTEL_EXPORTER_OTLP_LOGS_HEADERS"); headerStr != "" {
		for _, pair := range strings.Split(headerStr, ",") {
			if kv := strings.SplitN(pair, "=", 2); len(kv) == 2 {
				headers[strings.TrimSpace(kv[0])] = strings.TrimSpace(kv[1])
			}
		}
	}

	batchTimeout := 5 * time.Second

	if timeoutStr := os.Getenv("OTEL_EXPORTER_OTLP_LOGS_TIMEOUT"); timeoutStr != "" {
		if duration, err := time.ParseDuration(timeoutStr); err == nil {
			batchTimeout = duration
		}
	}

	return OTelConfig{
		Enabled:      getEnvBoolOrDefault("OTEL_LOGS_ENABLED", false),
		Endpoint:     getEnvOrDefault("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", ""),
		Headers:      headers,
		ServiceName:  getEnvOrDefault("OTEL_SERVICE_NAME", "serviceradar"),
		BatchTimeout: batchTimeout,
		Insecure:     getEnvBoolOrDefault("OTEL_EXPORTER_OTLP_LOGS_INSECURE", false),
	}
}

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}

	return defaultValue
}

func getEnvBoolOrDefault(key string, defaultValue bool) bool {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}

	value = strings.ToLower(value)

	return value == "true" || value == "1" || value == "yes" || value == "on"
}

func InitWithDefaults() error {
	return Init(DefaultConfig())
}
