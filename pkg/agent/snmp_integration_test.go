//go:build integration
// +build integration

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
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestSNMPAgentIntegration_ApplyProtoConfig tests applying configuration
// from the control plane via protobuf message.
func TestSNMPAgentIntegration_ApplyProtoConfig(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create service with mock factory to avoid actual SNMP polling
	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		Logger:         log,
		TestConfig:     snmp.DefaultConfig(), // Start disabled
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	// Start the service (disabled initially)
	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Initially disabled
	assert.False(t, svc.IsEnabled())

	// Apply proto config to enable SNMP with a target
	protoConfig := &proto.SNMPConfig{
		Enabled: true,
		Targets: []*proto.SNMPTargetConfig{
			{
				Name:                "proto-target",
				Host:                "192.168.1.1",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
				Community:           "public",
				PollIntervalSeconds: 60,
				TimeoutSeconds:      5,
				Retries:             3,
				Oids: []*proto.SNMPOIDConfig{
					{
						Oid:      ".1.3.6.1.2.1.1.1.0",
						Name:     "sysDescr",
						DataType: proto.SNMPDataType_SNMP_DATA_TYPE_STRING,
					},
					{
						Oid:      ".1.3.6.1.2.1.2.2.1.10",
						Name:     "ifInOctets",
						DataType: proto.SNMPDataType_SNMP_DATA_TYPE_COUNTER,
						Delta:    true,
					},
				},
			},
		},
	}

	// Apply the proto config
	err = svc.ApplyProtoConfig(ctx, protoConfig)
	require.NoError(t, err)

	// Service should now be enabled
	assert.True(t, svc.IsEnabled())

	// Config source should be "remote"
	assert.Equal(t, "remote", svc.GetConfigSource())

	// Config hash should be set
	assert.NotEmpty(t, svc.GetConfigHash())
}

