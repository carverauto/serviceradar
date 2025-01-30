package grpc

import (
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

	"github.com/stretchr/testify/require"
)

// generateTestCertificates creates a CA, server, and client certificates for testing
func generateTestCertificates(t *testing.T, dir string) {
	t.Helper()

	// Generate CA key and certificate
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err, "Failed to generate CA key")

	caTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			Organization: []string{"Test CA"},
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}

	// Self-sign the CA certificate
	caCertDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	require.NoError(t, err, "Failed to create CA certificate")

	// Save CA certificate
	savePEMCertificate(t, filepath.Join(dir, "ca.crt"), caCertDER)
	savePEMPrivateKey(t, filepath.Join(dir, "ca.key"), caKey)

	// Generate server certificate
	serverKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err, "Failed to generate server key")

	serverTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject: pkix.Name{
			Organization: []string{"Test Server"},
		},
		NotBefore:   time.Now(),
		NotAfter:    time.Now().Add(24 * time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:    []string{"localhost"},
	}

	serverCertDER, err := x509.CreateCertificate(rand.Reader, serverTemplate, caTemplate, &serverKey.PublicKey, caKey)
	require.NoError(t, err, "Failed to create server certificate")

	// Save server certificate and key
	savePEMCertificate(t, filepath.Join(dir, "server.crt"), serverCertDER)
	savePEMPrivateKey(t, filepath.Join(dir, "server.key"), serverKey)

	// Generate client certificate for mTLS
	clientKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err, "Failed to generate client key")

	clientTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(3),
		Subject: pkix.Name{
			Organization: []string{"Test Client"},
		},
		NotBefore:   time.Now(),
		NotAfter:    time.Now().Add(24 * time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}

	clientCertDER, err := x509.CreateCertificate(rand.Reader, clientTemplate, caTemplate, &clientKey.PublicKey, caKey)
	require.NoError(t, err, "Failed to create client certificate")

	// Save client certificate and key
	savePEMCertificate(t, filepath.Join(dir, "client.crt"), clientCertDER)
	savePEMPrivateKey(t, filepath.Join(dir, "client.key"), clientKey)

	// Verify all files exist
	files := []string{"ca.crt", "ca.key", "server.crt", "server.key", "client.crt", "client.key"}
	for _, file := range files {
		path := filepath.Join(dir, file)
		_, err := os.Stat(path)
		require.NoError(t, err, "Failed to verify file existence: %s", file)
	}
}

func savePEMCertificate(t *testing.T, path string, derBytes []byte) {
	t.Helper()
	certPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: derBytes,
	})
	err := os.WriteFile(path, certPEM, 0600)
	require.NoError(t, err, "Failed to save certificate to %s", path)
}

func savePEMPrivateKey(t *testing.T, path string, key *ecdsa.PrivateKey) {
	t.Helper()
	keyBytes, err := x509.MarshalECPrivateKey(key)
	require.NoError(t, err, "Failed to marshal private key")

	keyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "PRIVATE KEY",
		Bytes: keyBytes,
	})
	err = os.WriteFile(path, keyPEM, 0600)
	require.NoError(t, err, "Failed to save private key to %s", path)
}
