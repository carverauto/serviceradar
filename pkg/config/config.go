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

// Package config provides configuration loading and management utilities with support for file and KV store backends.
package config

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"time"

	"github.com/rs/zerolog"

	"github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
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

// OverlayFromKV loads the config from KV and overlays it onto dst (which should already
// contain the file-loaded configuration). KV values override only the fields present in KV.
// If KV is not configured or the key is not found, this is a no-op.
func (c *Config) OverlayFromKV(ctx context.Context, path string, dst interface{}) error {
	if c.kvStore == nil {
		return nil
	}

	// Build KV key the same way as KVConfigLoader does
	key := "config/" + path[strings.LastIndex(path, "/")+1:]

	data, found, err := c.kvStore.Get(ctx, key)
	if err != nil || !found {
		return nil // no overlay if not present or error
	}

	// Merge: marshal dst -> map, unmarshal KV -> map, deep-merge, decode back into dst
	baseBytes, err := json.Marshal(dst)
	if err != nil {
		return err
	}
	var base map[string]interface{}
	if err := json.Unmarshal(baseBytes, &base); err != nil {
		return err
	}
	var over map[string]interface{}
	if err := decodeJSONObject(data, &over); err != nil {
		return err
	}

	if normalizeOverlayTypes(over, base) {
		if normalized, err := json.Marshal(over); err == nil {
			if err := c.kvStore.Put(ctx, key, normalized, 0); err != nil && c.logger != nil {
				c.logger.Warn().
					Err(err).
					Str("key", key).
					Msg("failed to rewrite normalized KV entry")
			}
		}
	}

	merged := deepMerge(base, over)
	mergedBytes, err := json.Marshal(merged)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(mergedBytes, dst); err != nil {
		return err
	}

	if err := c.normalizeSecurityConfig(dst); err != nil {
		return fmt.Errorf("failed to normalize SecurityConfig after overlay: %w", err)
	}

	return ValidateConfig(dst)
}

// deepMerge overlays src onto dst recursively.
func deepMerge(dst, src map[string]interface{}) map[string]interface{} {
	for k, v := range src {
		if vm, ok := v.(map[string]interface{}); ok {
			if dv, ok := dst[k].(map[string]interface{}); ok {
				dst[k] = deepMerge(dv, vm)
			} else {
				dst[k] = vm
			}
		} else {
			dst[k] = v
		}
	}
	return dst
}

// MergeOverlayBytes deep-merges a JSON document onto an existing config struct in memory.
// Fields present in overlay override destination; others remain unchanged.
func MergeOverlayBytes(dst interface{}, overlay []byte) error {
	var base map[string]interface{}
	baseBytes, err := json.Marshal(dst)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(baseBytes, &base); err != nil {
		return err
	}
	var over map[string]interface{}
	if err := json.Unmarshal(overlay, &over); err != nil {
		return err
	}
	merged := deepMerge(base, over)
	mergedBytes, err := json.Marshal(merged)
	if err != nil {
		return err
	}
	return json.Unmarshal(mergedBytes, dst)
}

func decodeJSONObject(data []byte, out interface{}) error {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()

	return dec.Decode(out)
}

func normalizeOverlayTypes(overlay map[string]interface{}, base map[string]interface{}) bool {
	changed := false

	for key, value := range overlay {
		var baseValue interface{}
		if base != nil {
			baseValue = base[key]
		}
		if newValue, subChanged := coerceOverlayValue(value, baseValue); subChanged {
			overlay[key] = newValue
			changed = true
		}
	}

	return changed
}

func coerceOverlayValue(value interface{}, base interface{}) (interface{}, bool) {
	switch v := value.(type) {
	case map[string]interface{}:
		var baseMap map[string]interface{}
		if bm, ok := base.(map[string]interface{}); ok {
			baseMap = bm
		}
		if normalizeOverlayTypes(v, baseMap) {
			return v, true
		}
	case []interface{}:
		var sample interface{}
		if baseSlice, ok := base.([]interface{}); ok && len(baseSlice) > 0 {
			sample = baseSlice[0]
		}
		changed := false
		for i, elem := range v {
			if newElem, subChanged := coerceOverlayValue(elem, sample); subChanged {
				v[i] = newElem
				changed = true
			}
		}
		if changed {
			return v, true
		}
	default:
		if baseStr, ok := base.(string); ok {
			if _, isString := value.(string); isString {
				return value, false
			}
			if baseStr != "" && isDurationString(baseStr) {
				if formatted, ok := formatDurationValue(v); ok {
					return formatted, true
				}
			}
			if literal, ok := stringifyValue(v); ok {
				return literal, true
			}
		}
	}

	return value, false
}

func isDurationString(value string) bool {
	if value == "" {
		return false
	}
	_, err := time.ParseDuration(value)

	return err == nil
}

func formatDurationValue(value interface{}) (string, bool) {
	switch v := value.(type) {
	case json.Number:
		if i, err := v.Int64(); err == nil {
			return time.Duration(i).String(), true
		}
		if f, err := v.Float64(); err == nil {
			return time.Duration(int64(f)).String(), true
		}
	case float64:
		return time.Duration(int64(v)).String(), true
	case float32:
		return time.Duration(int64(v)).String(), true
	case int64:
		return time.Duration(v).String(), true
	case int32:
		return time.Duration(v).String(), true
	case int:
		return time.Duration(v).String(), true
	case uint64:
		return time.Duration(v).String(), true
	case uint32:
		return time.Duration(v).String(), true
	case uint:
		return time.Duration(v).String(), true
	}

	return "", false
}

func stringifyValue(value interface{}) (string, bool) {
	switch v := value.(type) {
	case json.Number:
		return v.String(), true
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64), true
	case float32:
		return strconv.FormatFloat(float64(v), 'f', -1, 32), true
	case int64:
		return strconv.FormatInt(v, 10), true
	case int32:
		return strconv.FormatInt(int64(v), 10), true
	case int:
		return strconv.Itoa(v), true
	case uint64:
		return strconv.FormatUint(v, 10), true
	case uint32:
		return strconv.FormatUint(uint64(v), 10), true
	case uint:
		return strconv.FormatUint(uint64(v), 10), true
	case bool:
		if v {
			return "true", true
		}
		return "false", true
	}

	return "", false
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

		// Always load the on-disk defaults first so sensitive values (e.g., JWT private keys)
		// remain present even though the KV overlay stores only sanitized data.
		fileErr := c.defaultLoader.Load(ctx, path, cfg)
		if fileErr != nil {
			loader = NewKVConfigLoader(c.kvStore, c.logger)
			if err := loader.Load(ctx, path, cfg); err != nil {
				return fmt.Errorf("%w from file: %w, and from KV: %w", errLoadConfigFailed, fileErr, err)
			}
			return nil
		}

		if err := c.OverlayFromKV(ctx, path, cfg); err != nil {
			if c.logger != nil {
				c.logger.Warn().
					Err(err).
					Str("path", path).
					Msg("failed to overlay configuration from KV; continuing with file defaults")
			}
		}
		return nil
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
