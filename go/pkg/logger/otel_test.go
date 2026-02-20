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
	"fmt"
	"strings"
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

	writer, err := NewOTELWriter(context.Background(), config)
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

	writer, err := NewOTELWriter(context.Background(), config)
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

	err := Init(context.Background(), config)
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

	err := Init(context.Background(), config)
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
		result := mapZerologLevelToOTEL(test.zerologLevel)
		if result.String() != test.expected {
			t.Errorf("mapZerologLevelToOTEL(%s) = %s, expected %s",
				test.zerologLevel, result.String(), test.expected)
		}
	}
}

func TestSanitizeLogEntryTruncatesLargeStrings(t *testing.T) {
	largeValue := strings.Repeat("x", maxAttributeValueLength+128)

	sanitized, truncated := sanitizeLogEntry(map[string]interface{}{
		"payload": largeValue,
	})

	got, ok := sanitized["payload"]
	if !ok {
		t.Fatalf("expected sanitized payload attribute")
	}

	if len(got) > maxAttributeValueLength+3 {
		t.Fatalf("expected truncated payload length <= %d, got %d", maxAttributeValueLength+3, len(got))
	}

	if !strings.HasSuffix(got, "...") {
		t.Fatalf("expected truncated payload to end with ellipsis, got %q", got[len(got)-4:])
	}

	if len(truncated) != 1 || truncated[0] != "payload" {
		t.Fatalf("expected payload to be marked as truncated, got %v", truncated)
	}
}

func TestSanitizeLogEntrySummariesLargeSlices(t *testing.T) {
	var devices []interface{}
	for i := 0; i < 100; i++ {
		devices = append(devices, fmt.Sprintf("device-%03d", i))
	}

	sanitized, truncated := sanitizeLogEntry(map[string]interface{}{
		"devices": devices,
	})

	got := sanitized["devices"]
	if !strings.Contains(got, "total=100") {
		t.Fatalf("expected summary to include total count, got %q", got)
	}

	if !strings.Contains(got, "truncated") {
		t.Fatalf("expected summary to note truncation, got %q", got)
	}

	if len(truncated) != 1 || truncated[0] != "devices" {
		t.Fatalf("expected devices to be marked truncated, got %v", truncated)
	}
}

func TestSanitizeLogEntryKeepsSmallSlicesVerbatim(t *testing.T) {
	sanitized, truncated := sanitizeLogEntry(map[string]interface{}{
		"sample": []interface{}{"alpha", "beta"},
	})

	expected := `["alpha","beta"]`
	if sanitized["sample"] != expected {
		t.Fatalf("expected verbatim slice JSON %q, got %q", expected, sanitized["sample"])
	}

	if len(truncated) != 0 {
		t.Fatalf("expected no truncation markers, got %v", truncated)
	}
}
