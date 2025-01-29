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
)

// TestNoSecurityProvider tests the NoSecurityProvider implementation
func TestNoSecurityProvider(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	provider := &NoSecurityProvider{}

	t.Run("GetClientCredentials", func(t *testing.T) {
		opt, err := provider.GetClientCredentials(ctx)
		require.NoError(t, err)
		require.NotNil(t, opt)

		// Check that it's a DialOption
		_, ok := opt.(grpc.DialOption)
		assert.True(t, ok)
	})

	t.Run("GetServerCredentials", func(t *testing.T) {
		opt, err := provider.GetServerCredentials(ctx)
		require.NoError(t, err)
		require.NotNil(t, opt)

		s := grpc.NewServer(opt)
		defer s.Stop()
		assert.NotNil(t, s)
	})

	t.Run("Close", func(t *testing.T) {
		err := provider.Close()
		assert.NoError(t, err)
	})
}

// TestTLSProvider tests the TLSProvider implementation
func TestTLSProvider(t *testing.T) {
	tmpDir := t.TempDir()
	err := generateAndWriteTestCertificates(t, tmpDir)
	require.NoError(t, err, "Failed to generate test certificates")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	config := &SecurityConfig{
		Mode:    SecurityModeTLS,
		CertDir: tmpDir,
	}

	t.Run("NewTLSProvider", func(t *testing.T) {
		provider, err := NewTLSProvider(config)
		require.NoError(t, err)
		require.NotNil(t, provider)
		assert.NotNil(t, provider.clientCreds)
		assert.NotNil(t, provider.serverCreds)
		defer provider.Close()
	})

	t.Run("GetClientCredentials", func(t *testing.T) {
		provider, err := NewTLSProvider(config)
		require.NoError(t, err)
		defer provider.Close()

		opt, err := provider.GetClientCredentials(ctx)
		require.NoError(t, err)
		require.NotNil(t, opt)

		// Verify it's a DialOption
		_, ok := opt.(grpc.DialOption)
		assert.True(t, ok)
	})

	t.Run("GetServerCredentials", func(t *testing.T) {
		provider, err := NewTLSProvider(config)
		require.NoError(t, err)
		defer provider.Close()

		opt, err := provider.GetServerCredentials(ctx)
		require.NoError(t, err)
		require.NotNil(t, opt)

		s := grpc.NewServer(opt)
		defer s.Stop()
		assert.NotNil(t, s)
	})

	t.Run("InvalidCertificates", func(t *testing.T) {
		invalidConfig := &SecurityConfig{
			Mode:    SecurityModeTLS,
			CertDir: "/nonexistent",
		}

		provider, err := NewTLSProvider(invalidConfig)
		assert.Error(t, err)
		assert.Nil(t, provider)
	})
}

// TestMTLSProvider tests the MTLSProvider implementation
func TestMTLSProvider(t *testing.T) {
	tmpDir := t.TempDir()
	err := generateAndWriteTestCertificates(t, tmpDir)
	require.NoError(t, err, "Failed to generate test certificates")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	config := &SecurityConfig{
		Mode:    SecurityModeMTLS,
		CertDir: tmpDir,
	}

	t.Run("NewMTLSProvider", func(t *testing.T) {
		provider, err := NewMTLSProvider(config)
		require.NoError(t, err)
		require.NotNil(t, provider)
		assert.NotNil(t, provider.clientCreds)
		assert.NotNil(t, provider.serverCreds)
		defer provider.Close()
	})

	t.Run("GetClientCredentials", func(t *testing.T) {
		provider, err := NewMTLSProvider(config)
		require.NoError(t, err)
		defer provider.Close()

		opt, err := provider.GetClientCredentials(ctx)
		require.NoError(t, err)
		require.NotNil(t, opt)

		// Verify it's a DialOption
		_, ok := opt.(grpc.DialOption)
		assert.True(t, ok)
	})

	t.Run("MissingClientCerts", func(t *testing.T) {
		// Create a new temporary directory without client certs
		emptyDir := t.TempDir()
		emptyConfig := &SecurityConfig{
			Mode:    SecurityModeMTLS,
			CertDir: emptyDir,
		}

		provider, err := NewMTLSProvider(emptyConfig)
		assert.Error(t, err)
		assert.Nil(t, provider)
	})
}

