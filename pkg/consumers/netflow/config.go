/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package netflow

import (
	"encoding/json"
	"errors"
	"strings"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
)

// Configuration errors
var (
	ErrMissingListenAddr   = errors.New("listen_addr is required")
	ErrMissingNATSURL      = errors.New("nats_url is required")
	ErrMissingStreamName   = errors.New("stream_name is required")
	ErrMissingConsumerName = errors.New("consumer_name is required")
	ErrMissingCNPGConfig   = errors.New("cnpg configuration is required")
	ErrInvalidJSON         = errors.New("failed to unmarshal JSON configuration")
	ErrFieldConflict       = errors.New("same column cannot be both enabled and disabled")
)

// NetflowConfig holds the configuration for the NetFlow consumer service.
type NetflowConfig struct {
	*models.NetflowConfig
}

// NewNetflowConfig creates a new NetflowConfig from a models.NetflowConfig
func NewNetflowConfig(cfg *models.NetflowConfig) *NetflowConfig {
	return &NetflowConfig{NetflowConfig: cfg}
}

// UnmarshalJSON hydrates the embedded models.NetflowConfig and normalizes TLS paths.
func (c *NetflowConfig) UnmarshalJSON(data []byte) error {
	type ConfigAlias struct {
		*models.NetflowConfig
	}

	var alias ConfigAlias

	if err := json.Unmarshal(data, &alias); err != nil {
		return errors.Join(ErrInvalidJSON, err)
	}

	if alias.NetflowConfig == nil {
		alias.NetflowConfig = &models.NetflowConfig{}
	}

	c.NetflowConfig = alias.NetflowConfig

	// Normalize TLS paths if SecurityConfig is present
	if c.Security != nil && c.Security.CertDir != "" {
		config.NormalizeTLSPaths(&c.Security.TLS, c.Security.CertDir)
	}

	return nil
}

// Validate ensures the configuration is valid.
func (c *NetflowConfig) Validate() error {
	var errs []error

	if c.ListenAddr == "" {
		errs = append(errs, ErrMissingListenAddr)
	}

	if c.NATSURL == "" {
		errs = append(errs, ErrMissingNATSURL)
	}

	if c.StreamName == "" {
		errs = append(errs, ErrMissingStreamName)
	}

	if c.ConsumerName == "" {
		errs = append(errs, ErrMissingConsumerName)
	}

	if c.CNPG == nil ||
		strings.TrimSpace(c.CNPG.Host) == "" ||
		strings.TrimSpace(c.CNPG.Username) == "" ||
		strings.TrimSpace(c.CNPG.Database) == "" {
		errs = append(errs, ErrMissingCNPGConfig)
	}

	// Check for overlapping EnabledFields and DisabledFields
	for _, enabled := range c.EnabledFields {
		for _, disabled := range c.DisabledFields {
			if enabled == disabled {
				errs = append(errs, ErrFieldConflict)
			}
		}
	}

	if len(errs) > 0 {
		return errors.Join(errs...)
	}

	return nil
}
