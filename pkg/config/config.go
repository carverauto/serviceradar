package config

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/models"
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

// LoadFile is a generic helper that loads a JSON file from path into the struct pointed to by dst.
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

// LoadAndValidate loads a configuration, normalizes SecurityConfig paths if present, and validates it.
func (c *Config) LoadAndValidate(ctx context.Context, path string, cfg interface{}) error {
	err := c.loadAndValidateWithSource(ctx, path, cfg)
	if err != nil {
		return err
	}

	// Normalize SecurityConfig paths if present
	if err := normalizeSecurityConfig(cfg); err != nil {
		return fmt.Errorf("failed to normalize SecurityConfig: %w", err)
	}

	return ValidateConfig(cfg)
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
		return fmt.Errorf("config must be a non-nil pointer")
	}

	v = v.Elem()
	if v.Kind() != reflect.Struct {
		return nil // Nothing to normalize if not a struct
	}

	t := v.Type()
	for i := 0; i < t.NumField(); i++ {
		field := v.Field(i)
		fieldType := t.Field(i)

		// Check if the field is a *SecurityConfig
		if fieldType.Type == reflect.TypeOf((*models.SecurityConfig)(nil)) {
			if !field.IsValid() || field.IsNil() {
				continue // Skip if nil
			}

			sec := field.Interface().(*models.SecurityConfig)

			if sec.CertDir == "" {
				continue // No normalization needed without CertDir
			}

			tls := &sec.TLS

			if !filepath.IsAbs(tls.CertFile) {
				tls.CertFile = filepath.Join(sec.CertDir, tls.CertFile)
			}

			if !filepath.IsAbs(tls.KeyFile) {
				tls.KeyFile = filepath.Join(sec.CertDir, tls.KeyFile)
			}

			if !filepath.IsAbs(tls.CAFile) {
				tls.CAFile = filepath.Join(sec.CertDir, tls.CAFile)
			}

			if tls.ClientCAFile != "" && !filepath.IsAbs(tls.ClientCAFile) {
				tls.ClientCAFile = filepath.Join(sec.CertDir, tls.ClientCAFile)
			} else if tls.ClientCAFile == "" {
				tls.ClientCAFile = tls.CAFile // Fallback to CAFile if unset
			}

			// Update the field with the normalized SecurityConfig
			field.Set(reflect.ValueOf(sec))
		}
	}

	return nil
}
