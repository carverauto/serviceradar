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

package armis

import (
	"bytes"
	"encoding/json"
	"strings"
	"unicode"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func defaultAttachmentMetadataFields() []string {
	return []string{
		"accessSwitch",
		"access_switch",
		"Access Switch",
		"accessSwitchName",
		"access_switch_name",
		"accessSwitchPort",
		"access_switch_port",
		"accessSwitchInterface",
		"access_switch_interface",
		"connectedSwitch",
		"connected_switch",
		"connectedSwitchPort",
		"connected_switch_port",
		"connectedSwitchInterface",
		"connected_switch_interface",
		"switch",
		"switchName",
		"switch_name",
		"switchPort",
		"switch_port",
		"portName",
		"port_name",
		"neighborDevice",
		"neighbor_device",
		"neighborPort",
		"neighbor_port",
		"connectionType",
		"connection_type",
		"Connection Type",
		"dhcpLeaseType",
		"dhcp_lease_type",
		"DHCP Lease Type",
		"vlan",
		"VLAN",
		"vlans",
		"VLANs",
		"vlanId",
		"vlan_id",
		"VLAN ID",
	}
}

func metadataFieldsForSource(source models.SourceConfig) []string {
	defaultFields := defaultAttachmentMetadataFields()
	fields := make([]string, 0, len(defaultFields))
	fields = append(fields, defaultFields...)
	fields = append(fields, stringListSetting(source.Settings, "extra_metadata_fields", "armis_extra_metadata_fields")...)
	fields = append(fields, stringListSetting(source.Settings, "attachment_fields")...)
	fields = append(fields, configuredAssetFields(source)...)

	return dedupeStrings(fields)
}

func configuredAssetFields(source models.SourceConfig) []string {
	return dedupeStrings(stringListSetting(source.Settings, "asset_fields", "armis_asset_fields"))
}

func stringListSetting(settings map[string]any, keys ...string) []string {
	for _, key := range keys {
		value, ok := settingValue(settings, key)
		if !ok {
			continue
		}

		if values := normalizeStringList(value); len(values) > 0 {
			return values
		}
	}

	return nil
}

func settingValue(settings map[string]any, key string) (any, bool) {
	if len(settings) == 0 {
		return nil, false
	}

	if value, ok := settings[key]; ok {
		return value, true
	}

	normalized := normalizeMetadataFieldName(key)
	for rawKey, value := range settings {
		if normalizeMetadataFieldName(rawKey) == normalized {
			return value, true
		}
	}

	return nil, false
}

func normalizeStringList(value any) []string {
	switch typed := value.(type) {
	case []string:
		return dedupeStrings(typed)
	case []any:
		values := make([]string, 0, len(typed))
		for _, item := range typed {
			if value := strings.TrimSpace(toStringValue(item)); value != "" {
				values = append(values, value)
			}
		}

		return dedupeStrings(values)
	case string:
		fields := strings.FieldsFunc(typed, func(r rune) bool {
			return r == ',' || r == '\n' || r == '\t'
		})
		return dedupeStrings(fields)
	default:
		if value := strings.TrimSpace(toStringValue(value)); value != "" {
			return []string{value}
		}
		return nil
	}
}

func dedupeStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	deduped := make([]string, 0, len(values))

	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}

		key := normalizeMetadataFieldName(value)
		if _, ok := seen[key]; ok {
			continue
		}

		seen[key] = struct{}{}
		deduped = append(deduped, value)
	}

	return deduped
}

func addArmisRawMetadata(metadata map[string]string, item device, fields []string) {
	for _, field := range fields {
		raw := item.rawField(field)
		if len(raw) == 0 {
			continue
		}

		key := armisMetadataKey(field)
		if key == "" {
			continue
		}

		value := rawMetadataValue(raw)
		if value == "" {
			continue
		}

		if _, exists := metadata[key]; !exists {
			metadata[key] = value
		}
	}
}

func armisMetadataKey(field string) string {
	normalized := normalizeMetadataFieldName(field)
	normalized = strings.TrimPrefix(normalized, "armis_")
	if normalized == "" {
		return ""
	}

	return "armis_" + normalized
}

func normalizeMetadataFieldName(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}

	var builder strings.Builder
	var previousUnderscore bool
	runes := []rune(value)

	for index, r := range runes {
		if unicode.IsUpper(r) {
			previousLowerOrDigit := index > 0 && (unicode.IsLower(runes[index-1]) || unicode.IsDigit(runes[index-1]))
			previousUpper := index > 0 && unicode.IsUpper(runes[index-1])
			nextLower := index+1 < len(runes) && unicode.IsLower(runes[index+1])

			if builder.Len() > 0 && !previousUnderscore && (previousLowerOrDigit || (previousUpper && nextLower)) {
				builder.WriteRune('_')
			}
			builder.WriteRune(unicode.ToLower(r))
			previousUnderscore = false
			continue
		}

		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			builder.WriteRune(unicode.ToLower(r))
			previousUnderscore = false
			continue
		}

		if builder.Len() > 0 && !previousUnderscore {
			builder.WriteRune('_')
			previousUnderscore = true
		}
	}

	return strings.Trim(builder.String(), "_")
}

func rawMetadataValue(raw json.RawMessage) string {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return ""
	}

	var stringValue string
	if err := json.Unmarshal(trimmed, &stringValue); err == nil {
		return strings.TrimSpace(stringValue)
	}

	var compacted bytes.Buffer
	if err := json.Compact(&compacted, trimmed); err == nil {
		return compacted.String()
	}

	return string(trimmed)
}

func toStringValue(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return typed
	case []byte:
		return string(typed)
	default:
		return strings.TrimSpace(strings.Trim(rawMetadataValue(mustJSON(typed)), `"`))
	}
}

func mustJSON(value any) json.RawMessage {
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil
	}

	return encoded
}
