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
	"fmt"
	"log"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
)

// NetflowConfig holds the configuration for the NetFlow consumer service.
type NetflowConfig struct {
	models.NetflowConfig
}

// NewNetflowConfig creates a new NetflowConfig from a models.NetflowConfig
func NewNetflowConfig(cfg models.NetflowConfig) *NetflowConfig {
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
		log.Printf("Failed to unmarshal Config JSON: %v", err)

		return fmt.Errorf("failed to unmarshal Config: %w", err)
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
		log.Printf("Normalized TLS paths in UnmarshalJSON: CertFile=%s, KeyFile=%s, CAFile=%s, ClientCAFile=%s",
			c.Security.TLS.CertFile, c.Security.TLS.KeyFile,
			c.Security.TLS.CAFile, c.Security.TLS.ClientCAFile)
	}

	return nil
}

/*
func (c *NetflowConfig) UnmarshalJSON(data []byte) error {
	// Unmarshal directly into the embedded NetflowConfig
	if err := json.Unmarshal(data, &c.NetflowConfig); err != nil {
		log.Printf("Failed to unmarshal NetflowConfig JSON: %v", err)

		return fmt.Errorf("failed to unmarshal NetflowConfig: %w", err)
	}

	return nil
}

*/

// Validate ensures the configuration is valid.
func (c *NetflowConfig) Validate() error {
	if c.ListenAddr == "" {
		return fmt.Errorf("listen_addr is required")
	}

	if c.NATSURL == "" {
		return fmt.Errorf("nats_url is required")
	}

	if c.StreamName == "" {
		return fmt.Errorf("stream_name is required")
	}

	if c.ConsumerName == "" {
		return fmt.Errorf("consumer_name is required")
	}

	if c.DBConfig.DBAddr == "" {
		return fmt.Errorf("database configuration is required")
	}

	// Validate EnabledFields and DisabledFields do not overlap
	for _, enabled := range c.EnabledFields {
		for _, disabled := range c.DisabledFields {
			if enabled == disabled {
				return fmt.Errorf("column %v cannot be both enabled and disabled", enabled)
			}
		}
	}

	return nil
}
