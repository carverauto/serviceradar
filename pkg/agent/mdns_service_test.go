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

	"github.com/carverauto/serviceradar/pkg/agent/mdns"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func testMdnsConfig() *mdns.Config {
	return mdns.DefaultConfig()
}

func TestNewMdnsAgentService(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		config    MdnsAgentServiceConfig
		wantErr   bool
		checkFunc func(*testing.T, *MdnsAgentService)
	}{
		{
			name: "default config",
			config: MdnsAgentServiceConfig{
				AgentID: "test-agent",
			},
			wantErr: false,
			checkFunc: func(t *testing.T, s *MdnsAgentService) {
				t.Helper()
				assert.Equal(t, "test-agent", s.agentID)
				assert.NotNil(t, s.logger)
			},
		},
		{
			name: "with partition",
			config: MdnsAgentServiceConfig{
				AgentID:   "test-agent",
				Partition: "us-west-2",
				Logger:    logger.NewTestLogger(),
			},
			wantErr: false,
			checkFunc: func(t *testing.T, s *MdnsAgentService) {
				t.Helper()
				assert.Equal(t, "test-agent", s.agentID)
				assert.Equal(t, "us-west-2", s.partition)
			},
		},
		{
			name: "with test config",
			config: MdnsAgentServiceConfig{
				AgentID:    "test-agent",
				Logger:     logger.NewTestLogger(),
				TestConfig: testMdnsConfig(),
			},
			wantErr: false,
			checkFunc: func(t *testing.T, s *MdnsAgentService) {
				t.Helper()
				assert.NotNil(t, s.testConfig)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			svc, err := NewMdnsAgentService(tt.config)
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

func TestMdnsAgentServiceName(t *testing.T) {
	t.Parallel()
	svc, err := NewMdnsAgentService(MdnsAgentServiceConfig{AgentID: "test"})
	require.NoError(t, err)
	assert.Equal(t, MdnsServiceName, svc.Name())
}

func TestMdnsAgentServiceLifecycle(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	cfg := testMdnsConfig()
	cfg.Enabled = false

	svc, err := NewMdnsAgentService(MdnsAgentServiceConfig{
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
	assert.False(t, status.Available)
	assert.Equal(t, MdnsServiceName, status.ServiceName)
	assert.Equal(t, MdnsServiceType, status.ServiceType)

	// Stop should succeed
	err = svc.Stop(ctx)
	require.NoError(t, err)
}

func TestMdnsAgentServiceGetStatus_NotStarted(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	svc, err := NewMdnsAgentService(MdnsAgentServiceConfig{
		AgentID: "test-agent",
		Logger:  logger.NewTestLogger(),
	})
	require.NoError(t, err)

	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, status)
	assert.False(t, status.Available)
	assert.Equal(t, MdnsServiceName, status.ServiceName)
}

func TestMdnsAgentServiceStartIdempotent(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewMdnsAgentService(MdnsAgentServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testMdnsConfig(),
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)

	err = svc.Stop(ctx)
	require.NoError(t, err)
}

func TestMdnsAgentServiceStopIdempotent(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewMdnsAgentService(MdnsAgentServiceConfig{
		AgentID:    "test-agent",
		Logger:     log,
		TestConfig: testMdnsConfig(),
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)

	err = svc.Stop(ctx)
	require.NoError(t, err)

	err = svc.Stop(ctx)
	require.NoError(t, err)
}

func TestMdnsConfigHashComputation(t *testing.T) {
	t.Parallel()

	cfg1 := mdns.DefaultConfig()
	cfg2 := mdns.DefaultConfig()
	cfg2.Enabled = true

	hash1 := computeMdnsConfigHash(cfg1)
	hash2 := computeMdnsConfigHash(cfg2)

	assert.Equal(t, hash1, computeMdnsConfigHash(cfg1))
	assert.NotEqual(t, hash1, hash2)
	assert.Len(t, hash1, 64)
	assert.Len(t, hash2, 64)
}

func TestMdnsDefaultFallbackWhenLocalUnavailable(t *testing.T) {
	t.Parallel()

	tmpDir := t.TempDir()

	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewMdnsAgentService(MdnsAgentServiceConfig{
		AgentID:   "test-agent",
		ConfigDir: tmpDir,
		Logger:    log,
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	assert.False(t, svc.IsEnabled(), "default mDNS config should be disabled")

	source := svc.GetConfigSource()
	assert.Empty(t, source, "config source not set when mDNS is disabled")
}

func TestMdnsAgentServiceConfigCaching(t *testing.T) {
	t.Parallel()

	tmpDir := t.TempDir()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create a disabled config file in the temp directory
	configPath := tmpDir + "/mdns.json"
	configData := `{
		"enabled": false,
		"listen_addr": "0.0.0.0:5353",
		"nats_url": "nats://localhost:4222",
		"stream_name": "DISCOVERY",
		"subject": "discovery.raw.mdns",
		"multicast_groups": ["224.0.0.251"],
		"dedup_ttl_secs": 300,
		"dedup_max_entries": 100000,
		"dedup_cleanup_interval_secs": 60
	}`
	err := os.WriteFile(configPath, []byte(configData), 0644)
	require.NoError(t, err)

	svc, err := NewMdnsAgentService(MdnsAgentServiceConfig{
		AgentID:   "test-agent",
		ConfigDir: tmpDir,
		Logger:    log,
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// mDNS is disabled, so source won't be set (early return)
	assert.False(t, svc.IsEnabled())
}
