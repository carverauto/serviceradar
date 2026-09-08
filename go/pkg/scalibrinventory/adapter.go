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
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/addon"
	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	cpb "github.com/google/osv-scalibr/binary/proto/config_go_proto"
	scalibrfilesystem "github.com/google/osv-scalibr/extractor/filesystem"
	"github.com/google/osv-scalibr/extractor/filesystem/os/apk"
	apkmeta "github.com/google/osv-scalibr/extractor/filesystem/os/apk/metadata"
	"github.com/google/osv-scalibr/extractor/filesystem/os/dpkg"
	dpkgmeta "github.com/google/osv-scalibr/extractor/filesystem/os/dpkg/metadata"
	"github.com/google/osv-scalibr/extractor/filesystem/os/rpm"
	rpmmeta "github.com/google/osv-scalibr/extractor/filesystem/os/rpm/metadata"
	scalibrfs "github.com/google/osv-scalibr/fs"
	scalibrinventory "github.com/google/osv-scalibr/inventory"
	"github.com/google/osv-scalibr/plugin"
	"github.com/google/osv-scalibr/result"
	"github.com/google/osv-scalibr/stats"
)

const (
	ProducerID            = "serviceradar.scalibr.endpoint_inventory"
	ProducerVersion       = "0.1.5"
	DefaultScannerID      = "osv-scalibr"
	DefaultScannerVersion = "v0.5.2"
	defaultCadence        = "24h"

	metadataScannerActivityKey = "scanner_activity"
	metadataScannerFindingsKey = "scanner_findings"

	scanStateScanned    = "scanned"
	scanStateNotScanned = "not_scanned"
	scanStateFailed     = "scan_failed"
	scanStatePartial    = "partial"

	coverageComplete = "complete"
	coveragePartial  = "partial"
	coverageFailed   = "failed"
	coverageUnknown  = "unknown"

	sourceStateError   = "error"
	sourceStatePartial = "partial"
	sourceStateSkipped = "skipped"
	sourceStateUnknown = "unknown"
)

var (
	errScaLibrScanFailed        = errors.New("scalibr endpoint inventory scan failed")
	errScanRootRequired         = errors.New("at least one scan root is required")
	errNilScaLibrScanResult     = errors.New("scalibr returned nil scan result")
	errPackageLimitExceeded     = errors.New("scalibr endpoint inventory package limit exceeded")
	errUnsupportedScaLibrPlugin = errors.New("unsupported scalibr endpoint inventory plugin")
)

type Config struct {
	endpointinventory.Config

	ScannerID      string   `json:"scanner_id"`
	ScannerVersion string   `json:"scanner_version"`
	ScaLibrPlugins []string `json:"scalibr_plugins"`
	ScanRoots      []string `json:"scan_roots"`
	PathsToExtract []string `json:"paths_to_extract"`
	DirsToSkip     []string `json:"dirs_to_skip"`
	NetworkOnline  bool     `json:"network_online"`
	ReadSymlinks   bool     `json:"read_symlinks"`
	MaxFileSize    int      `json:"max_file_size"`
	MaxInodes      int      `json:"max_inodes"`
}

func DefaultConfig() Config {
	base := endpointinventory.DefaultConfig()
	base.Cadence = defaultCadence
	base.CacheStaleThreshold = "26h"

	return Config{
		Config:         base,
		ScannerID:      DefaultScannerID,
		ScannerVersion: DefaultScannerVersion,
		ScaLibrPlugins: []string{"os/dpkg", "os/rpm", "os/apk"},
		ScanRoots:      []string{"/"},
	}
}

type Runner struct {
	cfg Config
}

func NewRunner(cfg Config) *Runner {
	return &Runner{cfg: cfg}
}