// Helper function to generate and write test certificates
func generateAndWriteTestCertificates(t *testing.T, dir string) error {
	// Generate CA key pair
	caPrivKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}

	// Create CA certificate
	ca := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			Organization: []string{"Test CA"},
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	// Self-sign CA certificate
	caCertDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &caPrivKey.PublicKey, caPrivKey)
	if err != nil {
		return err
	}

	// Generate server key pair
	serverPrivKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}

	// Create server certificate
	server := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject: pkix.Name{
			Organization: []string{"Test Server"},
		},
		NotBefore:   time.Now(),
		NotAfter:    time.Now().Add(24 * time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:    []string{"localhost"},
		IPAddresses: nil,
	}

	// Sign server certificate with CA
	serverCertDER, err := x509.CreateCertificate(rand.Reader, server, ca, &serverPrivKey.PublicKey, caPrivKey)
	if err != nil {
		return err
	}

	// Generate client key pair
	clientPrivKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}

	// Create client certificate
	client := &x509.Certificate{
		SerialNumber: big.NewInt(3),
		Subject: pkix.Name{
			Organization: []string{"Test Client"},
		},
		NotBefore:   time.Now(),
		NotAfter:    time.Now().Add(24 * time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}

	// Sign client certificate with CA
	clientCertDER, err := x509.CreateCertificate(rand.Reader, client, ca, &clientPrivKey.PublicKey, caPrivKey)
	if err != nil {
		return err
	}

	// Write CA certificate
	caCertFile, err := os.Create(filepath.Join(dir, "ca.crt"))
	if err != nil {
		return err
	}
	defer caCertFile.Close()
	err = pem.Encode(caCertFile, &pem.Block{Type: "CERTIFICATE", Bytes: caCertDER})
	if err != nil {
		return err
	}

	// Write server certificate and key
	serverCertFile, err := os.Create(filepath.Join(dir, "server.crt"))
	if err != nil {
		return err
	}
	defer serverCertFile.Close()
	err = pem.Encode(serverCertFile, &pem.Block{Type: "CERTIFICATE", Bytes: serverCertDER})
	if err != nil {
		return err
	}

	serverKeyFile, err := os.Create(filepath.Join(dir, "server.key"))
	if err != nil {
		return err
	}
	defer serverKeyFile.Close()
	serverKeyBytes, err := x509.MarshalECPrivateKey(serverPrivKey)
	if err != nil {
		return err
	}
	err = pem.Encode(serverKeyFile, &pem.Block{Type: "EC PRIVATE KEY", Bytes: serverKeyBytes})
	if err != nil {
		return err
	}

	// Write client certificate and key
	clientCertFile, err := os.Create(filepath.Join(dir, "client.crt"))
	if err != nil {
		return err
	}
	defer clientCertFile.Close()
	err = pem.Encode(clientCertFile, &pem.Block{Type: "CERTIFICATE", Bytes: clientCertDER})
	if err != nil {
		return err
	}

	clientKeyFile, err := os.Create(filepath.Join(dir, "client.key"))
	if err != nil {
		return err
	}
	defer clientKeyFile.Close()
	clientKeyBytes, err := x509.MarshalECPrivateKey(clientPrivKey)
	if err != nil {
		return err
	}
	return pem.Encode(clientKeyFile, &pem.Block{Type: "EC PRIVATE KEY", Bytes: clientKeyBytes})
}

