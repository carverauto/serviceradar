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
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const endpointInventoryUploadDeferredState = "upload_deferred"

var errEndpointInventorySpoolTooLarge = errors.New("endpoint inventory spool payload exceeds size budget")

// endpointInventorySpoolPayloadCap is the status-transport size budget enforced after
// ensureEndpointInventoryAgentID rewrites the payload. Declared as a var (not a const)
// so tests can shrink it; the production value is fixed at the transport limit. Same
// idiom as releaseDownloadInitialBackoff. Without it, asserting the cap costs a 32 MiB
// document marshalled twice and round-tripped through disk under -race.
//
//nolint:gochecknoglobals // tunable for tests
var endpointInventorySpoolPayloadCap = endpointinventory.MaxSpoolPayloadBytes

type EndpointInventorySpoolService struct {
	agentID   string
	spoolPath string
	cfg       endpointinventory.Config
}

func NewEndpointInventorySpoolService(agentID string, cfg *EndpointInventoryStatusConfig) *EndpointInventorySpoolService {
	inventoryCfg := endpointinventory.DefaultConfig()
	inventoryCfg.AgentID = agentID
	inventoryCfg.SpoolDir = filepath.Dir(cfg.effectiveSpoolPath())
	inventoryCfg.CacheDir = cfg.effectiveCacheDir()
	inventoryCfg.TmpDir = cfg.effectiveTmpDir()

	return &EndpointInventorySpoolService{
		agentID:   agentID,
		spoolPath: cfg.effectiveSpoolPath(),
		cfg:       inventoryCfg,
	}
}

func (s *EndpointInventorySpoolService) Start(context.Context) error { return nil }
func (s *EndpointInventorySpoolService) Stop(context.Context) error  { return nil }
func (s *EndpointInventorySpoolService) Name() string                { return endpointinventory.ServiceName }
func (s *EndpointInventorySpoolService) StatusServiceType() string {
	return endpointinventory.ServiceType
}
func (s *EndpointInventorySpoolService) StatusSource() string { return endpointinventory.SourceResults }
func (s *EndpointInventorySpoolService) UpdateConfig(*models.Config) error {
	return nil
}

func (s *EndpointInventorySpoolService) GetStatus(context.Context) (*proto.StatusResponse, error) {
	data, err := s.statusPayload()
	if err != nil {
		if errors.Is(err, endpointinventory.ErrPendingUploadUnavailable) {
			return nil, err
		}
		if errors.Is(err, os.ErrNotExist) {
			return s.notScannedStatus(), nil
		}
		return nil, err
	}
	data = ensureEndpointInventoryAgentID(data, s.agentID)
	if int64(len(data)) > endpointInventorySpoolPayloadCap {
		return nil, errEndpointInventorySpoolTooLarge
	}

	return &proto.StatusResponse{
		Available:   true,
		Message:     data,
		ServiceName: endpointinventory.ServiceName,
		ServiceType: endpointinventory.ServiceType,
	}, nil
}

func (s *EndpointInventorySpoolService) statusPayload() ([]byte, error) {
	manifest, pendingData, err := endpointinventory.ReadCacheManifestAndPending(s.cfg)
	if err != nil {
		return nil, err
	}
	if manifest != nil && manifest.PendingUpload != nil {
		if endpointinventory.PendingUploadDue(s.cfg, manifest, time.Now().UTC()) {
			return attachEndpointInventoryStandingQuestionCounts(pendingData, manifest), nil
		}

		data, err := os.ReadFile(s.spoolPath)
		if err != nil {
			return nil, err
		}

		return attachEndpointInventoryStandingQuestionCounts(deferEndpointInventoryUpload(s.cfg, data, manifest), manifest), nil
	}

	data, err := os.ReadFile(s.spoolPath)
	if err != nil {
		return nil, err
	}

	// Matching last-uploaded hashes prove the current package set has already
	// been acknowledged upstream. Re-emitting the raw
	// spool here re-ships the payload on every heartbeat: the scanner mints a
	// fresh scan_id and timestamps on each run, so the push-loop status
	// signature changes every scan even when the package set is byte-identical,
	// and core ingests a new scan row each time. Stabilize the unchanged status
	// so the signature is identical across runs and the heartbeat dedup
	// suppresses re-pushes until the package set actually changes.
	stabilized := stabilizeEndpointInventoryUnchangedStatus(
		suppressEndpointInventoryUploadedSBOM(data, manifest),
		manifest,
	)

	return attachEndpointInventoryStandingQuestionCounts(stabilized, manifest), nil
}

