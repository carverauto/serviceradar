package dbeventwriter

import (
	"errors"

	"github.com/carverauto/serviceradar/pkg/logger"
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
	ErrStreamSubjectRequired = errors.New("stream subject is required")
	ErrStreamTableRequired   = errors.New("stream table is required")
)

// StreamConfig holds configuration for a specific stream/table pair
type StreamConfig struct {
	Subject string `json:"subject"`
	Table   string `json:"table"`
}

// DBEventWriterConfig holds configuration for the DB event writer consumer.
type DBEventWriterConfig struct {
	ListenAddr   string                 `json:"listen_addr"`
	NATSURL      string                 `json:"nats_url"`
	Subject      string                 `json:"subject"` // Legacy field for backward compatibility
	StreamName   string                 `json:"stream_name"`
	ConsumerName string                 `json:"consumer_name"`
	Domain       string                 `json:"domain"`
	Table        string                 `json:"table"`   // Legacy field for backward compatibility
	Streams      []StreamConfig         `json:"streams"` // New multi-stream configuration
	Security     *models.SecurityConfig `json:"security"`
	DBSecurity   *models.SecurityConfig `json:"db_security"`
	Database     models.ProtonDatabase  `json:"database"`
	Logging      *logger.Config         `json:"logging"` // Logger configuration including OTEL settings
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

	// Check if using legacy single stream config or new multi-stream config
	if len(c.Streams) > 0 {
		// New multi-stream configuration
		for _, stream := range c.Streams {
			if stream.Subject == "" {
				errs = append(errs, ErrStreamSubjectRequired)
			}

			if stream.Table == "" {
				errs = append(errs, ErrStreamTableRequired)
			}
		}
	} else if c.Table == "" {
		// Legacy single stream configuration
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

// GetStreams returns the stream configurations, handling both legacy and new formats
func (c *DBEventWriterConfig) GetStreams() []StreamConfig {
	if len(c.Streams) > 0 {
		return c.Streams
	}

	// Legacy configuration - create single stream from legacy fields
	if c.Subject != "" && c.Table != "" {
		return []StreamConfig{{
			Subject: c.Subject,
			Table:   c.Table,
		}}
	}

	return nil
}
