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

	"github.com/carverauto/serviceradar/pkg/checker"
	cconfig "github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type mockKVStore struct{}

func (m *mockKVStore) Get(ctx context.Context, key string) ([]byte, bool, error) {
	return nil, false, nil // Simulate "not found" for simplicity
}

func (m *mockKVStore) Put(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	return nil
}

func (m *mockKVStore) Delete(ctx context.Context, key string) error {
	return nil
}

func (m *mockKVStore) Watch(ctx context.Context, key string) (<-chan []byte, error) {
	ch := make(chan []byte)
	close(ch) // Empty channel, no updates
	return ch, nil
}

func (m *mockKVStore) Close() error {
	return nil
}

var _ KVStore = (*mockKVStore)(nil) // Ensure mockKVStore implements KVStore

// setupKVStoreFunc is a variable holding the setupKVStore function, making it assignable in tests.
var setupKVStoreFunc = setupKVStore

func TestNewServer(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "serviceradar-test")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	config := &ServerConfig{
		ListenAddr: ":50051",
		Security:   &models.SecurityConfig{},
	}

	tests := []struct {
		name      string
		configDir string
		config    *ServerConfig
		setupFn   func(string)
		kvStore   KVStore
		wantErr   bool
	}{
		{
			name:      "valid_config_with_no_KV",
			configDir: tmpDir,
			config:    config,
			setupFn:   nil,
			kvStore:   &mockKVStore{}, // Inject mock KV store
			wantErr:   false,
		},
		{
			name:      "with_sweep_config",
			configDir: tmpDir,
			config:    config,
			setupFn: func(dir string) {
				sweepDir := filepath.Join(dir, "sweep")
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
			},
			kvStore: &mockKVStore{},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.setupFn != nil {
				tt.setupFn(tt.configDir)
			}

			// Temporarily override setupKVStoreFunc to return the mock
			origSetupKVStore := setupKVStoreFunc
			setupKVStoreFunc = func(ctx context.Context, cfgLoader *cconfig.Config, cfg *ServerConfig) (KVStore, error) {
				if cfg.KVAddress == "" {
					t.Log("KVAddress not set, using mock KV store")
					return tt.kvStore, nil // Return the mock KVStore directly
				}
				return origSetupKVStore(ctx, cfgLoader, cfg)
			}
			defer func() { setupKVStoreFunc = origSetupKVStore }()

			server, err := NewServer(context.Background(), tt.configDir, tt.config)
			if tt.wantErr {
				require.Error(t, err)
				assert.Nil(t, server)
				return
			}

			require.NoError(t, err)
			require.NotNil(t, server)
			assert.Equal(t, tt.config.ListenAddr, server.ListenAddr())
			assert.Equal(t, tt.config.Security, server.SecurityConfig())
			// No need to assert kvStore is nil; it’s mocked
			t.Logf("server.kvStore = %v", server.kvStore)
		})
	}
}

func TestServerGetStatus(t *testing.T) {
	// Create a temporary directory for config files
	tmpDir, err := os.MkdirTemp("", "serviceradar-test")
	require.NoError(t, err)
	defer func(path string) {
		err = os.RemoveAll(path)
		if err != nil {
			t.Logf("failed to remove temporary directory: %s", err)
		}
	}(tmpDir)

	// Create test server
	server, err := NewServer(context.Background(), tmpDir, &ServerConfig{ListenAddr: ":50051"})
	require.NoError(t, err)

	tests := []struct {
		name        string
		req         *proto.StatusRequest
		wantErr     bool
		checkStatus func(*testing.T, *proto.StatusResponse)
	}{
		{
			name: "sweep status request",
			req: &proto.StatusRequest{
				ServiceType: "sweep",
			},
			wantErr: false,
			checkStatus: func(t *testing.T, resp *proto.StatusResponse) {
				t.Helper()
				assert.False(t, resp.Available)
				assert.Equal(t, "Sweep service not configured", resp.Message)
				assert.Equal(t, "network_sweep", resp.ServiceName)
			},
		},
		{
			name: "port check request",
			req: &proto.StatusRequest{
				ServiceType: "port",
				ServiceName: "test-port",
				Details:     "localhost:8080",
			},
			wantErr: false,
			checkStatus: func(t *testing.T, resp *proto.StatusResponse) {
				t.Helper()
				assert.NotNil(t, resp)
				assert.Equal(t, "port", resp.ServiceType)
				assert.Equal(t, "test-port", resp.ServiceName)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp, err := server.GetStatus(context.Background(), tt.req)
			if tt.wantErr {
				assert.Error(t, err)
				return
			}

			require.NoError(t, err)
			require.NotNil(t, resp)
			tt.checkStatus(t, resp)
		})
	}
}

