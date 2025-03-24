package config

import (
	"context"
	"encoding/json"
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

// Load implements ConfigLoader by fetching and unmarshaling data from the KV store.
func (k *KVConfigLoader) Load(ctx context.Context, path string, dst interface{}) error {
	// Map the file path to a KV key (e.g., "/path/to/sweep.json" -> "config/sweep.json")
	key := "config/" + path[strings.LastIndex(path, "/")+1:]

	data, found, err := k.store.Get(ctx, key)
	if err != nil {
		return fmt.Errorf("failed to get key '%s' from KV store: %w", key, err)
	}
	if !found {
		return fmt.Errorf("key '%s' not found in KV store", key)
	}

	if err := json.Unmarshal(data, dst); err != nil {
		return fmt.Errorf("failed to unmarshal JSON from key '%s': %w", key, err)
	}

	return nil
}
