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
	if c.ListenAddr == "" {
		return errListenAddrRequired
	}
	if c.NatsURL == "" {
		return errNatsURLRequired
	}
	if c.Security == nil || c.Security.Mode != "mtls" {
		return errSecurityRequired
	}

	// Normalize paths by prepending CertDir if provided
	certDir := c.Security.CertDir
	if certDir != "" {
		if !filepath.IsAbs(c.Security.TLS.CertFile) {
			c.Security.TLS.CertFile = filepath.Join(certDir, c.Security.TLS.CertFile)
		}
		if !filepath.IsAbs(c.Security.TLS.KeyFile) {
			c.Security.TLS.KeyFile = filepath.Join(certDir, c.Security.TLS.KeyFile)
		}
		if !filepath.IsAbs(c.Security.TLS.CAFile) {
			c.Security.TLS.CAFile = filepath.Join(certDir, c.Security.TLS.CAFile)
		}
	}

	// Validate TLS fields
	if c.Security.TLS.CertFile == "" {
		return errCertFileRequired
	}
	if c.Security.TLS.KeyFile == "" {
		return errKeyFileRequired
	}
	if c.Security.TLS.CAFile == "" {
		return errCAFileRequired
	}

	// Default bucket if not specified
	if c.Bucket == "" {
		c.Bucket = "serviceradar-kv"
	}

	return nil
}
