/*-
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

package poller

import (
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errAgentAddressRequired = fmt.Errorf("agent address is required")
	errPollerIDRequired     = fmt.Errorf("poller id is required")
	errCloudAddressRequired = fmt.Errorf("cloud address is required")
)

const (
	pollDefaultInterval = 30 * time.Second
)

// AgentConfig represents configuration for a single agent.
type AgentConfig struct {
	Address  string                `json:"address"`
	Checks   []Check               `json:"checks"`
	Security models.SecurityConfig `json:"security"` // Per-agent security config
}

// Check represents a service check configuration.
type Check struct {
	Type    string `json:"service_type"`
	Name    string `json:"service_name"`
	Details string `json:"details,omitempty"`
	Port    int32  `json:"port,omitempty"`
}

// Config represents poller configuration.
type Config struct {
	Agents       map[string]AgentConfig `json:"agents"`
	ListenAddr   string                 `json:"listen_addr"`
	ServiceName  string                 `json:"service_name"`
	CloudAddress string                 `json:"cloud_address"`
	PollInterval config.Duration        `json:"poll_interval"`
	PollerID     string                 `json:"poller_id"`
	Security     *models.SecurityConfig `json:"security"`
}

// Validate implements config.Validator interface.
func (c *Config) Validate() error {
	if c.CloudAddress == "" {
		return errCloudAddressRequired
	}

	if c.PollerID == "" {
		return errPollerIDRequired
	}

	if len(c.Agents) == 0 {
		return errAgentAddressRequired
	}

	// Compare PollInterval to zero by casting to time.Duration
	if time.Duration(c.PollInterval) == 0 {
		// Construct a config.Duration from a time.Duration
		c.PollInterval = config.Duration(pollDefaultInterval)
	}

	return nil
}
