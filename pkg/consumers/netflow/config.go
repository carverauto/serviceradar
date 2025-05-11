package netflow

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"

	"github.com/carverauto/serviceradar/pkg/models"
)

// Error variables for config validation
var (
	ErrListenAddrRequired   = errors.New("listen_addr is required")
	ErrNATSURLRequired      = errors.New("nats_url is required")
	ErrStreamNameRequired   = errors.New("stream_name is required")
	ErrConsumerNameRequired = errors.New("consumer_name is required")
	ErrSecurityRequired     = errors.New("security configuration is required")
	ErrInvalidField         = errors.New("invalid enabled field")
	ErrDatabaseRequired     = errors.New("database configuration is required")
)

// DictionaryConfig represents a custom dictionary for enrichment
type DictionaryConfig struct {
	Name       string   `json:"name"`       // e.g., "asn_dictionary"
	Source     string   `json:"source"`     // e.g., "/path/to/asn.csv"
	Keys       []string `json:"keys"`       // e.g., ["ip"]
	Attributes []string `json:"attributes"` // e.g., ["asn", "name"]
	Layout     string   `json:"layout"`     // e.g., "hashed"
}

// Config holds the configuration for the NetFlow consumer service.
type Config struct {
	ListenAddr     string                 `json:"listen_addr"`
	NATSURL        string                 `json:"nats_url"`
	StreamName     string                 `json:"stream_name"`
	ConsumerName   string                 `json:"consumer_name"`
	Security       *models.SecurityConfig `json:"security"`
	EnabledFields  []models.ColumnKey     `json:"enabled_fields"`
	DisabledFields []models.ColumnKey     `json:"disabled_fields"`
	Dictionaries   []DictionaryConfig     `json:"dictionaries"`
	DBConfig       models.DBConfig        `json:"database"`
}

// UnmarshalJSON customizes JSON unmarshalling to handle DBConfig fields
func (c *Config) UnmarshalJSON(data []byte) error {
	log.Printf("Raw JSON data: %s", string(data))

	type ConfigAlias struct {
		ListenAddr     string                 `json:"listen_addr"`
		NATSURL        string                 `json:"nats_url"`
		StreamName     string                 `json:"stream_name"`
		ConsumerName   string                 `json:"consumer_name"`
		Security       *models.SecurityConfig `json:"security"`
		EnabledFields  []models.ColumnKey     `json:"enabled_fields"`
		DisabledFields []models.ColumnKey     `json:"disabled_fields"`
		Dictionaries   []DictionaryConfig     `json:"dictionaries"`
		Database       models.ProtonDatabase  `json:"database"`
	}

	var alias ConfigAlias
	if err := json.Unmarshal(data, &alias); err != nil {
		log.Printf("Failed to unmarshal Config JSON: %v", err)
		return fmt.Errorf("failed to unmarshal Config: %w", err)
	}

	c.ListenAddr = alias.ListenAddr
	c.NATSURL = alias.NATSURL
	c.StreamName = alias.StreamName
	c.ConsumerName = alias.ConsumerName
	c.Security = alias.Security
	c.EnabledFields = alias.EnabledFields
	c.DisabledFields = alias.DisabledFields
	c.Dictionaries = alias.Dictionaries
	c.DBConfig = models.DBConfig{
		Database: alias.Database,
	}

	if len(c.DBConfig.Database.Addresses) > 0 {
		c.DBConfig.DBAddr = c.DBConfig.Database.Addresses[0]
		log.Printf("Set DBAddr to: %s", c.DBConfig.DBAddr)
	} else {
		log.Printf("No addresses found in DBConfig.Database.Addresses")
	}

	c.DBConfig.DBName = alias.Database.Name
	c.DBConfig.DBUser = alias.Database.Username
	c.DBConfig.DBPass = alias.Database.Password
	c.DBConfig.Security = c.Security

	log.Printf("Unmarshalled Config: %+v", c)
	return nil
}

// Validate ensures the configuration is valid.
func (c *Config) Validate() error {
	if c.ListenAddr == "" {
		return fmt.Errorf("listen_addr is required")
	}
	if c.NATSURL == "" {
		return fmt.Errorf("nats_url is required")
	}
	if c.StreamName == "" {
		return fmt.Errorf("stream_name is required")
	}
	if c.ConsumerName == "" {
		return fmt.Errorf("consumer_name is required")
	}
	if c.DBConfig.DBAddr == "" {
		return fmt.Errorf("database configuration is required")
	}

	// Validate EnabledFields and DisabledFields do not overlap
	for _, enabled := range c.EnabledFields {
		for _, disabled := range c.DisabledFields {
			if enabled == disabled {
				return fmt.Errorf("column %v cannot be both enabled and disabled", enabled)
			}
		}
	}

	return nil
}
