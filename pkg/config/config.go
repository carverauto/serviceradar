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
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/google/uuid"
)

var (
	errKVStoreNotSet       = errors.New("KV store not initialized for CONFIG_SOURCE=kv; call SetKVStore first")
	errInvalidConfigSource = errors.New("invalid CONFIG_SOURCE value")
	errLoadConfigFailed    = errors.New("failed to load configuration")
	errInvalidConfigPtr    = errors.New("config must be a non-nil pointer")
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

// ValidateConfig validates a configuration if it implements Validator.
func ValidateConfig(cfg interface{}) error {
	v, ok := cfg.(Validator)
	if !ok {
		return nil
	}

	return v.Validate()
}

// LoadAndValidate loads a configuration, normalizes SecurityConfig paths if present, and validates it.
func (c *Config) LoadAndValidate(ctx context.Context, path string, cfg interface{}) error {
	callID := uuid.New().String() // Import "github.com/google/uuid"
	log.Printf("Entering LoadAndValidate [ID: %s] for path: %s", callID, path)
	err := c.loadAndValidateWithSource(ctx, path, cfg)
	if err != nil {
		log.Printf("LoadAndValidate [ID: %s] failed: %v", callID, err)
		return err
	}
	if err := normalizeSecurityConfig(cfg); err != nil {
		log.Printf("Failed to normalize SecurityConfig [ID: %s]: %v", callID, err)
		return fmt.Errorf("failed to normalize SecurityConfig: %w", err)
	}
	if err := ValidateConfig(cfg); err != nil {
		log.Printf("Config validation failed [ID: %s]: %v", callID, err)
		return err
	}
	log.Printf("LoadAndValidate [ID: %s] completed successfully", callID)
	return nil
}

/*
func (c *Config) LoadAndValidate(ctx context.Context, path string, cfg interface{}) error {
	err := c.loadAndValidateWithSource(ctx, path, cfg)
	if err != nil {
		return err
	}

	if err := normalizeSecurityConfig(cfg); err != nil {
		return fmt.Errorf("failed to normalize SecurityConfig: %w", err)
	}

	return ValidateConfig(cfg)
}

*/

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
	if err != nil {
		if source != configSourceKV {
			return err
		}

		err = c.defaultLoader.Load(ctx, path, cfg)
		if err != nil {
			return fmt.Errorf("%w from KV: %w, and from fallback file: %w", errLoadConfigFailed, err, err)
		}
	}

	return nil
}

// normalizeSecurityConfig normalizes TLS paths in any struct containing a SecurityConfig field.
func normalizeSecurityConfig(cfg interface{}) error {
	v := reflect.ValueOf(cfg)
	if v.Kind() != reflect.Ptr || v.IsNil() {
		return errInvalidConfigPtr
	}

	v = v.Elem()
	if v.Kind() != reflect.Struct {
		return nil // Nothing to normalize if not a struct
	}

	return normalizeStructFields(v)
}

// normalizeStructFields processes all fields in a struct to normalize SecurityConfig instances.
func normalizeStructFields(v reflect.Value) error {
	t := v.Type()

	for i := 0; i < t.NumField(); i++ {
		fieldType := t.Field(i)                                        // Assign to variable
		if err := normalizeField(v.Field(i), &fieldType); err != nil { // Pass pointer
			return err
		}
	}

	return nil
}

// normalizeField normalizes a single field if it’s a *SecurityConfig.
func normalizeField(field reflect.Value, fieldType *reflect.StructField) error {
	if fieldType.Type != reflect.TypeOf((*models.SecurityConfig)(nil)) {
		return nil
	}

	if !field.IsValid() || field.IsNil() {
		return nil
	}

	sec := field.Interface().(*models.SecurityConfig)
	if sec.CertDir == "" {
		return nil
	}

	tls := &sec.TLS
	normalizeTLSPaths(tls, sec.CertDir)

	// Update the field with the normalized SecurityConfig
	field.Set(reflect.ValueOf(sec))

	return nil
}

// normalizeTLSPaths adjusts TLS file paths based on the certificate directory.
func normalizeTLSPaths(tls *models.TLSConfig, certDir string) {
	if !filepath.IsAbs(tls.CertFile) {
		tls.CertFile = filepath.Join(certDir, tls.CertFile)
	}

	if !filepath.IsAbs(tls.KeyFile) {
		tls.KeyFile = filepath.Join(certDir, tls.KeyFile)
	}

	if !filepath.IsAbs(tls.CAFile) {
		tls.CAFile = filepath.Join(certDir, tls.CAFile)
	}

	if tls.ClientCAFile != "" && !filepath.IsAbs(tls.ClientCAFile) {
		tls.ClientCAFile = filepath.Join(certDir, tls.ClientCAFile)
	} else if tls.ClientCAFile == "" {
		tls.ClientCAFile = tls.CAFile // Fallback to CAFile if unset
	}
}
