package config

import (
	"context"
	"encoding/json"
	"strings"
)

// RepairConfigPlaceholders overwrites placeholder KV values with the sanitized config file defaults.
// It only mutates the KV entry when descriptor-critical fields still contain obvious placeholder values
// such as localhost bindings. This keeps the operation idempotent for real operator edits.
func (m *KVManager) RepairConfigPlaceholders(ctx context.Context, desc ServiceDescriptor, configPath string, cfg interface{}) error {
	if m == nil || m.client == nil || desc.KVKey == "" || len(desc.CriticalFields) == 0 {
		return nil
	}

	current, found, err := m.client.Get(ctx, desc.KVKey)
	if err != nil || !found {
		return err
	}

	if !needsPlaceholderRepair(desc, current) {
		return nil
	}

	replacement, err := sanitizeBootstrapSource(configPath, cfg)
	if err != nil || len(replacement) == 0 {
		return err
	}

	// Avoid extra writes when the file already matches the stored value.
	if len(current) == len(replacement) && string(current) == string(replacement) {
		return nil
	}

	return m.client.Put(ctx, desc.KVKey, replacement, 0)
}

func needsPlaceholderRepair(desc ServiceDescriptor, raw []byte) bool {
	if len(desc.CriticalFields) == 0 || len(raw) == 0 {
		return false
	}

	var doc map[string]interface{}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return false
	}

	for _, field := range desc.CriticalFields {
		val, ok := lookupStringField(doc, field)
		if !ok {
			return true
		}
		if isPlaceholderValue(val) {
			return true
		}
	}

	return false
}

func lookupStringField(doc map[string]interface{}, path string) (string, bool) {
	segments := strings.Split(path, ".")
	var current interface{} = doc

	for _, segment := range segments {
		m, ok := current.(map[string]interface{})
		if !ok {
			return "", false
		}
		current, ok = m[segment]
		if !ok {
			return "", false
		}
	}

	if s, ok := current.(string); ok {
		return s, true
	}

	return "", false
}

func isPlaceholderValue(value string) bool {
	trimmed := strings.ToLower(strings.TrimSpace(value))
	if trimmed == "" {
		return true
	}

	placeholders := []string{"127.0.0.1", "localhost", "placeholder"}
	for _, token := range placeholders {
		if strings.Contains(trimmed, token) {
			return true
		}
	}

	return false
}
