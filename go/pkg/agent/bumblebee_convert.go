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

package agent

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

type rawBumblebeeScanPayload struct {
	SchemaVersion        string                `json:"schema_version"`
	AgentID              string                `json:"agent_id"`
	DeviceUID            string                `json:"device_uid"`
	RunID                string                `json:"run_id"`
	ScannerVersion       string                `json:"scanner_version"`
	CatalogSnapshotRef   string                `json:"catalog_snapshot_ref"`
	State                string                `json:"state"`
	CoverageState        string                `json:"coverage_state"`
	AttemptedRootCount   int32                 `json:"attempted_root_count"`
	ScannedRootCount     int32                 `json:"scanned_root_count"`
	SkippedRootCount     int32                 `json:"skipped_root_count"`
	RootCovered          bool                  `json:"root_covered"`
	AttemptedRoots       []string              `json:"attempted_roots"`
	ScannedRoots         []string              `json:"scanned_roots"`
	SkippedRoots         []json.RawMessage     `json:"skipped_roots"`
	LastScanAt           string                `json:"last_scan_at"`
	LastSuccessfulScanAt string                `json:"last_successful_scan_at"`
	Findings             []rawBumblebeeFinding `json:"findings"`
	Metadata             json.RawMessage       `json:"metadata"`
}

type rawBumblebeeFinding struct {
	ID             string          `json:"id"`
	FindingID      string          `json:"finding_id"`
	CatalogID      string          `json:"catalog_id"`
	Severity       string          `json:"severity"`
	RiskScore      *int32          `json:"risk_score"`
	Ecosystem      string          `json:"ecosystem"`
	PackageName    string          `json:"package_name"`
	PackageVersion string          `json:"package_version"`
	Evidence       json.RawMessage `json:"evidence"`
	Confidence     string          `json:"confidence"`
	Metadata       json.RawMessage `json:"metadata"`
}

func bumblebeeScanPayloadFromJSON(raw []byte, agentID string) (*edgev1.BumblebeeScanPayloadV1, error) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil, fmt.Errorf("empty bumblebee scan payload")
	}
	var parsed rawBumblebeeScanPayload
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, err
	}

	resolvedAgentID := strings.TrimSpace(parsed.AgentID)
	if resolvedAgentID == "" {
		resolvedAgentID = strings.TrimSpace(agentID)
	}

	skippedRoots := make([]*edgev1.BumblebeeSkippedRootV1, 0, len(parsed.SkippedRoots))
	for i, rawRoot := range parsed.SkippedRoots {
		root, err := decodeBumblebeeSkippedRoot(rawRoot)
		if err != nil {
			return nil, fmt.Errorf("skipped_roots[%d]: %w", i, err)
		}
		if root != nil {
			skippedRoots = append(skippedRoots, root)
		}
	}

	findings := make([]*edgev1.BumblebeeFindingV1, 0, len(parsed.Findings))
	for _, rawFinding := range parsed.Findings {
		finding := &edgev1.BumblebeeFindingV1{
			Id:             rawFinding.ID,
			FindingId:      rawFinding.FindingID,
			CatalogId:      rawFinding.CatalogID,
			Severity:       rawFinding.Severity,
			Ecosystem:      rawFinding.Ecosystem,
			PackageName:    rawFinding.PackageName,
			PackageVersion: rawFinding.PackageVersion,
			EvidenceJson:   optionalRawJSONBytes(rawFinding.Evidence),
			Confidence:     rawFinding.Confidence,
			MetadataJson:   optionalRawJSONBytes(rawFinding.Metadata),
		}
		if rawFinding.RiskScore != nil {
			finding.RiskScore = *rawFinding.RiskScore
			finding.HasRiskScore = true
		}
		findings = append(findings, finding)
	}

	return &edgev1.BumblebeeScanPayloadV1{
		SchemaVersion:        parsed.SchemaVersion,
		AgentId:              resolvedAgentID,
		DeviceUid:            parsed.DeviceUID,
		RunId:                parsed.RunID,
		ScannerVersion:       parsed.ScannerVersion,
		CatalogSnapshotRef:   parsed.CatalogSnapshotRef,
		State:                parsed.State,
		CoverageState:        parsed.CoverageState,
		AttemptedRootCount:   parsed.AttemptedRootCount,
		ScannedRootCount:     parsed.ScannedRootCount,
		SkippedRootCount:     parsed.SkippedRootCount,
		RootCovered:          parsed.RootCovered,
		AttemptedRoots:       append([]string(nil), parsed.AttemptedRoots...),
		ScannedRoots:         append([]string(nil), parsed.ScannedRoots...),
		SkippedRoots:         skippedRoots,
		LastScanAt:           parsed.LastScanAt,
		LastSuccessfulScanAt: parsed.LastSuccessfulScanAt,
		Findings:             findings,
		MetadataJson:         optionalRawJSONBytes(parsed.Metadata),
	}, nil
}

func decodeBumblebeeSkippedRoot(raw json.RawMessage) (*edgev1.BumblebeeSkippedRootV1, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil, nil
	}
	var pathOnly string
	if err := json.Unmarshal(trimmed, &pathOnly); err == nil {
		return &edgev1.BumblebeeSkippedRootV1{Path: pathOnly}, nil
	}
	var root bumblebee.SkippedRoot
	if err := json.Unmarshal(trimmed, &root); err != nil {
		return nil, err
	}
	return &edgev1.BumblebeeSkippedRootV1{
		Path:   root.Path,
		Reason: root.Reason,
	}, nil
}

func optionalRawJSONBytes(raw json.RawMessage) []byte {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return nil
	}
	return append([]byte(nil), trimmed...)
}
