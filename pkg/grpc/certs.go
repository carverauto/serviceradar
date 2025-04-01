package grpc

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

const (
	certValidity       = 24 * time.Hour
	caSerialNumber     = 1
	serverSerialNumber = 2
	clientSerialNumber = 3
	certFilePerms      = 0600
)

// GenerateTestCertificates creates a CA, server, and client certificates in the specified directory.
// Generates: root.pem (CA), server.pem (server auth), client.pem (client auth).
func GenerateTestCertificates(dir string) error {
	caKey, caCertDER, err := generateCACert()
	if err != nil {
		return err
	}

	if saveErr := saveCertAndKey(dir, "root", caCertDER, caKey); saveErr != nil {
		return saveErr
	}

	serverKey, serverCertDER, err := generateServerCert(caKey, caCertDER)
	if err != nil {
		return err
	}

	if saveErr := saveCertAndKey(dir, "server", serverCertDER, serverKey); saveErr != nil {
		return saveErr
	}

	clientKey, clientCertDER, err := generateClientCert(caKey, caCertDER)
	if err != nil {
		return err
	}

	if saveErr := saveCertAndKey(dir, "client", clientCertDER, clientKey); saveErr != nil {
		return saveErr
	}

	return nil
}

// generateCACert generates a self-signed CA certificate and key.
func generateCACert() (*ecdsa.PrivateKey, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(caSerialNumber),
		Subject: pkix.Name{
			Organization: []string{"Test CA"},
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(certValidity),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}

	return key, certDER, nil
}

// generateServerCert generates a server certificate signed by the CA with server auth usage.
func generateServerCert(caKey *ecdsa.PrivateKey, caCertDER []byte) (*ecdsa.PrivateKey, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}

	caCert, err := x509.ParseCertificate(caCertDER)
	if err != nil {
		return nil, nil, err
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(serverSerialNumber),
		Subject: pkix.Name{
			Organization: []string{"Test Server"},
		},
		NotBefore:   time.Now(),
		NotAfter:    time.Now().Add(certValidity),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:    []string{"localhost"},
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, caCert, &key.PublicKey, caKey)
	if err != nil {
		return nil, nil, err
	}

	return key, certDER, nil
}

// generateClientCert generates a client certificate signed by the CA with client auth usage.
func generateClientCert(caKey *ecdsa.PrivateKey, caCertDER []byte) (*ecdsa.PrivateKey, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}

	caCert, err := x509.ParseCertificate(caCertDER)
	if err != nil {
		return nil, nil, err
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(clientSerialNumber),
		Subject: pkix.Name{
			Organization: []string{"Test Client"},
		},
		NotBefore:   time.Now(),
		NotAfter:    time.Now().Add(certValidity),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, caCert, &key.PublicKey, caKey)
	if err != nil {
		return nil, nil, err
	}

	return key, certDER, nil
}

// saveCertAndKey saves a certificate and private key to files.
func saveCertAndKey(dir, name string, certDER []byte, key *ecdsa.PrivateKey) error {
	certPath := filepath.Join(dir, name+".pem")
	if err := savePEMCertificate(certPath, certDER); err != nil {
		return err
	}

	keyPath := filepath.Join(dir, name+"-key.pem")
	if err := savePEMPrivateKey(keyPath, key); err != nil {
		return err
	}

	return nil
}

// savePEMCertificate writes a certificate in PEM format to the specified path.
func savePEMCertificate(path string, derBytes []byte) error {
	certPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: derBytes,
	})

	return os.WriteFile(path, certPEM, certFilePerms)
}

// savePEMPrivateKey writes a private key in PEM format to the specified path.
func savePEMPrivateKey(path string, key *ecdsa.PrivateKey) error {
	keyBytes, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}

	keyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "PRIVATE KEY",
		Bytes: keyBytes,
	})

	return os.WriteFile(path, keyPEM, certFilePerms)
}
