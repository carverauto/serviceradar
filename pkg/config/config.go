/*-
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
