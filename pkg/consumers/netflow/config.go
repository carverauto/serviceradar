package netflow

import (
	"errors"

	"github.com/carverauto/serviceradar/pkg/models"
)

// Error variables for config validation
var (
	ErrListenAddrRequired   = errors.New("listen_addr is required")
	ErrNATSURLRequired      = errors.New("nats_url is required")
	ErrStreamNameRequired   = errors.New("stream_name is required")
	ErrConsumerNameRequired = errors.New("consumer_name is required")
	ErrSecurityRequired     = errors.New("security configuration is required")
)

// Config holds the configuration for the NetFlow consumer service.
type Config struct {
	ListenAddr   string                 `json:"listen_addr"`   // e.g., ":50060"
	NATSURL      string                 `json:"nats_url"`      // e.g., "nats://172.236.111.20:4222"
	StreamName   string                 `json:"stream_name"`   // e.g., "goflow2"
	ConsumerName string                 `json:"consumer_name"` // e.g., "myconsumer"
	Security     *models.SecurityConfig `json:"security"`
}

// Validate ensures the configuration is valid.
func (c *Config) Validate() error {
	if c.ListenAddr == "" {
		return ErrListenAddrRequired
	}

	if c.NATSURL == "" {
		return ErrNATSURLRequired
	}

	if c.StreamName == "" {
		return ErrStreamNameRequired
	}

	if c.ConsumerName == "" {
		return ErrConsumerNameRequired
	}

	if c.Security == nil {
		return ErrSecurityRequired
	}

	return nil
}
