package main

import (
	"strings"
)

func extractSessionCookie(header string) string {
	header = strings.TrimSpace(header)
	if header == "" {
		return ""
	}

	parts := strings.Split(header, ";")
	if len(parts) == 0 {
		return ""
	}
	return strings.TrimSpace(parts[0])
}

func headerValue(headers map[string]string, key string) string {
	for candidate, value := range headers {
		if strings.EqualFold(strings.TrimSpace(candidate), key) {
			return value
		}
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			return value
		}
	}
	return ""
}

func normalizeMACKey(value string) string {
	value = strings.ToUpper(strings.TrimSpace(value))
	if value == "" {
		return ""
	}
	replacer := strings.NewReplacer(":", "", "-", "", ".", "")
	return replacer.Replace(value)
}

func mapString(m map[string]interface{}, key string) string {
	if m == nil {
		return ""
	}
	value, ok := m[key]
	if !ok {
		return ""
	}
	text, _ := value.(string)
	return strings.TrimSpace(text)
}

func mapStringFromNested(m map[string]interface{}, keys ...string) string {
	return mapString(mapNested(m, keys[:len(keys)-1]...), keys[len(keys)-1])
}

func mapNested(m map[string]interface{}, keys ...string) map[string]interface{} {
	current := m
	for _, key := range keys {
		if current == nil {
			return nil
		}
		next, ok := current[key].(map[string]interface{})
		if !ok {
			return nil
		}
		current = next
	}
	return current
}

func mapHasKey(m map[string]interface{}, key string) bool {
	if m == nil {
		return false
	}
	_, ok := m[key]
	return ok
}

func truthy(value interface{}) bool {
	boolean, ok := value.(bool)
	return ok && boolean
}

func trimBody(in EndpointResult) EndpointResult {
	out := in
	const maxBody = 256
	out.Body = trimStringBytes(out.Body, maxBody)
	return out
}

func trimStringBytes(value string, maxBytes int) string {
	if maxBytes <= 0 {
		return ""
	}
	if len(value) <= maxBytes {
		return value
	}

	end := 0
	for idx := range value {
		if idx > maxBytes {
			break
		}
		end = idx
	}

	return value[:end]
}
