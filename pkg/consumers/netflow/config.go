package netflow

import (
	"errors"

	"github.com/carverauto/serviceradar/pkg/models"
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
		return errors.New("listen_addr is required")
	}
	if c.NATSURL == "" {
		return errors.New("nats_url is required")
	}
	if c.StreamName == "" {
		return errors.New("stream_name is required")
	}
	if c.ConsumerName == "" {
		return errors.New("consumer_name is required")
	}
	if c.Security == nil {
		return errors.New("security configuration is required")
	}
	return nil
}