func (r *Runner) Run(ctx context.Context) (*endpointinventory.ScanPayload, error) {
	started := time.Now().UTC()
	configHash := computeConfigHash(r.cfg)
	identity := endpointinventory.CacheIdentity{
		AgentID:         r.cfg.AgentID,
		ConfigHash:      configHash,
		ProducerID:      ProducerID,
		ProducerVersion: ProducerVersion,
	}
	if !r.cfg.Enabled {
		return disabledPayload(r.cfg, started, configHash), nil
	}

	sourceMTimes := endpointinventory.CollectSourceMTimes(r.cfg.Config)
	cache, err := endpointinventory.ReadCacheManifest(r.cfg.Config)
	if err != nil {
		return nil, err
	}
	if endpointinventory.CacheCanSkipFullScan(r.cfg.Config, identity, cache, sourceMTimes, started) {
		payload := r.unchangedPayload(started, configHash, cache, "cadence_not_due")
		if err := endpointinventory.RecordCachedScan(r.cfg.Config, identity, sourceMTimes, started); err == nil {
			return payload, nil
		} else if !errors.Is(err, endpointinventory.ErrCacheRefreshRequired) {
			return nil, err
		}
	}

	ctx, cancel := context.WithTimeout(ctx, endpointinventory.ScanTimeout(r.cfg.Config))
	defer cancel()

	extractors, err := scalibrExtractors(r.cfg.ScaLibrPlugins)
	if err != nil {
		return r.failurePayload(started, configHash, nil, err), nil
	}

	scanRoots := make([]*scalibrfs.ScanRoot, 0, len(r.cfg.ScanRoots))
	for _, root := range r.cfg.ScanRoots {
		root = strings.TrimSpace(root)
		if root == "" {
			continue
		}
		scanRoots = append(scanRoots, scalibrfs.RealFSScanRoots(root)...)
	}
	if len(scanRoots) == 0 {
		return r.failurePayload(started, configHash, nil, errScanRootRequired), nil
	}

	capabilities := &plugin.Capabilities{
		OS:              plugin.OSLinux,
		Network:         plugin.NetworkOffline,
		DirectFS:        true,
		RunningSystem:   true,
		ExtractFromDirs: true,
	}
	if r.cfg.NetworkOnline {
		capabilities.Network = plugin.NetworkOnline
	}

	extractors = filterExtractorsByCapabilities(extractors, capabilities)
	scanResult := runScaLibrFilesystemScan(ctx, started, r.cfg, scanRoots, extractors)
	payload, packages := r.payloadAndPackagesFromResult(started, configHash, scanResult)
	if payload.State == scanStateScanned && payload.CoverageState == coverageComplete {
		discarded, err := r.finalizeFullScan(
			r.cfg.Config,
			identity,
			payload,
			packages,
			sourceMTimes,
			started,
		)
		if err != nil {
			return nil, err
		}
		if discarded {
			return nil, nil
		}
	}

	return payload, nil
}

func (r *Runner) finalizeFullScan(
	cfg endpointinventory.Config,
	identity endpointinventory.CacheIdentity,
	payload *endpointinventory.ScanPayload,
	packages []endpointinventory.Package,
	sourceMTimes map[string]endpointinventory.SourceMTime,
	started time.Time,
) (bool, error) {
	err := endpointinventory.FinalizeFullScan(cfg, identity, payload, packages, sourceMTimes, started)
	if errors.Is(err, endpointinventory.ErrStaleFullScan) {
		return true, nil
	}

	return false, err
}

func (r *Runner) payloadAndPackagesFromResult(
	started time.Time,
	configHash string,
	scanResult *result.ScanResult,
) (*endpointinventory.ScanPayload, []endpointinventory.Package) {
	if scanResult == nil {
		return r.failurePayload(started, configHash, nil, errNilScaLibrScanResult), nil
	}

	endedAt := firstTime(scanResult.EndTime, time.Now().UTC())
	packages := endpointPackages(scanResult.Inventory)
	diagnostics := sourceDiagnostics(scanResult.PluginStatus)
	if len(diagnostics) == 0 && len(r.cfg.ScaLibrPlugins) > 0 {
		for _, name := range r.cfg.ScaLibrPlugins {
			diagnostics = append(diagnostics, endpointinventory.SourceSummary{
				Name:  name,
				Type:  "scanner_plugin",
				State: sourceStateSkipped,
			})
		}
	}
	if len(packages) > r.cfg.MaxPackages {
		return r.failurePayload(
			started,
			configHash,
			scanResult.PluginStatus,
			fmt.Errorf("%w: got %d, max %d", errPackageLimitExceeded, len(packages), r.cfg.MaxPackages),
		), nil
	}

	state, coverage := scanState(scanResult.Status, diagnostics, len(packages))
	var (
		sbom           *endpointinventory.CycloneDXBOM
		packageSetHash string
		artifactHash   string
	)
	if state == scanStateScanned && coverage == coverageComplete {
		completeSBOM := endpointinventory.BuildCycloneDX(r.cfg.Config, started, endpointinventory.OSInfo{}, packages)
		sbom = &completeSBOM
		packageSetHash = endpointinventory.ComputePackageSetHash(packages)
		artifactHash = endpointinventory.ComputeArtifactHash(completeSBOM)
	}
	activity := r.scanActivity(started, endedAt, configHash, state, coverage, diagnostics, artifactHash, int64(len(packages)))
	findings := scannerFindings(r.cfg, scanResult.Inventory, activity.ScanID)

	payload := &endpointinventory.ScanPayload{
		SchemaVersion:        endpointinventory.SchemaVersion,
		AgentID:              r.cfg.AgentID,
		ScanID:               activity.ScanID,
		CollectorVersion:     ProducerVersion,
		State:                state,
		CoverageState:        coverage,
		ConfigHash:           configHash,
		LastScanAt:           started,
		LastSuccessfulScanAt: successfulAt(state, endedAt),
		EnabledPlugins:       append([]string(nil), r.cfg.ScaLibrPlugins...),
		DetectedPlugins:      detectedPlugins(diagnostics),
		Diagnostics:          diagnostics,
		PackageCount:         len(packages),
		PackageSetHash:       packageSetHash,
		ArtifactHash:         artifactHash,
		HashAlgorithm:        endpointinventory.HashAlgorithm,
		UploadReason:         endpointinventory.UploadReasonChanged,
		DurationMillis:       endedAt.Sub(started).Milliseconds(),
		Truncated:            diagnosticsTruncated(diagnostics),
		SBOM:                 sbom,
		Metadata: map[string]any{
			"scanner_family":               "endpoint_inventory",
			"scanner_contract_version":     addon.ScannerContractVersion,
			"scanner_producer_id":          ProducerID,
			"scanner_producer_version":     ProducerVersion,
			"scanner_id":                   firstNonEmpty(r.cfg.ScannerID, DefaultScannerID),
			"scanner_version":              r.cfg.ScannerVersion,
			"scanner_findings_count":       len(findings),
			metadataScannerActivityKey:     activity,
			metadataScannerFindingsKey:     findings,
			"scalibr_enabled_plugin_names": append([]string(nil), r.cfg.ScaLibrPlugins...),
		},
	}
	return payload, packages
}