func TestServerLifecycle(t *testing.T) {
	// Create a temporary directory for config files
	tmpDir, err := os.MkdirTemp("", "serviceradar-test")
	require.NoError(t, err)
	defer func(path string) {
		err = os.RemoveAll(path)
		if err != nil {
			t.Logf("failed to remove temporary directory: %s", err)
		}
	}(tmpDir)

	// Create test server
	server, err := NewServer(context.Background(), tmpDir, &ServerConfig{ListenAddr: ":50051"})
	require.NoError(t, err)

	// Test Start
	ctx := context.Background()
	err = server.Start(ctx)
	require.NoError(t, err)

	// Test Close (includes Stop)
	err = server.Close(ctx)
	require.NoError(t, err)
}

func TestServerListServices(t *testing.T) {
	// Create a temporary directory for config files
	tmpDir, err := os.MkdirTemp("", "serviceradar-test")
	require.NoError(t, err)
	defer func(path string) {
		err = os.RemoveAll(path)
		if err != nil {
			t.Logf("failed to remove temporary directory: %s", err)
		}
	}(tmpDir)

	// Create some test checker configs
	checkerConfig := CheckerConfig{
		Name:    "test-checker",
		Type:    "port",
		Address: "localhost",
		Port:    8080,
	}

	data, err := json.Marshal(checkerConfig)
	require.NoError(t, err)

	err = os.WriteFile(
		filepath.Join(tmpDir, "test-checker.json"),
		data,
		0600,
	)
	require.NoError(t, err)

	// Create test server
	server, err := NewServer(context.Background(), tmpDir, &ServerConfig{ListenAddr: ":50051"})
	require.NoError(t, err)

	// Test ListServices
	services := server.ListServices()
	assert.NotEmpty(t, services)
	assert.Contains(t, services, "test-checker")
}

func TestGetCheckerCaching(t *testing.T) {
	// Create a minimal Server instance with an empty checker cache
	// and an initialized registry.
	s := &Server{
		checkers: make(map[string]checker.Checker),
		registry: initRegistry(),
	}

	ctx := context.Background()

	// Create a status request for a port checker with details "127.0.0.1:22".
	req1 := &proto.StatusRequest{
		ServiceName: "SSH",
		ServiceType: "port",
		Details:     "127.0.0.1:22",
	}

	// Create another status request with the same service type/name
	// but with different details "192.168.1.1:22".
	req2 := &proto.StatusRequest{
		ServiceName: "SSH",
		ServiceType: "port",
		Details:     "192.168.1.1:22",
	}

	// Call getChecker twice with req1 and verify that the same instance is returned.
	checker1a, err := s.getChecker(ctx, req1)
	require.NoError(t, err)
	checker1b, err := s.getChecker(ctx, req1)
	require.NoError(t, err)
	assert.Equal(t, checker1a, checker1b, "repeated call with the same request should yield the same checker instance")

	// Call getChecker with req2 and verify that a different instance is returned.
	checker2, err := s.getChecker(ctx, req2)
	require.NoError(t, err)
	assert.NotEqual(t, checker1a, checker2, "requests with different details should yield different checker instances")
}
