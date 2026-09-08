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

package addon

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestAdvisoryFeedContractIsProducerAgnostic(t *testing.T) {
	batch := AdvisoryFeedBatch{
		SchemaVersion: AdvisoryFeedContractVersion,
		ProducerID:    "com.example.vulnerability-feed",
		Source: AdvisorySource{
			Provider:    "example",
			FeedKey:     "normalized",
			DisplayName: "Example Normalized Advisory Feed",
			Enabled:     true,
			Metadata: map[string]any{
				"addon_id": "example-feed-addon",
			},
		},
		Snapshot: AdvisorySnapshot{
			ObjectKey: "vulnerability-feeds/example/sha256.json",
			SHA256:    strings.Repeat("a", 64),
			Accepted:  true,
			Status:    "accepted",
			Validation: map[string]any{
				"schema": "producer-owned",
			},
		},
		Advisories: []AdvisoryRecord{
			{
				SourceObjectID:   "example:CVE-2026-1",
				AdvisoryID:       "CVE-2026-1",
				CVEID:            "CVE-2026-1",
				Severity:         "high",
				KEV:              true,
				ExploitAvailable: true,
				AffectedCoordinates: []AffectedCoordinate{
					{
						Type:           CoordinateTypePURL,
						Value:          "pkg:deb/debian/openssl@3.0.13?arch=amd64",
						MatchSemantics: "producer_normalized",
						VersionRanges: []map[string]any{
							{"fixed_version": "3.0.14"},
						},
					},
				},
			},
		},
	}

	data, err := json.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	payload := string(data)
	if !strings.Contains(payload, `"schema_version":"serviceradar.advisory_feed.contract.v1"`) {
		t.Fatalf("schema_version missing from payload: %s", payload)
	}
	if strings.Contains(strings.ToLower(payload), "vulncheck") ||
		strings.Contains(strings.ToLower(payload), "cisa") ||
		strings.Contains(strings.ToLower(payload), "nvd") {
		t.Fatalf("generic advisory contract leaked built-in provider assumptions: %s", payload)
	}
	if !strings.Contains(payload, `"affected_coordinates"`) ||
		!strings.Contains(payload, `"object_key"`) {
		t.Fatalf("advisory payload missing required contract fields: %s", payload)
	}
}
