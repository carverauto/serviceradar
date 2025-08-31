/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package models

import (
	"fmt"
	"reflect"
	"strings"
)

// FilterSensitiveFields removes fields marked with `sensitive:"true"` tag
// from a struct before serializing it. This ensures sensitive data like
// secrets and passwords are never stored in databases or sent to UIs.
func FilterSensitiveFields(input interface{}) (map[string]interface{}, error) {
	if input == nil {
		return make(map[string]interface{}), nil
	}
	
	result := filterRecursively(input)
	if result == nil {
		return make(map[string]interface{}), nil
	}
	
	if resultMap, ok := result.(map[string]interface{}); ok {
		return resultMap, nil
	}
	
	return nil, fmt.Errorf("input must be a struct or pointer to struct")
}

// filterRecursively handles the actual recursive filtering
func filterRecursively(input interface{}) interface{} {
	if input == nil {
		return nil
	}
	
	rv := reflect.ValueOf(input)
	rt := reflect.TypeOf(input)
	
	// Dereference pointers
	if rv.Kind() == reflect.Ptr {
		if rv.IsNil() {
			return nil
		}
		rv = rv.Elem()
		rt = rt.Elem()
	}
	
	switch rv.Kind() {
	case reflect.Struct:
		result := make(map[string]interface{})
		
		for i := 0; i < rt.NumField(); i++ {
			field := rt.Field(i)
			fieldValue := rv.Field(i)
			jsonTag := field.Tag.Get("json")
			sensitiveTag := field.Tag.Get("sensitive")
			
			// Skip unexported fields
			if !fieldValue.CanInterface() {
				continue
			}
			
			// Skip fields marked as sensitive
			if sensitiveTag == "true" {
				continue
			}
			
			// Skip fields with json:"-"
			if jsonTag == "-" {
				continue
			}
			
			// Get the JSON field name
			fieldName := field.Name
			if jsonTag != "" {
				// Remove comma and options from json tag
				if commaIdx := strings.Index(jsonTag, ","); commaIdx != -1 {
					fieldName = jsonTag[:commaIdx]
				} else {
					fieldName = jsonTag
				}
			}
			
			// Recursively filter the field value
			filteredValue := filterRecursively(fieldValue.Interface())
			result[fieldName] = filteredValue
		}
		
		return result
		
	case reflect.Slice, reflect.Array:
		result := make([]interface{}, rv.Len())
		for i := 0; i < rv.Len(); i++ {
			result[i] = filterRecursively(rv.Index(i).Interface())
		}
		return result
		
	case reflect.Map:
		result := make(map[string]interface{})
		for _, key := range rv.MapKeys() {
			if keyStr, ok := key.Interface().(string); ok {
				result[keyStr] = filterRecursively(rv.MapIndex(key).Interface())
			}
		}
		return result
		
	default:
		// For basic types, return as-is
		return input
	}
}

// ExtractSafeConfigMetadata extracts only safe, non-sensitive configuration
// metadata for service registration and tracking purposes.
func ExtractSafeConfigMetadata(config interface{}) map[string]string {
	metadata := make(map[string]string)
	
	safeData, err := FilterSensitiveFields(config)
	if err != nil {
		return metadata
	}
	
	// Convert the filtered data to string key-value pairs for database storage
	for key, value := range safeData {
		if value != nil {
			switch v := value.(type) {
			case string:
				if v != "" {
					metadata[key] = v
				}
			case bool:
				metadata[key] = fmt.Sprintf("%v", v)
			case float64, int, int64, int32:
				metadata[key] = fmt.Sprintf("%v", v)
			case map[string]interface{}:
				// For nested objects, just mark as configured
				if len(v) > 0 {
					metadata[key+"_configured"] = "true"
					// Also recursively process nested maps for their fields
					for nestedKey, nestedValue := range v {
						if nestedSlice, ok := nestedValue.([]interface{}); ok && len(nestedSlice) > 0 {
							metadata[key+"_"+nestedKey+"_configured"] = "true"
							metadata[key+"_"+nestedKey+"_count"] = fmt.Sprintf("%d", len(nestedSlice))
						} else if nestedMap, ok := nestedValue.(map[string]interface{}); ok && len(nestedMap) > 0 {
							metadata[key+"_"+nestedKey+"_configured"] = "true"
						}
					}
				}
			case []interface{}:
				// For arrays, just mark as configured and count
				if len(v) > 0 {
					metadata[key+"_configured"] = "true"
					metadata[key+"_count"] = fmt.Sprintf("%d", len(v))
				}
			default:
				// Handle custom types by converting them to string
				metadata[key] = fmt.Sprintf("%v", v)
			}
		}
	}
	
	return metadata
}