func (r *Runner) unchangedPayload(
	scannedAt time.Time,
	configHash string,
	cache *endpointinventory.InventoryCacheManifest,
	reason string,
) *endpointinventory.ScanPayload {
	return &endpointinventory.ScanPayload{
		SchemaVersion:        endpointinventory.SchemaVersion,
		AgentID:              r.cfg.AgentID,
		ScanID:               newScanID(scannedAt, r.cfg.AgentID, configHash),
		CollectorVersion:     ProducerVersion,
		State:                "unchanged",
		CoverageState:        "unchanged",
		ConfigHash:           configHash,
		LastScanAt:           scannedAt,
		LastSuccessfulScanAt: cache.LastSuccessfulScanAt,
		EnabledPlugins:       append([]string(nil), r.cfg.ScaLibrPlugins...),
		DetectedPlugins:      detectedPlugins(cache.SourceSummaries),
		Diagnostics:          append([]endpointinventory.SourceSummary(nil), cache.SourceSummaries...),
		PackageCount:         cache.PackageCount,
		PackageSetHash:       cache.PackageSetHash,
		ArtifactHash:         cache.ArtifactHash,
		HashAlgorithm:        firstNonEmpty(cache.HashAlgorithm, endpointinventory.HashAlgorithm),
		UploadReason:         endpointinventory.UploadReasonUnchanged,
		Metadata: map[string]any{
			"reason":                       reason,
			"scans_since_full":             cache.ScansSinceFull + 1,
			"scanner_family":               "endpoint_inventory",
			"scanner_contract_version":     addon.ScannerContractVersion,
			"scanner_producer_id":          ProducerID,
			"scanner_producer_version":     ProducerVersion,
			"scanner_id":                   firstNonEmpty(r.cfg.ScannerID, DefaultScannerID),
			"scanner_version":              r.cfg.ScannerVersion,
			"scalibr_enabled_plugin_names": append([]string(nil), r.cfg.ScaLibrPlugins...),
		},
	}
}

func (r *Runner) failurePayload(
	started time.Time,
	configHash string,
	statuses []*plugin.Status,
	err error,
) *endpointinventory.ScanPayload {
	endedAt := time.Now().UTC()
	diagnostics := sourceDiagnostics(statuses)
	if len(diagnostics) == 0 {
		diagnostics = []endpointinventory.SourceSummary{{
			Name:   firstNonEmpty(r.cfg.ScannerID, DefaultScannerID),
			Type:   "scanner",
			State:  "error",
			Reason: "scanner_error",
			Error:  err.Error(),
		}}
	}
	activity := r.scanActivity(started, endedAt, configHash, scanStateFailed, coverageFailed, diagnostics, "", 0)

	return &endpointinventory.ScanPayload{
		SchemaVersion:    endpointinventory.SchemaVersion,
		AgentID:          r.cfg.AgentID,
		ScanID:           activity.ScanID,
		CollectorVersion: ProducerVersion,
		State:            scanStateFailed,
		CoverageState:    coverageFailed,
		ConfigHash:       configHash,
		LastScanAt:       started,
		EnabledPlugins:   append([]string(nil), r.cfg.ScaLibrPlugins...),
		Diagnostics:      diagnostics,
		DurationMillis:   endedAt.Sub(started).Milliseconds(),
		Metadata: map[string]any{
			"scanner_family":           "endpoint_inventory",
			"scanner_contract_version": addon.ScannerContractVersion,
			"scanner_producer_id":      ProducerID,
			"scanner_producer_version": ProducerVersion,
			"scanner_id":               firstNonEmpty(r.cfg.ScannerID, DefaultScannerID),
			"scanner_version":          r.cfg.ScannerVersion,
			"error":                    err.Error(),
			metadataScannerActivityKey: activity,
		},
	}
}