// TestSNMPAgentIntegration_ApplyProtoConfigDisable tests disabling SNMP
// via proto config after it was enabled.
func TestSNMPAgentIntegration_ApplyProtoConfigDisable(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	// Start with enabled config
	cfg := snmp.DefaultConfig()
	cfg.Enabled = true
	cfg.Targets = []snmp.Target{
		{
			Name:      "initial-target",
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
		Logger:         log,
		TestConfig:     cfg,
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Initially enabled
	assert.True(t, svc.IsEnabled())

	// Apply proto config to disable SNMP
	disabledConfig := &proto.SNMPConfig{
		Enabled: false,
		Targets: nil,
	}

	err = svc.ApplyProtoConfig(ctx, disabledConfig)
	require.NoError(t, err)

	// Service should now be disabled
	assert.False(t, svc.IsEnabled())
}

// TestSNMPAgentIntegration_ProtoConfigIdempotent tests that applying
// the same config twice doesn't cause issues.
func TestSNMPAgentIntegration_ProtoConfigIdempotent(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		Logger:         log,
		TestConfig:     snmp.DefaultConfig(),
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	protoConfig := &proto.SNMPConfig{
		Enabled: true,
		Targets: []*proto.SNMPTargetConfig{
			{
				Name:                "target1",
				Host:                "10.0.0.1",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
				Community:           "public",
				PollIntervalSeconds: 60,
				TimeoutSeconds:      5,
				Retries:             3,
				Oids: []*proto.SNMPOIDConfig{
					{Oid: ".1.3.6.1.2.1.1.1.0", Name: "sysDescr", DataType: proto.SNMPDataType_SNMP_DATA_TYPE_STRING},
				},
			},
		},
	}

	// First apply
	err = svc.ApplyProtoConfig(ctx, protoConfig)
	require.NoError(t, err)
	hash1 := svc.GetConfigHash()

	// Second apply with same config - should be no-op
	err = svc.ApplyProtoConfig(ctx, protoConfig)
	require.NoError(t, err)
	hash2 := svc.GetConfigHash()

	// Hash should be the same (config unchanged)
	assert.Equal(t, hash1, hash2)
}

// TestSNMPAgentIntegration_ProtoConfigUpdate tests updating config via proto.
func TestSNMPAgentIntegration_ProtoConfigUpdate(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		Logger:         log,
		TestConfig:     snmp.DefaultConfig(),
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Apply initial config
	initialConfig := &proto.SNMPConfig{
		Enabled: true,
		Targets: []*proto.SNMPTargetConfig{
			{
				Name:                "target1",
				Host:                "10.0.0.1",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
				Community:           "public",
				PollIntervalSeconds: 60,
				TimeoutSeconds:      5,
				Retries:             3,
				Oids: []*proto.SNMPOIDConfig{
					{Oid: ".1.3.6.1.2.1.1.1.0", Name: "sysDescr", DataType: proto.SNMPDataType_SNMP_DATA_TYPE_STRING},
				},
			},
		},
	}

	err = svc.ApplyProtoConfig(ctx, initialConfig)
	require.NoError(t, err)
	initialHash := svc.GetConfigHash()

	// Apply updated config with additional target
	updatedConfig := &proto.SNMPConfig{
		Enabled: true,
		Targets: []*proto.SNMPTargetConfig{
			{
				Name:                "target1",
				Host:                "10.0.0.1",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
				Community:           "public",
				PollIntervalSeconds: 60,
				TimeoutSeconds:      5,
				Retries:             3,
				Oids: []*proto.SNMPOIDConfig{
					{Oid: ".1.3.6.1.2.1.1.1.0", Name: "sysDescr", DataType: proto.SNMPDataType_SNMP_DATA_TYPE_STRING},
				},
			},
			{
				Name:                "target2",
				Host:                "10.0.0.2",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
				Community:           "private",
				PollIntervalSeconds: 30,
				TimeoutSeconds:      3,
				Retries:             2,
				Oids: []*proto.SNMPOIDConfig{
					{Oid: ".1.3.6.1.2.1.2.2.1.10", Name: "ifInOctets", DataType: proto.SNMPDataType_SNMP_DATA_TYPE_COUNTER, Delta: true},
				},
			},
		},
	}

	err = svc.ApplyProtoConfig(ctx, updatedConfig)
	require.NoError(t, err)
	updatedHash := svc.GetConfigHash()

	// Hash should be different (config changed)
	assert.NotEqual(t, initialHash, updatedHash)
	assert.True(t, svc.IsEnabled())
}

// TestSNMPAgentIntegration_GetStatusWithTargets tests status reporting
// with active targets.
func TestSNMPAgentIntegration_GetStatusWithTargets(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	cfg := snmp.DefaultConfig()
	cfg.Enabled = true
	cfg.Targets = []snmp.Target{
		{
			Name:      "test-router",
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
		Logger:         log,
		TestConfig:     cfg,
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Get status
	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, status)

	// Should be available (mock returns available)
	assert.True(t, status.Available)
	assert.Equal(t, SNMPServiceName, status.ServiceName)
	assert.Equal(t, SNMPServiceType, status.ServiceType)
	assert.Greater(t, status.ResponseTime, int64(0))

	// Message should contain JSON with targets info
	assert.NotEmpty(t, status.Message)

	var payload struct {
		Available    bool                          `json:"available"`
		ResponseTime int64                         `json:"response_time"`
		Targets      map[string]snmp.TargetStatus  `json:"targets"`
	}
	err = json.Unmarshal(status.Message, &payload)
	require.NoError(t, err)
	assert.True(t, payload.Available)
}

// TestSNMPAgentIntegration_SNMPv3Config tests applying SNMPv3 configuration.
func TestSNMPAgentIntegration_SNMPv3Config(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		Logger:         log,
		TestConfig:     snmp.DefaultConfig(),
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Apply SNMPv3 config
	v3Config := &proto.SNMPConfig{
		Enabled: true,
		Targets: []*proto.SNMPTargetConfig{
			{
				Name:                "v3-target",
				Host:                "192.168.1.100",
				Port:                161,
				Version:             proto.SNMPVersion_SNMP_VERSION_V3,
				PollIntervalSeconds: 60,
				TimeoutSeconds:      5,
				Retries:             3,
				V3Auth: &proto.SNMPv3Auth{
					Username:      "admin",
					SecurityLevel: proto.SNMPSecurityLevel_SNMP_SECURITY_LEVEL_AUTH_PRIV,
					AuthProtocol:  proto.SNMPAuthProtocol_SNMP_AUTH_PROTOCOL_SHA,
					AuthPassword:  "authpass123",
					PrivProtocol:  proto.SNMPPrivProtocol_SNMP_PRIV_PROTOCOL_AES,
					PrivPassword:  "privpass456",
				},
				Oids: []*proto.SNMPOIDConfig{
					{Oid: ".1.3.6.1.2.1.1.1.0", Name: "sysDescr", DataType: proto.SNMPDataType_SNMP_DATA_TYPE_STRING},
				},
			},
		},
	}

	err = svc.ApplyProtoConfig(ctx, v3Config)
	require.NoError(t, err)

	assert.True(t, svc.IsEnabled())
	assert.Equal(t, "remote", svc.GetConfigSource())
}

// TestSNMPAgentIntegration_ConfigFileReload tests that local config file
// changes are detected and reloaded.
func TestSNMPAgentIntegration_ConfigFileReload(t *testing.T) {
	tmpDir := t.TempDir()
	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create initial config file
	initialConfig := `{
		"enabled": true,
		"targets": [
			{
				"name": "initial-target",
				"host": "127.0.0.1",
				"port": 161,
				"version": "2c",
				"community": "public",
				"timeout": 1,
				"oids": [{"oid": ".1.3.6.1.2.1.1.1.0", "name": "sysDescr", "type": "string"}]
			}
		]
	}`
	configPath := tmpDir + "/snmp.json"
	err := os.WriteFile(configPath, []byte(initialConfig), 0644)
	require.NoError(t, err)

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		ConfigDir:      tmpDir,
		Logger:         log,
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	initialHash := svc.GetConfigHash()
	assert.NotEmpty(t, initialHash)

	// Update config file with different content
	updatedConfig := `{
		"enabled": true,
		"targets": [
			{
				"name": "updated-target",
				"host": "10.0.0.1",
				"port": 161,
				"version": "2c",
				"community": "newcommunity",
				"timeout": 2,
				"oids": [
					{"oid": ".1.3.6.1.2.1.1.1.0", "name": "sysDescr", "type": "string"},
					{"oid": ".1.3.6.1.2.1.1.3.0", "name": "sysUpTime", "type": "timeticks"}
				]
			}
		]
	}`
	err = os.WriteFile(configPath, []byte(updatedConfig), 0644)
	require.NoError(t, err)

	// Trigger a config check manually (normally done by refresh loop)
	svc.checkConfigUpdate(ctx)

	// Hash should have changed
	newHash := svc.GetConfigHash()
	assert.NotEqual(t, initialHash, newHash, "config hash should change after file update")
}

// TestSNMPAgentIntegration_NilProtoConfig tests handling of nil proto config.
func TestSNMPAgentIntegration_NilProtoConfig(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		Logger:         log,
		TestConfig:     snmp.DefaultConfig(),
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Applying nil config should return error
	err = svc.ApplyProtoConfig(ctx, nil)
	assert.Error(t, err)
}

// TestSNMPAgentIntegration_ConcurrentStatusCalls tests concurrent GetStatus calls.
func TestSNMPAgentIntegration_ConcurrentStatusCalls(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	cfg := snmp.DefaultConfig()
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
		Logger:         log,
		TestConfig:     cfg,
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Make concurrent GetStatus calls
	done := make(chan bool, 10)
	for i := 0; i < 10; i++ {
		go func() {
			status, err := svc.GetStatus(ctx)
			assert.NoError(t, err)
			assert.NotNil(t, status)
			done <- true
		}()
	}

	// Wait for all goroutines
	for i := 0; i < 10; i++ {
		select {
		case <-done:
			// OK
		case <-time.After(5 * time.Second):
			t.Fatal("timeout waiting for concurrent status calls")
		}
	}
}

// TestSNMPAgentIntegration_ConcurrentConfigUpdates tests concurrent config updates.
func TestSNMPAgentIntegration_ConcurrentConfigUpdates(t *testing.T) {
	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSNMPAgentService(SNMPAgentServiceConfig{
		AgentID:        "test-agent",
		Logger:         log,
		TestConfig:     snmp.DefaultConfig(),
		ServiceFactory: &mockSNMPServiceFactory{},
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Make concurrent ApplyProtoConfig calls
	done := make(chan bool, 5)
	for i := 0; i < 5; i++ {
		go func(idx int) {
			config := &proto.SNMPConfig{
				Enabled: true,
				Targets: []*proto.SNMPTargetConfig{
					{
						Name:                "target",
						Host:                "10.0.0.1",
						Port:                161,
						Version:             proto.SNMPVersion_SNMP_VERSION_V2C,
						Community:           "public",
						PollIntervalSeconds: uint32(60 + idx), // Slightly different to cause hash changes
						TimeoutSeconds:      5,
						Retries:             3,
						Oids: []*proto.SNMPOIDConfig{
							{Oid: ".1.3.6.1.2.1.1.1.0", Name: "sysDescr", DataType: proto.SNMPDataType_SNMP_DATA_TYPE_STRING},
						},
					},
				},
			}
			// Errors are OK here - concurrent updates may race
			_ = svc.ApplyProtoConfig(ctx, config)
			done <- true
		}(i)
	}

	// Wait for all goroutines
	for i := 0; i < 5; i++ {
		select {
		case <-done:
			// OK
		case <-time.After(5 * time.Second):
			t.Fatal("timeout waiting for concurrent config updates")
		}
	}

	// Service should still be functional
	assert.True(t, svc.IsEnabled())
	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, status)
}
