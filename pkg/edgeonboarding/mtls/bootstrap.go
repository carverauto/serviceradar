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

// Package mtls provides mTLS bootstrap functionality for edge services.
// This is a simpler alternative to SPIRE-based edge onboarding that uses
// pre-generated mTLS certificates from an onboarding token or bundle file.
package mtls

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	// ErrTokenRequired is returned when no token is provided and no bundle path is set.
	ErrTokenRequired = errors.New("token is required for mTLS bootstrap")
	// ErrUnsupportedTokenFormat is returned when the token doesn't have the expected prefix.
	ErrUnsupportedTokenFormat = errors.New("unsupported token format (expected edgepkg-v1)")
	// ErrMissingPackageID is returned when the token is missing the package ID.
	ErrMissingPackageID = errors.New("token missing package id")
	// ErrMissingDownloadToken is returned when the token is missing the download token.
	ErrMissingDownloadToken = errors.New("token missing download token")
	// ErrCoreAPIHostRequired is returned when the Core API host cannot be determined.
	ErrCoreAPIHostRequired = errors.New("core API host is required (token missing api and --host not set)")
	// ErrBundleMissing is returned when the mTLS bundle is missing from the deliver response.
	ErrBundleMissing = errors.New("mTLS bundle missing in deliver response")
	// ErrBundleFieldMissing is returned when a required field is missing from the bundle.
	ErrBundleFieldMissing = errors.New("bundle missing required field")
	// ErrUnsupportedBundleFormat is returned when the bundle file format is not recognized.
	ErrUnsupportedBundleFormat = errors.New("unsupported bundle format (expected .json, .tar.gz, or directory with ca.pem/client.pem/client-key.pem)")
	// ErrDeliverEndpoint is returned when the Core API deliver endpoint returns an error.
	ErrDeliverEndpoint = errors.New("deliver endpoint error")
	// ErrBundleArchiveMissingFiles is returned when the tar.gz archive is missing required files.
	ErrBundleArchiveMissingFiles = errors.New("bundle archive missing mtls/ca.pem or client cert/key")
)

// BootstrapConfig contains configuration for mTLS bootstrap.
type BootstrapConfig struct {
	// Token is the edgepkg-v1 token containing package ID and download token.
	Token string

	// Host is the Core API host for mTLS bundle download (e.g., http://core:8090).
	// Used as fallback if the token doesn't contain an API URL.
	Host string

	// BundlePath is an optional path to a pre-fetched mTLS bundle (tar.gz, JSON, or directory).
	// If set, the token and host are not used.
	BundlePath string

	// CertDir is the directory to write mTLS certificates and keys.
	// Defaults to /etc/serviceradar/certs.
	CertDir string

	// ServerName is the server name to present in mTLS.
	// Defaults to the service name (e.g., "sysmon-vm.serviceradar").
	ServerName string

	// ServiceName is the name of the service (used for cert file naming).
	// Examples: "sysmon-vm", "agent", "poller".
	ServiceName string

	// Role is the security role for the service.
	Role models.ServiceRole

	// HTTPClient allows callers to override the HTTP client used for Core API requests.
	HTTPClient *http.Client
}

// Bootstrap performs mTLS bootstrap using either a bundle file or an onboarding token.
// Returns a SecurityConfig that can be used by the service.
func Bootstrap(ctx context.Context, cfg *BootstrapConfig) (*models.SecurityConfig, error) {
	if cfg == nil {
		return nil, ErrTokenRequired
	}

	// Set defaults
	if cfg.CertDir == "" {
		cfg.CertDir = "/etc/serviceradar/certs"
	}
	if cfg.ServiceName == "" {
		cfg.ServiceName = "client"
	}
	if cfg.Role == "" {
		cfg.Role = models.RoleChecker
	}

	// If bundle path is provided, load from file/directory
	if cfg.BundlePath != "" {
		bundle, err := LoadBundleFromPath(cfg.BundlePath)
		if err != nil {
			return nil, err
		}
		return installBundle(bundle, cfg)
	}

	// Otherwise, fetch from Core API using the token
	return bootstrapFromToken(ctx, cfg)
}

func bootstrapFromToken(ctx context.Context, cfg *BootstrapConfig) (*models.SecurityConfig, error) {
	payload, err := ParseToken(cfg.Token, cfg.Host)
	if err != nil {
		return nil, err
	}

	apiBase, err := ensureScheme(payload.CoreURL)
	if err != nil {
		return nil, err
	}

	deliverURL := fmt.Sprintf("%s/api/admin/edge-packages/%s/download?format=json",
		strings.TrimRight(apiBase, "/"),
		url.PathEscape(payload.PackageID))

	body := fmt.Sprintf(`{"download_token":"%s"}`, payload.DownloadToken)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, deliverURL, strings.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create deliver request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	client := cfg.HTTPClient
	if client == nil {
		client = http.DefaultClient
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request deliver endpoint: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		buf, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, fmt.Errorf("%w (%s): %s", ErrDeliverEndpoint, resp.Status, strings.TrimSpace(string(buf)))
	}

	var payloadResp deliverPayload
	if err := json.NewDecoder(resp.Body).Decode(&payloadResp); err != nil {
		return nil, fmt.Errorf("decode deliver response: %w", err)
	}

	if payloadResp.MTLSBundle == nil {
		return nil, ErrBundleMissing
	}

	return installBundle(payloadResp.MTLSBundle, cfg)
}

func installBundle(bundle *Bundle, cfg *BootstrapConfig) (*models.SecurityConfig, error) {
	if bundle == nil {
		return nil, ErrBundleMissing
	}

	if err := os.MkdirAll(cfg.CertDir, 0o755); err != nil {
		return nil, fmt.Errorf("create cert dir: %w", err)
	}

	write := func(name, content string, mode os.FileMode) error {
		if strings.TrimSpace(content) == "" {
			return fmt.Errorf("%w: %s", ErrBundleFieldMissing, name)
		}
		path := filepath.Join(cfg.CertDir, name)
		if err := os.WriteFile(path, []byte(content), mode); err != nil {
			return fmt.Errorf("write %s: %w", path, err)
		}
		return nil
	}

	serverName := cfg.ServerName
	if serverName == "" && strings.TrimSpace(bundle.ServerName) != "" {
		serverName = strings.TrimSpace(bundle.ServerName)
	}

	// Write certificate files
	if err := write("root.pem", bundle.CACertPEM, 0o644); err != nil {
		return nil, err
	}

	certFileName := cfg.ServiceName + ".pem"
	keyFileName := cfg.ServiceName + "-key.pem"

	if err := write(certFileName, bundle.ClientCert, 0o644); err != nil {
		return nil, err
	}
	if err := write(keyFileName, bundle.ClientKey, 0o600); err != nil {
		return nil, err
	}

	return &models.SecurityConfig{
		Mode:       models.SecurityModeMTLS,
		CertDir:    cfg.CertDir,
		ServerName: serverName,
		Role:       cfg.Role,
		TLS: models.TLSConfig{
			CertFile:     filepath.Join(cfg.CertDir, certFileName),
			KeyFile:      filepath.Join(cfg.CertDir, keyFileName),
			CAFile:       filepath.Join(cfg.CertDir, "root.pem"),
			ClientCAFile: filepath.Join(cfg.CertDir, "root.pem"),
		},
	}, nil
}

func ensureScheme(host string) (string, error) {
	host = strings.TrimSpace(host)
	if host == "" {
		return "", ErrCoreAPIHostRequired
	}
	if strings.HasPrefix(host, "http://") || strings.HasPrefix(host, "https://") {
		return host, nil
	}
	return "http://" + host, nil
}