func disabledPayload(cfg Config, scannedAt time.Time, configHash string) *endpointinventory.ScanPayload {
	return &endpointinventory.ScanPayload{
		SchemaVersion:    endpointinventory.SchemaVersion,
		AgentID:          cfg.AgentID,
		ScanID:           "scalibr-endpoint-inventory-disabled",
		CollectorVersion: ProducerVersion,
		State:            scanStateNotScanned,
		CoverageState:    "disabled",
		ConfigHash:       configHash,
		LastScanAt:       scannedAt,
		EnabledPlugins:   append([]string(nil), cfg.ScaLibrPlugins...),
		Diagnostics:      []endpointinventory.SourceSummary{},
		Metadata: map[string]any{
			"scanner_family":           "endpoint_inventory",
			"scanner_contract_version": addon.ScannerContractVersion,
			"scanner_producer_id":      ProducerID,
			"scanner_producer_version": ProducerVersion,
			"scanner_id":               firstNonEmpty(cfg.ScannerID, DefaultScannerID),
			"scanner_version":          cfg.ScannerVersion,
			"reason":                   "disabled",
		},
	}
}

func (r *Runner) scanActivity(
	started time.Time,
	ended time.Time,
	configHash string,
	state string,
	coverage string,
	diagnostics []endpointinventory.SourceSummary,
	artifactHash string,
	packageCount int64,
) addon.ScannerScanActivity {
	artifacts := []addon.ScannerInventoryArtifact{}
	if artifactHash != "" {
		artifacts = append(artifacts, addon.ScannerInventoryArtifact{
			Kind:      "sbom",
			Format:    endpointinventory.CycloneDXFormat,
			Version:   endpointinventory.CycloneDXSpecVersion,
			MediaType: "application/vnd.cyclonedx+json",
			SHA256:    artifactHash,
			Metadata: map[string]string{
				"package_count": fmt.Sprintf("%d", packageCount),
			},
		})
	}

	return addon.ScannerScanActivity{
		SchemaVersion:   addon.ScannerContractVersion,
		ScanID:          newScanID(started, r.cfg.AgentID, configHash),
		ProducerID:      ProducerID,
		ProducerVersion: ProducerVersion,
		ScannerID:       firstNonEmpty(r.cfg.ScannerID, DefaultScannerID),
		ScannerVersion:  r.cfg.ScannerVersion,
		Target: addon.ScannerTarget{
			Type:    "host",
			AgentID: r.cfg.AgentID,
			Name:    r.cfg.AgentID,
			Annotations: map[string]string{
				"scan_roots": strings.Join(r.cfg.ScanRoots, ","),
			},
		},
		State:         scannerState(state),
		CoverageState: scannerCoverage(coverage),
		StartedAt:     started,
		EndedAt:       ended,
		ConfigHash:    configHash,
		Diagnostics:   scannerDiagnostics(diagnostics),
		Artifacts:     artifacts,
		Metadata: map[string]any{
			"enabled_plugins":  append([]string(nil), r.cfg.ScaLibrPlugins...),
			"paths_to_extract": append([]string(nil), r.cfg.PathsToExtract...),
			"dirs_to_skip":     append([]string(nil), r.cfg.DirsToSkip...),
		},
	}
}

func endpointPackages(inv scalibrinventory.Inventory) []endpointinventory.Package {
	packages := make([]endpointinventory.Package, 0, len(inv.Packages))
	for _, pkg := range inv.Packages {
		if pkg == nil || strings.TrimSpace(pkg.Name) == "" {
			continue
		}
		manager := packageManager(pkg.Plugins, pkg.PURLType)
		purl := ""
		if packageURL := pkg.PURL(); packageURL != nil {
			purl = packageURL.String()
		}
		packages = append(packages, endpointinventory.Package{
			Name:      strings.TrimSpace(pkg.Name),
			Version:   strings.TrimSpace(pkg.Version),
			Arch:      metadataArchitecture(pkg.Metadata),
			Manager:   manager,
			Ecosystem: firstNonEmpty(strings.TrimSpace(pkg.PURLType), pkg.Ecosystem().String()),
			PURL:      purl,
		})
	}
	sort.Slice(packages, func(i, j int) bool {
		if packages[i].Manager == packages[j].Manager {
			if packages[i].Name == packages[j].Name {
				return packages[i].Version < packages[j].Version
			}
			return packages[i].Name < packages[j].Name
		}

		return packages[i].Manager < packages[j].Manager
	})

	return packages
}

func sourceDiagnostics(statuses []*plugin.Status) []endpointinventory.SourceSummary {
	diagnostics := make([]endpointinventory.SourceSummary, 0, len(statuses))
	for _, status := range statuses {
		if status == nil {
			continue
		}
		summary := endpointinventory.SourceSummary{
			Source: status.Name,
			Name:   status.Name,
			Type:   "scanner_plugin",
			State:  sourceStateUnknown,
		}
		if status.Status != nil {
			summary.State = pluginState(status.Status.Status)
			if status.Status.FailureReason != "" {
				summary.Error = status.Status.FailureReason
				summary.Reason = "plugin_error"
			}
			if len(status.Status.FileErrors) > 0 {
				summary.Reason = "file_errors"
				if summary.Error == "" {
					summary.Error = fmt.Sprintf("%d file errors", len(status.Status.FileErrors))
				}
			}
		}
		summary.Detected = summary.State == "scanned" || summary.State == "partial"
		diagnostics = append(diagnostics, summary)
	}

	return diagnostics
}

