package dusk

import (
	"fmt"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/config"
)

// Config represents Dusk checker configuration
type Config struct {
	NodeAddress string          `json:"node_address"`
	Timeout     config.Duration `json:"timeout"`
	ListenAddr  string          `json:"listen_addr"`
}

// Validate implements config.Validator interface
func (c *Config) Validate() error {
	if c.NodeAddress == "" {
		return fmt.Errorf("node_address is required")
	}
	if c.ListenAddr == "" {
		return fmt.Errorf("listen_addr is required")
	}

	// Cast to time.Duration for comparison
	if time.Duration(c.Timeout) == 0 {
		// Assign a default by constructing a config.Duration
		c.Timeout = config.Duration(5 * time.Minute)
	}

	return nil
}
