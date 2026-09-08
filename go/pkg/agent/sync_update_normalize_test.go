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

package agent

// These tests cover the generic device-update normalization the sync runtime
// applies to every emitted update, regardless of which integration produced
// it. The expectations are byte-identical to the wire format the Elixir core
// consumes: update["mac"] holds the first valid single MAC address and
// metadata["mac_addresses"] holds the comma-joined validated, normalized
// list. Keys with no valid MAC are omitted.

import (
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
)

func TestNormalizeUpdatePicksFirstValidMACFromMultiValueField(t *testing.T) {
	update := map[string]any{
		"mac":      "001AA0B94040,001422F42A2A,70B3D59EDC93",
		"metadata": map[string]string{},
	}

	syncsources.NormalizeUpdate(update)

	if update["mac"] != "001AA0B94040" {
		t.Fatalf("update[mac] = %q, want first MAC from comma-separated field", update["mac"])
	}
	metadata := update["metadata"].(map[string]string)
	if got := metadata["mac_addresses"]; got != "001AA0B94040,001422F42A2A,70B3D59EDC93" {
		t.Fatalf("metadata[mac_addresses] = %q, want full validated list", got)
	}
}

func TestNormalizeUpdateSkipsJunkMACEntries(t *testing.T) {
	update := map[string]any{
		"mac": " ,unknown,00:11:22:33:44:55:66, 00-1A-A0-B9-40-41 ,001422F42A2A",
	}

	syncsources.NormalizeUpdate(update)

	if update["mac"] != "00-1A-A0-B9-40-41" {
		t.Fatalf("update[mac] = %q, want first valid MAC after skipping junk", update["mac"])
	}
}

func TestNormalizeUpdatePreservesSingleColonSeparatedMAC(t *testing.T) {
	update := map[string]any{"mac": " 00:11:22:33:44:55 "}

	syncsources.NormalizeUpdate(update)

	if update["mac"] != "00:11:22:33:44:55" {
		t.Fatalf("update[mac] = %q, want trimmed colon-separated MAC", update["mac"])
	}
}

func TestNormalizeUpdateRemovesMACKeysWithoutValidMAC(t *testing.T) {
	for name, update := range map[string]map[string]any{
		"empty": {
			"mac":      "",
			"metadata": map[string]string{"mac_addresses": ""},
		},
		"garbage-only": {
			"mac":      "unknown, n/a ,00:11:22:33:44",
			"metadata": map[string]string{"mac_addresses": "unknown, n/a ,00:11:22:33:44"},
		},
	} {
		syncsources.NormalizeUpdate(update)

		if mac, ok := update["mac"]; ok {
			t.Fatalf("%s: update[mac] = %q, want key omitted", name, mac)
		}
		metadata := update["metadata"].(map[string]string)
		if value, ok := metadata["mac_addresses"]; ok {
			t.Fatalf("%s: metadata[mac_addresses] = %q, want key omitted", name, value)
		}
	}
}

func TestNormalizeUpdateFallsBackToMetadataMACList(t *testing.T) {
	update := map[string]any{
		"mac":      "n/a, also not a mac",
		"metadata": map[string]string{"mac_addresses": "bogus,00:1A:A0:B9:40:42"},
	}

	syncsources.NormalizeUpdate(update)

	if update["mac"] != "00:1A:A0:B9:40:42" {
		t.Fatalf("update[mac] = %q, want first valid MAC from metadata list", update["mac"])
	}
	metadata := update["metadata"].(map[string]string)
	if got := metadata["mac_addresses"]; got != "001AA0B94042" {
		t.Fatalf("metadata[mac_addresses] = %q, want normalized list", got)
	}
}

func TestNormalizeUpdateNormalizesAndDeduplicatesMACList(t *testing.T) {
	update := map[string]any{
		"mac":      "00:1a:a0:b9:40:40,garbage,001422F42A2A",
		"metadata": map[string]string{"mac_addresses": "00-1A-A0-B9-40-40,70b3.d59e.dc93,"},
	}

	syncsources.NormalizeUpdate(update)

	if update["mac"] != "00:1a:a0:b9:40:40" {
		t.Fatalf("update[mac] = %q, want first valid MAC preserving source formatting", update["mac"])
	}
	metadata := update["metadata"].(map[string]string)
	if got := metadata["mac_addresses"]; got != "001AA0B94040,001422F42A2A,70B3D59EDC93" {
		t.Fatalf("metadata[mac_addresses] = %q, want normalized deduplicated list", got)
	}
}

func TestNormalizeUpdateHandlesUntypedMetadataMap(t *testing.T) {
	update := map[string]any{
		"mac":      "garbage",
		"metadata": map[string]any{"mac_addresses": "00:1A:A0:B9:40:40"},
	}

	syncsources.NormalizeUpdate(update)

	if update["mac"] != "00:1A:A0:B9:40:40" {
		t.Fatalf("update[mac] = %q", update["mac"])
	}
	metadata := update["metadata"].(map[string]any)
	if got := metadata["mac_addresses"]; got != "001AA0B94040" {
		t.Fatalf("metadata[mac_addresses] = %v, want normalized MAC", got)
	}
}

func TestNormalizeUpdateLeavesNonStringMACUntouched(t *testing.T) {
	update := map[string]any{"mac": 42}

	syncsources.NormalizeUpdate(update)

	if update["mac"] != 42 {
		t.Fatalf("update[mac] = %v, want untouched non-string value", update["mac"])
	}
}

func TestNormalizeUpdateWithoutMACFieldsIsNoOp(t *testing.T) {
	update := map[string]any{
		"ip":       "10.0.0.2",
		"metadata": map[string]string{"integration_type": "synthetic"},
	}

	syncsources.NormalizeUpdate(update)

	if _, ok := update["mac"]; ok {
		t.Fatal("update[mac] should not be invented")
	}
	metadata := update["metadata"].(map[string]string)
	if _, ok := metadata["mac_addresses"]; ok {
		t.Fatal("metadata[mac_addresses] should not be invented")
	}
}
