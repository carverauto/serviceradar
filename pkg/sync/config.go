package sync

import (
	"errors"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	defaultTimeout = 30 * time.Second
)

var (
	errMissingSources = errors.New("at least one source must be defined")
	errMissingKV      = errors.New("kv_address is required")
	errMissingFields  = errors.New("source missing required fields (type, endpoint, prefix)")
)

type Config struct {
	Sources      map[string]models.SourceConfig `json:"sources"`       // e.g., "armis": {...}, "netbox": {...}
	KVAddress    string                         `json:"kv_address"`    // KV gRPC server address
	PollInterval config.Duration                `json:"poll_interval"` // Polling interval
	Security     *models.SecurityConfig         `json:"security"`      // mTLS config
}

func (c *Config) Validate() error {
	if len(c.Sources) == 0 {
		return errMissingSources
	}

	if c.KVAddress == "" {
		return errMissingKV
	}

	if time.Duration(c.PollInterval) == 0 {
		c.PollInterval = config.Duration(defaultTimeout)
	}

	for name, src := range c.Sources {
		if src.Type == "" || src.Endpoint == "" || src.Prefix == "" {
			return fmt.Errorf("source %s: %w", name, errMissingFields)
		}
	}

	return nil
}
