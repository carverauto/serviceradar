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

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/sysmon"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNewSysmonService(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		config    SysmonServiceConfig
		wantErr   bool
		checkFunc func(*testing.T, *SysmonService)
	}{
		{
			name: "default config",
			config: SysmonServiceConfig{
				AgentID: "test-agent",
			},
			wantErr: false,
			checkFunc: func(t *testing.T, s *SysmonService) {
				assert.Equal(t, "test-agent", s.agentID)
				assert.NotNil(t, s.logger)
			},
		},
		{
			name: "with partition",
			config: SysmonServiceConfig{
				AgentID:   "test-agent",
				Partition: "us-west-2",
				Logger:    logger.NewTestLogger(),
			},
			wantErr: false,
			checkFunc: func(t *testing.T, s *SysmonService) {
				assert.Equal(t, "test-agent", s.agentID)
				assert.Equal(t, "us-west-2", s.partition)
			},
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			svc, err := NewSysmonService(tt.config)
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

func TestSysmonServiceName(t *testing.T) {
	t.Parallel()
	svc, err := NewSysmonService(SysmonServiceConfig{AgentID: "test"})
	require.NoError(t, err)
	assert.Equal(t, SysmonServiceName, svc.Name())
}

func TestSysmonServiceLifecycle(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSysmonService(SysmonServiceConfig{
		AgentID: "test-agent",
		Logger:  log,
	})
	require.NoError(t, err)

	// Start should succeed
	err = svc.Start(ctx)
	require.NoError(t, err)

	// Wait for collector to gather some data
	time.Sleep(100 * time.Millisecond)

	// Should be enabled now
	assert.True(t, svc.IsEnabled())

	// GetStatus should return data
	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, status)
	assert.True(t, status.Available)
	assert.Equal(t, SysmonServiceName, status.ServiceName)
	assert.Equal(t, SysmonServiceType, status.ServiceType)

	// Stop should succeed
	err = svc.Stop(ctx)
	require.NoError(t, err)

	// Should no longer be enabled
	assert.False(t, svc.IsEnabled())
}

func TestSysmonServiceGetStatus_NotStarted(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	svc, err := NewSysmonService(SysmonServiceConfig{
		AgentID: "test-agent",
		Logger:  logger.NewTestLogger(),
	})
	require.NoError(t, err)

	// GetStatus before start should return unavailable
	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, status)
	assert.False(t, status.Available)
	assert.Equal(t, SysmonServiceName, status.ServiceName)
}

func TestSysmonServiceGetStatusPayload(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSysmonService(SysmonServiceConfig{
		AgentID: "test-agent",
		Logger:  log,
	})
	require.NoError(t, err)

	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Wait for metrics collection
	time.Sleep(200 * time.Millisecond)

	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.NotNil(t, status)
	require.True(t, status.Available)

	// Parse the message to verify structure
	var payload struct {
		Available    bool                 `json:"available"`
		ResponseTime int64                `json:"response_time"`
		Status       *sysmon.MetricSample `json:"status"`
	}
	err = json.Unmarshal(status.Message, &payload)
	require.NoError(t, err)

	assert.True(t, payload.Available)
	assert.Greater(t, payload.ResponseTime, int64(0))
	require.NotNil(t, payload.Status)
	assert.NotEmpty(t, payload.Status.HostID)
	assert.NotEmpty(t, payload.Status.Timestamp)
}

func TestSysmonServiceReconfigure(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSysmonService(SysmonServiceConfig{
		AgentID: "test-agent",
		Logger:  log,
	})
	require.NoError(t, err)

	// Reconfigure before start should fail
	err = svc.Reconfigure(&sysmon.ParsedConfig{
		Enabled:        true,
		SampleInterval: 5 * time.Second,
		CollectCPU:     true,
	})
	assert.Error(t, err)

	// Start the service
	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Reconfigure after start should succeed
	newConfig := &sysmon.ParsedConfig{
		Enabled:        true,
		SampleInterval: 10 * time.Second,
		CollectCPU:     true,
		CollectMemory:  true,
		CollectDisk:    false,
	}
	err = svc.Reconfigure(newConfig)
	require.NoError(t, err)
}

func TestSysmonServiceGetLatestSample(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSysmonService(SysmonServiceConfig{
		AgentID: "test-agent",
		Logger:  log,
	})
	require.NoError(t, err)

	// Before start, should return nil
	sample := svc.GetLatestSample()
	assert.Nil(t, sample)

	// Start the service
	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// Use GetStatus to trigger a collection if Latest is nil
	// This is the real-world usage pattern
	status, err := svc.GetStatus(ctx)
	require.NoError(t, err)
	require.True(t, status.Available)

	// After GetStatus, Latest should return a sample
	finalSample := svc.GetLatestSample()
	require.NotNil(t, finalSample, "Sample should be available after GetStatus")
	assert.NotEmpty(t, finalSample.HostID)
	assert.NotEmpty(t, finalSample.Timestamp)
}

func TestSysmonServiceStartIdempotent(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSysmonService(SysmonServiceConfig{
		AgentID: "test-agent",
		Logger:  log,
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

func TestSysmonServiceStopIdempotent(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSysmonService(SysmonServiceConfig{
		AgentID: "test-agent",
		Logger:  log,
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

func TestSysmonServiceConfigSource(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	log := logger.NewTestLogger()

	svc, err := NewSysmonService(SysmonServiceConfig{
		AgentID: "test-agent",
		Logger:  log,
	})
	require.NoError(t, err)

	// Before start, config source should be empty
	assert.Empty(t, svc.GetConfigSource())
	assert.Empty(t, svc.GetConfigHash())

	// Start the service
	err = svc.Start(ctx)
	require.NoError(t, err)
	defer func() { _ = svc.Stop(ctx) }()

	// After start, should have a config source (likely "default" since no config files exist)
	source := svc.GetConfigSource()
	assert.NotEmpty(t, source)
	// Source should be one of: local:*, cache:*, or default
	assert.True(t, source == "default" ||
		len(source) > 6 && (source[:6] == "local:" || source[:6] == "cache:"),
		"unexpected config source: %s", source)

	// Should have a config hash
	hash := svc.GetConfigHash()
	assert.NotEmpty(t, hash)
	assert.Len(t, hash, 64) // SHA256 hex string is 64 characters
}

func TestComputeConfigHash(t *testing.T) {
	t.Parallel()

	cfg1 := sysmon.DefaultConfig()
	cfg2 := sysmon.DefaultConfig()
	cfg2.SampleInterval = "30s" // Different from default

	hash1 := computeConfigHash(cfg1)
	hash2 := computeConfigHash(cfg2)

	// Same config should produce same hash
	assert.Equal(t, hash1, computeConfigHash(cfg1))

	// Different configs should produce different hashes
	assert.NotEqual(t, hash1, hash2)

	// Hash should be 64 hex characters (SHA256)
	assert.Len(t, hash1, 64)
	assert.Len(t, hash2, 64)
}

func TestSysmonServiceConfigCaching(t *testing.T) {
	// Skip if we can't write to temp directory
	tmpDir := t.TempDir()

	ctx := context.Background()
	log := logger.NewTestLogger()

	// Create a config file in the temp directory
	configPath := tmpDir + "/sysmon.json"
	configData := `{
		"enabled": true,
		"sample_interval": "15s",
		"collect_cpu": true,
		"collect_memory": true,
		"collect_disk": false,
		"collect_network": false,
		"collect_processes": false
	}`
	err := os.WriteFile(configPath, []byte(configData), 0644)
	require.NoError(t, err)

	svc, err := NewSysmonService(SysmonServiceConfig{
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