// TestSpiffeProvider tests the SpiffeProvider implementation.
func TestSpiffeProvider(t *testing.T) {
	_, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	config := &SecurityConfig{
		Mode:           SecurityModeSpiffe,
		TrustDomain:    "example.org",
		WorkloadSocket: "unix:/tmp/spire-agent/public/api.sock",
	}

	t.Run("NewSpiffeProvider", func(t *testing.T) {
		provider, err := NewSpiffeProvider(config)
		// This will fail without a running SPIFFE Workload API
		assert.Error(t, err)
		assert.Nil(t, provider)
	})

	t.Run("InvalidTrustDomain", func(t *testing.T) {
		invalidConfig := &SecurityConfig{
			Mode:        SecurityModeSpiffe,
			TrustDomain: "invalid trust domain",
		}

		provider, err := NewSpiffeProvider(invalidConfig)
		assert.Error(t, err)
		assert.Nil(t, provider)
	})
}

// TestNewSecurityProvider tests the factory function for creating security providers
func TestNewSecurityProvider(t *testing.T) {
	tmpDir := t.TempDir()
	setupTestCertificates(t, tmpDir)

	tests := []struct {
		name        string
		config      *SecurityConfig
		expectError bool
	}{
		{
			name: "NoSecurity",
			config: &SecurityConfig{
				Mode: SecurityModeNone,
			},
			expectError: false,
		},
		{
			name: "TLS",
			config: &SecurityConfig{
				Mode:    SecurityModeTLS,
				CertDir: tmpDir,
			},
			expectError: false,
		},
		{
			name: "MTLS",
			config: &SecurityConfig{
				Mode:    SecurityModeMTLS,
				CertDir: tmpDir,
			},
			expectError: true, // Will fail without client certs
		},
		{
			name: "SPIFFE",
			config: &SecurityConfig{
				Mode:        SecurityModeSpiffe,
				TrustDomain: "example.org",
			},
			expectError: true, // Will fail without Workload API
		},
		{
			name: "Invalid Mode",
			config: &SecurityConfig{
				Mode: "invalid",
			},
			expectError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			provider, err := NewSecurityProvider(tt.config)
			if tt.expectError {
				assert.Error(t, err)
				assert.Nil(t, provider)
				return
			}
			assert.NoError(t, err)
			assert.NotNil(t, provider)

			// Test basic provider operations if not expecting error
			opt, err := provider.GetClientCredentials(ctx)
			assert.NoError(t, err)
			assert.NotNil(t, opt)

			err = provider.Close()
			assert.NoError(t, err)
		})
	}
}

// Helper functions for test certificates
func setupTestCertificates(t *testing.T, dir string) {
	require.NoError(t, os.WriteFile(filepath.Join(dir, "ca.crt"), []byte(testCACert), 0644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "server.crt"), []byte(testServerCert), 0644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "server.key"), []byte(testServerKey), 0600))
}

func setupClientCertificates(t *testing.T, dir string) {
	require.NoError(t, os.WriteFile(filepath.Join(dir, "client.crt"), []byte(testClientCert), 0644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "client.key"), []byte(testClientKey), 0600))
}

