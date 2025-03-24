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
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/carverauto/serviceradar/pkg/config/kv"
)

var (
	errInvalidDuration     = fmt.Errorf("invalid duration")
	errKVStoreNotSet       = errors.New("KV store not initialized for CONFIG_SOURCE=kv; call SetKVStore first")
	errInvalidConfigSource = errors.New("invalid CONFIG_SOURCE value")
	errLoadConfigFailed    = errors.New("failed to load configuration")
)

const (
	configSourceKV   = "kv"
	configSourceFile = "file"
)

// Config holds the configuration loading dependencies.
type Config struct {
	kvStore       kv.KVStore
	defaultLoader ConfigLoader
}

// NewConfig initializes a new Config instance with a default file loader.
func NewConfig() *Config {
	return &Config{
		defaultLoader: &FileConfigLoader{},
	}
}

// LoadFile is a generic helper that loads a JSON file from path into
// the struct pointed to by dst.
func LoadFile(path string, dst interface{}) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("failed to read file '%s': %w", path, err)
	}

	err = json.Unmarshal(data, dst)
	if err != nil {
		return fmt.Errorf("failed to unmarshal JSON from '%s': %w", path, err)
	}

	return nil
}

// ValidateConfig validates a configuration if it implements Validator.
func ValidateConfig(cfg interface{}) error {
	v, ok := cfg.(Validator)
	if !ok {
		return nil
	}

	return v.Validate()
}

// LoadAndValidate loads a configuration and validates it if possible.
func (c *Config) LoadAndValidate(ctx context.Context, path string, cfg interface{}) error {
	return c.loadAndValidateWithSource(ctx, path, cfg)
}

// SetKVStore sets the KV store to be used when CONFIG_SOURCE=kv.
func (c *Config) SetKVStore(store kv.KVStore) {
	c.kvStore = store
}

// loadAndValidateWithSource loads and validates config using the appropriate loader.
func (c *Config) loadAndValidateWithSource(ctx context.Context, path string, cfg interface{}) error {
	source := strings.ToLower(os.Getenv("CONFIG_SOURCE"))

	var loader ConfigLoader

	if source == configSourceKV {
		if c.kvStore == nil {
			return errKVStoreNotSet
		}

		loader = NewKVConfigLoader(c.kvStore)
	}

	if source == configSourceFile || source == "" {
		loader = c.defaultLoader
	}

	if loader == nil {
		return fmt.Errorf("%w: %s (expected '%s' or '%s')", errInvalidConfigSource, source, configSourceFile, configSourceKV)
	}

	err := loader.Load(ctx, path, cfg)
	if err == nil {
		return ValidateConfig(cfg)
	}

	if source != configSourceKV {
		return err
	}

	err = c.defaultLoader.Load(ctx, path, cfg)
	if err != nil {
		return fmt.Errorf("%w from KV: %w, and from fallback file: %w", errLoadConfigFailed, err, err)
	}

	return ValidateConfig(cfg)
}
