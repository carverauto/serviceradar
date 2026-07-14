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

package agent

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

const (
	maxPluginHTTPTrustedCAFiles = 16
	maxPluginHTTPTrustedCABytes = 1 << 20
)

var errPluginHTTPTrustUnavailable = errors.New("plugin HTTP trust configuration unavailable")

// pluginHTTPClientWithTrustedCAs builds the host-owned transport used by Wasm
// HTTP calls. The configured roots augment the operating-system pool; they are
// never copied into plugin configuration or exposed to Wasm memory.
func pluginHTTPClientWithTrustedCAs(paths []string) (*http.Client, error) {
	if len(paths) == 0 {
		return nil, nil
	}
	if len(paths) > maxPluginHTTPTrustedCAFiles {
		return nil, fmt.Errorf("%w: too many CA files", errPluginHTTPTrustUnavailable)
	}

	roots, err := x509.SystemCertPool()
	if err != nil {
		return nil, fmt.Errorf("%w: load system roots: %w", errPluginHTTPTrustUnavailable, err)
	}
	if roots == nil {
		return nil, fmt.Errorf("%w: empty system root pool", errPluginHTTPTrustUnavailable)
	}

	seen := make(map[string]struct{}, len(paths))
	for _, rawPath := range paths {
		path := filepath.Clean(strings.TrimSpace(rawPath))
		if rawPath == "" || path == "." || !filepath.IsAbs(path) {
			return nil, fmt.Errorf("%w: CA file paths must be absolute", errPluginHTTPTrustUnavailable)
		}
		if _, duplicate := seen[path]; duplicate {
			continue
		}
		seen[path] = struct{}{}

		pemBytes, readErr := readBoundedPluginHTTPCAFile(path)
		if readErr != nil {
			return nil, readErr
		}
		if !roots.AppendCertsFromPEM(pemBytes) {
			clear(pemBytes)
			return nil, fmt.Errorf("%w: CA file contains no certificates", errPluginHTTPTrustUnavailable)
		}
		clear(pemBytes)
	}

	baseTransport, ok := http.DefaultTransport.(*http.Transport)
	if !ok || baseTransport == nil {
		return nil, fmt.Errorf("%w: default HTTP transport unsupported", errPluginHTTPTrustUnavailable)
	}
	transport := baseTransport.Clone()
	transport.TLSClientConfig = &tls.Config{
		MinVersion: tls.VersionTLS12,
		RootCAs:    roots,
	}

	return &http.Client{
		Timeout:   pluginDefaultHTTPTimeout,
		Transport: transport,
	}, nil
}

func readBoundedPluginHTTPCAFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("%w: open CA file: %w", errPluginHTTPTrustUnavailable, err)
	}
	defer func() { _ = file.Close() }()

	pemBytes, err := io.ReadAll(io.LimitReader(file, maxPluginHTTPTrustedCABytes+1))
	if err != nil {
		return nil, fmt.Errorf("%w: read CA file: %w", errPluginHTTPTrustUnavailable, err)
	}
	if len(pemBytes) == 0 || len(pemBytes) > maxPluginHTTPTrustedCABytes {
		clear(pemBytes)
		return nil, fmt.Errorf("%w: CA file is empty or exceeds size limit", errPluginHTTPTrustUnavailable)
	}

	return pemBytes, nil
}

type unavailablePluginHTTPTransport struct {
	err error
}

func (transport unavailablePluginHTTPTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, transport.err
}

func unavailablePluginHTTPClient(err error) *http.Client {
	if err == nil {
		err = errPluginHTTPTrustUnavailable
	}

	return &http.Client{
		Timeout:   pluginDefaultHTTPTimeout,
		Transport: unavailablePluginHTTPTransport{err: err},
	}
}
