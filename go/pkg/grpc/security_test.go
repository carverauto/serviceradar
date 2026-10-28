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
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
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

func generateTestCAPEM(t *testing.T) (*x509.Certificate, *ecdsa.PrivateKey, []byte) {
	t.Helper()

	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)

	now := time.Now().UTC()
	caTpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "ServiceRadar Synthetic Test CA"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	caDER, err := x509.CreateCertificate(rand.Reader, caTpl, caTpl, &caKey.PublicKey, caKey)
	require.NoError(t, err)

	caCert, err := x509.ParseCertificate(caDER)
	require.NoError(t, err)

	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})
	return caCert, caKey, caPEM
}

func generateTestLeafPEM(t *testing.T, caCert *x509.Certificate, caKey *ecdsa.PrivateKey, serial int64, notBefore, notAfter time.Time) ([]byte, []byte) {
	t.Helper()

	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)

	leafTpl := &x509.Certificate{
		SerialNumber: big.NewInt(serial),
		Subject:      pkix.Name{CommonName: "agent-synth-1.default.serviceradar"},
		NotBefore:    notBefore,
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"agent-synth-1.default.serviceradar"},
	}

	leafDER, err := x509.CreateCertificate(rand.Reader, leafTpl, caCert, &leafKey.PublicKey, caKey)
	require.NoError(t, err)

	pkcs8Bytes, err := x509.MarshalPKCS8PrivateKey(leafKey)
	require.NoError(t, err)

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8Bytes})
	return certPEM, keyPEM
}

func TestMTLSProviderHotReloadAndExpiryCheck(t *testing.T) {
	tempDir := t.TempDir()
	caCert, caKey, caPEM := generateTestCAPEM(t)
	now := time.Now().UTC()

	cert1PEM, key1PEM := generateTestLeafPEM(t, caCert, caKey, 1001, now.Add(-time.Hour), now.Add(2*time.Hour))
	cert2PEM, key2PEM := generateTestLeafPEM(t, caCert, caKey, 1002, now.Add(-time.Minute), now.Add(4*time.Hour))

	certPath := filepath.Join(tempDir, "component.pem")
	keyPath := filepath.Join(tempDir, "component-key.pem")
	caPath := filepath.Join(tempDir, "root.pem")

	require.NoError(t, os.WriteFile(caPath, caPEM, 0o644))
	require.NoError(t, os.WriteFile(certPath, cert1PEM, 0o644))
	require.NoError(t, os.WriteFile(keyPath, key1PEM, 0o600))

	cfg := &models.SecurityConfig{
		Mode:    SecurityModeMTLS,
		Role:    models.RoleAgent,
		CertDir: tempDir,
		TLS: models.TLSConfig{
			CertFile: "component.pem",
			KeyFile:  "component-key.pem",
			CAFile:   "root.pem",
		},
	}

	provider, err := NewMTLSProvider(cfg, createTestLogger(t))
	require.NoError(t, err)
	require.NotNil(t, provider.ClientLeaf())
	assert.Equal(t, int64(1001), provider.ClientLeaf().SerialNumber.Int64())

	require.NoError(t, os.WriteFile(keyPath, key2PEM, 0o600))
	require.NoError(t, os.WriteFile(certPath, cert2PEM, 0o644))
	require.NoError(t, provider.Reload())

	require.NotNil(t, provider.ClientLeaf())
	assert.Equal(t, int64(1002), provider.ClientLeaf().SerialNumber.Int64())

	clientCert, err := provider.getClientCertificate(nil)
	require.NoError(t, err)
	assert.Equal(t, int64(1002), clientCert.Leaf.SerialNumber.Int64())

	// Advance synthetic clock past NotAfter and verify pre-dial and handshake checks fail with ErrClientCertificateExpired.
	provider.SetNowFunc(func() time.Time { return now.Add(5 * time.Hour) })

	_, err = provider.GetClientCredentials(context.Background())
	require.ErrorIs(t, err, ErrClientCertificateExpired)
	assert.Contains(t, err.Error(), "local mTLS client certificate expired")
	assert.Contains(t, err.Error(), "re-enroll required")
}

func TestMTLSProviderStartupSelfHealFromComponentBundle(t *testing.T) {
	tempDir := t.TempDir()
	caCert, caKey, caPEM := generateTestCAPEM(t)
	now := time.Now().UTC()

	oldCertPEM, _ := generateTestLeafPEM(t, caCert, caKey, 2001, now.Add(-time.Hour), now.Add(2*time.Hour))
	newCertPEM, newKeyPEM := generateTestLeafPEM(t, caCert, caKey, 2002, now.Add(-time.Minute), now.Add(4*time.Hour))

	certPath := filepath.Join(tempDir, "component.pem")
	keyPath := filepath.Join(tempDir, "component-key.pem")
	caPath := filepath.Join(tempDir, "root.pem")
	bundlePath := filepath.Join(tempDir, "component-bundle.pem")

	// Simulate a crash mid-write: component-bundle.pem has the new matching pair,
	// component-key.pem was updated to newKeyPEM, but component.pem still has oldCertPEM.
	bundleContent := "# Component Certificate\n" + string(newCertPEM) + "# Component Private Key\n" + string(newKeyPEM) + "# CA Chain\n" + string(caPEM)
	require.NoError(t, os.WriteFile(caPath, caPEM, 0o644))
	require.NoError(t, os.WriteFile(bundlePath, []byte(bundleContent), 0o600))
	require.NoError(t, os.WriteFile(keyPath, newKeyPEM, 0o600))
	require.NoError(t, os.WriteFile(certPath, oldCertPEM, 0o644))

	cfg := &models.SecurityConfig{
		Mode:    SecurityModeMTLS,
		Role:    models.RoleAgent,
		CertDir: tempDir,
		TLS: models.TLSConfig{
			CertFile: "component.pem",
			KeyFile:  "component-key.pem",
			CAFile:   "root.pem",
		},
	}

	provider, err := NewMTLSProvider(cfg, createTestLogger(t))
	require.NoError(t, err)
	require.NotNil(t, provider.ClientLeaf())
	assert.Equal(t, int64(2002), provider.ClientLeaf().SerialNumber.Int64())

	// Verify component-bundle.pem was retained so a second crash during startup repair self-heals again.
	_, err = os.Stat(bundlePath)
	require.NoError(t, err)

	// Corrupt component.pem again and verify a second startup self-heals deterministically.
	require.NoError(t, os.WriteFile(certPath, oldCertPEM, 0o644))
	provider2, err := NewMTLSProvider(cfg, createTestLogger(t))
	require.NoError(t, err)
	assert.Equal(t, int64(2002), provider2.ClientLeaf().SerialNumber.Int64())
}
