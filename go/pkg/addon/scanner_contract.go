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

import "time"

const (
	// CapabilityScannerV1 marks add-ons that emit scanner contracts. The
	// scanner implementation is intentionally not part of the capability name.
	CapabilityScannerV1 = "scanner:v1"

	ScannerContractVersion = "serviceradar.scanner.contract.v1"

	ScannerSignalScanActivity      = "scan_activity"
	ScannerSignalFinding           = "finding"
	ScannerSignalInventoryArtifact = "inventory_artifact"

	ScannerStateSucceeded = "succeeded"
	ScannerStatePartial   = "partial"
	ScannerStateFailed    = "failed"
	ScannerStateSkipped   = "skipped"

	ScannerCoverageComplete    = "complete"
	ScannerCoveragePartial     = "partial"
	ScannerCoverageFailed      = "failed"
	ScannerCoverageNotScanned  = "not_scanned"
	ScannerCoverageUnsupported = "unsupported"
)

// ScannerTarget identifies what a scanner add-on examined. It is deliberately
// broad enough for hosts, devices, workloads, images, file systems, and future
// scanner target types.
type ScannerTarget struct {
	Type        string            `json:"type"`
	ID          string            `json:"id,omitempty"`
	Name        string            `json:"name,omitempty"`
	DeviceUID   string            `json:"device_uid,omitempty"`
	AgentID     string            `json:"agent_id,omitempty"`
	Namespace   string            `json:"namespace,omitempty"`
	Image       string            `json:"image,omitempty"`
	Annotations map[string]string `json:"annotations,omitempty"`
}

// ScannerSourceDiagnostic describes one scanner source, plugin, extractor, or
// detector execution. Add-ons should use stable reason codes and keep
// implementation-specific detail in Metadata.
type ScannerSourceDiagnostic struct {
	Name           string         `json:"name"`
	Type           string         `json:"type,omitempty"`
	State          string         `json:"state"`
	Detected       bool           `json:"detected,omitempty"`
	PackageCount   int            `json:"package_count,omitempty"`
	FindingCount   int            `json:"finding_count,omitempty"`
	Reason         string         `json:"reason,omitempty"`
	Error          string         `json:"error,omitempty"`
	Path           string         `json:"path,omitempty"`
	DurationMillis int64          `json:"duration_ms,omitempty"`
	Truncated      bool           `json:"truncated,omitempty"`
	Metadata       map[string]any `json:"metadata,omitempty"`
}

// ScannerInventoryArtifact references an inventory or SBOM artifact submitted
// through the normal ServiceRadar artifact path.
type ScannerInventoryArtifact struct {
	Kind      string            `json:"kind"`
	Format    string            `json:"format"`
	Version   string            `json:"version,omitempty"`
	MediaType string            `json:"media_type,omitempty"`
	ObjectKey string            `json:"object_key,omitempty"`
	SHA256    string            `json:"sha256,omitempty"`
	SizeBytes int64             `json:"size_bytes,omitempty"`
	Metadata  map[string]string `json:"metadata,omitempty"`
}

// ScannerScanActivity is the scanner-agnostic scan lifecycle payload. It maps
// onto OCSF Scan Activity during ingestion without naming a specific scanner.
type ScannerScanActivity struct {
	SchemaVersion   string                     `json:"schema_version"`
	ScanID          string                     `json:"scan_id"`
	ProducerID      string                     `json:"producer_id"`
	ProducerVersion string                     `json:"producer_version,omitempty"`
	ScannerID       string                     `json:"scanner_id,omitempty"`
	ScannerVersion  string                     `json:"scanner_version,omitempty"`
	Target          ScannerTarget              `json:"target"`
	State           string                     `json:"state"`
	CoverageState   string                     `json:"coverage_state"`
	StartedAt       time.Time                  `json:"started_at,omitempty"`
	EndedAt         time.Time                  `json:"ended_at,omitempty"`
	ConfigHash      string                     `json:"config_hash,omitempty"`
	Diagnostics     []ScannerSourceDiagnostic  `json:"diagnostics,omitempty"`
	Artifacts       []ScannerInventoryArtifact `json:"artifacts,omitempty"`
	Metadata        map[string]any             `json:"metadata,omitempty"`
}

// ScannerFinding is the scanner-agnostic finding payload. Add-ons set the OCSF
// class/type identifiers they map to and provide normalized evidence.
type ScannerFinding struct {
	SchemaVersion   string         `json:"schema_version"`
	FindingID       string         `json:"finding_id"`
	ParentScanID    string         `json:"parent_scan_id,omitempty"`
	ProducerID      string         `json:"producer_id"`
	ProducerVersion string         `json:"producer_version,omitempty"`
	OCSFClassUID    int            `json:"ocsf_class_uid,omitempty"`
	OCSFTypeUID     int            `json:"ocsf_type_uid,omitempty"`
	Title           string         `json:"title"`
	Description     string         `json:"description,omitempty"`
	Severity        string         `json:"severity,omitempty"`
	Status          string         `json:"status,omitempty"`
	Target          ScannerTarget  `json:"target"`
	Evidence        map[string]any `json:"evidence,omitempty"`
	Remediation     map[string]any `json:"remediation,omitempty"`
	References      []string       `json:"references,omitempty"`
	Metadata        map[string]any `json:"metadata,omitempty"`
}
