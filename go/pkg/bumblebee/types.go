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

// Package bumblebee contains the local root scanner wrapper contract used by
// the ServiceRadar agent and the root-owned Bumblebee systemd timer.
package bumblebee

import "time"

const (
	SchemaVersion = "serviceradar.bumblebee.scan.v1"
	ServiceName   = "bumblebee_exposure"
	ServiceType   = "bumblebee"
	SourceResults = "results"
)

type Config struct {
	Enabled            bool     `json:"enabled"`
	AgentID            string   `json:"agent_id"`
	DeviceUID          string   `json:"device_uid,omitempty"`
	CatalogPath        string   `json:"catalog_path"`
	CatalogSnapshotRef string   `json:"catalog_snapshot_ref"`
	ProfilePath        string   `json:"profile_path"`
	SpoolDir           string   `json:"spool_dir"`
	TmpDir             string   `json:"tmp_dir"`
	PasswdPath         string   `json:"passwd_path"`
	ScanTimeout        string   `json:"scan_timeout"`
	IncludeHomeRoots   bool     `json:"include_home_roots"`
	IncludeRoot        bool     `json:"include_root"`
	ExplicitRoots      []string `json:"explicit_roots"`
	ExcludeRoots       []string `json:"exclude_roots"`
	Ecosystems         []string `json:"ecosystems"`
	MaxFindings        int      `json:"max_findings"`
	MaxOutputBytes     int64    `json:"max_output_bytes"`
}

type ScanPayload struct {
	SchemaVersion        string         `json:"schema_version"`
	AgentID              string         `json:"agent_id"`
	DeviceUID            string         `json:"device_uid,omitempty"`
	RunID                string         `json:"run_id"`
	ScannerVersion       string         `json:"scanner_version,omitempty"`
	CatalogSnapshotRef   string         `json:"catalog_snapshot_ref,omitempty"`
	State                string         `json:"state"`
	CoverageState        string         `json:"coverage_state"`
	AttemptedRootCount   int            `json:"attempted_root_count"`
	ScannedRootCount     int            `json:"scanned_root_count"`
	SkippedRootCount     int            `json:"skipped_root_count"`
	RootCovered          bool           `json:"root_covered"`
	AttemptedRoots       []string       `json:"attempted_roots,omitempty"`
	ScannedRoots         []string       `json:"scanned_roots,omitempty"`
	SkippedRoots         []SkippedRoot  `json:"skipped_roots,omitempty"`
	LastScanAt           time.Time      `json:"last_scan_at"`
	LastSuccessfulScanAt *time.Time     `json:"last_successful_scan_at,omitempty"`
	Findings             []Finding      `json:"findings"`
	Metadata             map[string]any `json:"metadata,omitempty"`
}

type SkippedRoot struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

type Finding struct {
	ID             string         `json:"id,omitempty"`
	FindingID      string         `json:"finding_id,omitempty"`
	CatalogID      string         `json:"catalog_id,omitempty"`
	Severity       string         `json:"severity,omitempty"`
	RiskScore      int            `json:"risk_score,omitempty"`
	Ecosystem      string         `json:"ecosystem,omitempty"`
	PackageName    string         `json:"package_name,omitempty"`
	PackageVersion string         `json:"package_version,omitempty"`
	Evidence       map[string]any `json:"evidence,omitempty"`
	Confidence     string         `json:"confidence,omitempty"`
	Metadata       map[string]any `json:"metadata,omitempty"`
}

type RootCandidate struct {
	Path   string
	Source string
}

type RuntimeProfile struct {
	Enabled            *bool    `json:"enabled,omitempty"`
	AgentID            string   `json:"agent_id,omitempty"`
	DeviceUID          string   `json:"device_uid,omitempty"`
	CatalogSnapshotRef string   `json:"catalog_snapshot_ref,omitempty"`
	ScanTimeout        string   `json:"scan_timeout,omitempty"`
	IncludeHomeRoots   *bool    `json:"include_home_roots,omitempty"`
	IncludeRoot        *bool    `json:"include_root,omitempty"`
	ExplicitRoots      []string `json:"explicit_roots,omitempty"`
	ExcludeRoots       []string `json:"exclude_roots,omitempty"`
	Ecosystems         []string `json:"ecosystems,omitempty"`
	MaxFindings        *int     `json:"max_findings,omitempty"`
	MaxOutputBytes     *int64   `json:"max_output_bytes,omitempty"`
}
