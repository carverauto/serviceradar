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

package syncsources

import "strings"

const macAddressesMetadataKey = "mac_addresses"

// NormalizeUpdate applies integration-neutral hygiene to a single device
// update before it is streamed to the gateway. The runtime applies it to
// every update emitted by every driver, so drivers can pass raw,
// possibly-dirty field values straight from their API.
//
// MAC address hygiene (the only normalization today):
//   - update["mac"] is reduced to the first valid single MAC address found in
//     the comma-separated update["mac"] field (falling back to entries from
//     metadata["mac_addresses"]). The source formatting of the chosen entry is
//     preserved, minus surrounding whitespace. If no entry is a valid MAC the
//     key is removed.
//   - metadata["mac_addresses"] is rewritten as the comma-joined list of every
//     valid MAC across both fields, normalized (uppercase, separator-free) and
//     deduplicated in first-seen order. If no valid MAC exists the key is
//     removed.
func NormalizeUpdate(update map[string]any) {
	if update == nil {
		return
	}

	normalizeUpdateMAC(update)
}

func normalizeUpdateMAC(update map[string]any) {
	macValue, macPresent := update["mac"]
	rawMAC, macIsString := "", false
	if macPresent {
		rawMAC, macIsString = macValue.(string)
	}

	rawList, listPresent := metadataStringField(update, macAddressesMetadataKey)

	candidates := append(splitMACEntries(rawMAC), splitMACEntries(rawList)...)

	primary := ""
	for _, candidate := range candidates {
		if normalizeMACAddress(candidate) != "" {
			primary = candidate
			break
		}
	}

	// Leave a non-string mac field untouched; otherwise reduce it to the
	// first valid MAC (or remove/derive it).
	if !macPresent || macIsString {
		if primary != "" {
			update["mac"] = primary
		} else if macPresent {
			delete(update, "mac")
		}
	}

	normalized := normalizeMACList(candidates)
	if len(normalized) > 0 {
		setMetadataStringField(update, macAddressesMetadataKey, strings.Join(normalized, ","))
	} else if listPresent {
		deleteMetadataField(update, macAddressesMetadataKey)
	}
}

// splitMACEntries splits a comma-separated MAC field into trimmed entries.
func splitMACEntries(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}

	parts := strings.Split(value, ",")
	entries := make([]string, 0, len(parts))
	for _, part := range parts {
		if part = strings.TrimSpace(part); part != "" {
			entries = append(entries, part)
		}
	}

	return entries
}

// normalizeMACList validates and normalizes raw MAC candidates, deduplicating
// in first-seen order.
func normalizeMACList(candidates []string) []string {
	macs := make([]string, 0, len(candidates))
	seen := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		normalized := normalizeMACAddress(candidate)
		if normalized == "" {
			continue
		}
		if _, ok := seen[normalized]; ok {
			continue
		}
		seen[normalized] = struct{}{}
		macs = append(macs, normalized)
	}

	return macs
}

//nolint:gochecknoglobals // strings.Replacer is immutable and safe to reuse.
var macSeparatorReplacer = strings.NewReplacer(":", "", "-", "", ".", "")

// normalizeMACAddress strips ':', '-', and '.' separators and uppercases the
// value, returning "" unless the result is exactly 12 hexadecimal characters.
func normalizeMACAddress(value string) string {
	cleaned := macSeparatorReplacer.Replace(strings.TrimSpace(value))
	if len(cleaned) != 12 {
		return ""
	}
	for _, r := range cleaned {
		switch {
		case r >= '0' && r <= '9':
		case r >= 'a' && r <= 'f':
		case r >= 'A' && r <= 'F':
		default:
			return ""
		}
	}

	return strings.ToUpper(cleaned)
}

func metadataStringField(update map[string]any, key string) (string, bool) {
	switch metadata := update["metadata"].(type) {
	case map[string]string:
		value, ok := metadata[key]
		return value, ok
	case map[string]any:
		value, ok := metadata[key].(string)
		return value, ok
	default:
		return "", false
	}
}

func setMetadataStringField(update map[string]any, key, value string) {
	switch metadata := update["metadata"].(type) {
	case map[string]string:
		metadata[key] = value
	case map[string]any:
		metadata[key] = value
	}
}

func deleteMetadataField(update map[string]any, key string) {
	switch metadata := update["metadata"].(type) {
	case map[string]string:
		delete(metadata, key)
	case map[string]any:
		delete(metadata, key)
	}
}
