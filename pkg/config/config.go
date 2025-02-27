// Package config pkg/config/config.go
package config

import (
	"encoding/json"
	"fmt"
	"os"
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

// LoadAndValidate loads a configuration file and validates it if possible.
func LoadAndValidate(path string, cfg interface{}) error {
	if err := LoadFile(path, cfg); err != nil {
		return err
	}

	return ValidateConfig(cfg)
}
