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
	SchemaVersion                     = "serviceradar.endpoint_inventory.scan.v1"
	CacheVersion                      = "serviceradar.endpoint_inventory.cache.v1"
	ServiceName                       = "endpoint_inventory"
	ServiceType                       = "endpoint_inventory"
	SourceResults                     = "results"
	StandingQuestionResultCountSchema = "serviceradar.endpoint_inventory.standing_question_result_count.v1"

	CycloneDXFormat      = "CycloneDX"
	CycloneDXSpecVersion = "1.6"

	HashAlgorithmVersion  = byte(1)
	HashAlgorithm         = "sha256-v1"
	UploadReasonChanged   = "changed"
	UploadReasonUnchanged = "unchanged"

	CommandTypeCacheQuery     = "endpoint_inventory.cache_query"
	CommandTypeForceFreshScan = "endpoint_inventory.force_fresh_scan"

	// MaxSpoolPayloadBytes is the largest endpoint-inventory payload the agent
	// status transport accepts. Producers must not be configured to emit a
	// larger payload than the consumer can read.
	MaxSpoolPayloadBytes int64 = 32 * 1024 * 1024
)

// CacheIdentity binds cached inventory to the producer configuration that
// created it. All fields are required for cache reuse.
type CacheIdentity struct {
	AgentID         string `json:"agent_id"`
	ConfigHash      string `json:"config_hash"`
	ProducerID      string `json:"producer_id"`
	ProducerVersion string `json:"producer_version"`
}

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
	Cadence                string   `json:"cadence"`
	CollectPaths           bool     `json:"collect_paths"`
	CollectFileHashes      bool     `json:"collect_file_hashes"`
	ForceFreshEnabled      bool     `json:"force_fresh_enabled"`
	ForceFullScanInterval  int      `json:"force_full_scan_interval"`
	UploadJitter           string   `json:"upload_jitter"`
	UploadRetryInitial     string   `json:"upload_retry_initial"`
	UploadRetryMax         string   `json:"upload_retry_max"`
	UploadRetryMaxAttempts int      `json:"upload_retry_max_attempts"`
	CacheStaleThreshold    string   `json:"cache_stale_threshold"`
	MaxPackages            int      `json:"max_packages"`
	MaxOutputBytes         int64    `json:"max_output_bytes"`

	// ForceFreshScan, when true, bypasses the cadence floor and source-mtime
	// skip so an explicit operator-triggered force-fresh scan always performs a
	// full collection. It is a runtime-only flag and is never persisted.
	ForceFreshScan bool `json:"-"`
}

type RuntimeProfile struct {
	Enabled                *bool    `json:"enabled,omitempty"`
	AgentID                string   `json:"agent_id,omitempty"`
	ScanTimeout            string   `json:"scan_timeout,omitempty"`
	Sources                []string `json:"sources,omitempty"`
	Cadence                string   `json:"cadence,omitempty"`
	CollectPaths           *bool    `json:"collect_paths,omitempty"`
	CollectFileHashes      *bool    `json:"collect_file_hashes,omitempty"`
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
	SchemaVersion                string                        `json:"schema_version"`
	AgentID                      string                        `json:"agent_id"`
	ScanID                       string                        `json:"scan_id"`
	CollectorVersion             string                        `json:"collector_version,omitempty"`
	State                        string                        `json:"state"`
	CoverageState                string                        `json:"coverage_state"`
	ConfigHash                   string                        `json:"config_hash,omitempty"`
	LastScanAt                   time.Time                     `json:"last_scan_at"`
	LastSuccessfulScanAt         *time.Time                    `json:"last_successful_scan_at,omitempty"`
	OS                           OSInfo                        `json:"os,omitempty"`
	EnabledPlugins               []string                      `json:"enabled_plugins,omitempty"`
	DetectedPlugins              []string                      `json:"detected_plugins,omitempty"`
	Diagnostics                  []SourceSummary               `json:"diagnostics"`
	PackageCount                 int                           `json:"package_count"`
	PackageSetHash               string                        `json:"package_set_hash,omitempty"`
	ArtifactHash                 string                        `json:"artifact_hash,omitempty"`
	HashAlgorithm                string                        `json:"hash_algorithm,omitempty"`
	UploadReason                 string                        `json:"upload_reason,omitempty"`
	DurationMillis               int64                         `json:"duration_ms,omitempty"`
	Truncated                    bool                          `json:"truncated,omitempty"`
	StandingQuestionResultCounts []StandingQuestionResultCount `json:"standing_question_result_counts,omitempty"`
	SBOM                         *CycloneDXBOM                 `json:"sbom,omitempty"`
	// PackageDelta carries the change-only representation of this scan relative
	// to the previously uploaded package set. It is present only on changed
	// uploads that have a known prior state to diff against; core applies it
	// when its current hash matches PackageDelta.BasePackageSetHash and falls
	// back to the full SBOM anchor otherwise. Backward compatible: older cores
	// ignore the field and consume the SBOM anchor.
	PackageDelta *PackageSetDelta `json:"package_delta,omitempty"`
	Metadata     map[string]any   `json:"metadata,omitempty"`
}

