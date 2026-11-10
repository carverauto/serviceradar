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
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

type stubEndpointInventoryProvider struct {
	calls  int
	status *proto.StatusResponse
}

func (s *stubEndpointInventoryProvider) Name() string                      { return endpointinventory.ServiceName }
func (s *stubEndpointInventoryProvider) Start(context.Context) error       { return nil }
func (s *stubEndpointInventoryProvider) Stop(context.Context) error        { return nil }
func (s *stubEndpointInventoryProvider) UpdateConfig(*models.Config) error { return nil }
func (s *stubEndpointInventoryProvider) StatusServiceType() string {
	return endpointinventory.ServiceType
}
func (s *stubEndpointInventoryProvider) StatusSource() string { return endpointinventory.SourceResults }
func (s *stubEndpointInventoryProvider) GetStatus(context.Context) (*proto.StatusResponse, error) {
	s.calls++
	return s.status, nil
}

func grantEndpointInventory(t *testing.T, loop *PushLoop) {
	t.Helper()
	installTestEdgeGrants(t, loop, sysmonEdgeAgentID, []*proto.EdgeOutputGrant{
		discoveryGrant(
			t,
			edgerecord.EndpointInventoryContractID,
			edgerecord.EndpointInventoryProjectedWriteBytesPerRecord,
			"serviceradar.agent.endpoint_inventory",
		),
	}, time.Now())
}

func syntheticEndpointInventoryScanPayload() endpointinventory.ScanPayload {
	now := time.Date(2026, 7, 14, 12, 0, 0, 0, time.UTC)
	return endpointinventory.ScanPayload{
		SchemaVersion:        endpointinventory.SchemaVersion,
		AgentID:              sysmonEdgeAgentID,
		ScanID:               "scan-dusk-01",
		CollectorVersion:     "1.2.3-synthetic",
		State:                "scanned",
		CoverageState:        "complete",
		ConfigHash:           "cfg-hash-01",
		LastScanAt:           now,
		LastSuccessfulScanAt: &now,
		OS: endpointinventory.OSInfo{
			Name:       "SyntheticLinux",
			ID:         "synthetic",
			Version:    "1.0",
			VersionID:  "1",
			PrettyName: "SyntheticLinux 1.0",
		},
		EnabledPlugins:  []string{"os/dpkg"},
		DetectedPlugins: []string{"os/dpkg"},
		Diagnostics: []endpointinventory.SourceSummary{
			{
				Name:           "os/dpkg",
				Type:           "os",
				State:          "scanned",
				Detected:       true,
				PackageCount:   1,
				DurationMillis: 42,
			},
		},
		PackageCount:   1,
		PackageSetHash: "pkg-hash-dusk-01",
		ArtifactHash:   "art-hash-dusk-01",
		HashAlgorithm:  endpointinventory.HashAlgorithm,
		UploadReason:   endpointinventory.UploadReasonChanged,
		DurationMillis: 42,
		StandingQuestionResultCounts: []endpointinventory.StandingQuestionResultCount{
			{
				Schema:        endpointinventory.StandingQuestionResultCountSchema,
				QuestionID:    "q-openssl",
				PredicateHash: "pred-01",
				Mode:          endpointinventory.QueryModeCount,
				Matched:       true,
				Count:         1,
				EvaluatedAt:   now,
			},
		},
		SBOM: &endpointinventory.CycloneDXBOM{
			BOMFormat:   endpointinventory.CycloneDXFormat,
			SpecVersion: endpointinventory.CycloneDXSpecVersion,
			Version:     1,
			Components: []endpointinventory.CycloneDXComponent{
				{
					Type:    "library",
					Name:    "openssl",
					Version: "3.0.11-1",
					PURL:    "pkg:deb/debian/openssl@3.0.11?arch=amd64",
					Properties: []endpointinventory.CycloneDXProperty{
						{Name: "serviceradar:package_manager", Value: "dpkg"},
						{Name: "serviceradar:architecture", Value: "amd64"},
					},
				},
			},
		},
		Metadata: map[string]any{
			"reason":              "initial_scan",
			"scanner_producer_id": "scalibr",
		},
	}
}

