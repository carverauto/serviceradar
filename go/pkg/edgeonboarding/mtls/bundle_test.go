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
	"archive/tar"
	"compress/gzip"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	testCACert     = "-----BEGIN CERTIFICATE-----\ntest-ca-cert\n-----END CERTIFICATE-----"
	testClientCert = "-----BEGIN CERTIFICATE-----\ntest-client-cert\n-----END CERTIFICATE-----"
	testClientKey  = "-----BEGIN PRIVATE KEY-----\ntest-client-key\n-----END PRIVATE KEY-----"
)

func TestLoadBundleFromPath_JSONFile(t *testing.T) {
	tmpDir := t.TempDir()
	jsonPath := filepath.Join(tmpDir, "bundle.json")

	bundle := Bundle{
		CACertPEM:   testCACert,
		ClientCert:  testClientCert,
		ClientKey:   testClientKey,
		ServerName:  "test.serviceradar",
		GeneratedAt: "2025-01-01T00:00:00Z",
	}

	data, err := json.Marshal(bundle)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(jsonPath, data, 0644))

	loaded, err := LoadBundleFromPath(jsonPath)
	require.NoError(t, err)
	assert.Equal(t, testCACert, loaded.CACertPEM)
	assert.Equal(t, testClientCert, loaded.ClientCert)
	assert.Equal(t, testClientKey, loaded.ClientKey)
	assert.Equal(t, "test.serviceradar", loaded.ServerName)
}

func TestLoadBundleFromPath_Directory(t *testing.T) {
	tmpDir := t.TempDir()
	bundleDir := filepath.Join(tmpDir, "certs")
	require.NoError(t, os.MkdirAll(bundleDir, 0755))

	require.NoError(t, os.WriteFile(filepath.Join(bundleDir, "ca.pem"), []byte(testCACert), 0644))
	require.NoError(t, os.WriteFile(filepath.Join(bundleDir, "client.pem"), []byte(testClientCert), 0644))
	require.NoError(t, os.WriteFile(filepath.Join(bundleDir, "client-key.pem"), []byte(testClientKey), 0600))

	loaded, err := LoadBundleFromPath(bundleDir)
	require.NoError(t, err)
	assert.Equal(t, testCACert, loaded.CACertPEM)
	assert.Equal(t, testClientCert, loaded.ClientCert)
	assert.Equal(t, testClientKey, loaded.ClientKey)
}

func TestLoadBundleFromPath_TarGz(t *testing.T) {
	tmpDir := t.TempDir()
	archivePath := filepath.Join(tmpDir, "bundle.tar.gz")

	f, err := os.Create(archivePath)
	require.NoError(t, err)

	gzw := gzip.NewWriter(f)
	tw := tar.NewWriter(gzw)

	files := map[string]string{
		"mtls/ca.pem":         testCACert,
		"mtls/client.pem":     testClientCert,
		"mtls/client-key.pem": testClientKey,
	}

	for name, content := range files {
		hdr := &tar.Header{
			Name: name,
			Mode: 0644,
			Size: int64(len(content)),
		}
		require.NoError(t, tw.WriteHeader(hdr))
		_, err = tw.Write([]byte(content))
		require.NoError(t, err)
	}

	require.NoError(t, tw.Close())
	require.NoError(t, gzw.Close())
	require.NoError(t, f.Close())

	loaded, err := LoadBundleFromPath(archivePath)
	require.NoError(t, err)
	assert.Equal(t, testCACert, loaded.CACertPEM)
	assert.Equal(t, testClientCert, loaded.ClientCert)
	assert.Equal(t, testClientKey, loaded.ClientKey)
}

func TestLoadBundleFromPath_UnsupportedFormat(t *testing.T) {
	tmpDir := t.TempDir()
	unknownPath := filepath.Join(tmpDir, "bundle.xyz")
	require.NoError(t, os.WriteFile(unknownPath, []byte("unknown"), 0644))

	_, err := LoadBundleFromPath(unknownPath)
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrUnsupportedBundleFormat)
}

func TestLoadBundleFromPath_MissingFile(t *testing.T) {
	_, err := LoadBundleFromPath("/nonexistent/path/bundle.json")
	require.Error(t, err)
}

func TestLoadBundleFromPath_DirectoryMissingFiles(t *testing.T) {
	tmpDir := t.TempDir()
	bundleDir := filepath.Join(tmpDir, "incomplete")
	require.NoError(t, os.MkdirAll(bundleDir, 0755))

	// Only create ca.pem, missing client.pem and client-key.pem
	require.NoError(t, os.WriteFile(filepath.Join(bundleDir, "ca.pem"), []byte(testCACert), 0644))

	_, err := LoadBundleFromPath(bundleDir)
	require.Error(t, err)
}

func TestLoadBundleFromPath_TarGzMissingFiles(t *testing.T) {
	tmpDir := t.TempDir()
	archivePath := filepath.Join(tmpDir, "incomplete.tar.gz")

	f, err := os.Create(archivePath)
	require.NoError(t, err)

	gzw := gzip.NewWriter(f)
	tw := tar.NewWriter(gzw)

	// Only include ca.pem
	hdr := &tar.Header{
		Name: "mtls/ca.pem",
		Mode: 0644,
		Size: int64(len(testCACert)),
	}
	require.NoError(t, tw.WriteHeader(hdr))
	_, err = tw.Write([]byte(testCACert))
	require.NoError(t, err)

	require.NoError(t, tw.Close())
	require.NoError(t, gzw.Close())
	require.NoError(t, f.Close())

	_, err = LoadBundleFromPath(archivePath)
	require.Error(t, err)
}
