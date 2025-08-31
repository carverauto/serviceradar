package db

import (
	"encoding/json"
	"fmt"
)

// JSONMap is a helper type for ClickHouse JSON columns
// that wraps a map[string]string for proper JSON serialization
type JSONMap map[string]string

// String implements the Stringer interface to return JSON representation
func (j JSONMap) String() string {
	if j == nil {
		return "{}"
	}
	jsonBytes, err := json.Marshal(map[string]string(j))
	if err != nil {
		return "{}"
	}
	return string(jsonBytes)
}

// MarshalJSON implements json.Marshaler interface
func (j JSONMap) MarshalJSON() ([]byte, error) {
	if j == nil {
		return []byte("{}"), nil
	}
	return json.Marshal(map[string]string(j))
}

// UnmarshalJSON implements json.Unmarshaler interface
func (j *JSONMap) UnmarshalJSON(data []byte) error {
	var m map[string]string
	if err := json.Unmarshal(data, &m); err != nil {
		return err
	}
	*j = JSONMap(m)
	return nil
}

// Value implements driver.Valuer interface for database storage
func (j JSONMap) Value() (interface{}, error) {
	if j == nil {
		return "{}", nil
	}
	return j.String(), nil
}

// Scan implements sql.Scanner interface for database retrieval
func (j *JSONMap) Scan(value interface{}) error {
	if value == nil {
		*j = make(JSONMap)
		return nil
	}
	
	var jsonStr string
	switch v := value.(type) {
	case string:
		jsonStr = v
	case []byte:
		jsonStr = string(v)
	default:
		return fmt.Errorf("cannot scan %T into JSONMap", value)
	}
	
	var m map[string]string
	if err := json.Unmarshal([]byte(jsonStr), &m); err != nil {
		return err
	}
	*j = JSONMap(m)
	return nil
}

// ToMap converts JSONMap to regular map[string]string
func (j JSONMap) ToMap() map[string]string {
	if j == nil {
		return make(map[string]string)
	}
	return map[string]string(j)
}

// FromMap creates JSONMap from regular map[string]string
func FromMap(m map[string]string) JSONMap {
	if m == nil {
		return make(JSONMap)
	}
	return JSONMap(m)
}