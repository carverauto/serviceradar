/*
 * Copyright 2025 Carver Automation Corporation.
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

// Package endpointinventory contains the local software inventory collector
// contract used by the ServiceRadar agent and endpoint inventory add-on.
package endpointinventory

import "time"

const (
	SchemaVersion = "serviceradar.endpoint_inventory.scan.v1"
	CacheVersion  = "serviceradar.endpoint_inventory.cache.v1"
	ServiceName   = "endpoint_inventory"
	ServiceType   = "endpoint_inventory"
	SourceResults = "results"

	CycloneDXFormat      = "CycloneDX"
	CycloneDXSpecVersion = "1.6"

	HashAlgorithmVersion  = byte(1)
	HashAlgorithm         = "sha256-v1"
	UploadReasonChanged   = "changed"
	UploadReasonUnchanged = "unchanged"

	CommandTypeCacheQuery     = "endpoint_inventory.cache_query"
	CommandTypeForceFreshScan = "endpoint_inventory.force_fresh_scan"
)

type Config struct {
	Enabled                bool     `json:"enabled"`
	AgentID                string   `json:"agent_id"`
	ProfilePath            string   `json:"profile_path"`
	SpoolDir               string   `json:"spool_dir"`
	CacheDir               string   `json:"cache_dir"`
	TmpDir                 string   `json:"tmp_dir"`
	ScanTimeout            string   `json:"scan_timeout"`
	OSReleasePath          string   `json:"os_release_path"`
	DpkgStatusPath         string   `json:"dpkg_status_path"`
	APKInstalledPath       string   `json:"apk_installed_path"`
	RPMPath                string   `json:"rpm_path"`
	RPMDatabasePaths       []string `json:"rpm_database_paths"`
	Sources                []string `json:"sources"`
	ForceFreshEnabled      bool     `json:"force_fresh_enabled"`
	ForceFullScanInterval  int      `json:"force_full_scan_interval"`
	UploadJitter           string   `json:"upload_jitter"`
	UploadRetryInitial     string   `json:"upload_retry_initial"`
	UploadRetryMax         string   `json:"upload_retry_max"`
	UploadRetryMaxAttempts int      `json:"upload_retry_max_attempts"`
	CacheStaleThreshold    string   `json:"cache_stale_threshold"`
	MaxPackages            int      `json:"max_packages"`
	MaxOutputBytes         int64    `json:"max_output_bytes"`
}

type RuntimeProfile struct {
	Enabled                *bool    `json:"enabled,omitempty"`
	AgentID                string   `json:"agent_id,omitempty"`
	ScanTimeout            string   `json:"scan_timeout,omitempty"`
	Sources                []string `json:"sources,omitempty"`
	ForceFreshEnabled      *bool    `json:"force_fresh_enabled,omitempty"`
	ForceFullScanInterval  *int     `json:"force_full_scan_interval,omitempty"`
	UploadJitter           string   `json:"upload_jitter,omitempty"`
	UploadRetryInitial     string   `json:"upload_retry_initial,omitempty"`
	UploadRetryMax         string   `json:"upload_retry_max,omitempty"`
	UploadRetryMaxAttempts *int     `json:"upload_retry_max_attempts,omitempty"`
	CacheStaleThreshold    string   `json:"cache_stale_threshold,omitempty"`
	MaxPackages            *int     `json:"max_packages,omitempty"`
	MaxOutputBytes         *int64   `json:"max_output_bytes,omitempty"`
}

type ScanPayload struct {
	SchemaVersion        string          `json:"schema_version"`
	AgentID              string          `json:"agent_id"`
	ScanID               string          `json:"scan_id"`
	CollectorVersion     string          `json:"collector_version,omitempty"`
	State                string          `json:"state"`
	CoverageState        string          `json:"coverage_state"`
	LastScanAt           time.Time       `json:"last_scan_at"`
	LastSuccessfulScanAt *time.Time      `json:"last_successful_scan_at,omitempty"`
	OS                   OSInfo          `json:"os,omitempty"`
	Sources              []SourceSummary `json:"sources"`
	PackageCount         int             `json:"package_count"`
	PackageSetHash       string          `json:"package_set_hash,omitempty"`
	ArtifactHash         string          `json:"artifact_hash,omitempty"`
	HashAlgorithm        string          `json:"hash_algorithm,omitempty"`
	UploadReason         string          `json:"upload_reason,omitempty"`
	SBOM                 *CycloneDXBOM   `json:"sbom,omitempty"`
	Metadata             map[string]any  `json:"metadata,omitempty"`
}

type InventoryCacheManifest struct {
	SchemaVersion              string                 `json:"schema_version"`
	AgentID                    string                 `json:"agent_id"`
	PackageSetHash             string                 `json:"package_set_hash,omitempty"`
	ArtifactHash               string                 `json:"artifact_hash,omitempty"`
	LastUploadedPackageSetHash string                 `json:"last_uploaded_package_set_hash,omitempty"`
	LastUploadedArtifactHash   string                 `json:"last_uploaded_artifact_hash,omitempty"`
	HashAlgorithm              string                 `json:"hash_algorithm,omitempty"`
	PackageCount               int                    `json:"package_count"`
	Packages                   []Package              `json:"packages"`
	SourceSummaries            []SourceSummary        `json:"source_summaries"`
	SourceMTimes               map[string]SourceMTime `json:"source_mtimes"`
	LastScanAt                 time.Time              `json:"last_scan_at"`
	LastSuccessfulScanAt       *time.Time             `json:"last_successful_scan_at,omitempty"`
	LastChangedScanAt          *time.Time             `json:"last_changed_scan_at,omitempty"`
	ScansSinceFull             int                    `json:"scans_since_full"`
	UnchangedScanCount         int                    `json:"unchanged_scan_count"`
	FullScanCount              int                    `json:"full_scan_count"`
	PendingUpload              *PendingUploadState    `json:"pending_upload,omitempty"`
	UpdatedAt                  time.Time              `json:"updated_at"`
}

type PendingUploadState struct {
	ScanID         string     `json:"scan_id"`
	PackageSetHash string     `json:"package_set_hash"`
	ArtifactHash   string     `json:"artifact_hash"`
	UploadReason   string     `json:"upload_reason"`
	AvailableAfter time.Time  `json:"available_after"`
	NextAttemptAt  *time.Time `json:"next_attempt_at,omitempty"`
	Attempts       int        `json:"attempts"`
	Exhausted      bool       `json:"exhausted,omitempty"`
	LastAttemptAt  *time.Time `json:"last_attempt_at,omitempty"`
	LastError      string     `json:"last_error,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
}

type SourceMTime struct {
	Source        string `json:"source"`
	Path          string `json:"path,omitempty"`
	Exists        bool   `json:"exists"`
	MTimeUnixNano int64  `json:"mtime_unix_nano,omitempty"`
	Size          int64  `json:"size,omitempty"`
}

type OSInfo struct {
	Name       string `json:"name,omitempty"`
	ID         string `json:"id,omitempty"`
	Version    string `json:"version,omitempty"`
	VersionID  string `json:"version_id,omitempty"`
	PrettyName string `json:"pretty_name,omitempty"`
}

type SourceSummary struct {
	Source       string `json:"source"`
	State        string `json:"state"`
	PackageCount int    `json:"package_count"`
	Error        string `json:"error,omitempty"`
}

type Package struct {
	Name      string   `json:"name"`
	Version   string   `json:"version,omitempty"`
	Arch      string   `json:"architecture,omitempty"`
	Manager   string   `json:"manager"`
	Ecosystem string   `json:"ecosystem,omitempty"`
	PURL      string   `json:"purl,omitempty"`
	CPEs      []string `json:"cpes,omitempty"`
}

type CycloneDXBOM struct {
	BOMFormat    string               `json:"bomFormat"`
	SpecVersion  string               `json:"specVersion"`
	SerialNumber string               `json:"serialNumber,omitempty"`
	Version      int                  `json:"version"`
	Metadata     CycloneDXMetadata    `json:"metadata,omitempty"`
	Components   []CycloneDXComponent `json:"components,omitempty"`
	Properties   []CycloneDXProperty  `json:"properties,omitempty"`
}

type CycloneDXMetadata struct {
	Timestamp  time.Time           `json:"timestamp,omitempty"`
	Tools      []CycloneDXTool     `json:"tools,omitempty"`
	Component  *CycloneDXComponent `json:"component,omitempty"`
	Properties []CycloneDXProperty `json:"properties,omitempty"`
}

type CycloneDXTool struct {
	Vendor  string `json:"vendor,omitempty"`
	Name    string `json:"name"`
	Version string `json:"version,omitempty"`
}

type CycloneDXComponent struct {
	Type       string              `json:"type"`
	Name       string              `json:"name"`
	Version    string              `json:"version,omitempty"`
	Group      string              `json:"group,omitempty"`
	PURL       string              `json:"purl,omitempty"`
	CPE        string              `json:"cpe,omitempty"`
	Properties []CycloneDXProperty `json:"properties,omitempty"`
}

type CycloneDXProperty struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}
