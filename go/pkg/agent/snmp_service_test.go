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
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/snmp"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
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

func TestSNMPRefreshSkipsCacheWhileRemoteActive(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()
	tmpDir := t.TempDir()
	cachePath := filepath.Join(tmpDir, "cache", "snmp-config.json")

	localConfig := `{
		"enabled": true,
		"targets": [
			{
				"name": "local-target",
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
	err := os.WriteFile(filepath.Join(tmpDir, "snmp.json"), []byte(localConfig), 0644)
	require.NoError(t, err)

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		ConfigDir:      tmpDir,
		CachePath:      cachePath,
		Logger:         log,
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	err = svc.ApplyProtoConfig(ctx, &proto.SNMPConfig{
		Enabled: true,
		Targets: []*proto.SNMPTargetConfig{
			{
				Name:                "remote-target",
				Host:                "10.0.0.10",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
				Community:           "public",
				PollIntervalSeconds: 60,
				TimeoutSeconds:      2,
				Retries:             1,
				Oids: []*proto.SNMPOIDConfig{
					{
						Oid:      ".1.3.6.1.2.1.1.1.0",
						Name:     "sysDescr",
						DataType: proto.SNMPDataType_SNMP_DATA_TYPE_STRING,
					},
				},
			},
		},
	})
	require.NoError(t, err)

	remoteHash := svc.GetConfigHash()
	assert.Equal(t, snmpConfigSourceRemote, svc.GetConfigSource())

	conflictingCache := `{
		"enabled": true,
		"targets": [
			{
				"name": "cached-target",
				"host": "10.0.0.20",
				"port": 161,
				"version": "2c",
				"community": "public",
				"timeout": 1,
				"oids": [
					{"oid": ".1.3.6.1.2.1.1.3.0", "name": "sysUpTime", "type": "timeticks"}
				]
			}
		]
	}`
	err = os.MkdirAll(filepath.Dir(cachePath), 0755)
	require.NoError(t, err)
	err = os.WriteFile(cachePath, []byte(conflictingCache), 0644)
	require.NoError(t, err)

	svc.checkConfigUpdate(ctx)

	assert.Equal(t, snmpConfigSourceRemote, svc.GetConfigSource())
	assert.Equal(t, remoteHash, svc.GetConfigHash())
}

func TestProtoToSNMPOIDConfig_WalkFields(t *testing.T) {
	t.Parallel()

	got := protoToSNMPOIDConfig(&proto.SNMPOIDConfig{
		Oid:                ".1.3.6.1.2.1.31.1.1.1.6",
		Name:               "ifHCInOctets",
		DataType:           proto.SNMPDataType_SNMP_DATA_TYPE_COUNTER,
		Delta:              true,
		Mode:               "walk",
		MaxRows:            250,
		WalkTimeoutSeconds: 12,
	})

	require.Equal(t, snmp.ModeWalk, got.Mode)
	require.Equal(t, 250, got.MaxRows)
	require.Equal(t, snmp.Duration(12*time.Second), got.WalkTimeout)
	require.Equal(t, ".1.3.6.1.2.1.31.1.1.1.6", got.OID)
	require.Equal(t, "ifHCInOctets", got.Name)
	require.Equal(t, snmp.TypeCounter, got.DataType)
	require.True(t, got.Delta)
}

func TestProtoToSNMPOIDConfig_GetIsDefault(t *testing.T) {
	t.Parallel()

	got := protoToSNMPOIDConfig(&proto.SNMPOIDConfig{
		Oid:      ".1.3.6.1.2.1.1.5.0",
		Name:     "sysName",
		DataType: proto.SNMPDataType_SNMP_DATA_TYPE_STRING,
	})

	require.Empty(t, got.Mode)
	require.Zero(t, got.MaxRows)
	require.Zero(t, got.WalkTimeout)
}

func TestParseProtoSNMPConfigCopiesProfileAndTargetIDs(t *testing.T) {
	t.Parallel()

	got, err := parseProtoSNMPConfig(&proto.SNMPConfig{
		Enabled:     true,
		ProfileId:   "profile-uuid",
		ProfileName: "ClearPass node health",
		Targets: []*proto.SNMPTargetConfig{
			{
				Id:   "target-uuid",
				Name: "clearpass-a",
				Host: "10.0.0.8",
				Port: 161,
			},
		},
	})

	require.NoError(t, err)
	require.Equal(t, "profile-uuid", got.ProfileID)
	require.Equal(t, "ClearPass node health", got.ProfileName)
	require.Len(t, got.Targets, 1)
	require.Equal(t, "target-uuid", got.Targets[0].ID)
	require.Equal(t, "clearpass-a", got.Targets[0].Name)
}

func TestParseProtoSNMPConfig_SharedOIDsParity(t *testing.T) {
	t.Parallel()

	coreOIDs := []*proto.SNMPOIDConfig{
		{
			Oid:                ".1.3.6.1.2.1.31.1.1.1.6",
			Name:               "ifHCInOctets",
			DataType:           proto.SNMPDataType_SNMP_DATA_TYPE_COUNTER,
			Scale:              1.0,
			Delta:              true,
			Mode:               "walk",
			MaxRows:            200,
			WalkTimeoutSeconds: 15,
		},
		{
			Oid:      ".1.3.6.1.2.1.1.3.0",
			Name:     "sysUpTime",
			DataType: proto.SNMPDataType_SNMP_DATA_TYPE_TIMETICKS,
			Scale:    1.0,
		},
	}

	edgeOIDs := []*proto.SNMPOIDConfig{
		{
			Oid:      ".1.3.6.1.2.1.1.5.0",
			Name:     "sysName",
			DataType: proto.SNMPDataType_SNMP_DATA_TYPE_STRING,
			Scale:    1.0,
		},
	}

	legacyProto := &proto.SNMPConfig{
		Enabled:     true,
		ProfileId:   "prof-shared-1",
		ProfileName: "Shared OIDs Profile",
		Targets: []*proto.SNMPTargetConfig{
			{
				Id:                  "sr:dev-0001",
				Name:                "switch-01",
				Host:                "192.0.2.10",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
				Community:           "public",
				PollIntervalSeconds: 60,
				TimeoutSeconds:      5,
				Retries:             3,
				Oids:                coreOIDs,
			},
			{
				Id:                  "sr:dev-0002",
				Name:                "switch-02",
				Host:                "192.0.2.11",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
				Community:           "public",
				PollIntervalSeconds: 60,
				TimeoutSeconds:      5,
				Retries:             3,
				Oids:                coreOIDs,
			},
			{
				Id:                  "sr:dev-0003",
				Name:                "router-01",
				Host:                "192.0.2.12",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V3,
				PollIntervalSeconds: 30,
				TimeoutSeconds:      4,
				Retries:             2,
				V3Auth: &proto.SNMPv3Auth{
					Username:      "snmp-user",
					SecurityLevel: proto.SNMPSecurityLevel_SNMP_SECURITY_LEVEL_AUTH_PRIV,
					AuthProtocol:  proto.SNMPAuthProtocol_SNMP_AUTH_PROTOCOL_SHA256,
					AuthPassword:  "synthetic-auth-secret",
					PrivProtocol:  proto.SNMPPrivProtocol_SNMP_PRIV_PROTOCOL_AES,
					PrivPassword:  "synthetic-priv-secret",
				},
				Oids: edgeOIDs,
			},
		},
	}

	sharedProto := &proto.SNMPConfig{
		Enabled:     true,
		ProfileId:   "prof-shared-1",
		ProfileName: "Shared OIDs Profile",
		Format:      "shared-oids/v1",
		OidSets: []*proto.SNMPOIDSet{
			{Key: "oids-core", Oids: coreOIDs},
			{Key: "oids-edge", Oids: edgeOIDs},
		},
		Targets: []*proto.SNMPTargetConfig{
			{
				Id:                  "sr:dev-0001",
				Name:                "switch-01",
				Host:                "192.0.2.10",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
				Community:           "public",
				PollIntervalSeconds: 60,
				TimeoutSeconds:      5,
				Retries:             3,
				OidSet:              "oids-core",
			},
			{
				Id:                  "sr:dev-0002",
				Name:                "switch-02",
				Host:                "192.0.2.11",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
				Community:           "public",
				PollIntervalSeconds: 60,
				TimeoutSeconds:      5,
				Retries:             3,
				OidSet:              "oids-core",
			},
			{
				Id:                  "sr:dev-0003",
				Name:                "router-01",
				Host:                "192.0.2.12",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V3,
				PollIntervalSeconds: 30,
				TimeoutSeconds:      4,
				Retries:             2,
				V3Auth: &proto.SNMPv3Auth{
					Username:      "snmp-user",
					SecurityLevel: proto.SNMPSecurityLevel_SNMP_SECURITY_LEVEL_AUTH_PRIV,
					AuthProtocol:  proto.SNMPAuthProtocol_SNMP_AUTH_PROTOCOL_SHA256,
					AuthPassword:  "synthetic-auth-secret",
					PrivProtocol:  proto.SNMPPrivProtocol_SNMP_PRIV_PROTOCOL_AES,
					PrivPassword:  "synthetic-priv-secret",
				},
				OidSet: "oids-edge",
			},
		},
	}

	legacyCfg, err := parseProtoSNMPConfig(legacyProto)
	require.NoError(t, err)

	legacyProto.Format = "legacy"
	explicitLegacyCfg, err := parseProtoSNMPConfig(legacyProto)
	require.NoError(t, err)
	require.Equal(t, legacyCfg, explicitLegacyCfg)

	sharedCfg, err := parseProtoSNMPConfig(sharedProto)
	require.NoError(t, err)

	if !reflect.DeepEqual(legacyCfg, sharedCfg) {
		t.Fatalf("shared-oids parse differs from legacy:\nlegacy: %+v\nshared: %+v", legacyCfg, sharedCfg)
	}
	require.Equal(t, computeSNMPConfigHash(legacyCfg), computeSNMPConfigHash(sharedCfg))

	// Mutating one target's rehydrated OID slice must not affect another target sharing the set.
	sharedCfg.Targets[0].OIDs[0].Scale = 42.0
	require.InDelta(t, 1.0, sharedCfg.Targets[1].OIDs[0].Scale, 1e-9)
}

func TestParseProtoSNMPConfig_ErrorCases(t *testing.T) {
	t.Parallel()

	_, err := parseProtoSNMPConfig(&proto.SNMPConfig{
		Enabled: true,
		Format:  "shared-oids/v99",
	})
	require.ErrorIs(t, err, ErrUnsupportedSNMPConfigFormat)

	_, err = parseProtoSNMPConfig(&proto.SNMPConfig{
		Enabled: true,
		Format:  "shared-oids/v1",
		OidSets: []*proto.SNMPOIDSet{
			{Key: ""},
		},
	})
	require.ErrorIs(t, err, ErrSNMPOIDSetInvalidKey)

	_, err = parseProtoSNMPConfig(&proto.SNMPConfig{
		Enabled: true,
		Format:  "shared-oids/v1",
		OidSets: []*proto.SNMPOIDSet{
			{Key: "oids-dup"},
			{Key: "oids-dup"},
		},
	})
	require.ErrorIs(t, err, ErrSNMPOIDSetInvalidKey)

	_, err = parseProtoSNMPConfig(&proto.SNMPConfig{
		Enabled: true,
		Format:  "shared-oids/v1",
		OidSets: []*proto.SNMPOIDSet{
			{Key: "oids-present"},
		},
		Targets: []*proto.SNMPTargetConfig{
			{Name: "switch-01", Host: "192.0.2.10", OidSet: "oids-missing"},
		},
	})
	require.ErrorIs(t, err, ErrSNMPOIDSetMissing)
}

func TestApplyProtoConfig_UnknownFormatKeepsRunningConfig(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	tmpDir := t.TempDir()
	cachePath := filepath.Join(tmpDir, "cache", "snmp-config.json")

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		ConfigDir:      tmpDir,
		CachePath:      cachePath,
		Logger:         logger.NewTestLogger(),
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)
	require.NoError(t, svc.Start(ctx))
	defer func() { _ = svc.Stop(ctx) }()

	initialProto := &proto.SNMPConfig{
		Enabled:     true,
		ProfileId:   "prof-1",
		ProfileName: "Running Profile",
		Targets: []*proto.SNMPTargetConfig{
			{
				Id:                  "sr:dev-0001",
				Name:                "switch-01",
				Host:                "192.0.2.10",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
				Community:           "public",
				PollIntervalSeconds: 60,
				TimeoutSeconds:      2,
				Retries:             1,
				Oids: []*proto.SNMPOIDConfig{
					{
						Oid:      ".1.3.6.1.2.1.1.1.0",
						Name:     "sysDescr",
						DataType: proto.SNMPDataType_SNMP_DATA_TYPE_STRING,
					},
				},
			},
		},
	}

	require.NoError(t, svc.ApplyProtoConfig(ctx, initialProto))
	require.True(t, svc.IsEnabled())
	runningHash := svc.GetConfigHash()
	runningProfile := svc.GetProfileID()
	require.NotEmpty(t, runningHash)
	require.Equal(t, "prof-1", runningProfile)

	// Unknown format must be rejected without stopping or replacing the running config.
	err = svc.ApplyProtoConfig(ctx, &proto.SNMPConfig{
		Enabled:     false,
		ProfileId:   "prof-unknown",
		ProfileName: "Unknown Format",
		Format:      "yaml",
	})
	require.ErrorIs(t, err, ErrUnsupportedSNMPConfigFormat)
	require.True(t, svc.IsEnabled())
	require.Equal(t, runningHash, svc.GetConfigHash())
	require.Equal(t, "prof-1", svc.GetProfileID())

	// Missing oid_set reference must also keep the running config.
	err = svc.ApplyProtoConfig(ctx, &proto.SNMPConfig{
		Enabled:     true,
		ProfileId:   "prof-broken",
		ProfileName: "Broken Shared OIDs",
		Format:      "shared-oids/v1",
		Targets: []*proto.SNMPTargetConfig{
			{
				Id:     "sr:dev-0001",
				Name:   "switch-01",
				Host:   "192.0.2.10",
				Port:   161,
				OidSet: "oids-missing",
			},
		},
	})
	require.ErrorIs(t, err, ErrSNMPOIDSetMissing)
	require.True(t, svc.IsEnabled())
	require.Equal(t, runningHash, svc.GetConfigHash())
	require.Equal(t, "prof-1", svc.GetProfileID())

	// Valid shared-oids/v1 update applies cleanly.
	err = svc.ApplyProtoConfig(ctx, &proto.SNMPConfig{
		Enabled:     true,
		ProfileId:   "prof-2",
		ProfileName: "Shared Profile",
		Format:      "shared-oids/v1",
		OidSets: []*proto.SNMPOIDSet{
			{
				Key: "oids-sys",
				Oids: []*proto.SNMPOIDConfig{
					{
						Oid:      ".1.3.6.1.2.1.1.5.0",
						Name:     "sysName",
						DataType: proto.SNMPDataType_SNMP_DATA_TYPE_STRING,
					},
				},
			},
		},
		Targets: []*proto.SNMPTargetConfig{
			{
				Id:                  "sr:dev-0002",
				Name:                "switch-02",
				Host:                "192.0.2.11",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
				Community:           "public",
				PollIntervalSeconds: 60,
				TimeoutSeconds:      2,
				Retries:             1,
				OidSet:              "oids-sys",
			},
		},
	})
	require.NoError(t, err)
	require.True(t, svc.IsEnabled())
	require.NotEqual(t, runningHash, svc.GetConfigHash())
	require.Equal(t, "prof-2", svc.GetProfileID())
}

func TestAgentCapabilitiesAdvertiseSNMPSharedOIDs(t *testing.T) {
	t.Parallel()

	caps := agentCapabilities(agentCapabilityOptions{})
	if !slices.Contains(caps, "snmp-config-shared-oids:v1") {
		t.Fatalf("capabilities %v missing snmp-config-shared-oids:v1", caps)
	}
}
