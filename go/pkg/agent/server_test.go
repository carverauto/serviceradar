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
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	cconfig "github.com/carverauto/serviceradar/go/pkg/config"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

type mockService struct{}

func (*mockService) Start(context.Context) error       { return nil }
func (*mockService) Stop(context.Context) error        { return nil }
func (*mockService) Name() string                      { return "mock_sweep" }
func (*mockService) UpdateConfig(*models.Config) error { return nil }

func setupTempDir(t *testing.T) (tmpDir string, cleanup func()) {
	t.Helper()

	tmpDir, err := os.MkdirTemp("", "serviceradar-test")
	require.NoError(t, err)

	cleanup = func() {
		err := os.RemoveAll(tmpDir)
		if err != nil {
			t.Logf("Failed to remove temp dir %s: %v", tmpDir, err)
		}
	}

	return tmpDir, cleanup
}

func setupServerConfig() *ServerConfig {
	return &ServerConfig{
		AgentID:  "test-agent",
		Security: &models.SecurityConfig{},
	}
}

// In server_test.go

func TestNewServerBasic(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping: NewServer starts sysmon with real CPU sampling")
	}
	t.Parallel()

	tmpDir, cleanup := setupTempDir(t)
	defer cleanup()

	config := setupServerConfig()
	testLogger := createTestLogger()

	s := &Server{
		configDir: tmpDir,
		config:    config,
		services:  make([]Service, 0),
		errChan:   make(chan error, defaultErrChansize),
		done:      make(chan struct{}),
		logger:    testLogger,
	}

	s.createSweepService = func(_ context.Context, _ *SweepConfig) (Service, error) {
		return &mockService{}, nil
	}

	cfgLoader := cconfig.NewConfig(nil)
	err := s.loadConfigurations(context.Background(), cfgLoader)
	require.NoError(t, err)

	ctx := context.Background()
	server, err := NewServer(ctx, tmpDir, config, createTestLogger())

	require.NoError(t, err)
	require.NotNil(t, server)
	defer func() { _ = server.Close(ctx) }()

	assert.Equal(t, config.Security, server.SecurityConfig())
}

func TestNewServerWithSweepConfig(t *testing.T) {
	t.Parallel()

	tmpDir, cleanup := setupTempDir(t)
	defer cleanup()

	config := setupServerConfig()
	sweepDir := filepath.Join(tmpDir, "sweep")
	require.NoError(t, os.MkdirAll(sweepDir, 0755))

	sweepConfig := SweepConfig{
		Networks:   []string{"192.168.1.0/24"},
		Ports:      []int{80, 443},
		SweepModes: []models.SweepMode{models.ModeTCP},
		Interval:   Duration(time.Minute),
	}

	data, err := json.Marshal(sweepConfig)
	require.NoError(t, err)

	err = os.WriteFile(filepath.Join(sweepDir, "sweep.json"), data, 0600)
	require.NoError(t, err)

	testLogger := createTestLogger()
	s := &Server{
		configDir: tmpDir,
		config:    config,
		services:  make([]Service, 0),
		errChan:   make(chan error, defaultErrChansize),
		done:      make(chan struct{}),
		logger:    testLogger,
	}

	s.createSweepService = func(_ context.Context, sweepConfig *SweepConfig) (Service, error) {
		t.Logf("Using mock createSweepService for sweep config: %+v", sweepConfig)

		return &mockService{}, nil
	}

	cfgLoader := cconfig.NewConfig(nil)
	err = s.loadConfigurations(context.Background(), cfgLoader)
	require.NoError(t, err)

	assert.Equal(t, config.Security, s.SecurityConfig())
	assert.Len(t, s.services, 1)
	assert.Equal(t, "mock_sweep", s.services[0].Name())
}

func TestServerLifecycle(t *testing.T) {
	t.Parallel()

	if testing.Short() {
		t.Skip("skipping test in short mode - starts real services")
	}

	tmpDir, cleanup := setupTempDir(t)
	defer cleanup()

	server, err := NewServer(context.Background(), tmpDir, setupServerConfig(), createTestLogger())
	require.NoError(t, err)

	ctx := context.Background()
	err = server.Start(ctx)
	require.NoError(t, err)

	err = server.Close(ctx)
	require.NoError(t, err)
}
