package natsutil

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"os"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	// ErrMTLSRequired is returned when mTLS security is required but not configured
	ErrMTLSRequired = errors.New("mtls security required")
	// ErrCAParsingFailed is returned when CA certificate cannot be parsed
	ErrCAParsingFailed = errors.New("failed to parse CA certificate")
)

// TLSConfig builds a tls.Config for connecting to NATS using mTLS.
func TLSConfig(sec *models.SecurityConfig) (*tls.Config, error) {
	if sec == nil || sec.Mode != "mtls" {
		return nil, ErrMTLSRequired
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
		return nil, ErrCAParsingFailed
	}

	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      caPool,
		ServerName:   sec.ServerName,
		MinVersion:   tls.VersionTLS13,
	}, nil
}
