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
	"encoding/json"
	"fmt"
	"maps"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

type rawEndpointInventoryDiagnosticsEnvelope struct {
	Diagnostics []struct {
		Detected *bool `json:"detected"`
	} `json:"diagnostics"`
}

func convertEndpointInventoryScanPayload(
	raw []byte,
	fallbackAgentID string,
) (*edgev1.EndpointInventoryScanPayloadV1, *endpointinventory.ScanPayload, error) {
	var scan endpointinventory.ScanPayload
	if err := json.Unmarshal(raw, &scan); err != nil {
		return nil, nil, fmt.Errorf("unmarshal endpoint inventory scan payload: %w", err)
	}

	var diagEnvelope rawEndpointInventoryDiagnosticsEnvelope
	_ = json.Unmarshal(raw, &diagEnvelope)

	agentID := strings.TrimSpace(scan.AgentID)
	if agentID == "" {
		agentID = strings.TrimSpace(fallbackAgentID)
	}

	var metadataJSON []byte
	if len(scan.Metadata) > 0 {
		encoded, err := json.Marshal(scan.Metadata)
		if err != nil {
			return nil, &scan, fmt.Errorf("marshal endpoint inventory metadata_json: %w", err)
		}
		metadataJSON = encoded
	}

	protoScan := &edgev1.EndpointInventoryScanPayloadV1{
		SchemaVersion:                scan.SchemaVersion,
		AgentId:                      agentID,
		ScanId:                       scan.ScanID,
		CollectorVersion:             scan.CollectorVersion,
		State:                        scan.State,
		CoverageState:                scan.CoverageState,
		ConfigHash:                   scan.ConfigHash,
		LastScanAt:                   endpointInventoryTimeStr(scan.LastScanAt),
		LastSuccessfulScanAt:         endpointInventoryPtrTimeStr(scan.LastSuccessfulScanAt),
		Os:                           convertEndpointInventoryOSInfo(scan.OS),
		EnabledPlugins:               append([]string(nil), scan.EnabledPlugins...),
		DetectedPlugins:              append([]string(nil), scan.DetectedPlugins...),
		Diagnostics:                  convertEndpointInventoryDiagnostics(scan.Diagnostics, diagEnvelope),
		PackageCount:                 int32(scan.PackageCount),
		PackageSetHash:               scan.PackageSetHash,
		ArtifactHash:                 scan.ArtifactHash,
		HashAlgorithm:                scan.HashAlgorithm,
		UploadReason:                 scan.UploadReason,
		DurationMs:                   scan.DurationMillis,
		Truncated:                    scan.Truncated,
		StandingQuestionResultCounts: convertEndpointInventoryQuestionCounts(scan.StandingQuestionResultCounts),
		Sbom:                         convertEndpointInventorySBOM(scan.SBOM),
		PackageDelta:                 convertEndpointInventoryPackageDelta(scan.PackageDelta),
		MetadataJson:                 metadataJSON,
	}

	return protoScan, &scan, nil
}

func endpointInventoryTimeStr(ts time.Time) string {
	if ts.IsZero() || ts.Year() < 1970 {
		return ""
	}
	return ts.UTC().Format(time.RFC3339Nano)
}

func endpointInventoryPtrTimeStr(ts *time.Time) string {
	if ts == nil {
		return ""
	}
	return endpointInventoryTimeStr(*ts)
}

func convertEndpointInventoryOSInfo(os endpointinventory.OSInfo) *edgev1.EndpointInventoryOSInfoV1 {
	if os.Name == "" && os.ID == "" && os.Version == "" && os.VersionID == "" && os.PrettyName == "" {
		return nil
	}
	return &edgev1.EndpointInventoryOSInfoV1{
		Name:       os.Name,
		Id:         os.ID,
		Version:    os.Version,
		VersionId:  os.VersionID,
		PrettyName: os.PrettyName,
	}
}

