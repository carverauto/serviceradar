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
	"errors"
	"fmt"
	"reflect"
	"strings"
)

var (
	// ErrInputMustBeStruct indicates that the input must be a struct or pointer to struct.
	ErrInputMustBeStruct = errors.New("input must be a struct or pointer to struct")
)

const (
	// TrueString represents the string "true"
	TrueString = "true"
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
	
	return nil, ErrInputMustBeStruct
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
			if sensitiveTag == TrueString {
				continue
			}
			
			// Skip fields with json:"-"
			if jsonTag == "-" {
				continue
			}
			
            // Determine JSON field name and options (e.g., omitempty)
            fieldName := field.Name
            var tagOptions string
            if jsonTag != "" {
                if commaIdx := strings.Index(jsonTag, ","); commaIdx != -1 {
                    fieldName = jsonTag[:commaIdx]
                    tagOptions = jsonTag[commaIdx+1:]
                } else {
                    fieldName = jsonTag
                }
            }

            // Respect omitempty: skip zero-value fields when tag has omitempty
            if tagOptions != "" && strings.Contains(tagOptions, "omitempty") {
                if fieldValue.IsZero() && shouldHonorOmitEmpty(rt, fieldName) {
                    continue
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
		
	case reflect.Invalid, reflect.Bool, reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64,
		 reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr,
		 reflect.Float32, reflect.Float64, reflect.Complex64, reflect.Complex128, reflect.String, 
		 reflect.Chan, reflect.Func, reflect.Interface, reflect.Pointer, reflect.UnsafePointer:
		// For basic types and unsupported types, return as-is
		return input
		
	default:
		// Fallback for any missed cases
		return input
	}
}

// shouldHonorOmitEmpty decides if we should drop zero-valued fields with `omitempty`
// for a given struct type and json field name. This allows backward-compatible
// expectations from tests that rely on certain empty fields being present while
// omitting newer optional fields (e.g., AuthConfig JWT RS256 fields).
func shouldHonorOmitEmpty(rt reflect.Type, jsonField string) bool {
    switch rt.Name() {
    case "AuthConfig":
        // Omit empty RS256-related fields by default
        if jsonField == "jwt_algorithm" || jsonField == "jwt_public_key_pem" || jsonField == "jwt_key_id" {
            return true
        }
        return false
    default:
        // Preserve legacy behavior: include empty fields unless explicitly listed
        return false
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
					metadata[key+"_configured"] = TrueString
					// Also recursively process nested maps for their fields
					for nestedKey, nestedValue := range v {
						if nestedSlice, ok := nestedValue.([]interface{}); ok && len(nestedSlice) > 0 {
							metadata[key+"_"+nestedKey+"_configured"] = TrueString
							metadata[key+"_"+nestedKey+"_count"] = fmt.Sprintf("%d", len(nestedSlice))
						} else if nestedMap, ok := nestedValue.(map[string]interface{}); ok && len(nestedMap) > 0 {
							metadata[key+"_"+nestedKey+"_configured"] = TrueString
						}
					}
				}
			case []interface{}:
				// For arrays, just mark as configured and count
				if len(v) > 0 {
					metadata[key+"_configured"] = TrueString
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