func allDiagnosticsSucceeded(diagnostics []endpointinventory.SourceSummary) bool {
	if len(diagnostics) == 0 {
		return false
	}
	for _, diagnostic := range diagnostics {
		if diagnostic.State != scanStateScanned {
			return false
		}
	}

	return true
}

func runScaLibrFilesystemScan(
	ctx context.Context,
	started time.Time,
	cfg Config,
	scanRoots []*scalibrfs.ScanRoot,
	extractors []scalibrfilesystem.Extractor,
) *result.ScanResult {
	inv, statuses, err := scalibrfilesystem.Run(ctx, &scalibrfilesystem.Config{
		ReadSymlinks:   cfg.ReadSymlinks,
		Extractors:     extractors,
		PathsToExtract: cloneStrings(cfg.PathsToExtract),
		DirsToSkip:     cloneStrings(cfg.DirsToSkip),
		ScanRoots:      scanRoots,
		MaxInodes:      cfg.MaxInodes,
		MaxFileSize:    cfg.MaxFileSize,
		// osv-scalibr's filesystem walker calls stats.AfterInodeVisited on every inode
		// with no nil guard (extractor/filesystem/filesystem.go), so a nil Stats panics on
		// the first inode of every scan. Provide the library's no-op collector.
		Stats: stats.NoopCollector{},
	})

	ended := time.Now().UTC()
	status := scaLibrAggregateScanStatus(inv, statuses, err)

	return &result.ScanResult{
		Version:      cfg.ScannerVersion,
		StartTime:    started,
		EndTime:      ended,
		Status:       status,
		PluginStatus: statuses,
		Inventory:    inv,
	}
}

func scaLibrAggregateScanStatus(
	inv scalibrinventory.Inventory,
	statuses []*plugin.Status,
	scanErr error,
) *plugin.ScanStatus {
	switch {
	case scanErr != nil && inv.IsEmpty():
		return &plugin.ScanStatus{Status: plugin.ScanStatusFailed, FailureReason: scanErr.Error()}
	case scanErr != nil:
		return &plugin.ScanStatus{Status: plugin.ScanStatusPartiallySucceeded, FailureReason: scanErr.Error()}
	case !allPluginStatusesSucceeded(statuses):
		return &plugin.ScanStatus{Status: plugin.ScanStatusPartiallySucceeded}
	default:
		return &plugin.ScanStatus{Status: plugin.ScanStatusSucceeded}
	}
}

func scalibrExtractors(names []string) ([]scalibrfilesystem.Extractor, error) {
	cfg := &cpb.PluginConfig{}
	pluginsByName := make(map[string]scalibrfilesystem.Extractor)

	for _, name := range names {
		switch strings.TrimSpace(name) {
		case "", "os":
			for _, pluginName := range []string{dpkg.Name, rpm.Name, apk.Name} {
				if err := addScaLibrPlugin(pluginsByName, pluginName, cfg); err != nil {
					return nil, err
				}
			}
		case dpkg.Name, rpm.Name, apk.Name:
			if err := addScaLibrPlugin(pluginsByName, name, cfg); err != nil {
				return nil, err
			}
		default:
			return nil, fmt.Errorf("%w: %q", errUnsupportedScaLibrPlugin, name)
		}
	}

	out := make([]scalibrfilesystem.Extractor, 0, len(pluginsByName))
	for _, name := range []string{dpkg.Name, rpm.Name, apk.Name} {
		if p := pluginsByName[name]; p != nil {
			out = append(out, p)
		}
	}

	return out, nil
}

func addScaLibrPlugin(plugins map[string]scalibrfilesystem.Extractor, name string, cfg *cpb.PluginConfig) error {
	if plugins[name] != nil {
		return nil
	}

	var (
		p   scalibrfilesystem.Extractor
		err error
	)
	switch name {
	case dpkg.Name:
		p, err = dpkg.New(cfg)
	case rpm.Name:
		p, err = rpm.New(cfg)
	case apk.Name:
		p, err = apk.New(cfg)
	default:
		return fmt.Errorf("%w: %q", errUnsupportedScaLibrPlugin, name)
	}
	if err != nil {
		return err
	}
	plugins[name] = p

	return nil
}

func filterExtractorsByCapabilities(
	extractors []scalibrfilesystem.Extractor,
	capabilities *plugin.Capabilities,
) []scalibrfilesystem.Extractor {
	if capabilities == nil {
		return extractors
	}
	out := make([]scalibrfilesystem.Extractor, 0, len(extractors))
	for _, extractor := range extractors {
		if extractor == nil {
			continue
		}
		if err := plugin.ValidateRequirements(extractor, capabilities); err == nil {
			out = append(out, extractor)
		}
	}

	return out
}

