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

package mtls

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestBootstrap_NilConfig(t *testing.T) {
	_, err := Bootstrap(context.Background(), nil)
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrTokenRequired)
}

func TestBootstrap_FromBundlePath(t *testing.T) {
	tmpDir := t.TempDir()
	bundlePath := filepath.Join(tmpDir, "bundle.json")
	certDir := filepath.Join(tmpDir, "certs")

	bundle := Bundle{
		CACertPEM:  testCACert,
		ClientCert: testClientCert,
		ClientKey:  testClientKey,
		ServerName: "test.serviceradar",
	}

	data, err := json.Marshal(bundle)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(bundlePath, data, 0644))

	cfg := &BootstrapConfig{
		BundlePath:  bundlePath,
		CertDir:     certDir,
		ServiceName: "test-service",
		Role:        models.RoleChecker,
	}

	secCfg, err := Bootstrap(context.Background(), cfg)
	require.NoError(t, err)
	assert.Equal(t, models.SecurityModeMTLS, secCfg.Mode)
	assert.Equal(t, certDir, secCfg.CertDir)
	assert.Equal(t, "test.serviceradar", secCfg.ServerName)
	assert.Equal(t, models.RoleChecker, secCfg.Role)

	// Verify files were written
	assert.FileExists(t, filepath.Join(certDir, "root.pem"))
	assert.FileExists(t, filepath.Join(certDir, "test-service.pem"))
	assert.FileExists(t, filepath.Join(certDir, "test-service-key.pem"))

	// Verify file contents
	caContent, err := os.ReadFile(filepath.Join(certDir, "root.pem"))
	require.NoError(t, err)
	assert.Equal(t, testCACert, string(caContent))
}

func TestBootstrap_FromToken(t *testing.T) {
	bundle := Bundle{
		CACertPEM:  testCACert,
		ClientCert: testClientCert,
		ClientKey:  testClientKey,
		ServerName: "token.serviceradar",
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, http.MethodPost, r.Method)
		assert.Contains(t, r.URL.Path, "/api/admin/edge-packages/")
		assert.Contains(t, r.URL.Path, "/download")

		resp := deliverPayload{
			Package:    struct{ PackageID string `json:"package_id"` }{PackageID: "test-pkg-123"},
			MTLSBundle: &bundle,
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	tmpDir := t.TempDir()
	certDir := filepath.Join(tmpDir, "certs")

	token := makeTestToken("test-pkg-123", "dl-token-abc", server.URL)

	cfg := &BootstrapConfig{
		Token:       token,
		CertDir:     certDir,
		ServiceName: "token-test",
		Role:        models.RoleAgent,
	}

	secCfg, err := Bootstrap(context.Background(), cfg)
	require.NoError(t, err)
	assert.Equal(t, models.SecurityModeMTLS, secCfg.Mode)
	assert.Equal(t, "token.serviceradar", secCfg.ServerName)
	assert.Equal(t, models.RoleAgent, secCfg.Role)

	// Verify files were written
	assert.FileExists(t, filepath.Join(certDir, "root.pem"))
	assert.FileExists(t, filepath.Join(certDir, "token-test.pem"))
	assert.FileExists(t, filepath.Join(certDir, "token-test-key.pem"))
}

func TestBootstrap_FromToken_ServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("internal error"))
	}))
	defer server.Close()

	tmpDir := t.TempDir()
	token := makeTestToken("test-pkg", "dl-token", server.URL)

	cfg := &BootstrapConfig{
		Token:       token,
		CertDir:     filepath.Join(tmpDir, "certs"),
		ServiceName: "test",
	}

	_, err := Bootstrap(context.Background(), cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "500")
}

func TestBootstrap_FromToken_MissingBundle(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := deliverPayload{
			Package:    struct{ PackageID string `json:"package_id"` }{PackageID: "test-pkg"},
			MTLSBundle: nil,
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	tmpDir := t.TempDir()
	token := makeTestToken("test-pkg", "dl-token", server.URL)

	cfg := &BootstrapConfig{
		Token:       token,
		CertDir:     filepath.Join(tmpDir, "certs"),
		ServiceName: "test",
	}

	_, err := Bootstrap(context.Background(), cfg)
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrBundleMissing)
}

func TestBootstrap_Defaults(t *testing.T) {
	tmpDir := t.TempDir()
	bundlePath := filepath.Join(tmpDir, "bundle.json")

	bundle := Bundle{
		CACertPEM:  testCACert,
		ClientCert: testClientCert,
		ClientKey:  testClientKey,
	}

	data, err := json.Marshal(bundle)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(bundlePath, data, 0644))

	// Only provide BundlePath, let other fields default
	cfg := &BootstrapConfig{
		BundlePath: bundlePath,
		CertDir:    filepath.Join(tmpDir, "certs"),
	}

	secCfg, err := Bootstrap(context.Background(), cfg)
	require.NoError(t, err)

	// Check defaults
	assert.Equal(t, models.RoleChecker, secCfg.Role)
	assert.FileExists(t, filepath.Join(cfg.CertDir, "client.pem"))     // default service name
	assert.FileExists(t, filepath.Join(cfg.CertDir, "client-key.pem")) // default service name
}

func TestBootstrap_ServerNameFromConfig(t *testing.T) {
	tmpDir := t.TempDir()
	bundlePath := filepath.Join(tmpDir, "bundle.json")
	certDir := filepath.Join(tmpDir, "certs")

	// Bundle has no server name
	bundle := Bundle{
		CACertPEM:  testCACert,
		ClientCert: testClientCert,
		ClientKey:  testClientKey,
	}

	data, err := json.Marshal(bundle)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(bundlePath, data, 0644))

	cfg := &BootstrapConfig{
		BundlePath:  bundlePath,
		CertDir:     certDir,
		ServerName:  "config-server-name",
		ServiceName: "test",
	}

	secCfg, err := Bootstrap(context.Background(), cfg)
	require.NoError(t, err)
	assert.Equal(t, "config-server-name", secCfg.ServerName)
}

func TestEnsureScheme(t *testing.T) {
	tests := []struct {
		input    string
		expected string
		wantErr  bool
	}{
		{"", "", true},
		{"   ", "", true},
		{"http://example.com", "http://example.com", false},
		{"https://example.com", "https://example.com", false},
		{"example.com", "http://example.com", false},
		{"example.com:8080", "http://example.com:8080", false},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			result, err := ensureScheme(tt.input)
			if tt.wantErr {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tt.expected, result)
		})
	}
}
