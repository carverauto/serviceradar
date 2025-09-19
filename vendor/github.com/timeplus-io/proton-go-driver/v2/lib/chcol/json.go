// Licensed to ClickHouse, Inc. under one or more contributor
// license agreements. See the NOTICE file distributed with
// this work for additional information regarding copyright
// ownership. ClickHouse, Inc. licenses this file to you under
// the Apache License, Version 2.0 (the "License"); you may
// not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

package chcol

import (
	"database/sql/driver"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// JSONSerializer interface allows a struct to be manually converted to an optimized JSON structure instead of relying
// on recursive reflection.
// Note that the struct must be a pointer in order for the interface to be matched, reflection will be used otherwise.
type JSONSerializer interface {
	SerializeProtonJSON() (*JSON, error)
}

// JSONDeserializer interface allows a struct to load its data from an optimized JSON structure instead of relying
// on recursive reflection to set its fields.
type JSONDeserializer interface {
	DeserializeProtonJSON(*JSON) error
}

// ExtractJSONPath is a convenience function for asserting a path to a specific type.
// The underlying value is also extracted from its dynamic wrapper if present.
func ExtractJSONPath(o *JSON, path string) (interface{}, bool) {
	value, ok := o.valuesByPath[path]
	if !ok || value == nil {
		var empty interface{}
		return empty, false
	}

	dynValue, ok := value.(Dynamic)
	if !ok {
		return value, true
	}

	return dynValue.value, true
}

// JSON represents a ClickHouse JSON type that can hold multiple possible types
type JSON struct {
	valuesByPath map[string]interface{}
}

// NewJSON creates a new empty JSON value
func NewJSON() *JSON {
	return &JSON{
		valuesByPath: make(map[string]interface{}),
	}
}

func (o *JSON) ValuesByPath() map[string]interface{} {
	return o.valuesByPath
}

func (o *JSON) SetValueAtPath(path string, value interface{}) {
	o.valuesByPath[path] = value
}

func (o *JSON) ValueAtPath(path string) (interface{}, bool) {
	value, ok := o.valuesByPath[path]
	return value, ok
}

// NestedMap converts the flattened JSON data into a nested structure
func (o *JSON) NestedMap() map[string]interface{} {
	result := make(map[string]interface{})

	sortedPaths := make([]string, 0, len(o.valuesByPath))
	for path := range o.valuesByPath {
		sortedPaths = append(sortedPaths, path)
	}
	sort.Strings(sortedPaths)

	for _, path := range sortedPaths {
		value := o.valuesByPath[path]
		if vt, ok := value.(Variant); ok && vt.Nil() {
			continue
		}

		parts := strings.Split(path, ".")
		current := result

		for i := 0; i < len(parts)-1; i++ {
			part := parts[i]

			if _, exists := current[part]; !exists {
				current[part] = make(map[string]interface{})
			}

			if next, ok := current[part].(map[string]interface{}); ok {
				current = next
			}
		}
		current[parts[len(parts)-1]] = value
	}

	return result
}

// MarshalJSON implements the json.Marshaler interface
func (o *JSON) MarshalJSON() ([]byte, error) {
	return json.Marshal(o.NestedMap())
}

// Scan implements the sql.Scanner interface
func (o *JSON) Scan(value interface{}) error {
	switch vv := value.(type) {
	case JSON:
		o.valuesByPath = vv.valuesByPath
	case *JSON:
		o.valuesByPath = vv.valuesByPath
	case map[string]interface{}:
		o.valuesByPath = vv
	default:
		return fmt.Errorf("JSON Scan value must be proton.JSON or map[string]interface{}")
	}

	return nil
}

// Value implements the driver.Valuer interface
func (o *JSON) Value() (driver.Value, error) {
	return o, nil
}
