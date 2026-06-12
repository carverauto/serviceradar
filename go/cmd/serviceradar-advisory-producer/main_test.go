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

package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/addon"
)

func TestCISAKEVCommandNormalizesAdvisoryBatch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{
			"title": "CISA Known Exploited Vulnerabilities Catalog",
			"dateReleased": "2026-06-10",
			"vulnerabilities": [{
				"cveID": "CVE-2026-0001",
				"vendorProject": "Example",
				"product": "Router",
				"vulnerabilityName": "Example Router command injection",
				"shortDescription": "Command injection in Example Router.",
				"dateAdded": "2026-06-09",
				"requiredAction": "Apply mitigations",
				"dueDate": "2026-06-30",
				"knownRansomwareCampaignUse": "Known",
				"notes": "https://example.invalid/CVE-2026-0001"
			}]
		}`))
	}))
	defer server.Close()

	producer := &advisoryProducer{client: server.Client()}
	payload := mustJSON(t, map[string]any{
		"input_values": map[string]any{
			"provider": "cisa",
			"feed_key": "kev",
			"url":      server.URL,
		},
	})

	result, err := producer.RunCommand(context.Background(), addon.CommandRequest{
		ActionID:    "cisa_kev.refresh",
		PayloadJSON: payload,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Success {
		t.Fatalf("command failed: %s", result.Message)
	}

	var batch addon.AdvisoryFeedBatch
	if err := json.Unmarshal(result.PayloadJSON, &batch); err != nil {
		t.Fatal(err)
	}

	if batch.SchemaVersion != addon.AdvisoryFeedContractVersion {
		t.Fatalf("schema = %q", batch.SchemaVersion)
	}
	if batch.Source.Provider != "cisa" || batch.Source.FeedKey != "kev" {
		t.Fatalf("source = %#v", batch.Source)
	}
	if len(batch.Advisories) != 1 {
		t.Fatalf("advisories = %d", len(batch.Advisories))
	}
	advisory := batch.Advisories[0]
	if advisory.CVEID != "CVE-2026-0001" || !advisory.KEV || !advisory.ExploitAvailable {
		t.Fatalf("advisory = %#v", advisory)
	}
	if got := advisory.AffectedCoordinates[0]; got.Type != addon.CoordinateTypeVendorProduct || got.Vendor != "Example" || got.Product != "Router" {
		t.Fatalf("coordinate = %#v", got)
	}
	if !strings.Contains(batch.Snapshot.ObjectKey, "vulnerability-feeds/cisa/kev/") {
		t.Fatalf("snapshot object key = %q", batch.Snapshot.ObjectKey)
	}
}

func TestNVDCommandNormalizesCPECoordinates(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("apiKey") != "test-key" {
			t.Fatalf("missing NVD apiKey header")
		}
		_, _ = w.Write([]byte(`{
			"vulnerabilities": [{
				"cve": {
					"id": "CVE-2026-0002",
					"published": "2026-06-01T00:00:00.000",
					"lastModified": "2026-06-02T00:00:00.000",
					"descriptions": [{"lang":"en","value":"Example library overflow."}],
					"metrics": {
						"cvssMetricV31": [{
							"cvssData": {
								"baseScore": 9.8,
								"baseSeverity": "CRITICAL",
								"vectorString": "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"
							}
						}]
					},
					"configurations": [{
						"nodes": [{
							"cpeMatch": [{
								"vulnerable": true,
								"criteria": "cpe:2.3:a:example:library:1.0:*:*:*:*:*:*:*",
								"versionEndExcluding": "1.0.1"
							}]
						}]
					}],
					"references": [{"url":"https://nvd.nist.gov/vuln/detail/CVE-2026-0002"}]
				}
			}]
		}`))
	}))
	defer server.Close()

	producer := &advisoryProducer{client: server.Client()}
	payload := mustJSON(t, map[string]any{
		"input_values": map[string]any{
			"provider": "nvd",
			"feed_key": "cve-2.0",
			"url":      server.URL,
			"api_key":  "test-key",
		},
	})

	result, err := producer.RunCommand(context.Background(), addon.CommandRequest{
		ActionID:    "nvd_cve.refresh",
		PayloadJSON: payload,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Success {
		t.Fatalf("command failed: %s", result.Message)
	}

	var batch addon.AdvisoryFeedBatch
	if err := json.Unmarshal(result.PayloadJSON, &batch); err != nil {
		t.Fatal(err)
	}

	advisory := batch.Advisories[0]
	if advisory.CVEID != "CVE-2026-0002" || advisory.Severity != "CRITICAL" || advisory.CVSSScore != 9.8 {
		t.Fatalf("advisory = %#v", advisory)
	}
	if got := advisory.AffectedCoordinates[0]; got.Type != addon.CoordinateTypeCPE || got.Value != "cpe:2.3:a:example:library:1.0:*:*:*:*:*:*:*" {
		t.Fatalf("coordinate = %#v", got)
	}
}

func TestNVDCommandUsesConfiguredCredentialMaterial(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("apiKey") != "broker-key" {
			t.Fatalf("missing broker-backed NVD apiKey header")
		}
		_, _ = w.Write([]byte(`{
			"vulnerabilities": [{
				"cve": {
					"id": "CVE-2026-0004",
					"descriptions": [{"lang":"en","value":"Credential material test."}],
					"configurations": [{
						"nodes": [{
							"cpeMatch": [{
								"vulnerable": true,
								"criteria": "cpe:2.3:a:example:credential-test:1.0:*:*:*:*:*:*:*"
							}]
						}]
					}]
				}
			}]
		}`))
	}))
	defer server.Close()

	producer := &advisoryProducer{client: server.Client()}
	config := mustJSON(t, map[string]any{
		"_serviceradar": map[string]any{
			"credentials": []map[string]any{{
				"grant_id": "nvd_api_key",
				"value":    "broker-key",
			}},
		},
	})
	configResult, err := producer.Configure(context.Background(), config)
	if err != nil {
		t.Fatal(err)
	}
	if !configResult.Accepted {
		t.Fatalf("configure rejected: %s", configResult.Error)
	}

	payload := mustJSON(t, map[string]any{
		"input_values": map[string]any{
			"provider": "nvd",
			"feed_key": "cve-2.0",
			"url":      server.URL,
		},
	})

	result, err := producer.RunCommand(context.Background(), addon.CommandRequest{
		ActionID:    "nvd_cve.refresh",
		PayloadJSON: payload,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Success {
		t.Fatalf("command failed: %s", result.Message)
	}
}

func TestVulnCheckCommandNormalizesGenericEnrichedRecord(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer vc-token" {
			t.Fatalf("missing VulnCheck bearer token")
		}
		_, _ = w.Write([]byte(`{
			"data": [{
				"id": "vulncheck:CVE-2026-0003",
				"cve": "CVE-2026-0003",
				"title": "Example package vulnerable",
				"severity": "high",
				"cvss_score": 8.1,
				"kev": true,
				"purls": ["pkg:deb/example@1.0.0"],
				"cpes": ["cpe:2.3:a:example:package:1.0.0:*:*:*:*:*:*:*"],
				"references": ["https://vulncheck.example/CVE-2026-0003"]
			}]
		}`))
	}))
	defer server.Close()

	producer := &advisoryProducer{client: server.Client()}
	payload := mustJSON(t, map[string]any{
		"input_values": map[string]any{
			"provider":  "vulncheck",
			"feed_key":  "vulncheck-nvd-kev",
			"url":       server.URL,
			"api_token": "vc-token",
		},
	})

	result, err := producer.RunCommand(context.Background(), addon.CommandRequest{
		ActionID:    "vulncheck.refresh",
		PayloadJSON: payload,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !result.Success {
		t.Fatalf("command failed: %s", result.Message)
	}

	var batch addon.AdvisoryFeedBatch
	if err := json.Unmarshal(result.PayloadJSON, &batch); err != nil {
		t.Fatal(err)
	}

	advisory := batch.Advisories[0]
	if advisory.CVEID != "CVE-2026-0003" || !advisory.KEV {
		t.Fatalf("advisory = %#v", advisory)
	}
	if len(advisory.AffectedCoordinates) != 2 {
		t.Fatalf("coordinates = %#v", advisory.AffectedCoordinates)
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	payload, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return payload
}
