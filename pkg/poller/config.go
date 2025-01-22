package poller

import (
	"fmt"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/config"
)

// AgentConfig represents configuration for a single agent.
type AgentConfig struct {
	Address string  `json:"address"`
	Checks  []Check `json:"checks"`
}

// Check represents a service check configuration.
type Check struct {
	Type    string `json:"service_type"`
	Name    string `json:"service_name"`
	Details string `json:"details,omitempty"`
	Port    int32  `json:"port,omitempty"`
}

// Config represents poller configuration
type Config struct {
	Agents       map[string]AgentConfig `json:"agents"`
	CloudAddress string                 `json:"cloud_address"`
	PollInterval config.Duration        `json:"poll_interval"`
	PollerID     string                 `json:"poller_id"`
}

// Validate implements config.Validator interface
func (c *Config) Validate() error {
	if c.CloudAddress == "" {
		return fmt.Errorf("cloud_address is required")
	}
	if c.PollerID == "" {
		return fmt.Errorf("poller_id is required")
	}
	if len(c.Agents) == 0 {
		return fmt.Errorf("at least one agent configuration is required")
	}

	// Compare PollInterval to zero by casting to time.Duration
	if time.Duration(c.PollInterval) == 0 {
		// Construct a config.Duration from a time.Duration
		c.PollInterval = config.Duration(30 * time.Second)
	}

	return nil
}
