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
	"fmt"
	"os"
	"reflect"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
)

// EnvConfigLoader loads configuration from environment variables.
// It supports nested struct fields using underscore separation.
// For example: DATABASE_HOST maps to config.Database.Host
type EnvConfigLoader struct {
	logger logger.Logger
	prefix string // Optional prefix for all env vars (e.g., "SERVICERADAR_")
}

// NewEnvConfigLoader creates a new environment variable config loader.
func NewEnvConfigLoader(logger logger.Logger, prefix string) *EnvConfigLoader {
	return &EnvConfigLoader{
		logger: logger,
		prefix: prefix,
	}
}

// Load implements ConfigLoader by reading from environment variables.
func (e *EnvConfigLoader) Load(_ context.Context, _ string, dst interface{}) error {
	if e.logger != nil {
		e.logger.Debug().Msg("Loading configuration from environment variables")
	}

	// First check if there's a complete JSON config in an env var
	if jsonConfig := os.Getenv(e.prefix + "CONFIG_JSON"); jsonConfig != "" {
		if err := json.Unmarshal([]byte(jsonConfig), dst); err != nil {
			if e.logger != nil {
				e.logger.Error().Err(err).Msg("Failed to unmarshal CONFIG_JSON")
			}
			return fmt.Errorf("failed to unmarshal CONFIG_JSON: %w", err)
		}
		if e.logger != nil {
			e.logger.Info().Msg("Loaded configuration from CONFIG_JSON environment variable")
		}
		return nil
	}

	// Otherwise, load from individual environment variables
	v := reflect.ValueOf(dst)
	if v.Kind() != reflect.Ptr || v.IsNil() {
		return fmt.Errorf("dst must be a non-nil pointer")
	}

	v = v.Elem()
	if v.Kind() != reflect.Struct {
		return fmt.Errorf("dst must be a pointer to a struct")
	}

	if err := e.loadStruct(v, e.prefix); err != nil {
		return err
	}

	if e.logger != nil {
		e.logger.Info().Msg("Successfully loaded configuration from environment variables")
	}

	return nil
}

// loadStruct recursively loads a struct from environment variables.
func (e *EnvConfigLoader) loadStruct(v reflect.Value, prefix string) error {
	t := v.Type()

	for i := 0; i < t.NumField(); i++ {
		field := v.Field(i)
		fieldType := t.Field(i)

		// Skip unexported fields
		if !field.CanSet() {
			continue
		}

		// Get the JSON tag or use the field name
		jsonTag := fieldType.Tag.Get("json")
		if jsonTag == "" || jsonTag == "-" {
			continue
		}

		// Handle omitempty and other tag options
		tagParts := strings.Split(jsonTag, ",")
		fieldName := tagParts[0]

		// Build the environment variable name
		envName := e.buildEnvName(prefix, fieldName)

		// Handle different field types
		if err := e.setFieldValue(field, fieldType, envName); err != nil {
			if e.logger != nil {
				e.logger.Debug().
					Str("field", fieldName).
					Str("env", envName).
					Err(err).
					Msg("Failed to set field from environment variable")
			}
			// Continue with other fields even if one fails
			continue
		}
	}

	return nil
}

// buildEnvName constructs the environment variable name from prefix and field name.
func (e *EnvConfigLoader) buildEnvName(prefix, fieldName string) string {
	// Convert field name to uppercase and replace dots with underscores
	envName := strings.ToUpper(fieldName)
	envName = strings.ReplaceAll(envName, ".", "_")
	
	if prefix != "" {
		envName = prefix + envName
	}
	
	return envName
}

// setFieldValue sets a struct field value from an environment variable.
func (e *EnvConfigLoader) setFieldValue(field reflect.Value, fieldType reflect.StructField, envName string) error {
	envValue := os.Getenv(envName)
	
	// For nested structs, try with prefix
	if field.Kind() == reflect.Struct || (field.Kind() == reflect.Ptr && field.Type().Elem().Kind() == reflect.Struct) {
		prefix := envName + "_"
		
		// Initialize pointer if needed
		if field.Kind() == reflect.Ptr {
			if field.IsNil() {
				field.Set(reflect.New(field.Type().Elem()))
			}
			return e.loadStruct(field.Elem(), prefix)
		}
		return e.loadStruct(field, prefix)
	}

	// Skip if no environment variable is set
	if envValue == "" {
		return nil
	}

	// Handle different types
	switch field.Kind() {
	case reflect.String:
		field.SetString(envValue)
		
	case reflect.Bool:
		b, err := strconv.ParseBool(envValue)
		if err != nil {
			return fmt.Errorf("invalid boolean value for %s: %w", envName, err)
		}
		field.SetBool(b)
		
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		// Special handling for time.Duration
		if field.Type().String() == "time.Duration" {
			d, err := time.ParseDuration(envValue)
			if err != nil {
				return fmt.Errorf("invalid duration value for %s: %w", envName, err)
			}
			field.SetInt(int64(d))
		} else {
			i, err := strconv.ParseInt(envValue, 10, 64)
			if err != nil {
				return fmt.Errorf("invalid integer value for %s: %w", envName, err)
			}
			field.SetInt(i)
		}
		
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		u, err := strconv.ParseUint(envValue, 10, 64)
		if err != nil {
			return fmt.Errorf("invalid unsigned integer value for %s: %w", envName, err)
		}
		field.SetUint(u)
		
	case reflect.Float32, reflect.Float64:
		f, err := strconv.ParseFloat(envValue, 64)
		if err != nil {
			return fmt.Errorf("invalid float value for %s: %w", envName, err)
		}
		field.SetFloat(f)
		
	case reflect.Slice:
		// Handle string slices (comma-separated values)
		if field.Type().Elem().Kind() == reflect.String {
			values := strings.Split(envValue, ",")
			slice := reflect.MakeSlice(field.Type(), len(values), len(values))
			for i, v := range values {
				slice.Index(i).SetString(strings.TrimSpace(v))
			}
			field.Set(slice)
		} else {
			// Try to unmarshal as JSON for other slice types
			if err := json.Unmarshal([]byte(envValue), field.Addr().Interface()); err != nil {
				return fmt.Errorf("invalid slice value for %s: %w", envName, err)
			}
		}
		
	case reflect.Map:
		// Try to unmarshal as JSON for map types
		if err := json.Unmarshal([]byte(envValue), field.Addr().Interface()); err != nil {
			return fmt.Errorf("invalid map value for %s: %w", envName, err)
		}
		
	case reflect.Ptr:
		// Initialize the pointer and set its value
		if field.IsNil() {
			field.Set(reflect.New(field.Type().Elem()))
		}
		return e.setFieldValue(field.Elem(), fieldType, envName)
		
	default:
		// Try to unmarshal as JSON for complex types
		if err := json.Unmarshal([]byte(envValue), field.Addr().Interface()); err != nil {
			return fmt.Errorf("unsupported type %s for %s: %w", field.Kind(), envName, err)
		}
	}

	if e.logger != nil {
		e.logger.Debug().
			Str("env", envName).
			Str("value", "[set]").
			Msg("Loaded value from environment variable")
	}

	return nil
}