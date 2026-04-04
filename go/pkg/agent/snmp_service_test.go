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
	"path/filepath"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/agent/snmp"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// testSNMPConfig returns a minimal disabled config for testing.
// Since SNMP requires network access, tests use disabled config by default.
func testSNMPConfig() *snmp.SNMPConfig {
	return snmp.DefaultConfig()
}

// mockSNMPServiceFactory creates mock SNMP services that don't require network.
type mockSNMPServiceFactory struct{}

func (f *mockSNMPServiceFactory) CreateService(config *snmp.SNMPConfig, log logger.Logger) (*snmp.SNMPService, error) {
	// Create a service without starting collectors
	// The service will be created but collectors won't actually poll
	return snmp.NewMockServiceForTesting(config, log)
}

func TestNewSNMPAgentService(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		config    SNMPAgentServiceConfig
		wantErr   bool
		checkFunc func(*testing.T, *SNMPAgentService)
	}{
		{
			name: "default config",
			config: SNMPAgentServiceConfig{
				AgentID: "test-agent",
			},
			wantErr: false,
			checkFunc: func(t *testing.T, s *SNMPAgentService) {
				t.Helper()
				assert.Equal(t, "test-agent", s.agentID)
				assert.NotNil(t, s.logger)
			},
		},
		{
			name: "with partition",
			config: SNMPAgentServiceConfig{
				AgentID:   "test-agent",
				Partition: "us-west-2",
				Logger:    logger.NewTestLogger(),
			},
			wantErr: false,
			checkFunc: func(t *testing.T, s *SNMPAgentService) {
				t.Helper()
				assert.Equal(t, "test-agent", s.agentID)
				assert.Equal(t, "us-west-2", s.partition)
			},
		},
		{
			name: "with test config",
			config: SNMPAgentServiceConfig{
				AgentID:    "test-agent",
				Logger:     logger.NewTestLogger(),
				TestConfig: testSNMPConfig(),
			},
			wantErr: false,
			checkFunc: func(t *testing.T, s *SNMPAgentService) {
				t.Helper()
				assert.NotNil(t, s.testConfig)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			svc, err := NewSNMPAgentService(tt.config)
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

func TestSNMPAgentServiceName(t *testing.T) {
	t.Parallel()
	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{AgentID: "test"})
	require.NoError(t, err)
	assert.Equal(t, SNMPServiceName, svc.Name())
}

func TestSNMPAgentServiceLifecycle(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Use a disabled config since we don't have actual SNMP targets
	cfg := testSNMPConfig()
	cfg.Enabled = false

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: cfg,
	})
	require.NoError(t, err)

	// Start should succeed (even with disabled config)
	err = svc.Start(ctx)
	require.NoError(t, err)

	// Should NOT be enabled (disabled config)
	assert.False(t, svc.IsEnabled())

	// GetStatus should return data
	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, status)
	// Available should be false since SNMP is disabled
	assert.False(t, status.Available)
	assert.Equal(t, SNMPServiceName, status.ServiceName)
	assert.Equal(t, SNMPServiceType, status.ServiceType)

	// Stop should succeed
	err = svc.Stop(ctx)
	require.NoError(t, err)
}

func TestSNMPAgentServiceLifecycleEnabled(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()
	cachePath := filepath.Join(t.TempDir(), "cache", "snmp-config.json")

	// Use an enabled config with a mock target and OID
	// Note: The SNMP service requires at least one target with at least one OID when enabled
	cfg := testSNMPConfig()
	cfg.Enabled = true
	cfg.Targets = []snmp.Target{
		{
			Name:      "test-target",
			Host:      "127.0.0.1", // localhost, won't actually poll
			Port:      161,
			Version:   "2c",
			Community: "public",
			Timeout:   1, // 1 second timeout
			OIDs: []snmp.OIDConfig{
				{
					OID:      ".1.3.6.1.2.1.1.1.0", // sysDescr
					Name:     "sysDescr",
					DataType: snmp.TypeString,
				},
			},
		},
	}

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		CachePath:      cachePath,
		Logger:         log,
		TestConfig:     cfg,
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	// Start should succeed
	err = svc.Start(ctx)
	require.NoError(t, err)

	// Should be enabled
	assert.True(t, svc.IsEnabled())

	// GetStatus should return available
	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, status)
	assert.True(t, status.Available)
	assert.Equal(t, SNMPServiceName, status.ServiceName)

	// Stop should succeed
	err = svc.Stop(ctx)
	require.NoError(t, err)

	// Should no longer be enabled
	assert.False(t, svc.IsEnabled())
}