func convertEndpointInventoryDiagnostics(
	diags []endpointinventory.SourceSummary,
	rawEnvelope rawEndpointInventoryDiagnosticsEnvelope,
) []*edgev1.EndpointInventorySourceSummaryV1 {
	if len(diags) == 0 {
		return nil
	}
	out := make([]*edgev1.EndpointInventorySourceSummaryV1, 0, len(diags))
	for i, d := range diags {
		hasDetected := d.Detected
		detected := d.Detected
		if i < len(rawEnvelope.Diagnostics) {
			if rawEnvelope.Diagnostics[i].Detected == nil {
				hasDetected = false
				detected = false
			} else {
				hasDetected = true
				detected = *rawEnvelope.Diagnostics[i].Detected
			}
		}
		out = append(out, &edgev1.EndpointInventorySourceSummaryV1{
			Name:         d.Name,
			Type:         d.Type,
			State:        d.State,
			PackageCount: int32(d.PackageCount),
			FindingCount: int32(d.FindingCount),
			Reason:       d.Reason,
			Error:        d.Error,
			Path:         d.Path,
			Detected:     detected,
			HasDetected:  hasDetected,
			DurationMs:   d.DurationMillis,
			Truncated:    d.Truncated,
		})
	}
	return out
}

func convertEndpointInventoryQuestionCounts(
	counts []endpointinventory.StandingQuestionResultCount,
) []*edgev1.EndpointInventoryStandingQuestionResultCountV1 {
	if len(counts) == 0 {
		return nil
	}
	out := make([]*edgev1.EndpointInventoryStandingQuestionResultCountV1, 0, len(counts))
	for _, c := range counts {
		var freshness *edgev1.EndpointInventoryFreshnessVerdictV1
		if c.Freshness.Verdict != "" || c.Freshness.AgeSeconds != 0 ||
			c.Freshness.StaleThresholdSeconds != 0 || c.Freshness.LastSuccessfulScanAt != nil {
			freshness = &edgev1.EndpointInventoryFreshnessVerdictV1{
				Verdict:               c.Freshness.Verdict,
				AgeSeconds:            c.Freshness.AgeSeconds,
				StaleThresholdSeconds: c.Freshness.StaleThresholdSeconds,
				LastSuccessfulScanAt:  endpointInventoryPtrTimeStr(c.Freshness.LastSuccessfulScanAt),
			}
		}
		out = append(out, &edgev1.EndpointInventoryStandingQuestionResultCountV1{
			Schema:          c.Schema,
			QuestionId:      c.QuestionID,
			QuestionVersion: c.QuestionVersion,
			PredicateHash:   c.PredicateHash,
			Mode:            c.Mode,
			Matched:         c.Matched,
			Count:           int32(c.Count),
			PackageSetHash:  c.PackageSetHash,
			HashAlgorithm:   c.HashAlgorithm,
			EvaluatedAt:     endpointInventoryTimeStr(c.EvaluatedAt),
			Freshness:       freshness,
			Labels:          cloneEndpointInventoryStringMap(c.Labels),
			Metadata:        cloneEndpointInventoryStringMap(c.Metadata),
		})
	}
	return out
}

func cloneEndpointInventoryStringMap(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	maps.Copy(out, in)
	return out
}

func convertEndpointInventorySBOM(
	sbom *endpointinventory.CycloneDXBOM,
) *edgev1.EndpointInventoryCycloneDXBOMV1 {
	if sbom == nil {
		return nil
	}
	out := &edgev1.EndpointInventoryCycloneDXBOMV1{
		BomFormat:    sbom.BOMFormat,
		SpecVersion:  sbom.SpecVersion,
		SerialNumber: sbom.SerialNumber,
		Version:      int32(sbom.Version),
		Metadata:     convertEndpointInventorySBOMMetadata(sbom.Metadata),
		Properties:   convertEndpointInventorySBOMProperties(sbom.Properties),
	}
	for _, comp := range sbom.Components {
		out.Components = append(out.Components, convertEndpointInventorySBOMComponent(comp))
	}
	return out
}

