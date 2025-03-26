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

package kv

import (
	"fmt"
	"path/filepath"

	"github.com/carverauto/serviceradar/pkg/models"
)

// Role defines a role in the RBAC system.
type Role string

const (
	RoleReader Role = "reader"
	RoleWriter Role = "writer"
)

// RBACRule maps a client identity to a role.
type RBACRule struct {
	Identity string `json:"identity"`
	Role     Role   `json:"role"`
}

// Config holds the configuration for the KV service.
type Config struct {
	ListenAddr string                 `json:"listen_addr"`
	NatsURL    string                 `json:"nats_url"`
	Security   *models.SecurityConfig `json:"security"`
	RBAC       struct {
		Roles []RBACRule `json:"roles"`
	} `json:"rbac"`
	Bucket string `json:"bucket,omitempty"` // Added for NATS KV bucket
}

var (
	errListenAddrRequired = fmt.Errorf("listen_addr is required")
	errNatsURLRequired    = fmt.Errorf("nats_url is required")
	errSecurityRequired   = fmt.Errorf("security configuration is required for mTLS")
	errCertFileRequired   = fmt.Errorf("tls.cert_file is required for mTLS")
	errKeyFileRequired    = fmt.Errorf("tls.key_file is required for mTLS")
	errCAFileRequired     = fmt.Errorf("tls.ca_file is required for mTLS")
)

// Validate ensures the configuration is valid.
func (c *Config) Validate() error {
	if err := c.validateRequiredFields(); err != nil {
		return err
	}

	if err := c.validateSecurity(); err != nil {
		return err
	}

	c.normalizeCertPaths()
	c.setDefaultBucket()

	return nil
}

// validateRequiredFields checks for mandatory top-level fields.
func (c *Config) validateRequiredFields() error {
	if c.ListenAddr == "" {
		return errListenAddrRequired
	}

	if c.NatsURL == "" {
		return errNatsURLRequired
	}

	return nil
}

// validateSecurity ensures security settings are valid.
func (c *Config) validateSecurity() error {
	if c.Security == nil || c.Security.Mode != "mtls" {
		return errSecurityRequired
	}

	tls := c.Security.TLS

	if tls.CertFile == "" {
		return errCertFileRequired
	}

	if tls.KeyFile == "" {
		return errKeyFileRequired
	}

	if tls.CAFile == "" {
		return errCAFileRequired
	}

	return nil
}

// normalizeCertPaths prepends CertDir to relative TLS file paths.
func (c *Config) normalizeCertPaths() {
	certDir := c.Security.CertDir
	if certDir == "" {
		return
	}

	tls := &c.Security.TLS

	if !filepath.IsAbs(tls.CertFile) {
		tls.CertFile = filepath.Join(certDir, tls.CertFile)
	}

	if !filepath.IsAbs(tls.KeyFile) {
		tls.KeyFile = filepath.Join(certDir, tls.KeyFile)
	}

	if !filepath.IsAbs(tls.CAFile) {
		tls.CAFile = filepath.Join(certDir, tls.CAFile)
	}
}

// setDefaultBucket assigns a default bucket name if none is specified.
func (c *Config) setDefaultBucket() {
	if c.Bucket == "" {
		c.Bucket = "serviceradar-kv"
	}
}
