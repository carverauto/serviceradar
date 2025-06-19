package devices

import (
	"encoding/json"
	"errors"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
)

var (
	ErrMissingListenAddr     = errors.New("listen_addr is required")
	ErrMissingNATSURL        = errors.New("nats_url is required")
	ErrMissingStreamName     = errors.New("stream_name is required")
	ErrMissingConsumerName   = errors.New("consumer_name is required")
	ErrMissingDatabaseConfig = errors.New("database configuration is required")
	ErrInvalidJSON           = errors.New("failed to unmarshal JSON configuration")
)

type DeviceConsumerConfig struct {
	ListenAddr   string                 `json:"listen_addr"`
	NATSURL      string                 `json:"nats_url"`
	Subject      string                 `json:"subject"`
	StreamName   string                 `json:"stream_name"`
	ConsumerName string                 `json:"consumer_name"`
	Domain       string                 `json:"domain"`
	AgentID      string                 `json:"agent_id"`
	PollerID     string                 `json:"poller_id"`
	Security     *models.SecurityConfig `json:"security"`
	DBSecurity   *models.SecurityConfig `json:"db_security"`
	Database     models.ProtonDatabase  `json:"database"`
}

func (c *DeviceConsumerConfig) UnmarshalJSON(data []byte) error {
	type Alias DeviceConsumerConfig

	var alias struct {
		Alias
	}

	alias.Alias = Alias{}

	if err := json.Unmarshal(data, &alias); err != nil {
		return errors.Join(ErrInvalidJSON, err)
	}

	*c = DeviceConsumerConfig(alias.Alias)

	if c.Security != nil && c.Security.CertDir != "" {
		config.NormalizeTLSPaths(&c.Security.TLS, c.Security.CertDir)
	}

	if c.DBSecurity != nil && c.DBSecurity.CertDir != "" {
		config.NormalizeTLSPaths(&c.DBSecurity.TLS, c.DBSecurity.CertDir)
	}

	return nil
}

func (c *DeviceConsumerConfig) Validate() error {
	var errs []error

	if c.ListenAddr == "" {
		errs = append(errs, ErrMissingListenAddr)
	}

	if c.NATSURL == "" {
		errs = append(errs, ErrMissingNATSURL)
	}

	if c.StreamName == "" {
		errs = append(errs, ErrMissingStreamName)
	}

	if c.ConsumerName == "" {
		errs = append(errs, ErrMissingConsumerName)
	}

	if c.Database.Name == "" || len(c.Database.Addresses) == 0 {
		errs = append(errs, ErrMissingDatabaseConfig)
	}

	if len(errs) > 0 {
		return errors.Join(errs...)
	}

	return nil
}
