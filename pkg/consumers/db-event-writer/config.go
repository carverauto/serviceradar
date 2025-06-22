package dbeventwriter

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
	ErrMissingTableName      = errors.New("table is required")
	ErrMissingDatabaseConfig = errors.New("database configuration is required")
	ErrInvalidJSON           = errors.New("failed to unmarshal JSON configuration")
)

// DBEventWriterConfig holds configuration for the DB event writer consumer.
type DBEventWriterConfig struct {
	ListenAddr   string                 `json:"listen_addr"`
	NATSURL      string                 `json:"nats_url"`
	Subject      string                 `json:"subject"`
	StreamName   string                 `json:"stream_name"`
	ConsumerName string                 `json:"consumer_name"`
	Domain       string                 `json:"domain"`
	Table        string                 `json:"table"`
	Security     *models.SecurityConfig `json:"security"`
	DBSecurity   *models.SecurityConfig `json:"db_security"`
	Database     models.ProtonDatabase  `json:"database"`
}

// UnmarshalJSON ensures TLS paths are normalized.
func (c *DBEventWriterConfig) UnmarshalJSON(data []byte) error {
	type Alias DBEventWriterConfig

	var alias struct{ Alias }

	alias.Alias = Alias{}

	if err := json.Unmarshal(data, &alias); err != nil {
		return errors.Join(ErrInvalidJSON, err)
	}

	*c = DBEventWriterConfig(alias.Alias)

	if c.Security != nil && c.Security.CertDir != "" {
		config.NormalizeTLSPaths(&c.Security.TLS, c.Security.CertDir)
	}

	if c.DBSecurity != nil && c.DBSecurity.CertDir != "" {
		config.NormalizeTLSPaths(&c.DBSecurity.TLS, c.DBSecurity.CertDir)
	}

	return nil
}

// Validate checks the configuration for required fields.
func (c *DBEventWriterConfig) Validate() error {
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

	if c.Table == "" {
		errs = append(errs, ErrMissingTableName)
	}

	if c.Database.Name == "" || len(c.Database.Addresses) == 0 {
		errs = append(errs, ErrMissingDatabaseConfig)
	}

	if len(errs) > 0 {
		return errors.Join(errs...)
	}

	return nil
}
