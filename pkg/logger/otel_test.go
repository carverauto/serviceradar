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
	"testing"
	"time"
)

func TestOTelConfig(t *testing.T) {
	config := DefaultOTelConfig()

	if config.ServiceName == "" {
		t.Error("ServiceName should have a default value")
	}

	if config.BatchTimeout == 0 {
		t.Error("BatchTimeout should have a default value")
	}

	if config.BatchTimeout != Duration(5*time.Second) {
		t.Errorf("Expected default BatchTimeout to be 5s, got %v", config.BatchTimeout)
	}
}

func TestOTelWriter_Disabled(t *testing.T) {
	config := OTelConfig{
		Enabled: false,
	}

	writer, err := NewOTelWriter(config)
	if err == nil {
		t.Error("Expected error when OTel is disabled")
	}

	if writer != nil {
		t.Error("Writer should be nil when OTel is disabled")
	}
}

func TestOTelWriter_NoEndpoint(t *testing.T) {
	config := OTelConfig{
		Enabled:  true,
		Endpoint: "",
	}

	writer, err := NewOTelWriter(config)
	if err == nil {
		t.Error("Expected error when endpoint is empty")
	}

	if writer != nil {
		t.Error("Writer should be nil when endpoint is empty")
	}
}

func TestLoggerWithOTelDisabled(t *testing.T) {
	config := &Config{
		Level:  "info",
		Debug:  false,
		Output: "stdout",
		OTel: OTelConfig{
			Enabled: false,
		},
	}

	err := Init(config)
	if err != nil {
		t.Fatalf("Failed to initialize logger with OTel disabled: %v", err)
	}

	Info().Str("test", "value").Msg("Test message without OTel")
}

func TestLoggerWithOTelEnabledButNoEndpoint(t *testing.T) {
	config := &Config{
		Level:  "info",
		Debug:  false,
		Output: "stdout",
		OTel: OTelConfig{
			Enabled:  true,
			Endpoint: "",
		},
	}

	err := Init(config)
	if err != nil {
		t.Fatalf("Failed to initialize logger with OTel enabled but no endpoint: %v", err)
	}

	Info().Str("test", "value").Msg("Test message with OTel enabled but no endpoint")
}

func TestMapZerologLevelToOTel(t *testing.T) {
	tests := []struct {
		zerologLevel string
		expected     string
	}{
		{"trace", "TRACE"},
		{"debug", "DEBUG"},
		{"info", "INFO"},
		{"warn", "WARN"},
		{"warning", "WARN"},
		{"error", "ERROR"},
		{"fatal", "FATAL"},
		{"panic", "FATAL"},
		{"unknown", "INFO"},
	}

	for _, test := range tests {
		result := mapZerologLevelToOTel(test.zerologLevel)
		if result.String() != test.expected {
			t.Errorf("mapZerologLevelToOTel(%s) = %s, expected %s",
				test.zerologLevel, result.String(), test.expected)
		}
	}
}
