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
	"time"
)

func TestScannerScanActivityContractIsImplementationAgnostic(t *testing.T) {
	activity := ScannerScanActivity{
		SchemaVersion:   ScannerContractVersion,
		ScanID:          "scan-1",
		ProducerID:      "com.example.endpoint-scanner",
		ProducerVersion: "1.0.0",
		ScannerID:       "host-inventory",
		ScannerVersion:  "2.3.4",
		Target: ScannerTarget{
			Type:      "host",
			DeviceUID: "sr:device-1",
			AgentID:   "agent-1",
		},
		State:         ScannerStatePartial,
		CoverageState: ScannerCoveragePartial,
		StartedAt:     time.Unix(10, 0).UTC(),
		EndedAt:       time.Unix(11, 0).UTC(),
		ConfigHash:    strings.Repeat("a", 64),
		Diagnostics: []ScannerSourceDiagnostic{
			{
				Name:           "os-packages",
				Type:           "extractor",
				State:          ScannerStatePartial,
				Detected:       true,
				PackageCount:   12,
				Reason:         "output_truncated",
				DurationMillis: 1000,
				Truncated:      true,
			},
		},
		Artifacts: []ScannerInventoryArtifact{
			{
				Kind:      "sbom",
				Format:    "CycloneDX",
				Version:   "1.6",
				MediaType: "application/vnd.cyclonedx+json",
				ObjectKey: "scanner-artifacts/scan-1/sbom.json",
				SHA256:    strings.Repeat("b", 64),
				SizeBytes: 128,
			},
		},
	}

	data, err := json.Marshal(activity)
	if err != nil {
		t.Fatal(err)
	}
	payload := string(data)
	for _, forbidden := range []string{"scalibr", "trivy", "falco"} {
		if strings.Contains(strings.ToLower(payload), forbidden) {
			t.Fatalf("generic scanner contract leaked implementation name %q in %s", forbidden, payload)
		}
	}
	if !strings.Contains(payload, `"schema_version":"serviceradar.scanner.contract.v1"`) {
		t.Fatalf("schema_version missing from payload: %s", payload)
	}
	if !strings.Contains(payload, `"diagnostics"`) || !strings.Contains(payload, `"artifacts"`) {
		t.Fatalf("diagnostics/artifacts missing from payload: %s", payload)
	}
}

func TestScannerFindingContractCarriesOCSFMapping(t *testing.T) {
	finding := ScannerFinding{
		SchemaVersion: ScannerContractVersion,
		FindingID:     "finding-1",
		ParentScanID:  "scan-1",
		ProducerID:    "com.example.endpoint-scanner",
		OCSFClassUID:  2002,
		OCSFTypeUID:   200201,
		Title:         "Example vulnerability",
		Severity:      "High",
		Status:        "Open",
		Target: ScannerTarget{
			Type:      "host",
			DeviceUID: "sr:device-1",
		},
		Evidence: map[string]any{
			"package": "openssl",
			"version": "3.0.0",
		},
		References: []string{"https://example.invalid/advisory"},
	}

	data, err := json.Marshal(finding)
	if err != nil {
		t.Fatal(err)
	}
	payload := string(data)
	if !strings.Contains(payload, `"ocsf_class_uid":2002`) ||
		!strings.Contains(payload, `"evidence"`) ||
		!strings.Contains(payload, `"references"`) {
		t.Fatalf("finding payload missing OCSF/evidence fields: %s", payload)
	}
}
