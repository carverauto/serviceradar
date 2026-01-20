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

package agent

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// testDuskConfigDisabled returns a disabled dusk config for testing.
func testDuskConfigDisabled() *DuskConfig {
	return &DuskConfig{
		Enabled:     false,
		NodeAddress: "",
		Timeout:     models.Duration(5 * time.Minute),
	}
}

func TestNewDuskService(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		config    DuskServiceConfig
		wantErr   bool
		checkFunc func(*testing.T, *DuskService)
	}{
		{
			name: "default config",
			config: DuskServiceConfig{
				AgentID: "test-agent",
			},
			wantErr: false,
			checkFunc: func(t *testing.T, s *DuskService) {
				t.Helper()
				assert.Equal(t, "test-agent", s.agentID)
				assert.NotNil(t, s.logger)
			},
		},
		{
			name: "with partition",
			config: DuskServiceConfig{
				AgentID:   "test-agent",
				Partition: "us-west-2",
				Logger:    logger.NewTestLogger(),
			},
			wantErr: false,
			checkFunc: func(t *testing.T, s *DuskService) {
				t.Helper()
				assert.Equal(t, "test-agent", s.agentID)
				assert.Equal(t, "us-west-2", s.partition)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			svc, err := NewDuskService(tt.config)
			if tt.wantErr {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			require.NotNil(t, svc)
			if tt.checkFunc != nil {
				tt.checkFunc(t, svc)
			}
		})
	}
}

func TestDuskServiceName(t *testing.T) {
	t.Parallel()
	svc, err := NewDuskService(DuskServiceConfig{AgentID: "test"})
	require.NoError(t, err)
	assert.Equal(t, DuskServiceName, svc.Name())
}

func TestDuskServiceStartDisabled(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testDuskConfigDisabled(),
	})
	require.NoError(t, err)

	// Start with disabled config should succeed but not connect
	err = svc.Start(ctx)
	require.NoError(t, err)

	// Service should not be enabled (no checker running)
	assert.False(t, svc.IsEnabled())

	// Stop should succeed
	err = svc.Stop(ctx)
	require.NoError(t, err)
}

func TestDuskServiceStartNoNodeAddress(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Config is enabled but has no node address
	cfg := &DuskConfig{
		Enabled:     true,
		NodeAddress: "",
		Timeout:     models.Duration(5 * time.Minute),
	}

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: cfg,
	})
	require.NoError(t, err)

	// Start should succeed but not enable (missing node_address)
	err = svc.Start(ctx)
	require.NoError(t, err)

	// Service should not be enabled
	assert.False(t, svc.IsEnabled())

	// Stop should succeed
	err = svc.Stop(ctx)
	require.NoError(t, err)
}

func TestDuskServiceGetStatus_NotStarted(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID: "test-agent",
		Logger:  logger.NewTestLogger(),
	})
	require.NoError(t, err)

	// GetStatus before start should return unavailable
	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, status)
	assert.False(t, status.Available)
	assert.Equal(t, DuskServiceName, status.ServiceName)
	assert.Equal(t, DuskServiceType, status.ServiceType)
}

func TestDuskServiceGetStatus_Disabled(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testDuskConfigDisabled(),
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// GetStatus should return unavailable since dusk is disabled
	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, status)
	assert.False(t, status.Available)
	assert.Equal(t, DuskServiceName, status.ServiceName)
}

func TestDuskServiceStartIdempotent(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testDuskConfigDisabled(),
	})
	require.NoError(t, err)

	// First start
	err = svc.Start(ctx)
	require.NoError(t, err)

	// Second start should be idempotent (no error)
	err = svc.Start(ctx)
	require.NoError(t, err)

	// Stop
	err = svc.Stop(ctx)
	require.NoError(t, err)
}

func TestDuskServiceStopIdempotent(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testDuskConfigDisabled(),
	})
	require.NoError(t, err)

	// Start
	err = svc.Start(ctx)
	require.NoError(t, err)

	// First stop
	err = svc.Stop(ctx)
	require.NoError(t, err)

	// Second stop should be idempotent (no error)
	err = svc.Stop(ctx)
	require.NoError(t, err)
}

func TestDuskServiceConfigSource(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testDuskConfigDisabled(),
	})
	require.NoError(t, err)

	// Before start, config source should be empty
	assert.Empty(t, svc.GetConfigSource())
	assert.Empty(t, svc.GetConfigHash())

	// Start the service
	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// After start, should have a config source (test in this case)
	source := svc.GetConfigSource()
	assert.NotEmpty(t, source)
	assert.Equal(t, duskConfigSourceTest, source)

	// Should have a config hash
	hash := svc.GetConfigHash()
	assert.NotEmpty(t, hash)
	assert.Len(t, hash, 64) // SHA256 hex string is 64 characters
}