type InventoryCacheManifest struct {
	SchemaVersion                string                        `json:"schema_version"`
	AgentID                      string                        `json:"agent_id"`
	ConfigHash                   string                        `json:"config_hash,omitempty"`
	ProducerID                   string                        `json:"producer_id,omitempty"`
	ProducerVersion              string                        `json:"producer_version,omitempty"`
	PackageSetHash               string                        `json:"package_set_hash,omitempty"`
	ArtifactHash                 string                        `json:"artifact_hash,omitempty"`
	LastUploadedPackageSetHash   string                        `json:"last_uploaded_package_set_hash,omitempty"`
	LastUploadedArtifactHash     string                        `json:"last_uploaded_artifact_hash,omitempty"`
	HashAlgorithm                string                        `json:"hash_algorithm,omitempty"`
	PackageCount                 int                           `json:"package_count"`
	Packages                     []Package                     `json:"packages"`
	SourceSummaries              []SourceSummary               `json:"source_summaries"`
	SourceMTimes                 map[string]SourceMTime        `json:"source_mtimes"`
	StandingQuestionResultCounts []StandingQuestionResultCount `json:"standing_question_result_counts,omitempty"`
	LastScanAt                   time.Time                     `json:"last_scan_at"`
	LastSuccessfulScanAt         *time.Time                    `json:"last_successful_scan_at,omitempty"`
	LastFullScanAt               *time.Time                    `json:"last_full_scan_at,omitempty"`
	LastChangedScanAt            *time.Time                    `json:"last_changed_scan_at,omitempty"`
	ScansSinceFull               int                           `json:"scans_since_full"`
	UnchangedScanCount           int                           `json:"unchanged_scan_count"`
	FullScanCount                int                           `json:"full_scan_count"`
	PendingUpload                *PendingUploadState           `json:"pending_upload,omitempty"`
	ServerReconcileRequestedAt   *time.Time                    `json:"server_reconcile_requested_at,omitempty"`
	ServerReconcileReason        string                        `json:"server_reconcile_reason,omitempty"`
	UpdatedAt                    time.Time                     `json:"updated_at"`
}

type StandingQuestionResultCount struct {
	Schema          string            `json:"schema,omitempty"`
	QuestionID      string            `json:"question_id"`
	QuestionVersion string            `json:"question_version,omitempty"`
	PredicateHash   string            `json:"predicate_hash"`
	Mode            string            `json:"mode"`
	Matched         bool              `json:"matched"`
	Count           int               `json:"count"`
	PackageSetHash  string            `json:"package_set_hash,omitempty"`
	HashAlgorithm   string            `json:"hash_algorithm,omitempty"`
	EvaluatedAt     time.Time         `json:"evaluated_at"`
	Freshness       FreshnessVerdict  `json:"freshness,omitempty"`
	Labels          map[string]string `json:"labels,omitempty"`
	Metadata        map[string]string `json:"metadata,omitempty"`
}

type PendingUploadState struct {
	ScanID               string     `json:"scan_id"`
	AgentID              string     `json:"agent_id,omitempty"`
	ConfigHash           string     `json:"config_hash,omitempty"`
	ProducerID           string     `json:"producer_id,omitempty"`
	ProducerVersion      string     `json:"producer_version,omitempty"`
	PackageSetHash       string     `json:"package_set_hash"`
	ArtifactHash         string     `json:"artifact_hash"`
	UploadReason         string     `json:"upload_reason"`
	AvailableAfter       time.Time  `json:"available_after"`
	NextAttemptAt        *time.Time `json:"next_attempt_at,omitempty"`
	Attempts             int        `json:"attempts"`
	Exhausted            bool       `json:"exhausted,omitempty"`
	LastAttemptAt        *time.Time `json:"last_attempt_at,omitempty"`
	LastError            string     `json:"last_error,omitempty"`
	RetryInitial         string     `json:"retry_initial,omitempty"`
	RetryMax             string     `json:"retry_max,omitempty"`
	RetryMaxAttempts     int        `json:"retry_max_attempts,omitempty"`
	ReconcileRequestedAt *time.Time `json:"reconcile_requested_at,omitempty"`
	CreatedAt            time.Time  `json:"created_at"`
	UpdatedAt            time.Time  `json:"updated_at"`
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
	Source         string `json:"-"`
	Name           string `json:"name,omitempty"`
	Type           string `json:"type,omitempty"`
	State          string `json:"state"`
	PackageCount   int    `json:"package_count"`
	FindingCount   int    `json:"finding_count,omitempty"`
	Reason         string `json:"reason,omitempty"`
	Error          string `json:"error,omitempty"`
	Path           string `json:"path,omitempty"`
	Detected       bool   `json:"detected,omitempty"`
	DurationMillis int64  `json:"duration_ms,omitempty"`
	Truncated      bool   `json:"truncated,omitempty"`
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
