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

package lifecycle

import (
	"fmt"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/rs/zerolog"
)

// InitializeLogger initializes the logger with the provided configuration.
// If config is nil, it uses the default configuration.
func InitializeLogger(config *logger.Config) error {
	if config == nil {
		config = logger.DefaultConfig()
	}

	if err := logger.Init(config); err != nil {
		return fmt.Errorf("failed to initialize logger: %w", err)
	}

	return nil
}

// CreateLogger creates a new logger instance with the provided configuration.
// This returns a logger that can be injected into services.
func CreateLogger(config *logger.Config) (zerolog.Logger, error) {
	if err := InitializeLogger(config); err != nil {
		return zerolog.Logger{}, err
	}

	return logger.GetLogger(), nil
}

// CreateComponentLogger creates a logger for a specific component.
func CreateComponentLogger(component string, config *logger.Config) (zerolog.Logger, error) {
	if err := InitializeLogger(config); err != nil {
		return zerolog.Logger{}, err
	}

	return logger.WithComponent(component), nil
}

// ShutdownLogger shuts down the logger, flushing any pending logs.
func ShutdownLogger() error {
	return logger.Shutdown()
}

// IsLoggerEmpty checks if a logger is the zero value (not initialized).
func IsLoggerEmpty(log zerolog.Logger) bool {
	// A zero-value logger will have a nil hook chain
	return log.GetLevel() == zerolog.NoLevel
}