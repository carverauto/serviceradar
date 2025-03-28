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
	"log"
	"os"
	"strings"

	"github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
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
	skipKV        bool
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
// pkg/config/config.go
func (c *Config) LoadAndValidate(ctx context.Context, path string, target interface{}, opts ...LoadOption) error {
	for _, opt := range opts {
		opt(c)
	}
	if !c.skipKV && c.kvStore != nil {
		value, found, err := c.kvStore.Get(ctx, path)
		if err != nil {
			log.Printf("KV Get failed for %s: %v", path, err)
			return err
		}
		if found {
			if err := json.Unmarshal(value, target); err != nil {
				log.Printf("Failed to unmarshal KV data for %s: %v", path, err)
				return err
			}
			log.Printf("Loaded config from KV: %s", path)
			return nil
		}
		log.Printf("Key %s not found in KV, falling back to file", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		log.Printf("File read failed for %s: %v", path, err)
		return err
	}
	if err := json.Unmarshal(data, target); err != nil {
		log.Printf("Failed to unmarshal file data for %s: %v", path, err)
		return err
	}
	log.Printf("Loaded config from file: %s", path)
	return nil
}

func (c *Config) autoInitializeKVStore(ctx context.Context, path string) error {
	log.Printf("Auto-initializing KV store for path: %s", path)

	// First try loading minimal config via file to get KV address
	var minConfig struct {
		KVAddress string                 `json:"kv_address"`
		Security  *models.SecurityConfig `json:"security"`
	}

	if err := c.defaultLoader.Load(ctx, path, &minConfig); err != nil {
		return fmt.Errorf("failed to load initial config to get KV address: %w", err)
	}

	if minConfig.KVAddress == "" {
		return fmt.Errorf("CONFIG_SOURCE=kv but no KV address in config at %s", path)
	}

	log.Printf("Found KV address: %s", minConfig.KVAddress)

	// Set up gRPC client like in sync package
	clientCfg := grpc.ClientConfig{
		Address:    minConfig.KVAddress,
		MaxRetries: 3,
	}

	if minConfig.Security != nil {
		log.Printf("Setting up security provider with mode=%s", minConfig.Security.Mode)
		provider, err := grpc.NewSecurityProvider(ctx, minConfig.Security)
		if err != nil {
			return fmt.Errorf("failed to create security provider: %w", err)
		}
		clientCfg.SecurityProvider = provider
	}

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return fmt.Errorf("failed to create KV gRPC client: %w", err)
	}

	// Create KV client and store
	kvClient := proto.NewKVServiceClient(client.GetConnection())
	c.kvStore = &grpcKVStore{
		client: kvClient,
		conn:   client,
	}

	log.Printf("Successfully initialized KV store client")

	return nil
}

// SetKVStore sets the KV store to be used when CONFIG_SOURCE=kv.
func (c *Config) SetKVStore(store kv.KVStore) {
	c.kvStore = store
}

type LoadOption func(*Config)

func WithFileOnly() LoadOption {
	return func(c *Config) {
		c.skipKV = true
	}
}

// loadAndValidateWithSource loads and validates config using the appropriate loader.
func (c *Config) loadAndValidateWithSource(ctx context.Context, path string, cfg interface{}) error {
	source := strings.ToLower(os.Getenv("CONFIG_SOURCE"))

	var loader ConfigLoader

	if source == configSourceKV {
		if c.kvStore == nil {
			return errKVStoreNotSet
		}

		loader = NewKVConfigLoader(c.kvStore, "serviceradar-kv")
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
