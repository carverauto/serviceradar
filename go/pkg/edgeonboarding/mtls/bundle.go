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
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Bundle contains the mTLS certificate materials for a service.
type Bundle struct {
	CACertPEM   string            `json:"ca_cert_pem"`
	ClientCert  string            `json:"client_cert_pem"`
	ClientKey   string            `json:"client_key_pem"`
	ServerName  string            `json:"server_name"`
	Endpoints   map[string]string `json:"endpoints"`
	GeneratedAt string            `json:"generated_at"`
	ExpiresAt   string            `json:"expires_at"`
}

// deliverPayload is the response from the Core API deliver endpoint.
type deliverPayload struct {
	Package struct {
		PackageID string `json:"package_id"`
	} `json:"package"`
	MTLSBundle *Bundle `json:"mtls_bundle"`
}

// LoadBundleFromPath loads an mTLS bundle from a file path.
// Supports JSON files, tar.gz archives, and directories containing PEM files.
func LoadBundleFromPath(path string) (*Bundle, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open bundle: %w", err)
	}
	defer func() { _ = f.Close() }()

	stat, err := f.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat bundle: %w", err)
	}

	// Handle directory
	if stat.IsDir() {
		return loadBundleFromDirectory(path)
	}

	// Handle JSON file
	lowerPath := strings.ToLower(path)
	if strings.HasSuffix(lowerPath, ".json") {
		var bundle Bundle
		if err := json.NewDecoder(f).Decode(&bundle); err != nil {
			return nil, fmt.Errorf("decode bundle json: %w", err)
		}
		return &bundle, nil
	}

	// Handle tar.gz archive
	if strings.HasSuffix(lowerPath, ".tar.gz") || strings.HasSuffix(lowerPath, ".tgz") {
		return loadBundleFromArchive(f)
	}

	return nil, ErrUnsupportedBundleFormat
}

func loadBundleFromDirectory(dir string) (*Bundle, error) {
	read := func(name string) (string, error) {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return "", err
		}
		return string(b), nil
	}

	ca, err := read("ca.pem")
	if err != nil {
		return nil, fmt.Errorf("read ca.pem: %w", err)
	}
	cert, err := read("client.pem")
	if err != nil {
		return nil, fmt.Errorf("read client.pem: %w", err)
	}
	key, err := read("client-key.pem")
	if err != nil {
		return nil, fmt.Errorf("read client-key.pem: %w", err)
	}

	return &Bundle{
		CACertPEM:  ca,
		ClientCert: cert,
		ClientKey:  key,
	}, nil
}

func loadBundleFromArchive(r io.Reader) (*Bundle, error) {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return nil, fmt.Errorf("open gzip: %w", err)
	}
	defer func() { _ = gz.Close() }()

	tarReader := tar.NewReader(gz)
	var ca, cert, key string

	for {
		hdr, err := tarReader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read archive: %w", err)
		}

		name := strings.TrimSpace(hdr.Name)
		switch {
		case strings.HasSuffix(name, "mtls/ca.pem"):
			data, _ := io.ReadAll(tarReader)
			ca = string(data)
		case strings.HasSuffix(name, "mtls/client.pem"):
			data, _ := io.ReadAll(tarReader)
			cert = string(data)
		case strings.HasSuffix(name, "mtls/client-key.pem"):
			data, _ := io.ReadAll(tarReader)
			key = string(data)
		}
	}

	if ca == "" || cert == "" || key == "" {
		return nil, ErrBundleArchiveMissingFiles
	}

	return &Bundle{
		CACertPEM:  ca,
		ClientCert: cert,
		ClientKey:  key,
	}, nil
}