func TestSNMPAgentServiceGetStatus_NotStarted(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID: "test-agent",
		Logger:  logger.NewTestLogger(),
	})
	require.NoError(t, err)

	// GetStatus before start should return unavailable
	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, status)
	assert.False(t, status.Available)
	assert.Equal(t, SNMPServiceName, status.ServiceName)
}

func TestSNMPAgentServiceStartIdempotent(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testSNMPConfig(),
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

func TestSNMPAgentServiceStopIdempotent(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testSNMPConfig(),
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

func TestSNMPAgentServiceConfigSource(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()
	cachePath := filepath.Join(t.TempDir(), "cache", "snmp-config.json")

	// Use an enabled config with a target and OID so config source is set
	cfg := testSNMPConfig()
	cfg.Enabled = true
	cfg.Targets = []snmp.Target{
		{
			Name:      "test-target",
			Host:      "127.0.0.1",
			Port:      161,
			Version:   "2c",
			Community: "public",
			Timeout:   1,
			OIDs: []snmp.OIDConfig{
				{OID: ".1.3.6.1.2.1.1.1.0", Name: "sysDescr", DataType: snmp.TypeString},
			},
		},
	}

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		CachePath:      cachePath,
		Logger:         log,
		TestConfig:     cfg,
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	// Before start, config source should be empty
	assert.Empty(t, svc.GetConfigSource())
	assert.Empty(t, svc.GetConfigHash())

	// Start the service
	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// After start, should have a config source
	source := svc.GetConfigSource()
	assert.NotEmpty(t, source)
	// Source should be "test" when using TestConfig
	assert.Equal(t, "test", source, "should use test config source")

	// Should have a config hash
	hash := svc.GetConfigHash()
	assert.NotEmpty(t, hash)
	assert.Len(t, hash, 64) // SHA256 hex string is 64 characters
}

func TestSNMPAgentServiceConfigCaching(t *testing.T) {
	t.Parallel()

	// Skip if we can't write to temp directory
	tmpDir := t.TempDir()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create a config file in the temp directory with enabled SNMP, a target, and OIDs
	configPath := tmpDir + "/snmp.json"
	configData := `{
		"enabled": true,
		"targets": [
			{
				"name": "test-target",
				"host": "127.0.0.1",
				"port": 161,
				"version": "2c",
				"community": "public",
				"timeout": 1,
				"oids": [
					{"oid": ".1.3.6.1.2.1.1.1.0", "name": "sysDescr", "type": "string"}
				]
			}
		]
	}`
	err := os.WriteFile(configPath, []byte(configData), 0644)
	require.NoError(t, err)

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		ConfigDir:      tmpDir,
		CachePath:      filepath.Join(tmpDir, "cache", "snmp-config.json"),
		Logger:         log,
		ServiceFactory: &mockSNMPServiceFactory{},
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

func TestSNMPLocalOverrideTakesPrecedence(t *testing.T) {
	t.Parallel()

	tmpDir := t.TempDir()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create a "cached" config with 2 targets
	cacheDir := tmpDir + "/cache"
	err := os.MkdirAll(cacheDir, 0755)
	require.NoError(t, err)

	cachedConfig := `{
		"enabled": true,
		"targets": [
			{"name": "cached1", "host": "10.0.0.1", "port": 161, "version": "2c", "community": "public", "timeout": 1, "oids": [{"oid": ".1.3.6.1.2.1.1.1.0", "name": "sysDescr", "type": "string"}]},
			{"name": "cached2", "host": "10.0.0.2", "port": 161, "version": "2c", "community": "public", "timeout": 1, "oids": [{"oid": ".1.3.6.1.2.1.1.1.0", "name": "sysDescr", "type": "string"}]}
		]
	}`
	cachedPath := cacheDir + "/snmp-config.json"
	err = os.WriteFile(cachedPath, []byte(cachedConfig), 0644)
	require.NoError(t, err)

	// Create a local config with 1 target (should take precedence)
	localConfig := `{
		"enabled": true,
		"targets": [
			{"name": "local-target", "host": "127.0.0.1", "port": 161, "version": "2c", "community": "public", "timeout": 1, "oids": [{"oid": ".1.3.6.1.2.1.1.1.0", "name": "sysDescr", "type": "string"}]}
		]
	}`
	localPath := tmpDir + "/snmp.json"
	err = os.WriteFile(localPath, []byte(localConfig), 0644)
	require.NoError(t, err)

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		ConfigDir:      tmpDir,
		CachePath:      filepath.Join(tmpDir, "cache", "snmp-config.json"),
		Logger:         log,
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	// Start the service
	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Config source should indicate local file, not cache
	source := svc.GetConfigSource()
	assert.Contains(t, source, "local:", "should use local config, not cache")
	assert.Contains(t, source, localPath, "should reference the local config path")
	assert.NotContains(t, source, "cache:", "should not use cached config")

	// Service should be enabled (local config has enabled: true)
	assert.True(t, svc.IsEnabled(), "should use local config which is enabled")
}

func TestSNMPDefaultFallbackWhenLocalUnavailable(t *testing.T) {
	t.Parallel()

	tmpDir := t.TempDir()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create service with no config files in the directory
	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:   "test-agent",
		ConfigDir: tmpDir, // Empty directory, no config file
		CachePath: filepath.Join(tmpDir, "cache", "snmp-config.json"),
		Logger:    log,
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Default config has SNMP disabled, so configSource won't be set
	// (Start returns early when SNMP is disabled)
	assert.False(t, svc.IsEnabled(), "default SNMP config should be disabled")

	// When SNMP is disabled, source remains empty (early return in Start)
	source := svc.GetConfigSource()
	assert.Empty(t, source, "config source not set when SNMP is disabled")
}

func TestSNMPConfigRefreshPreservesLocalOverride(t *testing.T) {
	t.Parallel()

	tmpDir := t.TempDir()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create local config with enabled SNMP and a target with OIDs
	localConfig := `{
		"enabled": true,
		"targets": [
			{
				"name": "test-target",
				"host": "127.0.0.1",
				"port": 161,
				"version": "2c",
				"community": "public",
				"timeout": 1,
				"oids": [
					{"oid": ".1.3.6.1.2.1.1.1.0", "name": "sysDescr", "type": "string"}
				]
			}
		]
	}`
	configPath := tmpDir + "/snmp.json"
	err := os.WriteFile(configPath, []byte(localConfig), 0644)
	require.NoError(t, err)

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		ConfigDir:      tmpDir,
		CachePath:      filepath.Join(tmpDir, "cache", "snmp-config.json"),
		Logger:         log,
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Get initial state
	initialSource := svc.GetConfigSource()
	initialHash := svc.GetConfigHash()
	assert.Contains(t, initialSource, "local:")

	// Trigger a refresh check directly to verify the local override stays intact
	// without depending on wall-clock timing in a race-instrumented test run.
	svc.checkConfigUpdate(ctx)

	// Config should remain the same since local file hasn't changed
	afterSource := svc.GetConfigSource()
	afterHash := svc.GetConfigHash()

	assert.Equal(t, initialSource, afterSource, "source should remain local after refresh")
	assert.Equal(t, initialHash, afterHash, "hash should remain the same after refresh")
}

func TestSNMPConfigHashComputation(t *testing.T) {
	t.Parallel()

	cfg1 := snmp.DefaultConfig()
	cfg2 := snmp.DefaultConfig()
	cfg2.Enabled = true // Different from default

	hash1 := computeSNMPConfigHash(cfg1)
	hash2 := computeSNMPConfigHash(cfg2)

	// Same config should produce same hash
	assert.Equal(t, hash1, computeSNMPConfigHash(cfg1))

	// Different configs should produce different hashes
	assert.NotEqual(t, hash1, hash2)

	// Hash should be 64 hex characters (SHA256)
	assert.Len(t, hash1, 64)
	assert.Len(t, hash2, 64)
}
