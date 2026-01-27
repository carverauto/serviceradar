package edgeonboarding

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net/http"
	"os"
)

// BuildHTTPClient returns a client configured for optional TLS overrides.
func BuildHTTPClient(caFile string, insecure bool) (*http.Client, error) {
	if caFile == "" && !insecure {
		return nil, nil
	}

	tlsConfig := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}

	if caFile != "" {
		caPEM, err := os.ReadFile(caFile)
		if err != nil {
			return nil, fmt.Errorf("read CA file: %w", err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(caPEM) {
			return nil, fmt.Errorf("parse CA file: %s", caFile)
		}
		tlsConfig.RootCAs = pool
	}
	// Prefer explicit CA bundle over insecure mode.
	if caFile == "" && insecure {
		tlsConfig.InsecureSkipVerify = true
	}

	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = tlsConfig

	return &http.Client{Transport: transport}, nil
}