func TestEndpointInventoryWithGrantEmitsEdgeRecordAndNoStatus(t *testing.T) {
	sp := openTestEdgeSpool(t)
	payload := syntheticEndpointInventoryScanPayload()
	encoded, err := json.Marshal(payload)
	require.NoError(t, err)

	provider := &stubEndpointInventoryProvider{
		status: &proto.StatusResponse{
			Available:   true,
			Message:     encoded,
			ServiceName: endpointinventory.ServiceName,
			ServiceType: endpointinventory.ServiceType,
		},
	}

	server := &Server{
		config:   &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
		services: []Service{provider},
	}
	loop := &PushLoop{server: server, logger: logger.NewTestLogger()}
	loop.SetEdgeDiscoverySpool(sp)
	grantEndpointInventory(t, loop)

	statuses := loop.collectAllStatuses(context.Background())
	for _, st := range statuses {
		require.NotEqual(t, endpointinventory.ServiceName, st.GetServiceName(),
			"endpoint_inventory status must be suppressed when standing grant is active")
	}

	records := spooledRecords(t, sp)
	require.Len(t, records, 1)
	require.NoError(t, edgerecord.ValidateEndpointInventoryRecord(records[0]))
	require.Equal(t, uint32(1), records[0].GetProjectedRowCount())

	scan := &edgev1.EndpointInventoryScanPayloadV1{}
	require.NoError(t, gproto.Unmarshal(recordBody(t, records[0]), scan))
	require.Equal(t, sysmonEdgeAgentID, scan.GetAgentId())
	require.Equal(t, "scan-dusk-01", scan.GetScanId())
	require.Equal(t, "pkg-hash-dusk-01", scan.GetPackageSetHash())
	require.Equal(t, "art-hash-dusk-01", scan.GetArtifactHash())
	require.NotNil(t, scan.GetSbom())
	require.Len(t, scan.GetSbom().GetComponents(), 1)
	require.Equal(t, "openssl", scan.GetSbom().GetComponents()[0].GetName())
	require.Len(t, scan.GetDiagnostics(), 1)
	require.True(t, scan.GetDiagnostics()[0].GetHasDetected())
	require.True(t, scan.GetDiagnostics()[0].GetDetected())
}

func pendingEndpointInventoryUploadLoop(
	t *testing.T,
	payload endpointinventory.ScanPayload,
) (*PushLoop, endpointinventory.Config) {
	t.Helper()
	tmpDir := t.TempDir()
	spoolDir := filepath.Join(tmpDir, "spool")
	spoolPath := endpointinventory.LatestPath(spoolDir)
	cacheDir := filepath.Join(tmpDir, "cache")
	profilePath := filepath.Join(tmpDir, "profile.json")

	cfg := endpointinventory.DefaultConfig()
	cfg.AgentID = sysmonEdgeAgentID
	cfg.SpoolDir = spoolDir
	cfg.CacheDir = cacheDir
	cfg.TmpDir = filepath.Join(tmpDir, "tmp")
	cfg.ProfilePath = profilePath

	now := time.Now().UTC()
	require.NoError(t, endpointinventory.WriteSpool(cfg, &payload))
	manifest := &endpointinventory.InventoryCacheManifest{
		SchemaVersion:   endpointinventory.CacheVersion,
		AgentID:         sysmonEdgeAgentID,
		ConfigHash:      payload.ConfigHash,
		ProducerID:      "scalibr",
		ProducerVersion: payload.CollectorVersion,
		PendingUpload: &endpointinventory.PendingUploadState{
			ScanID:          payload.ScanID,
			AgentID:         sysmonEdgeAgentID,
			ConfigHash:      payload.ConfigHash,
			ProducerID:      "scalibr",
			ProducerVersion: payload.CollectorVersion,
			PackageSetHash:  payload.PackageSetHash,
			ArtifactHash:    payload.ArtifactHash,
			UploadReason:    payload.UploadReason,
			AvailableAfter:  now.Add(-time.Minute),
			CreatedAt:       now,
			UpdatedAt:       now,
		},
		Packages:        []endpointinventory.Package{},
		SourceSummaries: []endpointinventory.SourceSummary{},
		SourceMTimes:    map[string]endpointinventory.SourceMTime{},
	}
	require.NoError(t, endpointinventory.WriteCacheManifest(cfg, manifest))

	statusCfg := &EndpointInventoryStatusConfig{
		Enabled:     true,
		SpoolPath:   spoolPath,
		CacheDir:    cacheDir,
		ProfilePath: profilePath,
		TmpDir:      cfg.TmpDir,
	}
	svc := NewEndpointInventorySpoolService(sysmonEdgeAgentID, statusCfg)

	server := &Server{
		config: &ServerConfig{
			AgentID:           sysmonEdgeAgentID,
			Partition:         "default",
			EndpointInventory: statusCfg,
		},
		services: []Service{svc},
	}
	return &PushLoop{server: server, logger: logger.NewTestLogger()}, cfg
}

