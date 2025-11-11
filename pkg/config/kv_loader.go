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
	"strings"

	"github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/logger"
)

// KVConfigLoader loads configuration from a KV store.
type KVConfigLoader struct {
	store  kv.KVStore
	logger logger.Logger
}

// NewKVConfigLoader creates a new KVConfigLoader with the given KV store and logger.
func NewKVConfigLoader(store kv.KVStore, log logger.Logger) *KVConfigLoader {
	return &KVConfigLoader{
		store:  store,
		logger: log,
	}
}

var (
	errKVKeyNotFound = errors.New("key not found in KV store")
)

func isExplicitKVKey(path string) bool {
	trimmed := strings.TrimSpace(path)
	switch {
	case strings.HasPrefix(trimmed, "config/"),
		strings.HasPrefix(trimmed, "agents/"),
		strings.HasPrefix(trimmed, "pollers/"),
		strings.HasPrefix(trimmed, "watchers/"),
		strings.HasPrefix(trimmed, "templates/"),
		strings.HasPrefix(trimmed, "domains/"):
		return true
	default:
		return false
	}
}

func deriveKVKey(path string) string {
	trimmed := strings.TrimSpace(path)
	if isExplicitKVKey(trimmed) {
		return trimmed
	}

	lastSlash := strings.LastIndex(trimmed, "/")
	if lastSlash >= 0 && lastSlash < len(trimmed)-1 {
		return "config/" + trimmed[lastSlash+1:]
	}

	return "config/" + trimmed
}

// Load implements ConfigLoader by fetching and unmarshaling data from the KV store.
func (k *KVConfigLoader) Load(ctx context.Context, path string, dst interface{}) error {
	key := deriveKVKey(path)

	if k.logger != nil {
		k.logger.Debug().Str("key", key).Str("path", path).Msg("Loading configuration from KV store")
	}

	data, found, err := k.store.Get(ctx, key)
	if err != nil {
		if k.logger != nil {
			k.logger.Error().Str("key", key).Err(err).Msg("Failed to get key from KV store")
		}

		return fmt.Errorf("failed to get key '%s' from KV store: %w", key, err)
	}

	if !found {
		if k.logger != nil {
			k.logger.Warn().Str("key", key).Msg("Key not found in KV store")
		}

		return fmt.Errorf("%w: '%s'", errKVKeyNotFound, key)
	}

	err = json.Unmarshal(data, dst)
	if err != nil {
		if k.logger != nil {
			k.logger.Error().Str("key", key).Err(err).Msg("Failed to unmarshal JSON from KV store")
		}

		return fmt.Errorf("failed to unmarshal JSON from key '%s': %w", key, err)
	}

	if k.logger != nil {
		k.logger.Info().Str("key", key).Msg("Successfully loaded configuration from KV store")
	}

	return nil
}
