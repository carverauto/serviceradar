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

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultTimeout = 30 * time.Second
)

var (
	errMissingSources     = errors.New("at least one source must be defined")
	errMissingFields      = errors.New("source missing required fields (type, endpoint)")
	errListenAddrRequired = errors.New("listen_addr is required for the gRPC server")
)

// Config defines the configuration for the sync service including sources, logging, and OTEL settings.
type Config struct {
	Sources           map[string]*models.SourceConfig `json:"sources"`            // e.g., "armis": {...}, "netbox": {...}
	KVAddress         string                          `json:"kv_address"`         // KV gRPC server address (optional)
	ListenAddr        string                          `json:"listen_addr"`        // gRPC listen address for the discovery service
	PollInterval      models.Duration                 `json:"poll_interval"`      // Polling interval
	DiscoveryInterval models.Duration                 `json:"discovery_interval"` // How often to fetch devices from integrations
	UpdateInterval    models.Duration                 `json:"update_interval"`    // How often to update external systems (Armis/Netbox)
	AgentID           string                          `json:"agent_id"`           // Default Agent ID for device records
	PollerID          string                          `json:"poller_id"`          // Default Poller ID for device records
	Security          *models.SecurityConfig          `json:"security"`           // mTLS config for gRPC
	Logging           *logger.Config                  `json:"logging"`            // Logger configuration including OTEL settings
}

func (c *Config) Validate() error {
	if len(c.Sources) == 0 {
		return errMissingSources
	}

	if c.ListenAddr == "" {
		return errListenAddrRequired
	}

	if time.Duration(c.PollInterval) == 0 {
		c.PollInterval = models.Duration(defaultTimeout)
	}

	if time.Duration(c.DiscoveryInterval) == 0 {
		c.DiscoveryInterval = models.Duration(5 * time.Minute)
	}

	if time.Duration(c.UpdateInterval) == 0 {
		c.UpdateInterval = models.Duration(10 * time.Minute)
	}

	for name, src := range c.Sources {
		if src.Type == "" || src.Endpoint == "" {
			return fmt.Errorf("source %s: %w", name, errMissingFields)
		}
	}

	if c.Security != nil {
		c.normalizeCertPaths(c.Security)
	}

	return nil
}

func (*Config) normalizeCertPaths(sec *models.SecurityConfig) {
	certDir := sec.CertDir
	if certDir == "" {
		return
	}

	tls := &sec.TLS
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
		tls.ClientCAFile = tls.CAFile
	}
}
