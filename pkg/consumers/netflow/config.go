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

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
)

// Configuration errors
var (
	ErrMissingListenAddr     = errors.New("listen_addr is required")
	ErrMissingNATSURL        = errors.New("nats_url is required")
	ErrMissingStreamName     = errors.New("stream_name is required")
	ErrMissingConsumerName   = errors.New("consumer_name is required")
	ErrMissingDatabaseConfig = errors.New("database configuration is required")
	ErrInvalidJSON           = errors.New("failed to unmarshal JSON configuration")
	ErrFieldConflict         = errors.New("same column cannot be both enabled and disabled")
)

// NetflowConfig holds the configuration for the NetFlow consumer service.
type NetflowConfig struct {
	*models.NetflowConfig
}

// NewNetflowConfig creates a new NetflowConfig from a models.NetflowConfig
func NewNetflowConfig(cfg *models.NetflowConfig) *NetflowConfig {
	return &NetflowConfig{NetflowConfig: cfg}
}

// UnmarshalJSON customizes JSON unmarshalling to handle DBConfig fields
func (c *NetflowConfig) UnmarshalJSON(data []byte) error {
	type ConfigAlias struct {
		ListenAddr     string                    `json:"listen_addr"`
		NATSURL        string                    `json:"nats_url"`
		StreamName     string                    `json:"stream_name"`
		ConsumerName   string                    `json:"consumer_name"`
		Security       *models.SecurityConfig    `json:"security"`
		EnabledFields  []models.ColumnKey        `json:"enabled_fields"`
		DisabledFields []models.ColumnKey        `json:"disabled_fields"`
		Dictionaries   []models.DictionaryConfig `json:"dictionaries"`
		Database       models.ProtonDatabase     `json:"database"`
	}

	var alias ConfigAlias

	if err := json.Unmarshal(data, &alias); err != nil {
		return errors.Join(ErrInvalidJSON, err)
	}

	// Initialize NetflowConfig if nil
	if c.NetflowConfig == nil {
		c.NetflowConfig = &models.NetflowConfig{}
	}

	c.ListenAddr = alias.ListenAddr
	c.NATSURL = alias.NATSURL
	c.StreamName = alias.StreamName
	c.ConsumerName = alias.ConsumerName
	c.Security = alias.Security
	c.EnabledFields = alias.EnabledFields
	c.DisabledFields = alias.DisabledFields
	c.Dictionaries = alias.Dictionaries
	c.DBConfig = models.DBConfig{
		Database: alias.Database,
	}

	if len(c.DBConfig.Database.Addresses) > 0 {
		c.DBConfig.DBAddr = c.DBConfig.Database.Addresses[0]
	}

	c.DBConfig.DBName = alias.Database.Name
	c.DBConfig.DBUser = alias.Database.Username
	c.DBConfig.DBPass = alias.Database.Password
	c.DBConfig.Security = c.Security

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

	if c.DBConfig.DBAddr == "" {
		errs = append(errs, ErrMissingDatabaseConfig)
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
