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
	"os"
	"reflect"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
)

var (
	// ErrDstMustBeNonNilPointer indicates that the destination must be a non-nil pointer.
	ErrDstMustBeNonNilPointer = errors.New("dst must be a non-nil pointer")
	// ErrDstMustBePointerToStruct indicates that the destination must be a pointer to a struct.
	ErrDstMustBePointerToStruct = errors.New("dst must be a pointer to a struct")
)

// EnvConfigLoader loads configuration from environment variables.
// It supports nested struct fields using underscore separation.
// For example: DATABASE_HOST maps to config.Database.Host
type EnvConfigLoader struct {
	logger logger.Logger
	prefix string // Optional prefix for all env vars (e.g., "SERVICERADAR_")
}

// NewEnvConfigLoader creates a new environment variable config loader.
func NewEnvConfigLoader(log logger.Logger, prefix string) *EnvConfigLoader {
	return &EnvConfigLoader{
		logger: log,
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
		return ErrDstMustBeNonNilPointer
	}

	v = v.Elem()
	if v.Kind() != reflect.Struct {
		return ErrDstMustBePointerToStruct
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
		if err := e.setFieldValue(field, &fieldType, envName); err != nil {
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
func (*EnvConfigLoader) buildEnvName(prefix, fieldName string) string {
	// Convert field name to uppercase and replace dots with underscores
	envName := strings.ToUpper(fieldName)
	envName = strings.ReplaceAll(envName, ".", "_")

	if prefix != "" {
		envName = prefix + envName
	}

	return envName
}

// setFieldValue sets a struct field value from an environment variable.
func (e *EnvConfigLoader) setFieldValue(field reflect.Value, fieldType *reflect.StructField, envName string) error {
	envValue := os.Getenv(envName)

	// Handle nested structs
	if err := e.handleNestedStruct(field, envName); err != nil {
		return err
	}

	// Skip if no environment variable is set
	if envValue == "" {
		return nil
	}

	// Handle different types
	if err := e.setFieldByKind(field, fieldType, envName, envValue); err != nil {
		return err
	}

	if e.logger != nil {
		e.logger.Debug().
			Str("env", envName).
			Str("value", "[set]").
			Msg("Loaded value from environment variable")
	}

	return nil
}

// handleNestedStruct handles nested struct and pointer to struct types.
func (e *EnvConfigLoader) handleNestedStruct(field reflect.Value, envName string) error {
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

	return nil
}

// setFieldByKind sets field value based on its reflect.Kind.
func (e *EnvConfigLoader) setFieldByKind(field reflect.Value, fieldType *reflect.StructField, envName, envValue string) error {
	switch field.Kind() {
	case reflect.String:
		field.SetString(envValue)

	case reflect.Bool:
		return e.setBoolField(field, envName, envValue)

	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return e.setIntField(field, envName, envValue)

	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return e.setUintField(field, envName, envValue)

	case reflect.Float32, reflect.Float64:
		return e.setFloatField(field, envName, envValue)

	case reflect.Slice:
		return e.setSliceField(field, envName, envValue)

	case reflect.Map:
		return e.setMapField(field, envName, envValue)

	case reflect.Ptr:
		return e.setPtrField(field, fieldType, envName)

	case reflect.Invalid, reflect.Uintptr, reflect.Complex64, reflect.Complex128,
		reflect.Array, reflect.Chan, reflect.Func, reflect.Interface, reflect.Struct, reflect.UnsafePointer:
		// Handle unsupported types
		return e.setComplexField(field, envName, envValue)

	default:
		return e.setComplexField(field, envName, envValue)
	}

	return nil
}

// setBoolField sets a boolean field value.
func (*EnvConfigLoader) setBoolField(field reflect.Value, envName, envValue string) error {
	b, err := strconv.ParseBool(envValue)
	if err != nil {
		return fmt.Errorf("invalid boolean value for %s: %w", envName, err)
	}

	field.SetBool(b)

	return nil
}

// setIntField sets an integer field value, with special handling for time.Duration.
func (*EnvConfigLoader) setIntField(field reflect.Value, envName, envValue string) error {
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

	return nil
}

// setUintField sets an unsigned integer field value.
func (*EnvConfigLoader) setUintField(field reflect.Value, envName, envValue string) error {
	u, err := strconv.ParseUint(envValue, 10, 64)
	if err != nil {
		return fmt.Errorf("invalid unsigned integer value for %s: %w", envName, err)
	}

	field.SetUint(u)

	return nil
}

// setFloatField sets a floating-point field value.
func (*EnvConfigLoader) setFloatField(field reflect.Value, envName, envValue string) error {
	f, err := strconv.ParseFloat(envValue, 64)
	if err != nil {
		return fmt.Errorf("invalid float value for %s: %w", envName, err)
	}

	field.SetFloat(f)

	return nil
}

// setSliceField sets a slice field value.
func (*EnvConfigLoader) setSliceField(field reflect.Value, envName, envValue string) error {
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

	return nil
}

// setMapField sets a map field value.
func (*EnvConfigLoader) setMapField(field reflect.Value, envName, envValue string) error {
	// Try to unmarshal as JSON for map types
	if err := json.Unmarshal([]byte(envValue), field.Addr().Interface()); err != nil {
		return fmt.Errorf("invalid map value for %s: %w", envName, err)
	}

	return nil
}

// setPtrField sets a pointer field value.
func (e *EnvConfigLoader) setPtrField(field reflect.Value, fieldType *reflect.StructField, envName string) error {
	// Initialize the pointer and set its value
	if field.IsNil() {
		field.Set(reflect.New(field.Type().Elem()))
	}

	return e.setFieldValue(field.Elem(), fieldType, envName)
}

// setComplexField sets complex field types using JSON unmarshaling.
func (*EnvConfigLoader) setComplexField(field reflect.Value, envName, envValue string) error {
	// Try to unmarshal as JSON for complex types
	if err := json.Unmarshal([]byte(envValue), field.Addr().Interface()); err != nil {
		return fmt.Errorf("unsupported type %s for %s: %w", field.Kind(), envName, err)
	}

	return nil
}