func TestEndpointInventoryEdgeAdmissionAcknowledgesPendingUpload(t *testing.T) {
	sp := openTestEdgeSpool(t)
	payload := syntheticEndpointInventoryScanPayload()
	loop, cfg := pendingEndpointInventoryUploadLoop(t, payload)
	loop.SetEdgeDiscoverySpool(sp)
	grantEndpointInventory(t, loop)

	statuses := loop.collectAllStatuses(context.Background())
	for _, st := range statuses {
		require.NotEqual(t, endpointinventory.ServiceName, st.GetServiceName())
	}

	require.Len(t, spooledRecords(t, sp), 1)

	updatedManifest, err := endpointinventory.ReadCacheManifest(cfg)
	require.NoError(t, err)
	require.NotNil(t, updatedManifest)
	require.Nil(t, updatedManifest.PendingUpload, "edge spool admission must clear pending_upload")
	require.Equal(t, payload.PackageSetHash, updatedManifest.LastUploadedPackageSetHash)
	require.Equal(t, payload.ArtifactHash, updatedManifest.LastUploadedArtifactHash)
}

// A full SBOM larger than the 512 KiB edge record body bound cannot be sent;
// it must be dropped once per scan and recorded as a failed upload attempt
// rather than rebuilt and re-dropped on every tick, leaving the collector to
// report its deferred state until the retry window opens.
func TestEndpointInventoryOversizedScanIsDroppedOnceAndMarkedFailed(t *testing.T) {
	sp := openTestEdgeSpool(t)
	payload := syntheticEndpointInventoryScanPayload()
	components := make([]endpointinventory.CycloneDXComponent, 0, 8000)
	for i := range 8000 {
		name := fmt.Sprintf("synthetic-library-package-%05d", i)
		components = append(components, endpointinventory.CycloneDXComponent{
			Type:    "library",
			Name:    name,
			Version: "1.0.0-1",
			PURL:    fmt.Sprintf("pkg:deb/example/%s@1.0.0-1?arch=amd64&distro=example-1", name),
		})
	}
	payload.SBOM.Components = components
	payload.PackageCount = len(components)

	loop, cfg := pendingEndpointInventoryUploadLoop(t, payload)
	loop.SetEdgeDiscoverySpool(sp)
	grantEndpointInventory(t, loop)

	for range 3 {
		statuses := loop.collectAllStatuses(context.Background())
		for _, st := range statuses {
			require.NotEqual(t, endpointinventory.ServiceName, st.GetServiceName(),
				"an unsendable scan must not fall back to the status path while the grant is held")
		}
	}

	records := spooledRecords(t, sp)
	require.Len(t, records, 1, "after the failed attempt only the deferred status is emitted")
	deferred := &edgev1.EndpointInventoryScanPayloadV1{}
	require.NoError(t, gproto.Unmarshal(recordBody(t, records[0]), deferred))
	require.Nil(t, deferred.GetSbom())
	require.Equal(t, uint64(1), edgeDrops(loop, edgeProducerEndpointInventory, edgeDropInvalidRecord),
		"the same unsendable payload must be counted once, not once per tick")

	updatedManifest, err := endpointinventory.ReadCacheManifest(cfg)
	require.NoError(t, err)
	require.NotNil(t, updatedManifest.PendingUpload)
	require.Equal(t, 1, updatedManifest.PendingUpload.Attempts)
	require.NotEmpty(t, updatedManifest.PendingUpload.LastError)
	require.Empty(t, updatedManifest.LastUploadedPackageSetHash)
}

// A collector with no spool yet reports not_scanned with Available=false; core
// records that coverage state, so it must be projected on the edge contract.
func TestEndpointInventoryNotScannedStatusIsEmittedOnEdgeContract(t *testing.T) {
	sp := openTestEdgeSpool(t)
	statusCfg := &EndpointInventoryStatusConfig{
		Enabled:   true,
		SpoolPath: filepath.Join(t.TempDir(), "missing", "latest.json"),
	}
	server := &Server{
		config: &ServerConfig{
			AgentID:           sysmonEdgeAgentID,
			Partition:         "default",
			EndpointInventory: statusCfg,
		},
		services: []Service{NewEndpointInventorySpoolService(sysmonEdgeAgentID, statusCfg)},
	}
	loop := &PushLoop{server: server, logger: logger.NewTestLogger()}
	loop.SetEdgeDiscoverySpool(sp)
	grantEndpointInventory(t, loop)

	statuses := loop.collectAllStatuses(context.Background())
	for _, st := range statuses {
		require.NotEqual(t, endpointinventory.ServiceName, st.GetServiceName())
	}

	records := spooledRecords(t, sp)
	require.Len(t, records, 1)
	scan := &edgev1.EndpointInventoryScanPayloadV1{}
	require.NoError(t, gproto.Unmarshal(recordBody(t, records[0]), scan))
	require.Equal(t, "not_scanned", scan.GetState())
	require.Equal(t, "not_scanned", scan.GetCoverageState())
	require.Equal(t, sysmonEdgeAgentID, scan.GetAgentId())
}

