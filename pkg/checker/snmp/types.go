package snmp

import (
	"encoding/json"
	"fmt"
	"time"
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

// Interval represents a time interval for data aggregation
type Interval string

const (
	Minute Interval = "minute"
	Hour   Interval = "hour"
	Day    Interval = "day"
)
