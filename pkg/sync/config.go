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

package sync

import (
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultTimeout = 30 * time.Second
)

var (
	errMissingSources = errors.New("at least one source must be defined")
	errMissingNATS    = errors.New("nats_url is required")
	errMissingFields  = errors.New("source missing required fields (type, endpoint, prefix)")
)

type Config struct {
	Sources      map[string]*models.SourceConfig `json:"sources"`       // e.g., "armis": {...}, "netbox": {...}
	KVAddress    string                          `json:"kv_address"`    // KV gRPC server address (optional)
	NATSURL      string                          `json:"nats_url"`      // NATS server URL for JetStream
	PollInterval models.Duration                 `json:"poll_interval"` // Polling interval
	Security     *models.SecurityConfig          `json:"security"`      // mTLS config for gRPC/KV
	NATSSecurity *models.SecurityConfig          `json:"nats_security"` // Optional mTLS config for NATS
}

func (c *Config) Validate() error {
	if len(c.Sources) == 0 {
		return errMissingSources
	}

	if c.NATSURL == "" {
		c.NATSURL = "nats://localhost:4222"
	}

	if time.Duration(c.PollInterval) == 0 {
		c.PollInterval = models.Duration(defaultTimeout)
	}

	for name, src := range c.Sources {
		if src.Type == "" || src.Endpoint == "" || src.Prefix == "" {
			return fmt.Errorf("source %s: %w", name, errMissingFields)
		}
	}

	// Normalize TLS paths if security is configured
	if c.Security != nil {
		c.normalizeCertPaths(c.Security)
	}

	if c.NATSSecurity != nil {
		c.normalizeCertPaths(c.NATSSecurity)
	}

	return nil
}

// normalizeCertPaths ensures all TLS file paths are absolute by prepending CertDir.
func (c *Config) normalizeCertPaths(sec *models.SecurityConfig) {
	certDir := sec.CertDir
	if certDir == "" {
		return
	}

	tls := &sec.TLS // Use pointer to modify the original struct

	if !filepath.IsAbs(tls.CertFile) {
		tls.CertFile = filepath.Join(certDir, tls.CertFile)
	}

	if !filepath.IsAbs(tls.KeyFile) {
		tls.KeyFile = filepath.Join(certDir, tls.KeyFile)
	}

	if !filepath.IsAbs(tls.CAFile) {
		tls.CAFile = filepath.Join(certDir, tls.CAFile)
	}

	if tls.ClientCAFile != "" && !filepath.IsAbs(tls.ClientCAFile) {
		tls.ClientCAFile = filepath.Join(certDir, tls.ClientCAFile)
	} else if tls.ClientCAFile == "" {
		tls.ClientCAFile = tls.CAFile // Fallback to CAFile if unset
	}
}
