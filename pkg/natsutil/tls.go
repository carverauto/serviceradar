package natsutil

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
)

// TLSConfig builds a tls.Config for connecting to NATS using mTLS.
func TLSConfig(sec *models.SecurityConfig) (*tls.Config, error) {
	if sec == nil || sec.Mode != "mtls" {
		return nil, fmt.Errorf("mtls security required")
	}

	// Use the existing config package to normalize TLS paths
	config.NormalizeTLSPaths(&sec.TLS, sec.CertDir)

	cert, err := tls.LoadX509KeyPair(sec.TLS.CertFile, sec.TLS.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load client certificate: %w", err)
	}

	caCert, err := os.ReadFile(sec.TLS.CAFile)
	if err != nil {
		return nil, fmt.Errorf("failed to read CA certificate: %w", err)
	}

	caPool := x509.NewCertPool()
	if !caPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("failed to parse CA certificate")
	}

	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      caPool,
		ServerName:   sec.ServerName,
		MinVersion:   tls.VersionTLS13,
	}, nil
}
