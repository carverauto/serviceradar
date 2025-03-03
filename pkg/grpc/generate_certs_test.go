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

// generateTestCertificates creates a CA, server, and client certificates for testing.
// In generate_certs_test.go

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

	// Save CA certificate and key with .pem extension
	savePEMCertificate(t, filepath.Join(dir, "root.pem"), caCertDER)
	savePEMPrivateKey(t, filepath.Join(dir, "root-key.pem"), caKey)

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

	// Save server certificate and key with .pem extension
	savePEMCertificate(t, filepath.Join(dir, "server.pem"), serverCertDER)
	savePEMPrivateKey(t, filepath.Join(dir, "server-key.pem"), serverKey)

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

	// Save client certificate and key with .pem extension
	savePEMCertificate(t, filepath.Join(dir, "client.pem"), clientCertDER)
	savePEMPrivateKey(t, filepath.Join(dir, "client-key.pem"), clientKey)

	// Verify all files exist
	files := []string{
		"root.pem",
		"root-key.pem",
		"server.pem",
		"server-key.pem",
		"client.pem",
		"client-key.pem",
	}
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