func TestComputeDuskConfigHash(t *testing.T) {
	t.Parallel()

	cfg1 := DefaultDuskConfig()
	cfg2 := DefaultDuskConfig()
	cfg2.NodeAddress = "different:9999"

	hash1 := computeDuskConfigHash(cfg1)
	hash2 := computeDuskConfigHash(cfg2)

	// Same config should produce same hash
	assert.Equal(t, hash1, computeDuskConfigHash(cfg1))

	// Different configs should produce different hashes
	assert.NotEqual(t, hash1, hash2)

	// Hash should be 64 hex characters (SHA256)
	assert.Len(t, hash1, 64)
	assert.Len(t, hash2, 64)
}

func TestDefaultDuskConfig(t *testing.T) {
	t.Parallel()

	cfg := DefaultDuskConfig()
	assert.NotNil(t, cfg)
	assert.False(t, cfg.Enabled)
	assert.Empty(t, cfg.NodeAddress)
	assert.Equal(t, models.Duration(5*time.Minute), cfg.Timeout)
}

func TestLoadDuskConfigFromFile(t *testing.T) {
	t.Parallel()

	tmpDir := t.TempDir()

	// Create a config file
	configPath := tmpDir + "/dusk.json"
	configData := `{
		"enabled": true,
		"node_address": "localhost:8080",
		"timeout": "10m"
	}`
	err := os.WriteFile(configPath, []byte(configData), 0644)
	require.NoError(t, err)

	// Load the config
	cfg, err := LoadDuskConfigFromFile(configPath)
	require.NoError(t, err)
	require.NotNil(t, cfg)
	assert.True(t, cfg.Enabled)
	assert.Equal(t, "localhost:8080", cfg.NodeAddress)
	assert.Equal(t, models.Duration(10*time.Minute), cfg.Timeout)
}

func TestLoadDuskConfigFromFile_NotFound(t *testing.T) {
	t.Parallel()

	_, err := LoadDuskConfigFromFile("/nonexistent/path/dusk.json")
	require.Error(t, err)
}

func TestLoadDuskConfigFromFile_InvalidJSON(t *testing.T) {
	t.Parallel()

	tmpDir := t.TempDir()
	configPath := tmpDir + "/dusk.json"

	// Write invalid JSON
	err := os.WriteFile(configPath, []byte("{invalid json}"), 0644)
	require.NoError(t, err)

	_, err = LoadDuskConfigFromFile(configPath)
	require.Error(t, err)
}

func TestDuskServiceConfigDirectory(t *testing.T) {
	t.Parallel()

	tmpDir := t.TempDir()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create a config file in the temp directory
	configPath := tmpDir + "/dusk.json"
	configData := `{
		"enabled": false,
		"node_address": "",
		"timeout": "5m"
	}`
	err := os.WriteFile(configPath, []byte(configData), 0644)
	require.NoError(t, err)

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:   "test-agent",
		ConfigDir: tmpDir,
		Logger:    log,
	})
	require.NoError(t, err)

	// Start the service - it should load from the config directory
	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Config source should indicate the local file
	source := svc.GetConfigSource()
	assert.Contains(t, source, "local:")
	assert.Contains(t, source, configPath)
}

func TestDuskServiceConfigCaching(t *testing.T) {
	t.Parallel()

	tmpDir := t.TempDir()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create a config file (disabled to avoid connection attempts)
	configPath := tmpDir + "/dusk.json"
	configData := `{
		"enabled": false,
		"node_address": "",
		"timeout": "5m"
	}`
	err := os.WriteFile(configPath, []byte(configData), 0644)
	require.NoError(t, err)

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:   "test-agent",
		ConfigDir: tmpDir,
		Logger:    log,
	})
	require.NoError(t, err)

	// Start the service
	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Should have loaded from local file
	source := svc.GetConfigSource()
	assert.Contains(t, source, "local:")
}

func TestDuskServiceIsEnabled_States(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Test 1: Not started
	svc1, err := NewDuskService(DuskServiceConfig{
		AgentID: "test-agent",
		Logger:  log,
	})
	require.NoError(t, err)
	assert.False(t, svc1.IsEnabled(), "should be disabled when not started")

	// Test 2: Started but disabled config
	svc2, err := NewDuskService(DuskServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testDuskConfigDisabled(),
	})
	require.NoError(t, err)
	err = svc2.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc2.Stop(ctx) }()
	assert.False(t, svc2.IsEnabled(), "should be disabled when config.Enabled=false")

	// Test 3: Started but no node address
	cfgNoAddr := &DuskConfig{
		Enabled:     true,
		NodeAddress: "",
	}
	svc3, err := NewDuskService(DuskServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: cfgNoAddr,
	})
	require.NoError(t, err)
	err = svc3.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc3.Stop(ctx) }()
	assert.False(t, svc3.IsEnabled(), "should be disabled when node_address is empty")
}