func convertEndpointInventorySBOMMetadata(
	meta endpointinventory.CycloneDXMetadata,
) *edgev1.EndpointInventoryCycloneDXMetadataV1 {
	ts := endpointInventoryTimeStr(meta.Timestamp)
	if ts == "" && len(meta.Tools) == 0 && meta.Component == nil && len(meta.Properties) == 0 {
		return nil
	}
	out := &edgev1.EndpointInventoryCycloneDXMetadataV1{
		Timestamp:  ts,
		Properties: convertEndpointInventorySBOMProperties(meta.Properties),
	}
	for _, tool := range meta.Tools {
		out.Tools = append(out.Tools, &edgev1.EndpointInventoryCycloneDXToolV1{
			Vendor:  tool.Vendor,
			Name:    tool.Name,
			Version: tool.Version,
		})
	}
	if meta.Component != nil {
		out.Component = convertEndpointInventorySBOMComponent(*meta.Component)
	}
	return out
}

func convertEndpointInventorySBOMComponent(
	comp endpointinventory.CycloneDXComponent,
) *edgev1.EndpointInventoryCycloneDXComponentV1 {
	return &edgev1.EndpointInventoryCycloneDXComponentV1{
		Type:       comp.Type,
		Name:       comp.Name,
		Version:    comp.Version,
		Group:      comp.Group,
		Purl:       comp.PURL,
		Cpe:        comp.CPE,
		Properties: convertEndpointInventorySBOMProperties(comp.Properties),
	}
}

func convertEndpointInventorySBOMProperties(
	props []endpointinventory.CycloneDXProperty,
) []*edgev1.EndpointInventoryCycloneDXPropertyV1 {
	if len(props) == 0 {
		return nil
	}
	out := make([]*edgev1.EndpointInventoryCycloneDXPropertyV1, 0, len(props))
	for _, p := range props {
		out = append(out, &edgev1.EndpointInventoryCycloneDXPropertyV1{
			Name:  p.Name,
			Value: p.Value,
		})
	}
	return out
}

func convertEndpointInventoryPackageDelta(
	delta *endpointinventory.PackageSetDelta,
) *edgev1.EndpointInventoryPackageSetDeltaV1 {
	if delta == nil {
		return nil
	}
	return &edgev1.EndpointInventoryPackageSetDeltaV1{
		Schema:               delta.Schema,
		BasePackageSetHash:   delta.BasePackageSetHash,
		TargetPackageSetHash: delta.TargetPackageSetHash,
		HashAlgorithm:        delta.HashAlgorithm,
		Added:                convertEndpointInventoryPackages(delta.Added),
		Removed:              convertEndpointInventoryPackages(delta.Removed),
		Changed:              convertEndpointInventoryPackageChanges(delta.Changed),
	}
}

func convertEndpointInventoryPackages(
	pkgs []endpointinventory.Package,
) []*edgev1.EndpointInventoryPackageV1 {
	if len(pkgs) == 0 {
		return nil
	}
	out := make([]*edgev1.EndpointInventoryPackageV1, 0, len(pkgs))
	for _, pkg := range pkgs {
		out = append(out, &edgev1.EndpointInventoryPackageV1{
			Name:         pkg.Name,
			Version:      pkg.Version,
			Architecture: pkg.Arch,
			Manager:      pkg.Manager,
			Ecosystem:    pkg.Ecosystem,
			Purl:         pkg.PURL,
			Cpes:         append([]string(nil), pkg.CPEs...),
		})
	}
	return out
}

func convertEndpointInventoryPackageChanges(
	changes []endpointinventory.PackageChange,
) []*edgev1.EndpointInventoryPackageChangeV1 {
	if len(changes) == 0 {
		return nil
	}
	out := make([]*edgev1.EndpointInventoryPackageChangeV1, 0, len(changes))
	for _, chg := range changes {
		out = append(out, &edgev1.EndpointInventoryPackageChangeV1{
			Name:            chg.Name,
			Version:         chg.Version,
			Architecture:    chg.Arch,
			Manager:         chg.Manager,
			Ecosystem:       chg.Ecosystem,
			Purl:            chg.PURL,
			Cpes:            append([]string(nil), chg.CPEs...),
			PreviousVersion: chg.PreviousVersion,
		})
	}
	return out
}
