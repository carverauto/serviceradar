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

package agent

import (
	"encoding/json"

	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
	monitoringpb "github.com/carverauto/serviceradar/proto"
)

type bumblebeeConfigEnvelope struct {
	Bumblebee *bumblebeeConfigPayload `json:"bumblebee"`
}

type bumblebeeConfigPayload struct {
	Enabled           bool                         `json:"enabled"`
	AgentID           string                       `json:"agent_id,omitempty"`
	DeviceUID         string                       `json:"device_uid,omitempty"`
	ScanProfile       string                       `json:"scan_profile,omitempty"`
	RootDiscoveryMode string                       `json:"root_discovery_mode,omitempty"`
	ExplicitRoots     []string                     `json:"explicit_roots,omitempty"`
	ExcludeRoots      []string                     `json:"exclude_roots,omitempty"`
	Ecosystems        []string                     `json:"ecosystems,omitempty"`
	ScanTimeout       string                       `json:"scan_timeout,omitempty"`
	MaxFindings       int32                        `json:"max_findings,omitempty"`
	MaxOutputBytes    int64                        `json:"max_output_bytes,omitempty"`
	Cadence           string                       `json:"cadence,omitempty"`
	FindingsOnly      bool                         `json:"findings_only,omitempty"`
	Catalog           *bumblebee.CatalogAssignment `json:"catalog,omitempty"`
}

func parseGatewayBumblebeeConfig(configJSON []byte) (*bumblebeeConfigPayload, error) {
	if len(configJSON) == 0 {
		return nil, nil
	}

	var envelope bumblebeeConfigEnvelope
	if err := json.Unmarshal(configJSON, &envelope); err != nil {
		return nil, err
	}

	if envelope.Bumblebee == nil {
		return nil, nil
	}

	return envelope.Bumblebee, nil
}

func bumblebeeConfigFromProto(cfg *monitoringpb.BumblebeeConfig) *bumblebeeConfigPayload {
	if cfg == nil {
		return nil
	}

	payload := &bumblebeeConfigPayload{
		Enabled:           cfg.GetEnabled(),
		AgentID:           cfg.GetAgentId(),
		ScanProfile:       cfg.GetScanProfile(),
		RootDiscoveryMode: cfg.GetRootDiscoveryMode(),
		ExplicitRoots:     cfg.GetExplicitRoots(),
		ExcludeRoots:      cfg.GetExcludeRoots(),
		Ecosystems:        cfg.GetEcosystems(),
		ScanTimeout:       cfg.GetScanTimeout(),
		MaxFindings:       cfg.GetMaxFindings(),
		MaxOutputBytes:    cfg.GetMaxOutputBytes(),
		Cadence:           cfg.GetCadence(),
		FindingsOnly:      cfg.GetFindingsOnly(),
	}

	if catalog := cfg.GetCatalog(); catalog != nil {
		payload.Catalog = &bumblebee.CatalogAssignment{
			SchemaVersion:  catalog.GetSchemaVersion(),
			SnapshotRef:    catalog.GetSnapshotRef(),
			CatalogVersion: catalog.GetCatalogVersion(),
			SourceRevision: catalog.GetSourceRevision(),
			ObjectKey:      catalog.GetObjectKey(),
			SHA256:         catalog.GetSha256(),
			SizeBytes:      catalog.GetSizeBytes(),
		}
	}

	return payload
}

func (p *bumblebeeConfigPayload) runtimeProfile(agentID string) bumblebee.RuntimeProfile {
	if p == nil {
		return bumblebee.RuntimeProfile{}
	}

	enabled := p.Enabled
	profile := bumblebee.RuntimeProfile{
		Enabled:       &enabled,
		AgentID:       agentID,
		DeviceUID:     p.DeviceUID,
		ScanTimeout:   p.ScanTimeout,
		ExplicitRoots: append([]string(nil), p.ExplicitRoots...),
		ExcludeRoots:  append([]string(nil), p.ExcludeRoots...),
		Ecosystems:    append([]string(nil), p.Ecosystems...),
	}

	if p.Catalog != nil {
		profile.CatalogSnapshotRef = p.Catalog.SnapshotRef
	}
	if p.MaxFindings > 0 {
		maxFindings := int(p.MaxFindings)
		profile.MaxFindings = &maxFindings
	}
	if p.MaxOutputBytes > 0 {
		maxOutputBytes := p.MaxOutputBytes
		profile.MaxOutputBytes = &maxOutputBytes
	}

	includeHomes, includeRoot, ok := rootDiscoveryBooleans(p.RootDiscoveryMode)
	if ok {
		profile.IncludeHomeRoots = &includeHomes
		profile.IncludeRoot = &includeRoot
	}

	return profile
}

func rootDiscoveryBooleans(mode string) (bool, bool, bool) {
	switch mode {
	case "", "all", "system":
		return true, true, mode != ""
	case "home", "homes", "home_roots":
		return true, false, true
	case "root":
		return false, true, true
	case "explicit":
		return false, false, true
	default:
		return false, false, false
	}
}

func resolveGatewayBumblebeeConfig(
	protoConfig *monitoringpb.BumblebeeConfig,
	configJSON []byte,
) (*bumblebeeConfigPayload, error) {
	if cfg := bumblebeeConfigFromProto(protoConfig); cfg != nil {
		jsonCfg, err := parseGatewayBumblebeeConfig(configJSON)
		if err != nil {
			return nil, err
		}
		mergeBumblebeeCatalogDelivery(cfg, jsonCfg)
		return cfg, nil
	}

	return parseGatewayBumblebeeConfig(configJSON)
}

func mergeBumblebeeCatalogDelivery(cfg, jsonCfg *bumblebeeConfigPayload) {
	if cfg == nil || jsonCfg == nil {
		return
	}

	if cfg.DeviceUID == "" {
		cfg.DeviceUID = jsonCfg.DeviceUID
	}

	if cfg.Catalog == nil || jsonCfg.Catalog == nil {
		return
	}

	if cfg.Catalog.DownloadURL == "" {
		cfg.Catalog.DownloadURL = jsonCfg.Catalog.DownloadURL
	}
	if cfg.Catalog.DownloadToken == "" {
		cfg.Catalog.DownloadToken = jsonCfg.Catalog.DownloadToken
	}
}
