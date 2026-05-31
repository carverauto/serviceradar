/*
 * Copyright 2026 Carver Automation Corporation.
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

// Package manifestschema validates a native ServiceRadar add-on manifest
// (addon.yaml) against the published manifest JSON-Schema (issue 3425). It is
// consumed by the addon-manifest-validator command (the build/CI gate) and
// exercised by unit tests with valid + invalid fixtures.
//
// The validator interprets the subset of JSON-Schema (draft 2020-12) keywords the
// native-addon manifest schema uses: type, required, enum, pattern, minLength,
// minItems, maxItems, minimum, uniqueItems, additionalProperties (false), and
// nested object/array schemas. Keeping the schema document as the single source of
// truth (rather than hand-coding field rules) means the gate fails closed on any
// drift between the schema and a manifest, with no third-party dependency.
package manifestschema

import (
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// errNonStringMappingKey is returned when a YAML mapping uses a non-string key,
// which the JSON value model the validator targets cannot represent.
var errNonStringMappingKey = errors.New("non-string mapping key")

// SchemaJSON is the embedded native-addon manifest JSON-Schema. The schema file is
// copied next to this package by go:generate-free embedding (see the //go:embed
// directive); it is the same file shipped at addons/native-addon-manifest.schema.json.
//
//go:embed native-addon-manifest.schema.json
var SchemaJSON []byte

// Error describes a single validation failure at a JSON pointer-ish path.
type Error struct {
	Path    string
	Message string
}

func (e Error) String() string {
	if e.Path == "" {
		return e.Message
	}

	return fmt.Sprintf("%s: %s", e.Path, e.Message)
}

// Result is the outcome of validating one manifest.
type Result struct {
	Errors []Error
}

// OK reports whether the manifest satisfied the schema.
func (r *Result) OK() bool { return len(r.Errors) == 0 }

func (r *Result) addf(path, format string, args ...any) {
	r.Errors = append(r.Errors, Error{Path: path, Message: fmt.Sprintf(format, args...)})
}

// ValidateYAML parses a YAML add-on manifest and validates it against the embedded
// schema. It returns a Result whose Errors are empty iff the manifest is valid.
func ValidateYAML(manifest []byte) (*Result, error) {
	var raw any
	if err := yaml.Unmarshal(manifest, &raw); err != nil {
		return nil, fmt.Errorf("parsing manifest YAML: %w", err)
	}

	doc, err := normalizeYAML(raw)
	if err != nil {
		return nil, fmt.Errorf("normalizing manifest YAML: %w", err)
	}

	return validateValue(doc)
}

// ValidateJSON validates an already-JSON manifest document against the embedded
// schema.
func ValidateJSON(manifest []byte) (*Result, error) {
	var doc any
	if err := json.Unmarshal(manifest, &doc); err != nil {
		return nil, fmt.Errorf("parsing manifest JSON: %w", err)
	}

	return validateValue(doc)
}

// normalizeYAML converts a value decoded by gopkg.in/yaml.v3 into the JSON value
// model used by the validator: map[string]any objects, []any arrays, string, bool,
// float64 numbers and nil. yaml.v3 decodes mappings into map[string]interface{}
// when keys are strings (always true for add-on manifests) and integers into int;
// the validator's numeric checks use float64 (the JSON model), so integers are
// converted accordingly.
func normalizeYAML(value any) (any, error) {
	switch v := value.(type) {
	case map[string]any:
		out := make(map[string]any, len(v))
		for key, elem := range v {
			normalized, err := normalizeYAML(elem)
			if err != nil {
				return nil, err
			}

			out[key] = normalized
		}

		return out, nil
	case map[any]any:
		out := make(map[string]any, len(v))
		for key, elem := range v {
			keyStr, ok := key.(string)
			if !ok {
				return nil, fmt.Errorf("%w: %v (%T)", errNonStringMappingKey, key, key)
			}

			normalized, err := normalizeYAML(elem)
			if err != nil {
				return nil, err
			}

			out[keyStr] = normalized
		}

		return out, nil
	case []any:
		out := make([]any, len(v))
		for i, elem := range v {
			normalized, err := normalizeYAML(elem)
			if err != nil {
				return nil, err
			}

			out[i] = normalized
		}

		return out, nil
	case int:
		return float64(v), nil
	case int64:
		return float64(v), nil
	case float64:
		return v, nil
	default:
		return value, nil
	}
}

func validateValue(doc any) (*Result, error) {
	var schema map[string]any
	if err := json.Unmarshal(SchemaJSON, &schema); err != nil {
		return nil, fmt.Errorf("parsing embedded schema: %w", err)
	}

	res := &Result{}
	validate(res, "", schema, doc)
	sort.SliceStable(res.Errors, func(i, j int) bool {
		if res.Errors[i].Path == res.Errors[j].Path {
			return res.Errors[i].Message < res.Errors[j].Message
		}

		return res.Errors[i].Path < res.Errors[j].Path
	})

	return res, nil
}

func validate(res *Result, path string, schema map[string]any, value any) {
	if !checkType(res, path, schema, value) {
		// A type mismatch makes deeper keyword checks meaningless.
		return
	}

	checkEnum(res, path, schema, value)
	checkString(res, path, schema, value)
	checkNumber(res, path, schema, value)
	checkObject(res, path, schema, value)
	checkArray(res, path, schema, value)
}

func checkType(res *Result, path string, schema map[string]any, value any) bool {
	want, ok := schema["type"].(string)
	if !ok {
		return true
	}

	if matchesType(want, value) {
		return true
	}

	res.addf(path, "expected type %q, got %s", want, jsonType(value))

	return false
}

func matchesType(want string, value any) bool {
	switch want {
	case "object":
		_, ok := value.(map[string]any)
		return ok
	case "array":
		_, ok := value.([]any)
		return ok
	case "string":
		_, ok := value.(string)
		return ok
	case "boolean":
		_, ok := value.(bool)
		return ok
	case "integer":
		f, ok := value.(float64)
		return ok && f == math.Trunc(f)
	case "number":
		_, ok := value.(float64)
		return ok
	case "null":
		return value == nil
	default:
		return true
	}
}

func jsonType(value any) string {
	switch v := value.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case float64:
		if v == math.Trunc(v) {
			return "integer"
		}

		return "number"
	case string:
		return "string"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	default:
		return fmt.Sprintf("%T", value)
	}
}

func checkEnum(res *Result, path string, schema map[string]any, value any) {
	raw, ok := schema["enum"].([]any)
	if !ok {
		return
	}

	for _, candidate := range raw {
		if equalJSON(candidate, value) {
			return
		}
	}

	allowed := make([]string, 0, len(raw))
	for _, candidate := range raw {
		allowed = append(allowed, fmt.Sprintf("%v", candidate))
	}

	res.addf(path, "value %q is not one of the allowed values [%s]",
		fmt.Sprintf("%v", value), strings.Join(allowed, ", "))
}

func checkString(res *Result, path string, schema map[string]any, value any) {
	str, ok := value.(string)
	if !ok {
		return
	}

	if minLen, ok := schema["minLength"].(float64); ok && float64(len(str)) < minLen {
		res.addf(path, "string is shorter than minLength %d", int(minLen))
	}

	if pattern, ok := schema["pattern"].(string); ok {
		re, err := regexp.Compile(pattern)
		if err != nil {
			res.addf(path, "schema pattern %q is invalid: %v", pattern, err)
		} else if !re.MatchString(str) {
			res.addf(path, "string %q does not match pattern %q", str, pattern)
		}
	}
}

func checkNumber(res *Result, path string, schema map[string]any, value any) {
	num, ok := value.(float64)
	if !ok {
		return
	}

	if minimum, ok := schema["minimum"].(float64); ok && num < minimum {
		res.addf(path, "value %v is less than minimum %v", num, minimum)
	}
}

func checkObject(res *Result, path string, schema map[string]any, value any) {
	obj, ok := value.(map[string]any)
	if !ok {
		return
	}

	if required, ok := schema["required"].([]any); ok {
		for _, raw := range required {
			field, ok := raw.(string)
			if !ok {
				continue
			}

			if _, present := obj[field]; !present {
				res.addf(joinPath(path, field), "required field is missing")
			}
		}
	}

	props, _ := schema["properties"].(map[string]any)

	if additional, ok := schema["additionalProperties"].(bool); ok && !additional {
		for key := range obj {
			if props != nil {
				if _, declared := props[key]; declared {
					continue
				}
			}

			res.addf(joinPath(path, key), "unknown property is not permitted")
		}
	}

	if props == nil {
		return
	}

	for key, rawSubSchema := range props {
		subValue, present := obj[key]
		if !present {
			continue
		}

		subSchema, ok := rawSubSchema.(map[string]any)
		if !ok {
			continue
		}

		validate(res, joinPath(path, key), subSchema, subValue)
	}
}

func checkArray(res *Result, path string, schema map[string]any, value any) {
	arr, ok := value.([]any)
	if !ok {
		return
	}

	if minItems, ok := schema["minItems"].(float64); ok && float64(len(arr)) < minItems {
		res.addf(path, "array has fewer than minItems %d", int(minItems))
	}

	if maxItems, ok := schema["maxItems"].(float64); ok && float64(len(arr)) > maxItems {
		res.addf(path, "array has more than maxItems %d", int(maxItems))
	}

	if unique, ok := schema["uniqueItems"].(bool); ok && unique {
		seen := make([]any, 0, len(arr))
		for i, item := range arr {
			for _, prev := range seen {
				if equalJSON(prev, item) {
					res.addf(fmt.Sprintf("%s[%d]", path, i), "duplicate array item is not permitted (uniqueItems)")
					break
				}
			}

			seen = append(seen, item)
		}
	}

	itemSchema, ok := schema["items"].(map[string]any)
	if !ok {
		return
	}

	for i, item := range arr {
		validate(res, fmt.Sprintf("%s[%d]", path, i), itemSchema, item)
	}
}

func equalJSON(a, b any) bool {
	aj, err := json.Marshal(a)
	if err != nil {
		return false
	}

	bj, err := json.Marshal(b)
	if err != nil {
		return false
	}

	return string(aj) == string(bj)
}

func joinPath(parent, key string) string {
	if parent == "" {
		return key
	}

	return parent + "." + key
}
