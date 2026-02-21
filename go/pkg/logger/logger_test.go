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

package logger

import (
	"context"
	"testing"

	"github.com/rs/zerolog"
)

func TestInit(t *testing.T) {
	config := &Config{
		Level:  "debug",
		Debug:  true,
		Output: "stdout",
	}

	err := Init(context.Background(), config)
	if err != nil {
		t.Fatalf("Failed to initialize logger: %v", err)
	}

	logger := GetLogger()
	if logger.GetLevel() != zerolog.DebugLevel {
		t.Errorf("Expected debug level, got %v", logger.GetLevel())
	}
}

func TestSetDebug(t *testing.T) {
	SetDebug(true)

	logger := GetLogger()
	if logger.GetLevel() != zerolog.DebugLevel {
		t.Errorf("Expected debug level after SetDebug(true), got %v", logger.GetLevel())
	}

	SetDebug(false)

	logger = GetLogger()
	if logger.GetLevel() != zerolog.InfoLevel {
		t.Errorf("Expected info level after SetDebug(false), got %v", logger.GetLevel())
	}
}

func TestWithComponent(t *testing.T) {
	componentLogger := WithComponent("test-component")

	if componentLogger.GetLevel() == zerolog.Disabled {
		t.Error("Component logger should not be disabled")
	}
}

func TestFieldLogger(t *testing.T) {
	logger := GetLogger()
	fieldLogger := NewFieldLogger(&logger)

	if fieldLogger == nil {
		t.Fatal("FieldLogger should not be nil")
	}

	enrichedLogger := fieldLogger.WithField("test", "value")
	if enrichedLogger == nil {
		t.Error("WithField should return a valid logger")
	}

	fields := map[string]interface{}{
		"key1": "value1",
		"key2": 42,
	}

	enrichedLogger2 := fieldLogger.WithFields(fields)
	if enrichedLogger2 == nil {
		t.Error("WithFields should return a valid logger")
	}
}

func TestDefaultConfig(t *testing.T) {
	config := DefaultConfig()

	if config.Level == "" {
		t.Error("Default config should have a level set")
	}

	if config.Output == "" {
		t.Error("Default config should have an output set")
	}
}
