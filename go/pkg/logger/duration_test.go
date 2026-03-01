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
	"encoding/json"
	"testing"
	"time"
)

func TestDuration_UnmarshalJSON(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected Duration
		wantErr  bool
	}{
		{
			name:     "string duration",
			input:    `"5s"`,
			expected: Duration(5 * time.Second),
			wantErr:  false,
		},
		{
			name:     "numeric duration (nanoseconds)",
			input:    `5000000000`,
			expected: Duration(5 * time.Second),
			wantErr:  false,
		},
		{
			name:     "complex duration string",
			input:    `"1h30m45s"`,
			expected: Duration(1*time.Hour + 30*time.Minute + 45*time.Second),
			wantErr:  false,
		},
		{
			name:    "invalid duration string",
			input:   `"invalid"`,
			wantErr: true,
		},
		{
			name:    "invalid type",
			input:   `true`,
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var d Duration

			err := json.Unmarshal([]byte(tt.input), &d)

			if tt.wantErr {
				if err == nil {
					t.Errorf("Expected error but got none")
				}

				return
			}

			if err != nil {
				t.Errorf("Unexpected error: %v", err)
				return
			}

			if d != tt.expected {
				t.Errorf("Expected %v, got %v", tt.expected, d)
			}
		})
	}
}

func TestOTelConfig_JSONUnmarshaling(t *testing.T) {
	configJSON := `{
		"enabled": true,
		"endpoint": "localhost:4317",
		"service_name": "test-service",
		"batch_timeout": "10s",
		"insecure": true,
		"headers": {
			"x-api-key": "test-key"
		}
	}`

	var config OTelConfig

	err := json.Unmarshal([]byte(configJSON), &config)
	if err != nil {
		t.Fatalf("Failed to unmarshal config: %v", err)
	}

	if !config.Enabled {
		t.Error("Expected Enabled to be true")
	}

	if config.Endpoint != "localhost:4317" {
		t.Errorf("Expected endpoint localhost:4317, got %s", config.Endpoint)
	}

	if config.ServiceName != "test-service" {
		t.Errorf("Expected service_name test-service, got %s", config.ServiceName)
	}

	expectedTimeout := Duration(10 * time.Second)
	if config.BatchTimeout != expectedTimeout {
		t.Errorf("Expected batch_timeout %v, got %v", expectedTimeout, config.BatchTimeout)
	}

	if !config.Insecure {
		t.Error("Expected Insecure to be true")
	}

	if config.Headers["x-api-key"] != "test-key" {
		t.Errorf("Expected x-api-key header test-key, got %s", config.Headers["x-api-key"])
	}
}