// Test certificates for testing purposes only - DO NOT USE IN PRODUCTION
const (
	testCACert = `-----BEGIN CERTIFICATE-----
MIIBcjCCARegAwIBAgIRANgz6QVQQNQEThHH8NLdXw4wCgYIKoZIzj0EAwIwEjEQ
MA4GA1UEChMHQWNtZSBDbzAeFw0yNDAxMjkwMDAwMDBaFw0yNTAxMjgwMDAwMDBa
MBIxEDAOBgNVBAoTB0FjbWUgQ28wWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARd
4MoZ6NdLGGqMYu8Zw9a8YhFGUSnyKU3Bq5CtOLHnpuoZw/HgglgYDKaJKmxOYPT/
+g8ILrC6YzaIGBK9gShuo0UwQzAOBgNVHQ8BAf8EBAMCAQYwEgYDVR0TAQH/BAgw
BgEB/wIBATAdBgNVHQ4EFgQUo/YygCZmJSmNtR/CQk6pNHGhh8swCgYIKoZIzj0E
AwIDSAAwRQIgULkqE1yUAqmQYxgiXOpeuq+qmPgUEyb6Y2bYnyi7FEwCIQCfI4Ew
YYIhgrV8EbcJKBB5IVxBNTuGv1QSXGwLM4mfkw==
-----END CERTIFICATE-----`

	testServerCert = `-----BEGIN CERTIFICATE-----
MIIBdzCCAR6gAwIBAgIRAMLL3dBYXZws0e5xFRZHqwYwCgYIKoZIzj0EAwIwEjEQ
MA4GA1UEChMHQWNtZSBDbzAeFw0yNDAxMjkwMDAwMDBaFw0yNTAxMjgwMDAwMDBa
MBIxEDAOBgNVBAoTB0FjbWUgQ28wWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAT+
CXuXHNqUDzyeaJ6p0aiVGzXjhgJT4p9HjY7CQ9yV6tK8VaLQ3jYsJ3JqM0kgf0pf
QZmIwLjbKjJ0yCMV5Qz+o2YwZDAOBgNVHQ8BAf8EBAMCB4AwHQYDVR0lBBYwFAYI
KwYBBQUHAwEGCCsGAQUFBwMCMB0GA1UdDgQWBBQ/VsdTFePo1BXlKmr2r6VfQ3q2
TzASBgNVHREECzAJggd0ZXN0LWNhMAoGCCqGSM49BAMCA0cAMEQCIDyWBiEjGrQc
5axkB2qPC69UTqj/AfnUBk6QhfpCq1SQAiAj7fsZKTKW7M5cBA3oWOL3ylmdwZ7A
CuKHBl0HRDqPnw==
-----END CERTIFICATE-----`

	testServerKey = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgXJE4pB9Ss51bpixd
kfqanPHp2DJyEKHgSV3YvKgDnOGhRANCAASr2SwnvE3pe1RBuGBQBMrP5EVsQ3pc
zx2zHQ+VxeGKUJUfECBfyGXUcsHVXvyQMY9yFQA3JGZL2UjzAEk2F7Pz
-----END PRIVATE KEY-----`

	testClientCert = `-----BEGIN CERTIFICATE-----
MIIBeDCCAR2gAwIBAgIQMSJNHj4mpxvvLyF8k8YtyTAKBggqhkjOPQQDAjASMRAw
DgYDVQQKEwdBY21lIENvMB4XDTI0MDEyOTAwMDAwMFoXDTI1MDEyODAwMDAwMFow
EjEQMA4GA1UEChMHQWNtZSBDbzBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABMCO
CfFAVxfOGYH/atdsWSHN8hT/gW3jDaJs7KxRufY0cPaIDjH656YhHXBfjuVE4qxG
+PpRVu7q28lNH0aVIuujZjBkMA4GA1UdDwEB/wQEAwIHgDAdBgNVHSUEFjAUBggr
BgEFBQcDAQYIKwYBBQUHAwIwHQYDVR0OBBYEFLmZayS2TEG7gf4YBiZK+t+1qUVC
MBIGA1UdEQQLMAmCB3Rlc3QtY2EwCgYIKoZIzj0EAwIDSAAwRQIgKMgtKrdG3p8R
uGXPQO0ZvlPKJQz3O0jGxuGfHzrrmqUCIQDuN9JBF2lTCkGoeS3QiPKJzYB62qKB
7HZyvIzyuLNc9A==
-----END CERTIFICATE-----`

	testClientKey = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg1YGgFJYy/WXzRxVL
pJ39sFhJnELdwL4bdTVzQg7xDgmhRANCAAQPd2+AjHyfYz8ZXB0yAUmJEtKKbO3b
3O6ytY5UZBjMG/V9IRl+3TprBGP9HL+bEqOGRrL5q4DHExn/M4Y1qhLX
-----END PRIVATE KEY-----`
)
