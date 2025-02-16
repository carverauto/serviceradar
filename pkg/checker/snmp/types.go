package snmp

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/config"
	"github.com/mfreeman451/serviceradar/pkg/grpc"
)

// SNMPVersion represents supported SNMP versions
type SNMPVersion string

const (
	Version1  SNMPVersion = "v1"
	Version2c SNMPVersion = "v2c"
	Version3  SNMPVersion = "v3"
)

// DataType represents the type of data being collected
type DataType string

const (
	TypeCounter DataType = "counter"
	TypeGauge   DataType = "gauge"
	TypeBoolean DataType = "boolean"
	TypeBytes   DataType = "bytes"
	TypeString  DataType = "string"
)

// Target represents a device to monitor via SNMP
type Target struct {
	Name      string        `json:"name"`
	Host      string        `json:"host"`
	Port      uint16        `json:"port"`
	Community string        `json:"community"`
	Version   SNMPVersion   `json:"version"`
	Timeout   Duration      `json:"timeout"`
	Retries   int           `json:"retries"`
	OIDs      []OIDConfig   `json:"oids"`
	Interval  time.Duration `json:"interval"`
}

// OIDConfig represents an OID to monitor
type OIDConfig struct {
	OID      string   `json:"oid"`
	Name     string   `json:"name"`
	DataType DataType `json:"type"`
	Scale    float64  `json:"scale,omitempty"` // For scaling values (e.g., bytes to megabytes)
	Delta    bool     `json:"delta,omitempty"` // Calculate change between samples
}

// Config represents the SNMP plugin configuration
type Config struct {
	Targets     []Target             `json:"targets"`
	Interval    Duration             `json:"interval"`
	NodeAddress string               `json:"node_address"`
	Timeout     config.Duration      `json:"timeout"`
	ListenAddr  string               `json:"listen_addr"`
	Security    *grpc.SecurityConfig `json:"security"`
}

// Duration is a wrapper for time.Duration that implements JSON marshaling
type Duration time.Duration

func (d *Duration) UnmarshalJSON(b []byte) error {
	var v interface{}
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}

	switch value := v.(type) {
	case float64:
		*d = Duration(time.Duration(value))
		return nil
	case string:
		tmp, err := time.ParseDuration(value)
		if err != nil {
			return err
		}
		*d = Duration(tmp)
		return nil
	default:
		return fmt.Errorf("invalid duration")
	}
}

// TimeSeriesData represents a single data point
type TimeSeriesData struct {
	OIDName   string
	Timestamp time.Time
	Value     interface{}
}

// DataPoint represents a single aggregated data point
type DataPoint struct {
	OIDName   string
	Timestamp time.Time
	Min       float64
	Max       float64
	Avg       float64
	Count     int64
	Value     interface{}
}

// Interval represents a time interval for data aggregation
type Interval string

const (
	Minute Interval = "minute"
	Hour   Interval = "hour"
	Day    Interval = "day"
)
