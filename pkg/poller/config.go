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

package poller

import (
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	errAgentAddressRequired = fmt.Errorf("agent address is required")
	errPollerIDRequired     = fmt.Errorf("poller id is required")
	errCoreAddressRequired  = fmt.Errorf("core address is required")
	errSourceIPRequired     = fmt.Errorf("source_ip is required")
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
	Type            string           `json:"service_type"`
	Name            string           `json:"service_name"`
	Details         string           `json:"details,omitempty"`
	Port            int32            `json:"port,omitempty"`
	ResultsInterval *models.Duration `json:"results_interval,omitempty"` // Optional interval for GetResults calls
}

// Config represents poller configuration.
type Config struct {
	Agents       map[string]AgentConfig `json:"agents"`
	ListenAddr   string                 `json:"listen_addr"`
	ServiceName  string                 `json:"service_name"`
	CoreAddress  string                 `json:"core_address"`
	PollInterval models.Duration        `json:"poll_interval"`
	PollerID     string                 `json:"poller_id"`
	Partition    string                 `json:"partition"`
	SourceIP     string                 `json:"source_ip"`
	Security     *models.SecurityConfig `json:"security"`
	Logging      *logger.Config         `json:"logging,omitempty"` // Logger configuration
}

// Validate implements config.Validator interface.
func (c *Config) Validate() error {
	if c.CoreAddress == "" {
		return errCoreAddressRequired
	}

	if c.PollerID == "" {
		return errPollerIDRequired
	}

	if c.SourceIP == "" {
		return errSourceIPRequired
	}

	if c.Partition == "" {
		c.Partition = "default"
	}

	if len(c.Agents) == 0 {
		return errAgentAddressRequired
	}

	// Compare PollInterval to zero by casting to time.Duration
	if time.Duration(c.PollInterval) == 0 {
		// Construct a config.Duration from a time.Duration
		c.PollInterval = models.Duration(pollDefaultInterval)
	}

	return nil
}
