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
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
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
	scalibrTestConfig  = "cfg-hash"
	severityHigh       = "High"
)

func TestPayloadFromResultTranslatesPackagesDiagnosticsAndScannerActivity(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = scalibrTestAgentID
	cfg.ScaLibrPlugins = []string{"os"}
	cfg.ScanRoots = []string{"/"}
	cfg.ScannerVersion = DefaultScannerVersion
	runner := NewRunner(cfg)
	started := time.Date(2026, 6, 11, 12, 0, 0, 0, time.UTC)
	ended := started.Add(2 * time.Second)

	payload, _ := runner.payloadAndPackagesFromResult(started, scalibrTestConfig, &result.ScanResult{
		Version:   DefaultScannerVersion,
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

	payload, _ := runner.payloadAndPackagesFromResult(started, scalibrTestConfig, &result.ScanResult{
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

	payload, _ := runner.payloadAndPackagesFromResult(started, scalibrTestConfig, &result.ScanResult{
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

func TestLoadConfigKeepsAddonCadenceWhenRuntimeProfileDiffers(t *testing.T) {
	tmpDir := t.TempDir()
	profilePath := filepath.Join(tmpDir, "runtime.json")
	if err := os.WriteFile(profilePath, []byte(`{
  "enabled": true,
  "agent_id": "profile-agent",
  "cadence": "1h"
}`), 0o600); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(tmpDir, "scalibr.json")
	config := DefaultConfig()
	config.Enabled = false
	config.AgentID = "staged-agent"
	config.ProfilePath = profilePath
	config.Cadence = "24h"
	data, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, data, 0o600); err != nil {
		t.Fatal(err)
	}

	loaded, err := LoadConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !loaded.Enabled || loaded.AgentID != "profile-agent" {
		t.Fatalf("runtime identity/profile was not applied: %#v", loaded)
	}
	if loaded.Cadence != "24h" {
		t.Fatalf("cadence = %q, want staged add-on cadence 24h", loaded.Cadence)
	}
}

func TestScaLibrConfigDefaultsAndValidationMatchTransportContract(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = scalibrTestAgentID
	cfg.Cadence = ""
	applyDefaults(&cfg)
	if cfg.Cadence != defaultCadence {
		t.Fatalf("empty cadence default = %q, want %q", cfg.Cadence, defaultCadence)
	}

	tests := map[string]func(*Config){
		"invalid cadence":   func(got *Config) { got.Cadence = "invalid" },
		"negative attempts": func(got *Config) { got.UploadRetryMaxAttempts = -1 },
		"retry max below initial": func(got *Config) {
			got.UploadRetryInitial = "10m"
			got.UploadRetryMax = "5m"
		},
		"oversize output": func(got *Config) {
			got.MaxOutputBytes = endpointinventory.MaxSpoolPayloadBytes + 1
		},
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			invalid := cfg
			mutate(&invalid)
			if err := validateConfig(invalid); err == nil {
				t.Fatal("expected invalid ScaLibr config to be rejected")
			}
		})
	}
}

func TestScaLibrConfigHashCoversCollectionInputsOnly(t *testing.T) {
	base := DefaultConfig()
	base.AgentID = scalibrTestAgentID
	baseHash := computeConfigHash(base)
	collectionMutations := map[string]func(*Config){
		"scanner identity": func(cfg *Config) { cfg.ScannerID = "other-scanner" },
		"scanner version":  func(cfg *Config) { cfg.ScannerVersion = "v2" },
		"network":          func(cfg *Config) { cfg.NetworkOnline = !cfg.NetworkOnline },
		"symlinks":         func(cfg *Config) { cfg.ReadSymlinks = !cfg.ReadSymlinks },
		"file limit":       func(cfg *Config) { cfg.MaxFileSize++ },
		"inode limit":      func(cfg *Config) { cfg.MaxInodes++ },
		"scan root":        func(cfg *Config) { cfg.ScanRoots = []string{"/other"} },
		"plugin":           func(cfg *Config) { cfg.ScaLibrPlugins = []string{"os/dpkg"} },
	}
	for name, mutate := range collectionMutations {
		t.Run(name, func(t *testing.T) {
			changed := base
			mutate(&changed)
			if got := computeConfigHash(changed); got == baseHash {
				t.Fatalf("collection-affecting %s did not change config hash", name)
			}
		})
	}

	operational := base
	operational.Cadence = "1h"
	operational.UploadRetryInitial = "30m"
	operational.CacheDir = "/other/cache"
	if got := computeConfigHash(operational); got != baseHash {
		t.Fatalf("operational-only settings changed config hash: got %s want %s", got, baseHash)
	}
}

func TestPartialScaLibrResultHasNoAuthoritativeSBOMOrCacheCommit(t *testing.T) {
	root := t.TempDir()
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = scalibrTestAgentID
	cfg.SpoolDir = filepath.Join(root, "spool")
	cfg.CacheDir = filepath.Join(root, "cache")
	cfg.TmpDir = filepath.Join(root, "tmp")
	runner := NewRunner(cfg)
	started := time.Unix(2_000, 0).UTC()
	payload, packages := runner.payloadAndPackagesFromResult(started, scalibrTestConfig, &result.ScanResult{
		StartTime: started,
		EndTime:   started.Add(time.Second),
		Status:    &plugin.ScanStatus{Status: plugin.ScanStatusPartiallySucceeded},
		Inventory: scalibrinventory.Inventory{Packages: []*extractor.Package{{
			Name: "partial-package", Version: "1.0.0", PURLType: "deb", Plugins: []string{"os/dpkg"},
		}}},
	})

	if payload.State != scanStatePartial || payload.CoverageState != coveragePartial ||
		payload.SBOM != nil || payload.LastSuccessfulScanAt != nil ||
		payload.PackageSetHash != "" || payload.ArtifactHash != "" {
		t.Fatalf("partial scan retained authoritative inventory: %#v", payload)
	}
	identity := endpointinventory.CacheIdentity{
		AgentID:         cfg.AgentID,
		ConfigHash:      scalibrTestConfig,
		ProducerID:      ProducerID,
		ProducerVersion: ProducerVersion,
	}
	if err := endpointinventory.FinalizeFullScan(cfg.Config, identity, payload, packages, nil, started); !errors.Is(err, endpointinventory.ErrIncompleteFullScan) {
		t.Fatalf("partial finalize error = %v, want ErrIncompleteFullScan", err)
	}
	manifest, err := endpointinventory.ReadCacheManifest(cfg.Config)
	if err != nil {
		t.Fatal(err)
	}
	if manifest != nil {
		t.Fatalf("partial scan created cache state: %#v", manifest)
	}
}

func TestNilAggregateStatusCannotHidePartialPluginDiagnostics(t *testing.T) {
	state, coverage := scanState(nil, []endpointinventory.SourceSummary{{
		Name: "os/dpkg", State: sourceStateError, Error: "permission denied",
	}}, 10)
	if state != scanStatePartial || coverage != coveragePartial {
		t.Fatalf("nil aggregate status with failed plugin = %s/%s, want partial/partial", state, coverage)
	}
}

func TestNilAggregateStatusRequiresAffirmativePluginSuccess(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = scalibrTestAgentID
	runner := NewRunner(cfg)
	started := time.Unix(2_500, 0).UTC()
	packageInventory := scalibrinventory.Inventory{Packages: []*extractor.Package{{
		Name: "unproven-package", Version: "1.0.0", PURLType: "deb",
	}}}

	for name, statuses := range map[string][]*plugin.Status{
		"nested nil status": {{Name: "os/dpkg", Status: nil}},
		"wholly nil plugin": {nil},
	} {
		t.Run(name, func(t *testing.T) {
			payload, _ := runner.payloadAndPackagesFromResult(started, scalibrTestConfig, &result.ScanResult{
				StartTime: started, EndTime: started.Add(time.Second), Status: nil,
				PluginStatus: statuses, Inventory: packageInventory,
			})
			if payload.State != scanStatePartial || payload.CoverageState != coveragePartial ||
				payload.SBOM != nil || payload.LastSuccessfulScanAt != nil {
				t.Fatalf("unproven nil-status inventory became authoritative: %#v", payload)
			}
		})
	}
}

func TestScaLibrAggregateStatusRequiresAffirmativePluginSuccess(t *testing.T) {
	inventoryWithPackage := scalibrinventory.Inventory{Packages: []*extractor.Package{{Name: "package"}}}
	tests := map[string]struct {
		statuses []*plugin.Status
		want     plugin.ScanStatusEnum
	}{
		"empty statuses":    {statuses: nil, want: plugin.ScanStatusPartiallySucceeded},
		"wholly nil plugin": {statuses: []*plugin.Status{nil}, want: plugin.ScanStatusPartiallySucceeded},
		"nested nil status": {
			statuses: []*plugin.Status{{Name: "os/dpkg", Status: nil}},
			want:     plugin.ScanStatusPartiallySucceeded,
		},
		"unspecified status": {
			statuses: []*plugin.Status{{Name: "os/dpkg", Status: &plugin.ScanStatus{Status: plugin.ScanStatusUnspecified}}},
			want:     plugin.ScanStatusPartiallySucceeded,
		},
		"failed status": {
			statuses: []*plugin.Status{{Name: "os/dpkg", Status: &plugin.ScanStatus{Status: plugin.ScanStatusFailed}}},
			want:     plugin.ScanStatusPartiallySucceeded,
		},
		"partial status": {
			statuses: []*plugin.Status{{Name: "os/dpkg", Status: &plugin.ScanStatus{Status: plugin.ScanStatusPartiallySucceeded}}},
			want:     plugin.ScanStatusPartiallySucceeded,
		},
		"success with failure detail": {
			statuses: []*plugin.Status{{Name: "os/dpkg", Status: &plugin.ScanStatus{
				Status: plugin.ScanStatusSucceeded, FailureReason: "unexpected detail",
			}}},
			want: plugin.ScanStatusPartiallySucceeded,
		},
		"affirmative success": {
			statuses: []*plugin.Status{{Name: "os/dpkg", Status: &plugin.ScanStatus{Status: plugin.ScanStatusSucceeded}}},
			want:     plugin.ScanStatusSucceeded,
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			got := scaLibrAggregateScanStatus(inventoryWithPackage, tc.statuses, nil)
			if got.Status != tc.want {
				t.Fatalf("aggregate status = %v, want %v", got.Status, tc.want)
			}
		})
	}
}

func TestScaLibrPackageLimitFailsBeforeBuildingSBOM(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = scalibrTestAgentID
	cfg.MaxPackages = 1
	runner := NewRunner(cfg)
	started := time.Unix(3_000, 0).UTC()
	payload, packages := runner.payloadAndPackagesFromResult(started, scalibrTestConfig, &result.ScanResult{
		StartTime: started,
		EndTime:   started.Add(time.Second),
		Status:    &plugin.ScanStatus{Status: plugin.ScanStatusSucceeded},
		Inventory: scalibrinventory.Inventory{Packages: []*extractor.Package{
			{Name: "one", Version: "1"},
			{Name: "two", Version: "2"},
		}},
	})

	if payload.State != scanStateFailed || payload.SBOM != nil || payload.LastSuccessfulScanAt != nil || len(packages) != 0 {
		t.Fatalf("package-limit failure retained inventory authority: payload=%#v packages=%#v", payload, packages)
	}
}

func TestStaleScaLibrFinalizeIsSuccessfulDiscard(t *testing.T) {
	root := t.TempDir()
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = scalibrTestAgentID
	cfg.SpoolDir = filepath.Join(root, "spool")
	cfg.CacheDir = filepath.Join(root, "cache")
	cfg.TmpDir = filepath.Join(root, "tmp")
	cfg.UploadJitter = "0s"
	runner := NewRunner(cfg)
	identity := endpointinventory.CacheIdentity{
		AgentID: cfg.AgentID, ConfigHash: scalibrTestConfig, ProducerID: ProducerID, ProducerVersion: ProducerVersion,
	}
	newerAt := time.Unix(5_000, 0).UTC()
	newer := completePayloadForFinalizeTest(cfg, "scan-newer", "newer-package", "newer-artifact", newerAt)
	if err := endpointinventory.FinalizeFullScan(cfg.Config, identity, newer, []endpointinventory.Package{{Name: "newer"}}, nil, newerAt); err != nil {
		t.Fatal(err)
	}
	if err := endpointinventory.WriteSpool(cfg.Config, newer); err != nil {
		t.Fatal(err)
	}

	olderAt := newerAt.Add(-time.Minute)
	older := completePayloadForFinalizeTest(cfg, "scan-older", "older-package", "older-artifact", olderAt)
	discarded, err := runner.finalizeFullScan(cfg.Config, identity, older, []endpointinventory.Package{{Name: "older"}}, nil, olderAt)
	if err != nil || !discarded {
		t.Fatalf("stale timer result = discarded:%v err:%v, want successful discard", discarded, err)
	}
	data, err := os.ReadFile(endpointinventory.LatestPath(cfg.SpoolDir))
	if err != nil {
		t.Fatal(err)
	}
	var got endpointinventory.ScanPayload
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got.ScanID != newer.ScanID {
		t.Fatalf("stale timer overwrote latest spool with %q", got.ScanID)
	}
}

func completePayloadForFinalizeTest(
	cfg Config,
	scanID string,
	packageHash string,
	artifactHash string,
	scannedAt time.Time,
) *endpointinventory.ScanPayload {
	return &endpointinventory.ScanPayload{
		SchemaVersion: endpointinventory.SchemaVersion, AgentID: cfg.AgentID, ConfigHash: scalibrTestConfig,
		CollectorVersion: ProducerVersion, ScanID: scanID, State: scanStateScanned,
		CoverageState: coverageComplete, LastScanAt: scannedAt, LastSuccessfulScanAt: &scannedAt,
		PackageCount: 1, PackageSetHash: packageHash, ArtifactHash: artifactHash,
		HashAlgorithm: endpointinventory.HashAlgorithm, UploadReason: endpointinventory.UploadReasonChanged,
		SBOM: &endpointinventory.CycloneDXBOM{}, Metadata: map[string]any{"scanner_producer_id": ProducerID},
	}
}

func TestScaLibrPayloadUsesSharedPendingAckAndReconcileLifecycle(t *testing.T) {
	tmpDir := t.TempDir()
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.AgentID = scalibrTestAgentID
	cfg.SpoolDir = filepath.Join(tmpDir, "spool")
	cfg.CacheDir = filepath.Join(tmpDir, "cache")
	cfg.TmpDir = filepath.Join(tmpDir, "tmp")
	cfg.UploadJitter = "0s"
	runner := NewRunner(cfg)
	identity := endpointinventory.CacheIdentity{
		AgentID:         cfg.AgentID,
		ConfigHash:      scalibrTestConfig,
		ProducerID:      ProducerID,
		ProducerVersion: ProducerVersion,
	}
	started := time.Unix(1_000, 0).UTC()
	scanResult := &result.ScanResult{
		StartTime: started,
		EndTime:   started.Add(time.Second),
		Status:    &plugin.ScanStatus{Status: plugin.ScanStatusSucceeded},
		PluginStatus: []*plugin.Status{{
			Name:   "os/dpkg",
			Status: &plugin.ScanStatus{Status: plugin.ScanStatusSucceeded},
		}},
		Inventory: scalibrinventory.Inventory{
			Packages: []*extractor.Package{{
				Name:     "openssl",
				Version:  "3.0.2-0ubuntu1",
				PURLType: "deb",
				Plugins:  []string{"os/dpkg"},
			}},
		},
	}

	first, packages := runner.payloadAndPackagesFromResult(started, scalibrTestConfig, scanResult)
	if err := endpointinventory.FinalizeFullScan(cfg.Config, identity, first, packages, nil, started); err != nil {
		t.Fatal(err)
	}
	manifest, err := endpointinventory.ReadCacheManifest(cfg.Config)
	if err != nil {
		t.Fatal(err)
	}
	if first.CollectorVersion != ProducerVersion ||
		first.UploadReason != endpointinventory.UploadReasonChanged ||
		first.SBOM == nil ||
		manifest == nil ||
		manifest.PendingUpload == nil {
		t.Fatalf("first ScaLibr result did not create pending state before spooling: payload=%#v manifest=%#v", first, manifest)
	}
	if err := endpointinventory.WriteSpool(cfg.Config, first); err != nil {
		t.Fatal(err)
	}
	if err := endpointinventory.MarkUploadSucceeded(cfg.Config, first, started.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(endpointinventory.PendingUploadPath(cfg.SpoolDir)); !os.IsNotExist(err) {
		t.Fatalf("pending spool file remains after ack: %v", err)
	}

	reconcileAt := started.Add(2 * time.Minute)
	if err := endpointinventory.MarkServerReconcileRequested(cfg.Config, reconcileAt, "server floor"); err != nil {
		t.Fatal(err)
	}
	secondStarted := started.Add(3 * time.Minute)
	secondResult := *scanResult
	secondResult.StartTime = secondStarted
	secondResult.EndTime = secondStarted.Add(time.Second)
	second, secondPackages := runner.payloadAndPackagesFromResult(secondStarted, scalibrTestConfig, &secondResult)
	if err := endpointinventory.FinalizeFullScan(
		cfg.Config,
		identity,
		second,
		secondPackages,
		nil,
		secondStarted,
	); err != nil {
		t.Fatal(err)
	}
	manifest, err = endpointinventory.ReadCacheManifest(cfg.Config)
	if err != nil {
		t.Fatal(err)
	}
	if second.UploadReason != endpointinventory.UploadReasonChanged ||
		second.SBOM == nil ||
		second.Metadata[endpointinventory.MetadataReasonKey] != "server_reconcile_floor" ||
		manifest.PendingUpload == nil ||
		manifest.ServerReconcileRequestedAt == nil {
		t.Fatalf("reconcile did not force a pending full anchor: payload=%#v manifest=%#v", second, manifest)
	}
	if err := endpointinventory.WriteSpool(cfg.Config, second); err != nil {
		t.Fatal(err)
	}
	if err := endpointinventory.MarkUploadSucceeded(cfg.Config, second, secondStarted.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}

	thirdStarted := started.Add(5 * time.Minute)
	thirdResult := *scanResult
	thirdResult.StartTime = thirdStarted
	thirdResult.EndTime = thirdStarted.Add(time.Second)
	third, thirdPackages := runner.payloadAndPackagesFromResult(thirdStarted, scalibrTestConfig, &thirdResult)
	if err := endpointinventory.FinalizeFullScan(
		cfg.Config,
		identity,
		third,
		thirdPackages,
		nil,
		thirdStarted,
	); err != nil {
		t.Fatal(err)
	}
	if third.UploadReason != endpointinventory.UploadReasonUnchanged ||
		third.SBOM != nil ||
		third.Metadata[endpointinventory.MetadataReasonKey] != endpointinventory.MetadataReasonFullScanHashUnchanged {
		t.Fatalf("acknowledged identical full scan should be a freshness-only status: %#v", third)
	}
}
