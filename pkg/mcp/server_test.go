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
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNewMCPServer(t *testing.T) {
	// Test that NewMCPServer doesn't panic with nil inputs
	// Full integration testing should be done at higher levels
	defer func() {
		if r := recover(); r != nil {
			t.Errorf("NewMCPServer panicked: %v", r)
		}
	}()
	
	config := &MCPConfig{
		Enabled: true,
		Host:    "localhost",
		Port:    "8081",
	}

	// This will panic if there are major issues, but that's OK for this test
	server := NewMCPServer(nil, nil, config, nil)
	assert.NotNil(t, server)
	assert.Equal(t, config, server.config)
}

func TestGetDefaultConfig(t *testing.T) {
	config := GetDefaultConfig()

	assert.NotNil(t, config)
	assert.False(t, config.Enabled)
	assert.Equal(t, "8081", config.Port)
	assert.Equal(t, "localhost", config.Host)
}

func TestMCPServerStart_Disabled(t *testing.T) {
	config := &MCPConfig{
		Enabled: false,
		Host:    "localhost",
		Port:    "8081",
	}

	server := NewMCPServer(nil, nil, config, nil)
	
	// Should return nil (no error) when disabled
	err := server.Start()
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
			expected: "SELECT * FROM devices",
		},
		{
			name:     "query with filter",
			entity:   "devices",
			filter:   "poller_id = 'test'",
			orderBy:  "",
			limit:    0,
			sortDesc: false,
			expected: "SELECT * FROM devices WHERE poller_id = 'test'",
		},
		{
			name:     "query with order and limit",
			entity:   "devices",
			filter:   "",
			orderBy:  "timestamp",
			limit:    10,
			sortDesc: true,
			expected: "SELECT * FROM devices ORDER BY timestamp DESC LIMIT 10",
		},
		{
			name:     "complete query",
			entity:   "logs",
			filter:   "level = 'error'",
			orderBy:  "timestamp",
			limit:    50,
			sortDesc: true,
			expected: "SELECT * FROM logs WHERE level = 'error' ORDER BY timestamp DESC LIMIT 50",
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