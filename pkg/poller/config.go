// Package poller pkg/poller/config.go
package poller

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

// AgentConfig represents configuration for a single agent.
type AgentConfig struct {
	Address string  `json:"address"`
	Checks  []Check `json:"checks"`
}

// Config represents poller configuration
type Config struct {
	Agents       map[string]AgentConfig `json:"agents"`
	CloudAddress string                 `json:"cloud_address"`
	PollInterval Duration               `json:"poll_interval"`
	PollerID     string                 `json:"poller_id"`
}

// LoadConfig loads configuration from a file
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}

	return &cfg, nil
}

func (c *Config) validate() error {
	if c.CloudAddress == "" {
		return fmt.Errorf("cloud_address is required")
	}
	if c.PollerID == "" {
		return fmt.Errorf("poller_id is required")
	}
	if len(c.Agents) == 0 {
		return fmt.Errorf("at least one agent configuration is required")
	}
	if c.PollInterval.Duration == 0 {
		c.PollInterval = Duration{Duration: 30 * time.Second} // default
	}
	return nil
}

// Duration wraps time.Duration for JSON unmarshaling
type Duration struct {
	time.Duration
}

func (d *Duration) UnmarshalJSON(b []byte) error {
	var v interface{}
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}

	switch value := v.(type) {
	case float64:
		d.Duration = time.Duration(value)
		return nil
	case string:
		var err error
		d.Duration, err = time.ParseDuration(value)
		if err != nil {
			return fmt.Errorf("invalid duration: %w", err)
		}
		return nil
	default:
		return fmt.Errorf("invalid duration type: %T", v)
	}
}