func scannerFindings(cfg Config, inv scalibrinventory.Inventory, parentScanID string) []addon.ScannerFinding {
	findings := make([]addon.ScannerFinding, 0, len(inv.PackageVulns)+len(inv.GenericFindings))
	target := addon.ScannerTarget{Type: "host", AgentID: cfg.AgentID, Name: cfg.AgentID}

	for _, vuln := range inv.PackageVulns {
		if vuln == nil || vuln.Vulnerability == nil {
			continue
		}
		pkgEvidence := map[string]any{}
		if vuln.Package != nil {
			pkgEvidence["package_name"] = vuln.Package.Name
			pkgEvidence["installed_version"] = vuln.Package.Version
			if purl := vuln.Package.PURL(); purl != nil {
				pkgEvidence["purl"] = purl.String()
			}
			pkgEvidence["plugins"] = append([]string(nil), vuln.Package.Plugins...)
		}
		findings = append(findings, addon.ScannerFinding{
			SchemaVersion:   addon.ScannerContractVersion,
			FindingID:       newFindingID(parentScanID, vuln.Vulnerability.GetId(), pkgEvidence),
			ParentScanID:    parentScanID,
			ProducerID:      ProducerID,
			ProducerVersion: ProducerVersion,
			OCSFClassUID:    2002,
			Title:           firstNonEmpty(vuln.Vulnerability.GetSummary(), vuln.Vulnerability.GetId()),
			Description:     vuln.Vulnerability.GetDetails(),
			Severity:        osvSeverity(vuln.Vulnerability.GetSeverity()),
			Status:          "open",
			Target:          target,
			Evidence: map[string]any{
				"advisory_id": vuln.Vulnerability.GetId(),
				"aliases":     append([]string(nil), vuln.Vulnerability.GetAliases()...),
				"package":     pkgEvidence,
				"plugins":     append([]string(nil), vuln.Plugins...),
			},
			References: osvReferences(vuln.Vulnerability.GetReferences()),
		})
	}

	for _, finding := range inv.GenericFindings {
		if finding == nil || finding.Adv == nil || finding.Adv.ID == nil {
			continue
		}
		id := firstNonEmpty(finding.Adv.ID.Reference, finding.Adv.ID.Publisher)
		findings = append(findings, addon.ScannerFinding{
			SchemaVersion:   addon.ScannerContractVersion,
			FindingID:       newFindingID(parentScanID, id, nil),
			ParentScanID:    parentScanID,
			ProducerID:      ProducerID,
			ProducerVersion: ProducerVersion,
			OCSFClassUID:    2004,
			Title:           firstNonEmpty(finding.Adv.Title, id),
			Description:     finding.Adv.Description,
			Severity:        genericSeverity(finding.Adv.Sev),
			Status:          "open",
			Target:          target,
			Evidence: map[string]any{
				"advisory_id": id,
				"publisher":   finding.Adv.ID.Publisher,
				"target":      genericTargetExtra(finding),
				"plugins":     append([]string(nil), finding.Plugins...),
			},
			Remediation: map[string]any{
				"recommendation": finding.Adv.Recommendation,
			},
		})
	}

	return findings
}

func scanState(status *plugin.ScanStatus, diagnostics []endpointinventory.SourceSummary, packageCount int) (string, string) {
	if status == nil {
		if hasDiagnosticFailure(diagnostics) {
			return scanStatePartial, coveragePartial
		}
		if packageCount > 0 && allDiagnosticsSucceeded(diagnostics) {
			return scanStateScanned, coverageComplete
		}
		if packageCount > 0 {
			return scanStatePartial, coveragePartial
		}
		return scanStateNotScanned, coverageUnknown
	}

	switch status.Status {
	case plugin.ScanStatusSucceeded:
		return scanStateScanned, coverageComplete
	case plugin.ScanStatusPartiallySucceeded:
		return scanStatePartial, coveragePartial
	case plugin.ScanStatusFailed:
		if packageCount > 0 {
			return scanStatePartial, coveragePartial
		}
		return scanStateFailed, coverageFailed
	case plugin.ScanStatusUnspecified:
		fallthrough
	default:
		if hasDiagnosticFailure(diagnostics) {
			return scanStatePartial, coveragePartial
		}
		return scanStateNotScanned, coverageUnknown
	}
}

func pluginState(state plugin.ScanStatusEnum) string {
	switch state {
	case plugin.ScanStatusSucceeded:
		return scanStateScanned
	case plugin.ScanStatusPartiallySucceeded:
		return sourceStatePartial
	case plugin.ScanStatusFailed:
		return sourceStateError
	case plugin.ScanStatusUnspecified:
		return sourceStateUnknown
	default:
		return sourceStateUnknown
	}
}

func scannerState(state string) string {
	switch state {
	case scanStateScanned, "unchanged":
		return addon.ScannerStateSucceeded
	case scanStateFailed:
		return addon.ScannerStateFailed
	case scanStatePartial:
		return addon.ScannerStatePartial
	default:
		return addon.ScannerStateSkipped
	}
}

func scannerCoverage(coverage string) string {
	switch coverage {
	case coverageComplete:
		return addon.ScannerCoverageComplete
	case coveragePartial:
		return addon.ScannerCoveragePartial
	case coverageFailed:
		return addon.ScannerCoverageFailed
	case "disabled", scanStateNotScanned, coverageUnknown:
		return addon.ScannerCoverageNotScanned
	default:
		return coverage
	}
}

