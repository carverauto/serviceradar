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

package config

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/carverauto/serviceradar/pkg/logger"
)

// FileConfigLoader loads configuration from a local JSON file.
type FileConfigLoader struct {
	logger logger.Logger
}

// Load implements ConfigLoader by reading and unmarshaling a JSON file.
func (f *FileConfigLoader) Load(_ context.Context, path string, dst interface{}) error {
	if f.logger != nil {
		f.logger.Debug().Str("path", path).Msg("Loading configuration from file")
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if f.logger != nil {
			f.logger.Error().Str("path", path).Err(err).Msg("Failed to read configuration file")
		}

		return fmt.Errorf("failed to read file '%s': %w", path, err)
	}

	err = json.Unmarshal(data, dst)
	if err != nil {
		if f.logger != nil {
			f.logger.Error().Str("path", path).Err(err).Msg("Failed to unmarshal JSON from file")
		}

		return fmt.Errorf("failed to unmarshal JSON from '%s': %w", path, err)
	}

	if f.logger != nil {
		f.logger.Info().Str("path", path).Msg("Successfully loaded configuration from file")
	}

	return nil
}