func TestEndpointInventoryBackpressurePausesPollingAndRetriesSameEventID(t *testing.T) {
	payload := syntheticEndpointInventoryScanPayload()
	encoded, err := json.Marshal(payload)
	require.NoError(t, err)

	provider := &stubEndpointInventoryProvider{
		status: &proto.StatusResponse{
			Available:   true,
			Message:     encoded,
			ServiceName: endpointinventory.ServiceName,
			ServiceType: endpointinventory.ServiceType,
		},
	}

	server := &Server{
		config:   &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
		services: []Service{provider},
	}
	loop := &PushLoop{server: server, logger: logger.NewTestLogger()}
	loop.SetEdgeDiscoverySpool(refusingEdgeSpool(t))
	grantEndpointInventory(t, loop)

	// First tick polls GetStatus, builds 1 record, and holds it when spool refuses.
	statuses := loop.collectAllStatuses(context.Background())
	for _, st := range statuses {
		require.NotEqual(t, endpointinventory.ServiceName, st.GetServiceName())
	}
	require.Equal(t, 1, provider.calls)
	require.NotNil(t, loop.endpointInventoryEdge.built)
	firstEventID := append([]byte(nil), loop.endpointInventoryEdge.built.record.GetEventId()...)

	// Second tick while spool still refuses must NOT call GetStatus.
	statuses = loop.collectAllStatuses(context.Background())
	for _, st := range statuses {
		require.NotEqual(t, endpointinventory.ServiceName, st.GetServiceName())
	}
	require.Equal(t, 1, provider.calls, "GetStatus must not be called while a built record is unadmitted")
	require.NotNil(t, loop.endpointInventoryEdge.built)

	// Once spool accepts, the held record is admitted with the exact same event_id.
	accepting := openTestEdgeSpool(t)
	loop.SetEdgeDiscoverySpool(accepting)
	statuses = loop.collectAllStatuses(context.Background())
	for _, st := range statuses {
		require.NotEqual(t, endpointinventory.ServiceName, st.GetServiceName())
	}
	require.Nil(t, loop.endpointInventoryEdge.built)

	records := spooledRecords(t, accepting)
	require.Len(t, records, 1)
	require.Equal(t, firstEventID, records[0].GetEventId())
}

func TestEndpointInventoryUnchangedPayloadHashIsDeduplicated(t *testing.T) {
	sp := openTestEdgeSpool(t)
	payload := syntheticEndpointInventoryScanPayload()
	encoded, err := json.Marshal(payload)
	require.NoError(t, err)

	provider := &stubEndpointInventoryProvider{
		status: &proto.StatusResponse{
			Available:   true,
			Message:     encoded,
			ServiceName: endpointinventory.ServiceName,
			ServiceType: endpointinventory.ServiceType,
		},
	}

	server := &Server{
		config:   &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
		services: []Service{provider},
	}
	loop := &PushLoop{server: server, logger: logger.NewTestLogger()}
	loop.SetEdgeDiscoverySpool(sp)
	grantEndpointInventory(t, loop)

	loop.collectAllStatuses(context.Background())
	loop.collectAllStatuses(context.Background())
	require.Equal(t, 2, provider.calls)
	require.Len(t, spooledRecords(t, sp), 1, "identical payload hash must not emit a duplicate record")
}

// Without a grant the scan is neither polled, sent as a status, nor spooled:
// the collector's spooled scan waits on disk, and the hold is counted. Once
// the grant is held the scan is spooled.
func TestEndpointInventoryWithoutGrantIsNotPolled(t *testing.T) {
	sp := openTestEdgeSpool(t)
	payload := syntheticEndpointInventoryScanPayload()
	encoded, err := json.Marshal(payload)
	require.NoError(t, err)

	provider := &stubEndpointInventoryProvider{
		status: &proto.StatusResponse{
			Available:   true,
			Message:     encoded,
			ServiceName: endpointinventory.ServiceName,
			ServiceType: endpointinventory.ServiceType,
		},
	}

	server := &Server{
		config:   &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
		services: []Service{provider},
	}
	loop := &PushLoop{server: server, logger: logger.NewTestLogger()}
	loop.SetEdgeDiscoverySpool(sp)

	statuses := loop.collectAllStatuses(context.Background())
	for _, st := range statuses {
		require.NotEqual(t, endpointinventory.ServiceName, st.GetServiceName(),
			"endpoint inventory must never ride the status path")
	}
	require.Zero(t, provider.calls, "the scan was polled without a grant")
	require.Empty(t, spooledRecords(t, sp))
	require.Equal(t, uint64(1), loop.server.edgeProducerDrops.grantHolds[edgeProducerEndpointInventory].Load())

	grantEndpointInventory(t, loop)
	loop.collectAllStatuses(context.Background())
	require.Equal(t, 1, provider.calls)
	require.Len(t, spooledRecords(t, sp), 1)
}
