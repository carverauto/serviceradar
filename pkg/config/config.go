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
	"os"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/rs/zerolog"
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
	configSourceEnv  = "env"
)

// Config holds the configuration loading dependencies.
type Config struct {
	kvStore       kv.KVStore
	defaultLoader ConfigLoader
	logger        logger.Logger
}

// NewConfig initializes a new Config instance with a default file loader and logger.
// If logger is nil, creates a basic logger for config loading.
func NewConfig(log logger.Logger) *Config {
	if log == nil {
		// Create a basic logger for config loading
		log = createBasicLogger()
	}

	return &Config{
		defaultLoader: &FileConfigLoader{logger: log},
		logger:        log,
	}
}

// basicLogger implements a simple logger for config loading without circular imports
type basicLogger struct {
	logger zerolog.Logger
}

// createBasicLogger creates a simple logger for config loading
func createBasicLogger() logger.Logger {
	// Create a minimal logger for config loading
	zlog := zerolog.New(os.Stderr).
		Level(zerolog.WarnLevel).
		With().
		Timestamp().
		Logger()

	return &basicLogger{logger: zlog}
}

func (b *basicLogger) Trace() *zerolog.Event {
	return b.logger.Trace()
}

func (b *basicLogger) Debug() *zerolog.Event {
	return b.logger.Debug()
}

func (b *basicLogger) Info() *zerolog.Event {
	return b.logger.Info()
}

func (b *basicLogger) Warn() *zerolog.Event {
	return b.logger.Warn()
}

func (b *basicLogger) Error() *zerolog.Event {
	return b.logger.Error()
}

func (b *basicLogger) Fatal() *zerolog.Event {
	return b.logger.Fatal()
}

func (b *basicLogger) Panic() *zerolog.Event {
	return b.logger.Panic()
}

func (b *basicLogger) With() zerolog.Context {
	return b.logger.With()
}

func (b *basicLogger) WithComponent(component string) zerolog.Logger {
	return b.logger.With().Str("component", component).Logger()
}

func (b *basicLogger) WithFields(fields map[string]interface{}) zerolog.Logger {
	ctx := b.logger.With()
	for key, value := range fields {
		ctx = ctx.Interface(key, value)
	}

	return ctx.Logger()
}

func (b *basicLogger) SetLevel(level zerolog.Level) {
	b.logger = b.logger.Level(level)
}

func (b *basicLogger) SetDebug(debug bool) {
	if debug {
		b.SetLevel(zerolog.DebugLevel)
	} else {
		b.SetLevel(zerolog.InfoLevel)
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
	err := c.loadAndValidateWithSource(ctx, path, cfg)
	if err != nil {
		return err
	}

	if err := c.normalizeSecurityConfig(cfg); err != nil {
		return fmt.Errorf("failed to normalize SecurityConfig: %w", err)
	}

	if err := ValidateConfig(cfg); err != nil {
		return err
	}

	return nil
}

// SetKVStore sets the KV store to be used when CONFIG_SOURCE=kv.
func (c *Config) SetKVStore(store kv.KVStore) {
	c.kvStore = store
}

// loadAndValidateWithSource loads and validates config using the appropriate loader.
func (c *Config) loadAndValidateWithSource(ctx context.Context, path string, cfg interface{}) error {
	source := strings.ToLower(os.Getenv("CONFIG_SOURCE"))

	var loader ConfigLoader

	switch source {
	case configSourceKV:
		if c.kvStore == nil {
			return errKVStoreNotSet
		}

		loader = NewKVConfigLoader(c.kvStore, c.logger)
	case configSourceEnv:
		// Use environment variables with optional prefix
		prefix := os.Getenv("CONFIG_ENV_PREFIX")
		if prefix == "" {
			prefix = "SERVICERADAR_"
		}

		loader = NewEnvConfigLoader(c.logger, prefix)
	case configSourceFile, "":
		loader = c.defaultLoader
	default:
		return fmt.Errorf("%w: %s (expected '%s', '%s', or '%s')",
			errInvalidConfigSource, source, configSourceFile, configSourceKV, configSourceEnv)
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
func (c *Config) normalizeSecurityConfig(cfg interface{}) error {
	v := reflect.ValueOf(cfg)

	if v.Kind() != reflect.Ptr || v.IsNil() {
		return errInvalidConfigPtr
	}

	v = v.Elem()

	if v.Kind() != reflect.Struct {
		return nil
	}

	return c.normalizeStructFields(v)
}

// normalizeStructFields processes all fields in a struct to normalize SecurityConfig instances.
func (c *Config) normalizeStructFields(v reflect.Value) error {
	t := v.Type()

	for i := 0; i < t.NumField(); i++ {
		fieldType := t.Field(i)

		if err := c.normalizeField(v.Field(i), &fieldType); err != nil {
			return err
		}
	}

	return nil
}

// normalizeField normalizes a single field if it's a *SecurityConfig.
func (c *Config) normalizeField(field reflect.Value, fieldType *reflect.StructField) error {
	if fieldType.Type != reflect.TypeOf((*models.SecurityConfig)(nil)) {
		return nil
	}

	if !field.IsValid() || field.IsNil() {
		return nil
	}

	sec := field.Interface().(*models.SecurityConfig)

	tls := &sec.TLS

	c.normalizeTLSPaths(tls, sec.CertDir)

	// Update the field with the normalized SecurityConfig
	field.Set(reflect.ValueOf(sec))

	return nil
}

// normalizeTLSPaths adjusts TLS file paths based on the certificate directory.
func (c *Config) normalizeTLSPaths(tls *models.TLSConfig, certDir string) {
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

	if c.logger != nil {
		c.logger.Info().
			Str("cert_file", tls.CertFile).
			Str("key_file", tls.KeyFile).
			Str("ca_file", tls.CAFile).
			Str("client_ca_file", tls.ClientCAFile).
			Msg("Normalized TLS paths")
	}
}

// NormalizeTLSPaths is a convenience function that normalizes TLS paths with default logging.
// This function exists for backward compatibility with existing code.
func NormalizeTLSPaths(tls *models.TLSConfig, certDir string) {
	basicLogger := createBasicLogger()

	cfg := &Config{logger: basicLogger}
	cfg.normalizeTLSPaths(tls, certDir)
}
