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

	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	monitoringpb "github.com/carverauto/serviceradar/proto"
)

type endpointInventoryConfigEnvelope struct {
	EndpointInventory *endpointInventoryConfigPayload `json:"endpoint_inventory"`
}

type endpointInventoryConfigPayload struct {
	Enabled        bool     `json:"enabled"`
	AgentID        string   `json:"agent_id,omitempty"`
	Sources        []string `json:"sources,omitempty"`
	ScanTimeout    string   `json:"scan_timeout,omitempty"`
	MaxPackages    int32    `json:"max_packages,omitempty"`
	MaxOutputBytes int64    `json:"max_output_bytes,omitempty"`
	Cadence        string   `json:"cadence,omitempty"`
	CollectPaths   bool     `json:"collect_paths,omitempty"`
	CollectHashes  bool     `json:"collect_file_hashes,omitempty"`
	ForceFresh     bool     `json:"force_fresh_enabled,omitempty"`
	ForceFullScan  int32    `json:"force_full_scan_interval,omitempty"`
	CacheStale     string   `json:"cache_stale_threshold,omitempty"`
	UploadJitter   string   `json:"upload_jitter,omitempty"`
	RetryInitial   string   `json:"upload_retry_initial,omitempty"`
	RetryMax       string   `json:"upload_retry_max,omitempty"`
	RetryAttempts  int32    `json:"upload_retry_max_attempts,omitempty"`
}

func parseGatewayEndpointInventoryConfig(configJSON []byte) (*endpointInventoryConfigPayload, error) {
	if len(configJSON) == 0 {
		return nil, nil
	}

	var envelope endpointInventoryConfigEnvelope
	if err := json.Unmarshal(configJSON, &envelope); err != nil {
		return nil, err
	}
	if envelope.EndpointInventory == nil {
		return nil, nil
	}

	return envelope.EndpointInventory, nil
}

func endpointInventoryConfigFromProto(cfg *monitoringpb.EndpointInventoryConfig) *endpointInventoryConfigPayload {
	if cfg == nil {
		return nil
	}

	return &endpointInventoryConfigPayload{
		Enabled:        cfg.GetEnabled(),
		AgentID:        cfg.GetAgentId(),
		Sources:        cfg.GetSources(),
		ScanTimeout:    cfg.GetScanTimeout(),
		MaxPackages:    cfg.GetMaxPackages(),
		MaxOutputBytes: cfg.GetMaxOutputBytes(),
		Cadence:        cfg.GetCadence(),
		CollectPaths:   cfg.GetCollectPaths(),
		CollectHashes:  cfg.GetCollectFileHashes(),
		ForceFresh:     cfg.GetForceFreshEnabled(),
		ForceFullScan:  cfg.GetForceFullScanInterval(),
		CacheStale:     cfg.GetCacheStaleThreshold(),
		UploadJitter:   cfg.GetUploadJitter(),
		RetryInitial:   cfg.GetUploadRetryInitial(),
		RetryMax:       cfg.GetUploadRetryMax(),
		RetryAttempts:  cfg.GetUploadRetryMaxAttempts(),
	}
}

func (p *endpointInventoryConfigPayload) runtimeProfile(agentID string) endpointinventory.RuntimeProfile {
	if p == nil {
		return endpointinventory.RuntimeProfile{}
	}

	enabled := p.Enabled
	profile := endpointinventory.RuntimeProfile{
		Enabled:             &enabled,
		AgentID:             agentID,
		ScanTimeout:         p.ScanTimeout,
		Sources:             append([]string(nil), p.Sources...),
		Cadence:             p.Cadence,
		CacheStaleThreshold: p.CacheStale,
		UploadJitter:        p.UploadJitter,
		UploadRetryInitial:  p.RetryInitial,
		UploadRetryMax:      p.RetryMax,
	}
	collectPaths := p.CollectPaths
	profile.CollectPaths = &collectPaths
	collectHashes := p.CollectHashes
	profile.CollectFileHashes = &collectHashes
	if p.ForceFresh {
		forceFresh := true
		profile.ForceFreshEnabled = &forceFresh
	}
	if p.ForceFullScan > 0 {
		forceFullScan := int(p.ForceFullScan)
		profile.ForceFullScanInterval = &forceFullScan
	}
	if p.RetryAttempts > 0 {
		retryAttempts := int(p.RetryAttempts)
		profile.UploadRetryMaxAttempts = &retryAttempts
	}
	if p.MaxPackages > 0 {
		maxPackages := int(p.MaxPackages)
		profile.MaxPackages = &maxPackages
	}
	if p.MaxOutputBytes > 0 {
		maxOutputBytes := p.MaxOutputBytes
		profile.MaxOutputBytes = &maxOutputBytes
	}

	return profile
}

func resolveGatewayEndpointInventoryConfig(
	protoConfig *monitoringpb.EndpointInventoryConfig,
	configJSON []byte,
) (*endpointInventoryConfigPayload, error) {
	if cfg := endpointInventoryConfigFromProto(protoConfig); cfg != nil {
		return cfg, nil
	}

	return parseGatewayEndpointInventoryConfig(configJSON)
}
