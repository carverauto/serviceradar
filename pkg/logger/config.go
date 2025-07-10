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
)

func DefaultConfig() Config {
	return Config{
		Level:      getEnvOrDefault("LOG_LEVEL", "info"),
		Debug:      getEnvBoolOrDefault("DEBUG", false),
		Output:     getEnvOrDefault("LOG_OUTPUT", "stdout"),
		TimeFormat: getEnvOrDefault("LOG_TIME_FORMAT", ""),
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
