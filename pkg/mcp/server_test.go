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

package mcp

import (
    "context"
    "testing"

    "github.com/stretchr/testify/assert"

    "github.com/carverauto/serviceradar/pkg/core/auth"
    "github.com/carverauto/serviceradar/pkg/logger"
)

// mockQueryExecutor implements local QueryExecutor for testing
type mockQueryExecutor struct{}

func (*mockQueryExecutor) ExecuteSRQLQuery(_ context.Context, _ string, _ int) ([]map[string]interface{}, error) {
	return []map[string]interface{}{}, nil
}

// Ensure mockQueryExecutor implements the interface
var _ QueryExecutor = &mockQueryExecutor{}

func TestNewMCPServer(t *testing.T) {
	// Test that NewMCPServer doesn't panic with valid inputs
	config := &MCPConfig{
		Enabled: true,
		APIKey:  "test-key",
	}

	ctx := context.Background()

	mockExecutor := &mockQueryExecutor{}
	mockLogger := logger.NewTestLogger()

	var mockAuth auth.AuthService

	server := NewMCPServer(ctx, mockExecutor, mockLogger, config, mockAuth)
	assert.NotNil(t, server)
	assert.Equal(t, config, server.config)
}

func TestGetDefaultConfig(t *testing.T) {
	config := GetDefaultConfig()

	assert.NotNil(t, config)
	assert.True(t, config.Enabled)
	assert.Empty(t, config.APIKey)
}

func TestMCPServerStop(t *testing.T) {
	config := &MCPConfig{
		Enabled: true,
		APIKey:  "test-key",
	}

	ctx := context.Background()

	mockExecutor := &mockQueryExecutor{}
	mockLogger := logger.NewTestLogger()

	var mockAuth auth.AuthService

	server := NewMCPServer(ctx, mockExecutor, mockLogger, config, mockAuth)

	// Should return nil (no error) when stopping
	err := server.Stop()
	assert.NoError(t, err)
}

func TestBuildSRQL(t *testing.T) {
	tests := []struct {
		name     string
		entity   string
		filter   string
		orderBy  string
		limit    int
		sortDesc bool
		expected string
	}{
		{
			name:     "basic query",
			entity:   "devices",
			filter:   "",
			orderBy:  "",
			limit:    0,
			sortDesc: false,
			expected: "SHOW devices",
		},
		{
			name:     "query with filter",
			entity:   "devices",
			filter:   "poller_id = 'test'",
			orderBy:  "",
			limit:    0,
			sortDesc: false,
			expected: "SHOW devices WHERE poller_id = 'test'",
		},
		{
			name:     "query with order and limit",
			entity:   "devices",
			filter:   "",
			orderBy:  "timestamp",
			limit:    10,
			sortDesc: true,
			expected: "SHOW devices ORDER BY timestamp DESC LIMIT 10",
		},
		{
			name:     "complete query",
			entity:   "logs",
			filter:   "level = 'error'",
			orderBy:  "timestamp",
			limit:    50,
			sortDesc: true,
			expected: "SHOW logs WHERE level = 'error' ORDER BY timestamp DESC LIMIT 50",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := BuildSRQL(tt.entity, tt.filter, tt.orderBy, tt.limit, tt.sortDesc)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestCombineFilters(t *testing.T) {
	tests := []struct {
		name     string
		filters  []string
		expected string
	}{
		{
			name:     "no filters",
			filters:  []string{},
			expected: "",
		},
		{
			name:     "single filter",
			filters:  []string{"level = 'error'"},
			expected: "(level = 'error')",
		},
		{
			name:     "multiple filters",
			filters:  []string{"level = 'error'", "timestamp > '2025-01-01'"},
			expected: "(level = 'error') AND (timestamp > '2025-01-01')",
		},
		{
			name:     "filters with empty strings",
			filters:  []string{"level = 'error'", "", "timestamp > '2025-01-01'"},
			expected: "(level = 'error') AND (timestamp > '2025-01-01')",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := CombineFilters(tt.filters...)
			assert.Equal(t, tt.expected, result)
		})
	}
}
