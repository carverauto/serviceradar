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
	log.Printf("Raw JSON data: %s", string(data))

	// Unmarshal directly into the embedded NetflowConfig
	if err := json.Unmarshal(data, &c.NetflowConfig); err != nil {
		log.Printf("Failed to unmarshal NetflowConfig JSON: %v", err)
		return fmt.Errorf("failed to unmarshal NetflowConfig: %w", err)
	}

	log.Printf("Unmarshalled NetflowConfig: %+v", c)
	return nil
}

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