func (s *EndpointInventorySpoolService) notScannedStatus() *proto.StatusResponse {
	payload := map[string]any{
		"schema_version": endpointinventory.SchemaVersion,
		"agent_id":       s.agentID,
		"scan_id":        "endpoint-inventory-not-scanned",
		"state":          "not_scanned",
		"coverage_state": "not_scanned",
		"package_count":  0,
		"sources":        []endpointinventory.SourceSummary{},
		"metadata": map[string]any{
			"spool_path": s.spoolPath,
			"reason":     "spool_not_found",
		},
	}

	data, _ := json.Marshal(payload)

	return &proto.StatusResponse{
		Available:   false,
		Message:     data,
		ServiceName: endpointinventory.ServiceName,
		ServiceType: endpointinventory.ServiceType,
	}
}

func ensureEndpointInventoryAgentID(data []byte, agentID string) []byte {
	if agentID == "" {
		return data
	}

	var payload map[string]any
	if err := json.Unmarshal(data, &payload); err != nil {
		return data
	}

	payload["agent_id"] = agentID
	updated, err := json.Marshal(payload)
	if err != nil {
		return data
	}

	return updated
}

func deferEndpointInventoryUpload(
	cfg endpointinventory.Config,
	data []byte,
	manifest *endpointinventory.InventoryCacheManifest,
) []byte {
	var payload map[string]any
	if err := json.Unmarshal(data, &payload); err != nil {
		return data
	}

	delete(payload, "sbom")
	payload["state"] = endpointInventoryUploadDeferredState
	payload["coverage_state"] = endpointInventoryUploadDeferredState
	payload["upload_reason"] = endpointinventory.UploadReasonChanged
	if payload["metadata"] == nil {
		payload["metadata"] = map[string]any{}
	}
	if metadata, ok := payload["metadata"].(map[string]any); ok {
		metadata["reason"] = "upload_not_due"
		metadata["pending_upload"] = manifest.PendingUpload
		metadata["retry_exhausted"] = endpointinventory.PendingUploadExhausted(cfg, manifest)
	}

	updated, err := json.Marshal(payload)
	if err != nil {
		return data
	}

	return updated
}

func suppressEndpointInventoryUploadedSBOM(
	data []byte,
	manifest *endpointinventory.InventoryCacheManifest,
) []byte {
	var payload endpointinventory.ScanPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return data
	}
	if !endpointinventory.PayloadRequiresFullUpload(&payload) ||
		!endpointinventory.UploadAcknowledged(&payload, manifest) {
		return data
	}

	payload.SBOM = nil
	payload.UploadReason = endpointinventory.UploadReasonUnchanged
	if payload.Metadata == nil {
		payload.Metadata = map[string]any{}
	}
	payload.Metadata["reason"] = "upload_already_acknowledged"

	updated, err := json.Marshal(payload)
	if err != nil {
		return data
	}

	return updated
}

// stabilizeEndpointInventoryUnchangedStatus rewrites an already-acknowledged
// unchanged scan status into a deterministic form so repeated heartbeats that
// re-read freshly-written spool files (new scan_id + timestamps every scan)
// produce an identical push-loop status signature. Only statuses the manifest
// confirms are already uploaded-and-unchanged are rewritten; changed scans,
// pending uploads, and failure states are left untouched so they still upload.
func stabilizeEndpointInventoryUnchangedStatus(
	data []byte,
	manifest *endpointinventory.InventoryCacheManifest,
) []byte {
	var payload endpointinventory.ScanPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return data
	}
	if !endpointinventory.ShouldStabilizeUnchangedScan(&payload, manifest) {
		return data
	}

	endpointinventory.StabilizeUnchangedScanPayload(&payload)

	updated, err := json.Marshal(&payload)
	if err != nil {
		return data
	}

	return updated
}

func attachEndpointInventoryStandingQuestionCounts(
	data []byte,
	manifest *endpointinventory.InventoryCacheManifest,
) []byte {
	if manifest == nil || len(manifest.StandingQuestionResultCounts) == 0 {
		return data
	}

	var payload endpointinventory.ScanPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return data
	}
	if len(payload.StandingQuestionResultCounts) > 0 {
		return data
	}

	payload.StandingQuestionResultCounts = append(
		[]endpointinventory.StandingQuestionResultCount(nil),
		manifest.StandingQuestionResultCounts...,
	)
	updated, err := json.Marshal(payload)
	if err != nil {
		return data
	}

	return updated
}
