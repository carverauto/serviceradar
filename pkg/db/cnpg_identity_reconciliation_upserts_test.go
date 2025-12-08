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

package db

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBuildDeviceIdentifierArgs(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		input       *models.DeviceIdentifier
		wantErr     bool
		errContains string
		validate    func(t *testing.T, args []interface{})
	}{
		{
			name:        "nil identifier returns error",
			input:       nil,
			wantErr:     true,
			errContains: "nil",
		},
		{
			name: "empty device_id returns error",
			input: &models.DeviceIdentifier{
				DeviceID: "",
				IDType:   "armis_device_id",
				IDValue:  "12345",
			},
			wantErr:     true,
			errContains: "device_id",
		},
		{
			name: "empty id_type returns error",
			input: &models.DeviceIdentifier{
				DeviceID: "sr:abc-123",
				IDType:   "",
				IDValue:  "12345",
			},
			wantErr:     true,
			errContains: "id_type",
		},
		{
			name: "empty id_value returns error",
			input: &models.DeviceIdentifier{
				DeviceID: "sr:abc-123",
				IDType:   "armis_device_id",
				IDValue:  "",
			},
			wantErr:     true,
			errContains: "id_value",
		},
		{
			name: "valid identifier with empty metadata uses empty JSON object",
			input: &models.DeviceIdentifier{
				DeviceID:   "sr:abc-123",
				IDType:     "armis_device_id",
				IDValue:    "12345",
				Confidence: "strong",
				Metadata:   nil, // Empty metadata - this was causing NULL inserts
			},
			wantErr: false,
			validate: func(t *testing.T, args []interface{}) {
				t.Helper()
				require.Len(t, args, 10, "expected 10 arguments")

				// Check partition defaults to "default"
				assert.Equal(t, "default", args[3], "partition should default to 'default'")

				// Check metadata is not nil and is valid empty JSON object
				metadata := args[9]
				require.NotNil(t, metadata, "metadata should not be nil (was causing NOT NULL constraint violations)")

				rawJSON, ok := metadata.(json.RawMessage)
				require.True(t, ok, "metadata should be json.RawMessage")
				assert.Equal(t, "{}", string(rawJSON), "empty metadata should be empty JSON object")
			},
		},
		{
			name: "valid identifier with populated metadata marshals correctly",
			input: &models.DeviceIdentifier{
				DeviceID:   "sr:abc-123",
				IDType:     "mac",
				IDValue:    "AABBCCDDEEFF",
				Partition:  "test-partition",
				Confidence: "strong",
				Source:     "sweep",
				Metadata:   map[string]string{"vendor": "Cisco", "model": "Switch"},
			},
			wantErr: false,
			validate: func(t *testing.T, args []interface{}) {
				t.Helper()
				require.Len(t, args, 10, "expected 10 arguments")

				// Check device_id
				assert.Equal(t, "sr:abc-123", args[0])

				// Check id_type
				assert.Equal(t, "mac", args[1])

				// Check id_value
				assert.Equal(t, "AABBCCDDEEFF", args[2])

				// Check partition
				assert.Equal(t, "test-partition", args[3])

				// Check confidence
				assert.Equal(t, "strong", args[4])

				// Check source
				assert.Equal(t, "sweep", args[5])

				// Check metadata is not nil and contains expected data
				metadata := args[9]
				require.NotNil(t, metadata, "metadata should not be nil")

				rawJSON, ok := metadata.(json.RawMessage)
				require.True(t, ok, "metadata should be json.RawMessage")

				var parsed map[string]string
				err := json.Unmarshal(rawJSON, &parsed)
				require.NoError(t, err, "metadata should be valid JSON")
				assert.Equal(t, "Cisco", parsed["vendor"])
				assert.Equal(t, "Switch", parsed["model"])
			},
		},
		{
			name: "whitespace-only fields are trimmed and rejected",
			input: &models.DeviceIdentifier{
				DeviceID: "  sr:abc-123  ",
				IDType:   "  ",
				IDValue:  "12345",
			},
			wantErr:     true,
			errContains: "id_type",
		},
		{
			name: "empty confidence defaults to weak",
			input: &models.DeviceIdentifier{
				DeviceID:   "sr:abc-123",
				IDType:     "armis_device_id",
				IDValue:    "12345",
				Confidence: "", // Empty confidence
			},
			wantErr: false,
			validate: func(t *testing.T, args []interface{}) {
				t.Helper()
				require.Len(t, args, 10)
				assert.Equal(t, "default", args[3], "empty partition should default to 'default'")
				assert.Equal(t, "weak", args[4], "empty confidence should default to 'weak'")
			},
		},
		{
			name: "zero timestamps are sanitized",
			input: &models.DeviceIdentifier{
				DeviceID:   "sr:abc-123",
				IDType:     "armis_device_id",
				IDValue:    "12345",
				Confidence: "strong",
				FirstSeen:  time.Time{}, // Zero time
				LastSeen:   time.Time{}, // Zero time
			},
			wantErr: false,
			validate: func(t *testing.T, args []interface{}) {
				t.Helper()
				require.Len(t, args, 10)

				firstSeen, ok := args[6].(time.Time)
				require.True(t, ok, "first_seen should be time.Time")
				assert.False(t, firstSeen.IsZero(), "zero first_seen should be sanitized to current time")

				lastSeen, ok := args[7].(time.Time)
				require.True(t, ok, "last_seen should be time.Time")
				assert.False(t, lastSeen.IsZero(), "zero last_seen should be sanitized to current time")
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			args, err := buildDeviceIdentifierArgs(tt.input)

			if tt.wantErr {
				require.Error(t, err, "expected error")
				if tt.errContains != "" {
					assert.Contains(t, err.Error(), tt.errContains, "error message should contain expected string")
				}
				return
			}

			require.NoError(t, err, "unexpected error")

			if tt.validate != nil {
				tt.validate(t, args)
			}
		})
	}
}

// TestBuildDeviceIdentifierArgs_NullMetadataRegression ensures we don't regress on the
// NULL metadata bug that caused "null value in column 'metadata'" database errors.
func TestBuildDeviceIdentifierArgs_NullMetadataRegression(t *testing.T) {
	t.Parallel()

	// This test specifically validates the fix for the bug where empty Metadata
	// resulted in NULL being passed to the database, violating the NOT NULL constraint.
	// The database has: metadata JSONB NOT NULL DEFAULT '{}'::jsonb
	// But when we explicitly pass NULL, the default doesn't apply.

	testCases := []struct {
		name     string
		metadata map[string]string
	}{
		{
			name:     "nil metadata",
			metadata: nil,
		},
		{
			name:     "empty map metadata",
			metadata: map[string]string{},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			id := &models.DeviceIdentifier{
				DeviceID:   "sr:test-device",
				IDType:     "armis_device_id",
				IDValue:    "test-value",
				Confidence: "strong",
				Metadata:   tc.metadata,
			}

			args, err := buildDeviceIdentifierArgs(id)
			require.NoError(t, err)
			require.Len(t, args, 10)

			// The critical assertion: metadata must NOT be nil
			metadata := args[9]
			require.NotNil(t, metadata, "metadata must not be nil to avoid NOT NULL constraint violation")

			// Should be valid JSON
			rawJSON, ok := metadata.(json.RawMessage)
			require.True(t, ok, "metadata should be json.RawMessage, got %T", metadata)

			// Should be parseable as valid JSON
			var parsed interface{}
			err = json.Unmarshal(rawJSON, &parsed)
			require.NoError(t, err, "metadata should be valid JSON")
		})
	}
}
