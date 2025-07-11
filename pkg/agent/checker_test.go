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
	"sort"
	"testing"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestProcessChecker_ValidateProcessName(t *testing.T) {
	tests := []struct {
		name      string
		process   string
		wantError bool
	}{
		{
			name:      "valid process name",
			process:   "nginx",
			wantError: false,
		},
		{
			name:      "valid process name with hyphen",
			process:   "my-service",
			wantError: false,
		},
		{
			name:      "valid process name with underscore",
			process:   "my_service",
			wantError: false,
		},
		{
			name:      "invalid characters",
			process:   "my service!", // space and !
			wantError: true,
		},
		{
			name:      "empty name",
			process:   "",
			wantError: true,
		},
		{
			name:      "too long",
			process:   string(make([]byte, maxProcessNameLength+1)),
			wantError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			checker := &ProcessChecker{
				ProcessName: tt.process,
			}

			err := checker.validateProcessName()
			if tt.wantError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestNewPortChecker(t *testing.T) {
	tests := []struct {
		name      string
		details   string
		wantHost  string
		wantPort  int
		wantError bool
	}{
		{
			name:      "valid host:port",
			details:   "localhost:8080",
			wantHost:  "localhost",
			wantPort:  8080,
			wantError: false,
		},
		{
			name:      "valid IP:port",
			details:   "127.0.0.1:80",
			wantHost:  "127.0.0.1",
			wantPort:  80,
			wantError: false,
		},
		{
			name:      "empty details",
			details:   "",
			wantError: true,
		},
		{
			name:      "invalid format",
			details:   "localhost",
			wantError: true,
		},
		{
			name:      "invalid port",
			details:   "localhost:abc",
			wantError: true,
		},
		{
			name:      "port out of range (too high)",
			details:   "localhost:65536",
			wantError: true,
		},
		{
			name:      "port out of range (negative)",
			details:   "localhost:-1",
			wantError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			checker, err := NewPortChecker(tt.details)
			if tt.wantError {
				require.Error(t, err)
				assert.Nil(t, checker)

				return
			}

			require.NoError(t, err)
			require.NotNil(t, checker)
			assert.Equal(t, tt.wantHost, checker.Host)
			assert.Equal(t, tt.wantPort, checker.Port)
		})
	}
}

func TestIPv4Sorter(t *testing.T) {
	tests := []struct {
		name     string
		input    []string
		expected []string
	}{
		{
			name: "mixed IPs",
			input: []string{
				"192.168.1.2",
				"192.168.1.1",
				"10.0.0.1",
				"172.16.0.1",
			},
			expected: []string{
				"10.0.0.1",
				"172.16.0.1",
				"192.168.1.1",
				"192.168.1.2",
			},
		},
		{
			name: "same subnet",
			input: []string{
				"192.168.1.10",
				"192.168.1.2",
				"192.168.1.1",
			},
			expected: []string{
				"192.168.1.1",
				"192.168.1.2",
				"192.168.1.10",
			},
		},
		{
			name: "invalid IPs handled",
			input: []string{
				"192.168.1.1",
				"invalid",
				"192.168.1.2",
				"bad.ip",
			},
			expected: []string{
				"bad.ip",
				"invalid",
				"192.168.1.1",
				"192.168.1.2",
			},
		},
		{
			name: "mixed valid and invalid",
			input: []string{
				"192.168.1.1",
				"invalid2",
				"10.0.0.1",
				"invalid1",
			},
			expected: []string{
				"invalid1",
				"invalid2",
				"10.0.0.1",
				"192.168.1.1",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			sorter := IPSorter(tt.input)
			require.Equal(t, len(tt.input), sorter.Len())

			// Sort the IPs
			sort.Sort(sorter)

			// Verify the sort result
			assert.Equal(t, tt.expected, []string(sorter), "Incorrect sort order")

			// Test Swap functionality
			if len(sorter) >= 2 {
				orig0, orig1 := sorter[0], sorter[1]
				sorter.Swap(0, 1)
				assert.Equal(t, orig0, sorter[1])
				assert.Equal(t, orig1, sorter[0])
			}
		})
	}
}

func TestExternalChecker(t *testing.T) {
	// Create a temporary directory for certificates
	tmpDir, err := os.MkdirTemp("", "serviceradar-test")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	// Generate test certificates
	err = grpc.GenerateTestCertificates(tmpDir)
	require.NoError(t, err)

	// Define a mock security config for testing
	security := &models.SecurityConfig{
		Mode:    "mtls",
		CertDir: tmpDir,
		Role:    models.RoleAgent,
		TLS: models.TLSConfig{
			CertFile: filepath.Join(tmpDir, "client.pem"),
			KeyFile:  filepath.Join(tmpDir, "client-key.pem"),
			CAFile:   filepath.Join(tmpDir, "root.pem"),
		},
	}

	tests := []struct {
		name            string
		serviceName     string
		grpcServiceName string
		serviceType     string
		address         string
		wantErr         bool
	}{
		{
			name:            "invalid address",
			serviceName:     "test-service",
			serviceType:     "grpc",
			grpcServiceName: "monitoring.AgentService",
			address:         "invalid:address",
			wantErr:         true,
		},
		{
			name:            "empty address",
			serviceName:     "test-service",
			grpcServiceName: "monitoring.AgentService",
			serviceType:     "grpc",
			address:         "",
			wantErr:         true,
		},
		// Note: We can't easily test a valid gRPC connection here without a running server,
		// so we're limited to error cases unless we mock or set up a test server.
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx := context.Background()

			checker, err := NewExternalChecker(ctx, tt.serviceName, tt.serviceType, tt.address, tt.grpcServiceName, security, createTestLogger())
			if tt.wantErr {
				require.Error(t, err)
				assert.Nil(t, checker)

				return
			}

			require.NoError(t, err)
			assert.NotNil(t, checker)

			// Test Close
			if checker != nil {
				err = checker.Close()
				assert.NoError(t, err)
			}
		})
	}
}

func TestSNMPChecker(t *testing.T) {
	// Create a temporary directory for certificates
	tmpDir, err := os.MkdirTemp("", "serviceradar-test")
	require.NoError(t, err)
	defer os.RemoveAll(tmpDir)

	// Generate test certificates
	err = grpc.GenerateTestCertificates(tmpDir)
	require.NoError(t, err)

	// Define a mock security config for testing
	security := &models.SecurityConfig{
		Mode:    "mtls",
		CertDir: tmpDir,
		Role:    models.RoleAgent,
		TLS: models.TLSConfig{
			CertFile: filepath.Join(tmpDir, "client.pem"),
			KeyFile:  filepath.Join(tmpDir, "client-key.pem"),
			CAFile:   filepath.Join(tmpDir, "root.pem"),
		},
	}

	tests := []struct {
		name    string
		address string
		wantErr bool
	}{
		{
			name:    "empty address",
			address: "",
			wantErr: true,
		},
		{
			name:    "invalid address",
			address: "invalid:address",
			wantErr: true,
		},
		// Note: Testing a valid SNMP connection requires a mock server or real SNMP endpoint,
		// which is beyond this test scope without additional setup.
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			checker, err := NewSNMPChecker(context.Background(), tt.address, security, createTestLogger())
			if tt.wantErr {
				require.Error(t, err)
				assert.Nil(t, checker)

				return
			}

			require.NoError(t, err)
			assert.NotNil(t, checker)
		})
	}
}
