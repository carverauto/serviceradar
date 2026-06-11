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

package scalibrinventory

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/addon"
	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	"github.com/google/osv-scalibr/extractor"
	dpkgmeta "github.com/google/osv-scalibr/extractor/filesystem/os/dpkg/metadata"
	scalibrinventory "github.com/google/osv-scalibr/inventory"
	"github.com/google/osv-scalibr/plugin"
	"github.com/google/osv-scalibr/result"
)

const (
	scalibrTestAgentID = "agent-ns01"
	severityHigh       = "High"
)

func TestPayloadFromResultTranslatesPackagesDiagnosticsAndScannerActivity(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = scalibrTestAgentID
	cfg.ScaLibrPlugins = []string{"os"}
	cfg.ScanRoots = []string{"/"}
	cfg.ScannerVersion = "v0.4.5"
	runner := NewRunner(cfg)
	started := time.Date(2026, 6, 11, 12, 0, 0, 0, time.UTC)
	ended := started.Add(2 * time.Second)

	payload := runner.payloadFromResult(started, "cfg-hash", &result.ScanResult{
		Version:   "v0.4.5",
		StartTime: started,
		EndTime:   ended,
		Status:    &plugin.ScanStatus{Status: plugin.ScanStatusSucceeded},
		PluginStatus: []*plugin.Status{{
			Name:    "os/dpkg",
			Version: 1,
			Status:  &plugin.ScanStatus{Status: plugin.ScanStatusSucceeded},
		}},
		Inventory: scalibrinventory.Inventory{
			Packages: []*extractor.Package{{
				Name:     "openssl",
				Version:  "3.0.2-0ubuntu1",
				PURLType: "deb",
				Plugins:  []string{"os/dpkg"},
				Metadata: &dpkgmeta.Metadata{Architecture: "amd64"},
			}},
		},
	})

	if payload.State != scanStateScanned || payload.CoverageState != coverageComplete {
		t.Fatalf("unexpected scan state: %s/%s", payload.State, payload.CoverageState)
	}
	if payload.PackageCount != 1 || payload.SBOM == nil || len(payload.SBOM.Components) != 1 {
		t.Fatalf("expected one package and SBOM component, got count=%d sbom=%#v", payload.PackageCount, payload.SBOM)
	}
	component := payload.SBOM.Components[0]
	if component.Name != "openssl" || component.Version != "3.0.2-0ubuntu1" || component.PURL == "" {
		t.Fatalf("unexpected component: %#v", component)
	}
	if len(payload.Diagnostics) != 1 || payload.Diagnostics[0].Name != "os/dpkg" || payload.Diagnostics[0].State != scanStateScanned {
		t.Fatalf("unexpected diagnostics: %#v", payload.Diagnostics)
	}

	activity, ok := payload.Metadata[metadataScannerActivityKey].(addon.ScannerScanActivity)
	if !ok {
		t.Fatalf("missing scanner activity metadata: %#v", payload.Metadata)
	}
	if activity.SchemaVersion != addon.ScannerContractVersion ||
		activity.ProducerID != ProducerID ||
		activity.ScannerID != DefaultScannerID ||
		activity.Target.AgentID != scalibrTestAgentID ||
		activity.CoverageState != addon.ScannerCoverageComplete ||
		len(activity.Diagnostics) != 1 ||
		len(activity.Artifacts) != 1 {
		t.Fatalf("unexpected scanner activity: %#v", activity)
	}
}

func TestPayloadFromResultTranslatesGenericFindingsToScannerFindings(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = scalibrTestAgentID
	runner := NewRunner(cfg)
	started := time.Date(2026, 6, 11, 12, 0, 0, 0, time.UTC)

	payload := runner.payloadFromResult(started, "cfg-hash", &result.ScanResult{
		StartTime: started,
		EndTime:   started.Add(time.Second),
		Status:    &plugin.ScanStatus{Status: plugin.ScanStatusSucceeded},
		Inventory: scalibrinventory.Inventory{
			GenericFindings: []*scalibrinventory.GenericFinding{{
				Adv: &scalibrinventory.GenericFindingAdvisory{
					ID: &scalibrinventory.AdvisoryID{
						Publisher: "test",
						Reference: "TEST-2026-0001",
					},
					Title:          "weak host setting",
					Description:    "details",
					Recommendation: "tighten the setting",
					Sev:            scalibrinventory.SeverityHigh,
				},
				Target:  &scalibrinventory.GenericFindingTargetDetails{Extra: "/etc/example.conf"},
				Plugins: []string{"test-detector"},
			}},
		},
	})

	findings, ok := payload.Metadata[metadataScannerFindingsKey].([]addon.ScannerFinding)
	if !ok {
		t.Fatalf("missing scanner findings metadata: %#v", payload.Metadata)
	}
	if len(findings) != 1 {
		t.Fatalf("expected one finding, got %#v", findings)
	}
	finding := findings[0]
	if finding.SchemaVersion != addon.ScannerContractVersion ||
		finding.ParentScanID != payload.ScanID ||
		finding.ProducerID != ProducerID ||
		finding.Title != "weak host setting" ||
		finding.Severity != severityHigh ||
		finding.Evidence["advisory_id"] != "TEST-2026-0001" ||
		finding.Remediation["recommendation"] != "tighten the setting" {
		t.Fatalf("unexpected finding: %#v", finding)
	}
}

func TestPayloadFromResultKeepsFailedScanAsDiagnosticPayload(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = scalibrTestAgentID
	runner := NewRunner(cfg)
	started := time.Date(2026, 6, 11, 12, 0, 0, 0, time.UTC)

	payload := runner.payloadFromResult(started, "cfg-hash", &result.ScanResult{
		StartTime: started,
		EndTime:   started.Add(time.Second),
		Status: &plugin.ScanStatus{
			Status:        plugin.ScanStatusFailed,
			FailureReason: "permission denied",
		},
		PluginStatus: []*plugin.Status{{
			Name: "os/dpkg",
			Status: &plugin.ScanStatus{
				Status:        plugin.ScanStatusFailed,
				FailureReason: "permission denied",
			},
		}},
	})

	if payload.State != scanStateFailed || payload.CoverageState != coverageFailed || payload.SBOM != nil {
		t.Fatalf("unexpected failed payload: %#v", payload)
	}
	if len(payload.Diagnostics) != 1 ||
		payload.Diagnostics[0].State != sourceStateError ||
		payload.Diagnostics[0].Reason != "plugin_error" {
		t.Fatalf("unexpected diagnostics: %#v", payload.Diagnostics)
	}
}

func TestLegacyEndpointInventoryCollectorRemainsAvailableAsFallback(t *testing.T) {
	cfg := endpointinventory.DefaultConfig()
	if len(cfg.Sources) == 0 {
		t.Fatal("legacy endpoint inventory sources should remain configured as fallback")
	}
}