func scannerDiagnostics(summaries []endpointinventory.SourceSummary) []addon.ScannerSourceDiagnostic {
	diagnostics := make([]addon.ScannerSourceDiagnostic, 0, len(summaries))
	for _, summary := range summaries {
		diagnostics = append(diagnostics, addon.ScannerSourceDiagnostic{
			Name:           firstNonEmpty(summary.Name, summary.Source),
			Type:           firstNonEmpty(summary.Type, "scanner_plugin"),
			State:          scannerStateFromDiagnostic(summary.State),
			Detected:       summary.Detected,
			PackageCount:   summary.PackageCount,
			FindingCount:   summary.FindingCount,
			Reason:         summary.Reason,
			Error:          summary.Error,
			Path:           summary.Path,
			DurationMillis: summary.DurationMillis,
			Truncated:      summary.Truncated,
		})
	}

	return diagnostics
}

func scannerStateFromDiagnostic(state string) string {
	switch state {
	case scanStateScanned:
		return addon.ScannerStateSucceeded
	case coveragePartial:
		return addon.ScannerStatePartial
	case sourceStateError:
		return addon.ScannerStateFailed
	case sourceStateSkipped, "unavailable":
		return addon.ScannerStateSkipped
	default:
		return state
	}
}

func packageManager(plugins []string, purlType string) string {
	for _, pluginName := range plugins {
		if strings.HasPrefix(pluginName, "os/") {
			return strings.TrimPrefix(pluginName, "os/")
		}
	}
	return firstNonEmpty(strings.TrimSpace(purlType), "scalibr")
}

func metadataArchitecture(metadata any) string {
	switch value := metadata.(type) {
	case *dpkgmeta.Metadata:
		return value.Architecture
	case *rpmmeta.Metadata:
		return value.Architecture
	case *apkmeta.Metadata:
		return value.Architecture
	default:
		return exportedStringField(metadata, "Architecture")
	}
}

func exportedStringField(value any, field string) string {
	if value == nil {
		return ""
	}
	rv := reflect.ValueOf(value)
	if rv.Kind() == reflect.Pointer {
		if rv.IsNil() {
			return ""
		}
		rv = rv.Elem()
	}
	if rv.Kind() != reflect.Struct {
		return ""
	}
	fieldValue := rv.FieldByName(field)
	if !fieldValue.IsValid() || fieldValue.Kind() != reflect.String {
		return ""
	}

	return fieldValue.String()
}

func detectedPlugins(diagnostics []endpointinventory.SourceSummary) []string {
	detected := make([]string, 0, len(diagnostics))
	for _, diagnostic := range diagnostics {
		if diagnostic.Detected || diagnostic.State == scanStateScanned || diagnostic.State == coveragePartial {
			detected = append(detected, firstNonEmpty(diagnostic.Name, diagnostic.Source))
		}
	}
	sort.Strings(detected)

	return detected
}

func diagnosticsTruncated(diagnostics []endpointinventory.SourceSummary) bool {
	for _, diagnostic := range diagnostics {
		if diagnostic.Truncated {
			return true
		}
	}

	return false
}

func allPluginStatusesSucceeded(statuses []*plugin.Status) bool {
	if len(statuses) == 0 {
		return false
	}

	for _, status := range statuses {
		if status == nil || status.Status == nil {
			return false
		}
		if status.Status.Status != plugin.ScanStatusSucceeded ||
			status.Status.FailureReason != "" ||
			len(status.Status.FileErrors) > 0 {
			return false
		}
	}

	return true
}

func hasDiagnosticFailure(diagnostics []endpointinventory.SourceSummary) bool {
	for _, diagnostic := range diagnostics {
		if diagnostic.State == sourceStateError || diagnostic.State == coveragePartial {
			return true
		}
	}

	return false
}

func successfulAt(state string, at time.Time) *time.Time {
	if state == scanStateFailed || state == scanStatePartial || state == scanStateNotScanned {
		return nil
	}
	return &at
}

func genericTargetExtra(finding *scalibrinventory.GenericFinding) string {
	if finding == nil || finding.Target == nil {
		return ""
	}
	return finding.Target.Extra
}

func genericSeverity(sev scalibrinventory.SeverityEnum) string {
	switch sev {
	case scalibrinventory.SeverityCritical:
		return "Critical"
	case scalibrinventory.SeverityHigh:
		return "High"
	case scalibrinventory.SeverityMedium:
		return "Medium"
	case scalibrinventory.SeverityLow:
		return "Low"
	case scalibrinventory.SeverityMinimal:
		return "Informational"
	case scalibrinventory.SeverityUnspecified:
		return ""
	default:
		return ""
	}
}

