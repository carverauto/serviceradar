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
)

// KVConfigLoader loads configuration from a KV store.
type KVConfigLoader struct {
	store kv.KVStore
}

// NewKVConfigLoader creates a new KVConfigLoader with the given KV store.
func NewKVConfigLoader(store kv.KVStore) *KVConfigLoader {
	return &KVConfigLoader{store: store}
}

var (
	errKVKeyNotFound = errors.New("key not found in KV store")
)

// Load implements ConfigLoader by fetching and unmarshaling data from the KV store.
func (k *KVConfigLoader) Load(ctx context.Context, path string, dst interface{}) error {
	key := "config/" + path[strings.LastIndex(path, "/")+1:]

	data, found, err := k.store.Get(ctx, key)
	if err != nil {
		return fmt.Errorf("failed to get key '%s' from KV store: %w", key, err)
	}

	if !found {
		return fmt.Errorf("%w: '%s'", errKVKeyNotFound, key)
	}

	err = json.Unmarshal(data, dst)
	if err != nil {
		return fmt.Errorf("failed to unmarshal JSON from key '%s': %w", key, err)
	}

	return nil
}