// TestDuskConfigRefreshDetectsChanges verifies that config refresh
// detects and applies configuration changes (hot-reload).
func TestDuskConfigRefreshDetectsChanges(t *testing.T) {
	t.Parallel()

	tmpDir := t.TempDir()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create initial disabled config
	configPath := tmpDir + "/dusk.json"
	initialConfig := `{
		"enabled": false,
		"node_address": "",
		"timeout": "5m"
	}`
	err := os.WriteFile(configPath, []byte(initialConfig), 0644)
	require.NoError(t, err)

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:   "test-agent",
		ConfigDir: tmpDir,
		Logger:    log,
	})
	require.NoError(t, err)

	// Start the service
	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Record initial state
	initialHash := svc.GetConfigHash()
	assert.NotEmpty(t, initialHash)
	assert.False(t, svc.IsEnabled(), "should be disabled initially")

	// Update config file with new settings
	updatedConfig := `{
		"enabled": false,
		"node_address": "localhost:9999",
		"timeout": "10m"
	}`
	err = os.WriteFile(configPath, []byte(updatedConfig), 0644)
	require.NoError(t, err)

	// Trigger config refresh check
	svc.checkConfigUpdate(ctx)

	// Verify config was updated
	afterHash := svc.GetConfigHash()
	assert.NotEqual(t, initialHash, afterHash, "hash should change after config update")
}

// TestDuskConfigRefreshPreservesLocalOverride verifies that config refresh
// doesn't unexpectedly change a local config.
func TestDuskConfigRefreshPreservesLocalOverride(t *testing.T) {
	t.Parallel()

	tmpDir := t.TempDir()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create a local config file
	configPath := tmpDir + "/dusk.json"
	configData := `{
		"enabled": false,
		"node_address": "",
		"timeout": "5m"
	}`
	err := os.WriteFile(configPath, []byte(configData), 0644)
	require.NoError(t, err)

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:   "test-agent",
		ConfigDir: tmpDir,
		Logger:    log,
	})
	require.NoError(t, err)

	// Start the service
	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Record initial state
	initialSource := svc.GetConfigSource()
	initialHash := svc.GetConfigHash()
	assert.Contains(t, initialSource, "local:")

	// Simulate a config refresh (in production this happens on a timer)
	svc.checkConfigUpdate(ctx)

	// Config should remain the same since local file hasn't changed
	afterSource := svc.GetConfigSource()
	afterHash := svc.GetConfigHash()

	assert.Equal(t, initialSource, afterSource, "source should remain local after refresh")
	assert.Equal(t, initialHash, afterHash, "hash should remain the same after refresh")
}

// TestDuskServiceGetStatusPayload verifies the status response structure.
func TestDuskServiceGetStatusPayload(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testDuskConfigDisabled(),
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Get status
	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, status)

	// Verify basic status fields
	assert.Equal(t, DuskServiceName, status.ServiceName)
	assert.Equal(t, DuskServiceType, status.ServiceType)
	assert.False(t, status.Available, "should be unavailable when disabled")

	// When disabled, message may be empty (no checker running)
	// The important thing is the status response has correct ServiceName/Type
	assert.GreaterOrEqual(t, status.ResponseTime, int64(0), "response time should be non-negative")
}

// TestDuskServiceReconfigure verifies the Reconfigure method works correctly.
func TestDuskServiceReconfigure(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testDuskConfigDisabled(),
	})
	require.NoError(t, err)

	// Start the service
	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	initialHash := svc.GetConfigHash()

	// Reconfigure with new settings should succeed
	newConfig := &DuskConfig{
		Enabled:     false,
		NodeAddress: "localhost:9999",
		Timeout:     models.Duration(10 * time.Minute),
	}
	err = svc.Reconfigure(newConfig, "test-reconfigure")
	require.NoError(t, err)

	// Verify config was updated
	assert.Equal(t, "test-reconfigure", svc.GetConfigSource())
	assert.NotEqual(t, initialHash, svc.GetConfigHash(), "hash should change after reconfigure")
}

// TestDuskServiceReconfigureNilConfig verifies Reconfigure fails with nil config.
func TestDuskServiceReconfigureNilConfig(t *testing.T) {
	t.Parallel()

	log := logger.NewTestLogger()

	svc, err := NewDuskService(DuskServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testDuskConfigDisabled(),
	})
	require.NoError(t, err)

	// Reconfigure with nil config should fail
	err = svc.Reconfigure(nil, "test")
	require.Error(t, err, "reconfigure should fail with nil config")
	assert.Contains(t, err.Error(), "nil config")
}