func osvSeverity(severities any) string {
	// The OSV schema can carry CVSS strings in several versions. Keep this
	// conservative here; feed enrichment owns exact scoring later in the pipeline.
	rv := reflect.ValueOf(severities)
	if !rv.IsValid() || rv.Kind() != reflect.Slice || rv.Len() == 0 {
		return ""
	}
	for i := 0; i < rv.Len(); i++ {
		score := strings.ToUpper(methodString(rv.Index(i).Interface(), "GetScore"))
		switch {
		case strings.Contains(score, "CRITICAL"):
			return "Critical"
		case strings.Contains(score, "HIGH"):
			return "High"
		case strings.Contains(score, "MEDIUM"):
			return "Medium"
		case strings.Contains(score, "LOW"):
			return "Low"
		}
	}

	return ""
}

func osvReferences(refs any) []string {
	rv := reflect.ValueOf(refs)
	if !rv.IsValid() || rv.Kind() != reflect.Slice {
		return nil
	}
	out := make([]string, 0, rv.Len())
	for i := 0; i < rv.Len(); i++ {
		url := strings.TrimSpace(methodString(rv.Index(i).Interface(), "GetUrl"))
		if url == "" {
			continue
		}
		out = append(out, url)
	}

	return out
}

func methodString(value any, name string) string {
	if value == nil {
		return ""
	}
	method := reflect.ValueOf(value).MethodByName(name)
	if !method.IsValid() || method.Type().NumIn() != 0 || method.Type().NumOut() != 1 {
		return ""
	}
	out := method.Call(nil)
	if len(out) != 1 || out[0].Kind() != reflect.String {
		return ""
	}

	return out[0].String()
}

func firstTime(values ...time.Time) time.Time {
	for _, value := range values {
		if !value.IsZero() {
			return value.UTC()
		}
	}

	return time.Now().UTC()
}

func computeConfigHash(cfg Config) string {
	data, err := json.Marshal(struct {
		ScannerID         string   `json:"scanner_id"`
		ScannerVersion    string   `json:"scanner_version"`
		Plugins           []string `json:"scalibr_plugins"`
		ScanRoots         []string `json:"scan_roots"`
		PathsToExtract    []string `json:"paths_to_extract"`
		DirsToSkip        []string `json:"dirs_to_skip"`
		NetworkOnline     bool     `json:"network_online"`
		ReadSymlinks      bool     `json:"read_symlinks"`
		MaxFileSize       int      `json:"max_file_size"`
		MaxInodes         int      `json:"max_inodes"`
		Sources           []string `json:"sources"`
		DpkgStatusPath    string   `json:"dpkg_status_path"`
		APKInstalledPath  string   `json:"apk_installed_path"`
		RPMDatabasePaths  []string `json:"rpm_database_paths"`
		ScanTimeout       string   `json:"scan_timeout"`
		CollectPaths      bool     `json:"collect_paths"`
		CollectFileHashes bool     `json:"collect_file_hashes"`
		MaxPackages       int      `json:"max_packages"`
		MaxOutputBytes    int64    `json:"max_output_bytes"`
	}{
		ScannerID:         cfg.ScannerID,
		ScannerVersion:    cfg.ScannerVersion,
		Plugins:           append([]string(nil), cfg.ScaLibrPlugins...),
		ScanRoots:         append([]string(nil), cfg.ScanRoots...),
		PathsToExtract:    append([]string(nil), cfg.PathsToExtract...),
		DirsToSkip:        append([]string(nil), cfg.DirsToSkip...),
		NetworkOnline:     cfg.NetworkOnline,
		ReadSymlinks:      cfg.ReadSymlinks,
		MaxFileSize:       cfg.MaxFileSize,
		MaxInodes:         cfg.MaxInodes,
		Sources:           append([]string(nil), cfg.Sources...),
		DpkgStatusPath:    cfg.DpkgStatusPath,
		APKInstalledPath:  cfg.APKInstalledPath,
		RPMDatabasePaths:  append([]string(nil), cfg.RPMDatabasePaths...),
		ScanTimeout:       cfg.ScanTimeout,
		CollectPaths:      cfg.CollectPaths,
		CollectFileHashes: cfg.CollectFileHashes,
		MaxPackages:       cfg.MaxPackages,
		MaxOutputBytes:    cfg.MaxOutputBytes,
	})
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)

	return hex.EncodeToString(sum[:])
}

func newScanID(started time.Time, agentID string, configHash string) string {
	return "scan-" + stableHash(started.Format(time.RFC3339Nano), agentID, configHash)
}

func newFindingID(parentScanID string, nativeID string, evidence any) string {
	encoded, _ := json.Marshal(evidence)
	return "finding-" + stableHash(parentScanID, nativeID, string(encoded))
}

func stableHash(values ...string) string {
	hash := sha256.New()
	for _, value := range values {
		hash.Write([]byte(value))
		hash.Write([]byte{0})
	}

	return hex.EncodeToString(hash.Sum(nil))[:32]
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}

	return ""
}

func cloneStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	return append([]string(nil), values...)
}

func IsScanFailed(payload *endpointinventory.ScanPayload) bool {
	return payload != nil && (payload.State == scanStateFailed || payload.State == scanStatePartial)
}

func ScanFailedError() error {
	return errScaLibrScanFailed
}
