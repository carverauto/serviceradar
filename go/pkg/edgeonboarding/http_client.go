package edgeonboarding

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net/http"
	"os"
)

var errParseCAFile = errors.New("parse CA file")

// BuildHTTPClient returns a client configured for verified TLS, optionally with
// an explicit CA bundle.
func BuildHTTPClient(caFile string) (*http.Client, error) {
	if caFile == "" {
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
			return nil, fmt.Errorf("%w: %s", errParseCAFile, caFile)
		}
		tlsConfig.RootCAs = pool
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = tlsConfig

	return &http.Client{Transport: transport}, nil
}
