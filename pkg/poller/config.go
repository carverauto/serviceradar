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
)

const (
	defaultPollInterval = 5 * time.Minute
)

// AgentConfig represents configuration for a single agent.
type AgentConfig struct {
	Address  string                 `json:"address" hot:"rebuild"`
	Checks   []Check                `json:"checks" hot:"rebuild"`
	Security *models.SecurityConfig `json:"security" hot:"rebuild"` // Per-agent security config
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
	Agents       map[string]AgentConfig `json:"agents" hot:"rebuild"`
	ListenAddr   string                 `json:"listen_addr"`
	ServiceName  string                 `json:"service_name"`
	CoreAddress  string                 `json:"core_address" hot:"rebuild"`
	PollInterval models.Duration        `json:"poll_interval" hot:"reload"`
	PollerID     string                 `json:"poller_id"`
	Partition    string                 `json:"partition"`
	SourceIP     string                 `json:"source_ip"`
	Security     *models.SecurityConfig `json:"security" hot:"rebuild"`
	Logging      *logger.Config         `json:"logging,omitempty"`    // Logger configuration
	KVAddress    string                 `json:"kv_address,omitempty"` // Optional KV store address (deprecated for ID/domain)
	KVDomain     string                 `json:"kv_domain,omitempty"`  // JetStream domain for KV (e.g., "hub", "leaf-001")
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
		c.SourceIP = "auto"
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
		c.PollInterval = models.Duration(defaultPollInterval)
	}

	return nil
}
