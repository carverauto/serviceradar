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

package grpc

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
)

func createTestLogger(_ *testing.T) logger.Logger {
	return logger.NewTestLogger()
}

// TestNoSecurityProvider tests the NoSecurityProvider implementation.
func TestNoSecurityProvider(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	provider := &NoSecurityProvider{}

	t.Run("GetClientCredentials", func(t *testing.T) {
		opt, err := provider.GetClientCredentials(ctx)
		require.NoError(t, err)
		require.NotNil(t, opt)
	})

	t.Run("GetServerCredentials", func(t *testing.T) {
		opt, err := provider.GetServerCredentials(ctx)
		require.NoError(t, err)
		require.NotNil(t, opt)

		// Create server with a timeout to avoid hanging
		s := grpc.NewServer(opt)
		defer s.Stop()

		assert.NotNil(t, s)
	})

	t.Run("Close", func(t *testing.T) {
		err := provider.Close()
		assert.NoError(t, err)
	})
}

func TestMTLSProvider(t *testing.T) {
	tmpDir := t.TempDir()

	err := GenerateTestCertificates(tmpDir)
	if err != nil {
		t.Fatalf("Failed to generate test certificates: %v", err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Define config with TLS fields for all subtests
	config := &models.SecurityConfig{
		Mode:    SecurityModeMTLS,
		CertDir: tmpDir,
		Role:    models.RoleGateway,
		TLS: models.TLSConfig{
			CertFile: filepath.Join(tmpDir, "server.pem"),
			KeyFile:  filepath.Join(tmpDir, "server-key.pem"),
			CAFile:   filepath.Join(tmpDir, "root.pem"),
		},
	}

	t.Run("NewMTLSProvider", func(t *testing.T) {
		provider, err := NewMTLSProvider(config, createTestLogger(t))

		require.NoError(t, err)
		require.NotNil(t, provider)
		assert.NotNil(t, provider.clientCreds)
		assert.NotNil(t, provider.serverCreds)

		defer func(provider *MTLSProvider) {
			err := provider.Close()
			if err != nil {
				t.Fatalf("Expected Close to succeed, got error: %v", err)
			}
		}(provider)
	})

	t.Run("GetClientCredentials", func(t *testing.T) {
		provider, err := NewMTLSProvider(config, createTestLogger(t))
		require.NoError(t, err)

		defer func(provider *MTLSProvider) {
			err = provider.Close()
			if err != nil {
				t.Fatalf("Expected Close to succeed, got error: %v", err)
			}
		}(provider)

		opt, err := provider.GetClientCredentials(ctx)
		require.NoError(t, err)
		require.NotNil(t, opt)
	})

	t.Run("MissingClientCerts", func(t *testing.T) {
		var err error

		noCertDir := filepath.Join(t.TempDir(), "no-client-certs")

		err = os.MkdirAll(noCertDir, 0755)
		require.NoError(t, err)

		// Copy only server and CA certs
		for _, file := range []string{"root.pem", "server.pem", "server-key.pem"} {
			var content []byte

			srcPath := filepath.Join(tmpDir, file)
			dstPath := filepath.Join(noCertDir, file)

			content, err = os.ReadFile(srcPath)
			require.NoError(t, err)

			err = os.WriteFile(dstPath, content, 0600)
			require.NoError(t, err)
		}

		noCertConfig := &models.SecurityConfig{
			Mode:    SecurityModeMTLS,
			CertDir: noCertDir,
			Role:    models.RoleGateway,
			// Intentionally omit TLS fields to test missing certs behavior
		}

		provider, err := NewMTLSProvider(noCertConfig, createTestLogger(t))
		require.Error(t, err)
		assert.Nil(t, provider)
	})
}

// TestNewSecurityProvider tests the factory function for creating security providers.
func TestNewSecurityProvider(t *testing.T) {
	tmpDir := t.TempDir()

	err := GenerateTestCertificates(tmpDir)
	if err != nil {
		t.Fatalf("Failed to generate test certificates: %v", err)

		return
	}

	tests := []struct {
		name        string
		config      *models.SecurityConfig
		expectError bool
	}{
		{
			name:        "NilConfig",
			config:      nil,
			expectError: true,
		},
		{
			name: "EmptyMode",
			config: &models.SecurityConfig{
				Mode: "",
			},
			expectError: true,
		},
		{
			name: "NoSecurity",
			config: &models.SecurityConfig{
				Mode: SecurityModeNone,
			},
			expectError: false,
		},
		{
			name: "MTLS",
			config: &models.SecurityConfig{
				Mode:       SecurityModeMTLS,
				CertDir:    tmpDir,
				ServerName: "localhost",
				Role:       "gateway",
				TLS: models.TLSConfig{
					CertFile: filepath.Join(tmpDir, "server.pem"),
					KeyFile:  filepath.Join(tmpDir, "server-key.pem"),
					CAFile:   filepath.Join(tmpDir, "root.pem"),
				},
			},
			expectError: false,
		},
		{
			name: "SPIFFE Mode Rejected",
			config: &models.SecurityConfig{
				Mode: "spiffe",
			},
			expectError: true,
		},
		{
			name: "Invalid Mode",
			config: &models.SecurityConfig{
				Mode: "invalid",
			},
			expectError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			provider, err := NewSecurityProvider(ctx, tt.config, createTestLogger(t))
			if tt.expectError {
				require.Error(t, err)
				assert.Nil(t, provider)

				return
			}

			require.NoError(t, err)
			assert.NotNil(t, provider)

			// Test basic provider operations if not expecting error
			opt, err := provider.GetClientCredentials(ctx)
			require.NoError(t, err)
			assert.NotNil(t, opt)

			err = provider.Close()
			assert.NoError(t, err)
		})
	}
}

func TestNewClientRequiresSecurityProvider(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	client, err := NewClient(ctx, ClientConfig{
		Address: "127.0.0.1:50051",
		Logger:  createTestLogger(t),
	})
	require.Error(t, err)
	require.ErrorIs(t, err, errSecurityProviderRequired)
	assert.Nil(t, client)
}

func TestNewSecurityProviderRejectsSPIFFE(t *testing.T) {
	for _, mode := range []models.SecurityMode{"spiffe", "SPIFFE"} {
		t.Run(string(mode), func(t *testing.T) {
			provider, err := NewSecurityProvider(context.Background(), &models.SecurityConfig{
				Mode: mode,
			}, createTestLogger(t))
			require.Error(t, err)
			require.ErrorIs(t, err, errUnknownSecurityMode)
			assert.Contains(t, err.Error(), "https://docs.serviceradar.cloud/docs/migrating-off-spire")
			assert.Nil(t, provider)
		})
	}
}
