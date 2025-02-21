package grpc

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"
)

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
	generateTestCertificates(t, tmpDir)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	config := &models.SecurityConfig{
		Mode:    SecurityModeMTLS,
		CertDir: tmpDir,
	}

	t.Run("NewMTLSProvider", func(t *testing.T) {
		provider, err := NewMTLSProvider(config)
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
		provider, err := NewMTLSProvider(config)
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
		// Remove client certificates
		err := os.Remove(filepath.Join(tmpDir, "client.crt"))
		require.NoError(t, err)

		err = os.Remove(filepath.Join(tmpDir, "client.key"))
		require.NoError(t, err)

		provider, err := NewMTLSProvider(config)
		require.Error(t, err)
		assert.Nil(t, provider)
	})
}

// TestSpiffeProvider tests the SpiffeProvider implementation.
func TestSpiffeProvider(t *testing.T) {
	ctrl, ctx := gomock.WithContext(context.Background(), t)
	defer ctrl.Finish()

	// Skip if no SPIFFE workload API is available
	if _, err := os.Stat("/run/spire/sockets/agent.sock"); os.IsNotExist(err) {
		t.Skip("Skipping SPIFFE tests - no workload API available")
	}

	_, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	config := &models.SecurityConfig{
		Mode:           SecurityModeSpiffe,
		TrustDomain:    "example.org",
		WorkloadSocket: "unix:/run/spire/sockets/agent.sock",
	}

	t.Run("NewSpiffeProvider", func(t *testing.T) {
		provider, err := NewSpiffeProvider(ctx, config)
		if err != nil {
			// If we get a connection refused, skip the test
			if strings.Contains(err.Error(), "connection refused") {
				t.Skip("Skipping test - SPIFFE Workload API not responding")
			}
			// Otherwise, fail the test with the error
			t.Fatalf("Expected NewSpiffeProvider to succeed, got error: %v", err)
		}

		assert.NotNil(t, provider)

		if provider != nil {
			err := provider.Close()
			if err != nil {
				t.Fatalf("Expected Close to succeed, got error: %v", err)
				return
			}
		}
	})

	t.Run("InvalidTrustDomain", func(t *testing.T) {
		invalidConfig := &models.SecurityConfig{
			Mode:        SecurityModeSpiffe,
			TrustDomain: "invalid trust domain",
		}

		provider, err := NewSpiffeProvider(ctx, invalidConfig)
		require.Error(t, err)
		assert.Nil(t, provider)
	})
}

// TestNewSecurityProvider tests the factory function for creating security providers.
func TestNewSecurityProvider(t *testing.T) {
	tmpDir := t.TempDir()
	generateTestCertificates(t, tmpDir)

	tests := []struct {
		name        string
		config      *models.SecurityConfig
		expectError bool
	}{
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
				Role:       "poller",
			},
			expectError: false,
		},
		/*
			{
				name: "SPIFFE",
				config: &SecurityConfig{
					Mode:        SecurityModeSpiffe,
					TrustDomain: "example.org",
				},
				expectError: true, // Will fail without Workload API
			},
		*/
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

			provider, err := NewSecurityProvider(ctx, tt.config)
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

// generateTestCertificatesWithCFSSL uses cfssl to generate real test certificates.
func generateTestCertificatesWithCFSSL(t *testing.T, dir string) {
	t.Helper()

	// Write cfssl config
	cfssl := []byte(`{
        "signing": {
            "default": {
                "expiry": "24h"
            },
            "profiles": {
                "server": {
                    "usages": ["signing", "key encipherment", "server auth"],
                    "expiry": "24h"
                },
                "client": {
                    "usages": ["signing", "key encipherment", "client auth"],
                    "expiry": "24h"
                }
            }
        }
    }`)

	csr := []byte(`{
        "hosts": ["localhost", "127.0.0.1"],
        "key": {
            "algo": "ecdsa",
            "size": 256
        },
        "names": [{
            "O": "Test Organization"
        }]
    }`)

	cfssljsonPath := filepath.Join(dir, "cfssl.json")
	csrPath := filepath.Join(dir, "csr.json")

	require.NoError(t, os.WriteFile(cfssljsonPath, cfssl, 0600))
	require.NoError(t, os.WriteFile(csrPath, csr, 0600))

	// Generate CA
	cmd := exec.Command("cfssl", "genkey", "-initca", csrPath)
	cmd.Dir = dir
	output, err := cmd.CombinedOutput()
	require.NoError(t, err, "Failed to generate CA: %s", output)

	// Generate server cert
	cmd = exec.Command("cfssl", "gencert", "-ca", "ca.pem", "-ca-key", "ca-key.pem", "-config", "cfssl.json", "-profile", "server", csrPath)
	cmd.Dir = dir
	output, err = cmd.CombinedOutput()
	require.NoError(t, err, "Failed to generate server cert: %s", output)

	// Generate client cert
	cmd = exec.Command("cfssl", "gencert", "-ca", "ca.pem", "-ca-key", "ca-key.pem", "-config", "cfssl.json", "-profile", "client", csrPath)
	cmd.Dir = dir
	output, err = cmd.CombinedOutput()
	require.NoError(t, err, "Failed to generate client cert: %s", output)
}
