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
	"strings"

	"github.com/carverauto/serviceradar/pkg/config/kv"
)

var (
	errInvalidDuration = fmt.Errorf("invalid duration")
)

// LoadFile is a generic helper that loads a JSON file from path into
// the struct pointed to by dst.
func LoadFile(path string, dst interface{}) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("failed to read file '%s': %w", path, err)
	}

	if err := json.Unmarshal(data, dst); err != nil {
		return fmt.Errorf("failed to unmarshal JSON from '%s': %w", path, err)
	}

	return nil
}

// ValidateConfig validates a configuration if it implements Validator.
func ValidateConfig(cfg interface{}) error {
	if v, ok := cfg.(Validator); ok {
		return v.Validate()
	}
	return nil
}

// LoaderFactory defines a function that creates a ConfigLoader.
type LoaderFactory func() (ConfigLoader, error)

// LoadAndValidate loads a configuration from the specified source and validates it if possible.
// The loader is determined by the CONFIG_SOURCE environment variable ("file" or "kv").
// If the KV loader fails, it falls back to the file-based loader.
func LoadAndValidate(ctx context.Context, path string, cfg interface{}, kvStore kv.KVStore) error {
	source := strings.ToLower(os.Getenv("CONFIG_SOURCE"))
	var loader ConfigLoader

	switch source {
	case "kv":
		if kvStore == nil {
			return fmt.Errorf("KV store not provided for CONFIG_SOURCE=kv")
		}
		loader = NewKVConfigLoader(kvStore)
	case "file", "":
		loader = &FileConfigLoader{}
	default:
		return fmt.Errorf("invalid CONFIG_SOURCE value: %s (expected 'file' or 'kv')", source)
	}

	// Attempt to load with the selected loader
	err := loader.Load(ctx, path, cfg)
	if err != nil && source == "kv" {
		// Fallback to file-based loading if KV fails
		fallbackLoader := &FileConfigLoader{}
		if fallbackErr := fallbackLoader.Load(ctx, path, cfg); fallbackErr != nil {
			return fmt.Errorf("failed to load config from KV (%v) and fallback file (%v)", err, fallbackErr)
		}
	} else if err != nil {
		return err
	}

	return ValidateConfig(cfg)
}
