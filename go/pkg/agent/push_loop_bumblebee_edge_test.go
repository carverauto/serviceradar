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
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

type fakeBumblebeeProvider struct {
	status    *proto.StatusResponse
	telemetry *addonpb.TelemetryBatch
	calls     int
}

func (f *fakeBumblebeeProvider) Name() string                      { return bumblebee.ServiceName }
func (f *fakeBumblebeeProvider) Start(context.Context) error       { return nil }
func (f *fakeBumblebeeProvider) Stop(context.Context) error        { return nil }
func (f *fakeBumblebeeProvider) UpdateConfig(*models.Config) error { return nil }
func (f *fakeBumblebeeProvider) StatusServiceType() string         { return bumblebee.ServiceType }
func (f *fakeBumblebeeProvider) StatusSource() string              { return bumblebee.SourceResults }
func (f *fakeBumblebeeProvider) GetStatus(context.Context) (*proto.StatusResponse, error) {
	f.calls++
	return f.status, nil
}
func (f *fakeBumblebeeProvider) AddonTelemetryBatch(*proto.StatusResponse) (string, *addonpb.TelemetryBatch) {
	if f.telemetry == nil {
		return "", nil
	}
	return "bumblebee", f.telemetry
}

func bumblebeeGrant(t *testing.T, maxRows uint32) *proto.EdgeOutputGrant {
	t.Helper()
	_, key, err := ed25519.GenerateKey(nil)
	require.NoError(t, err)
	digest := sha256.Sum256([]byte("synthetic-" + edgerecord.BumblebeeScanContractID))
	now := time.Now()
	capability := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1,
		IssuerId:          []byte("test-issuer"),
		IssuerKeyId:       []byte("test-issuer-key-1"),
		Algorithm:         "ed25519",
		NotBeforeUnixNano: now.Add(-time.Hour).UnixNano(),
		ExpiresAtUnixNano: now.Add(8 * 24 * time.Hour).UnixNano(),
		Claims: &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{
			ContractId:             edgerecord.BumblebeeScanContractID,
			ContractVersion:        edgerecord.BumblebeeScanContractVersion,
			ContractBundleSha256:   digest[:],
			RegistryEpoch:          1,
			RegistrySnapshotSha256: digest[:],
			EffectiveGrantSha256:   digest[:],
			NetworkScopeId:         testNetworkScopeID[:],
			ProducerAssignmentId:   testAssignmentID[:],
			RunId:                  testAssignmentID[:],
			AuthorityEpoch:         1,
			ScopeId:                testAssignmentID[:],
			ScopeSha256:            digest[:],
			OriginKind:             edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT,
			OriginPrincipalId:      []byte(sysmonEdgeAgentID),
			ProducerInstanceId:     []byte(sysmonEdgeAgentID),
			RouteProfile:           edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
			TrafficClass:           edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK,
			PackageId:              "serviceradar.agent.bumblebee",
			PackageSha256:          digest[:],
			CostModelVersion:       1,
			MaxProjectedRowCount:   maxRows,
			MaxProjectedWriteBytes: uint64(maxRows) * edgerecord.BumblebeeScanProjectedWriteBytesPerRecord,
		}},
	}
	edgerecord.SignCapability(capability, key)
	encoded, err := gproto.Marshal(capability)
	require.NoError(t, err)
	return &proto.EdgeOutputGrant{
		ContractId:           edgerecord.BumblebeeScanContractID,
		ContractVersion:      edgerecord.BumblebeeScanContractVersion,
		ProductionCapability: encoded,
	}
}

func TestPushLoopBumblebeeEdgeSpoolsValidatedRecordAndSuppressesLegacyStatus(t *testing.T) {
	t.Parallel()

	rawJSON := []byte(`{
		"schema_version": "serviceradar.bumblebee.scan.v1",
		"run_id": "run-101",
		"scanner_version": "0.2.0",
		"catalog_snapshot_ref": "2026.04.14.1",
		"state": "completed",
		"coverage_state": "partial",
		"attempted_root_count": 2,
		"scanned_root_count": 1,
		"skipped_root_count": 1,
		"root_covered": true,
		"attempted_roots": ["/", "/mnt/nfs"],
		"scanned_roots": ["/"],
		"skipped_roots": [{"path": "/mnt/nfs", "reason": "remote_fs"}, "/proc"],
		"last_scan_at": "2026-04-14T22:00:00Z",
		"last_successful_scan_at": "2026-04-14T22:00:00Z",
		"metadata": {"profile": "default"},
		"findings": [
			{
				"id": "id-1",
				"finding_id": "finding-1",
				"catalog_id": "CVE-2026-0001",
				"severity": "low",
				"risk_score": 0,
				"ecosystem": "cargo",
				"package_name": "demo",
				"package_version": "1.2.3",
				"evidence": {"lockfile": "/app/Cargo.lock"},
				"confidence": "high",
				"metadata": {"scanner": "bumblebee"}
			},
			{
				"finding_id": "finding-2",
				"catalog_id": "CVE-2026-0002",
				"severity": "high",
				"ecosystem": "deb",
				"package_name": "openssl",
				"package_version": "3.0.0"
			}
		]
	}`)

	fakeSvc := &fakeBumblebeeProvider{
		status: &proto.StatusResponse{
			Available:   true,
			Message:     rawJSON,
			ServiceName: bumblebee.ServiceName,
			ServiceType: bumblebee.ServiceType,
		},
		telemetry: &addonpb.TelemetryBatch{
			Source: &addonpb.TelemetrySource{
				SourceType:     "bumblebee",
				SourceInstance: sysmonEdgeAgentID,
			},
			Records: []*addonpb.TelemetryRecord{
				{
					EventId:     "00000000-0000-4000-8000-000000000001",
					PayloadKind: addonpb.TelemetryPayloadKind_TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
					Payload:     []byte(`{"class_uid":6007}`),
				},
			},
			Counters: &addonpb.TelemetryCounters{Received: 1, Emitted: 1},
		},
	}

	sp := openTestEdgeSpool(t)
	server := &Server{
		config:         &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
		services:       []Service{fakeSvc},
		addonTelemetry: newAddonTelemetryBuffer(0),
		logger:         logger.NewTestLogger(),
	}
	pl := NewPushLoop(server, nil, time.Second, logger.NewTestLogger())
	pl.SetEdgeDiscoverySpool(sp)
	pl.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{bumblebeeGrant(t, 64)}, time.Now())

	statuses, _ := pl.collectAllStatusesSeparated(context.Background())
	for _, st := range statuses {
		if st.GetServiceType() == bumblebee.ServiceType || st.GetServiceName() == bumblebee.ServiceName {
			t.Fatalf("bumblebee status leaked onto legacy status slice while grant is held: %+v", st)
		}
	}
	envelopes, _, _ := server.addonTelemetry.drain(0)
	require.Len(t, envelopes, 1)

	records := spooledRecords(t, sp)
	require.Len(t, records, 1)
	require.NoError(t, edgerecord.ValidateBumblebeeScanRecord(records[0]))
	require.Equal(t, uint32(2), records[0].GetProjectedRowCount())

	var decoded edgev1.BumblebeeScanPayloadV1
	require.NoError(t, gproto.Unmarshal(recordBody(t, records[0]), &decoded))
	require.Equal(t, sysmonEdgeAgentID, decoded.GetAgentId())
	require.Equal(t, "run-101", decoded.GetRunId())
	require.Len(t, decoded.GetSkippedRoots(), 2)
	require.Equal(t, "remote_fs", decoded.GetSkippedRoots()[0].GetReason())
	require.Equal(t, "/proc", decoded.GetSkippedRoots()[1].GetPath())
	require.Len(t, decoded.GetFindings(), 2)
	require.True(t, decoded.GetFindings()[0].GetHasRiskScore())
	require.Equal(t, int32(0), decoded.GetFindings()[0].GetRiskScore())
	require.False(t, decoded.GetFindings()[1].GetHasRiskScore())

	// Second poll with identical payload bytes is deduplicated by hash.
	pl.collectAllStatusesSeparated(context.Background())
	require.Len(t, spooledRecords(t, sp), 1)

	// An unchanged scan is re-emitted once the refresh interval has passed, so
	// core re-runs device resolution for it.
	later := time.Now().Add(bumblebeeEdgeRefreshInterval + time.Minute)
	require.True(t, pl.handleBumblebeeEdgeOrPause(context.Background(), fakeSvc, fakeSvc, later))
	refreshed := spooledRecords(t, sp)
	require.Len(t, refreshed, 2)
	var refreshedScan edgev1.BumblebeeScanPayloadV1
	require.NoError(t, gproto.Unmarshal(recordBody(t, refreshed[1]), &refreshedScan))
	require.Equal(t, "run-101", refreshedScan.GetRunId())
}

func TestPushLoopBumblebeeEdgeSpoolsNotScannedPostureWhenSpoolFileIsMissing(t *testing.T) {
	t.Parallel()

	spoolSvc := NewBumblebeeSpoolService(sysmonEdgeAgentID, &BumblebeeStatusConfig{
		SpoolPath: filepath.Join(t.TempDir(), "latest-scan.json"),
	})
	sp := openTestEdgeSpool(t)
	server := &Server{
		config:   &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
		services: []Service{spoolSvc},
		logger:   logger.NewTestLogger(),
	}
	pl := NewPushLoop(server, nil, time.Second, logger.NewTestLogger())
	pl.SetEdgeDiscoverySpool(sp)
	pl.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{bumblebeeGrant(t, 64)}, time.Now())

	pl.collectAllStatusesSeparated(context.Background())

	records := spooledRecords(t, sp)
	require.Len(t, records, 1)
	require.NoError(t, edgerecord.ValidateBumblebeeScanRecord(records[0]))
	var decoded edgev1.BumblebeeScanPayloadV1
	require.NoError(t, gproto.Unmarshal(recordBody(t, records[0]), &decoded))
	require.Equal(t, "not_scanned", decoded.GetState())
	require.Equal(t, sysmonEdgeAgentID, decoded.GetAgentId())
	require.Empty(t, decoded.GetFindings())
}

func TestPushLoopBumblebeeEdgeBackpressurePausesSpoolServicePollingAndRetainsEventID(t *testing.T) {
	t.Parallel()

	spoolDir := t.TempDir()
	spoolFile := filepath.Join(spoolDir, "latest-scan.json")
	spoolSvc := NewBumblebeeSpoolService(sysmonEdgeAgentID, &BumblebeeStatusConfig{
		SpoolPath: spoolFile,
	})

	writeScanFile := func(runID string) {
		t.Helper()
		payload := bumblebee.ScanPayload{
			SchemaVersion: bumblebee.SchemaVersion,
			AgentID:       sysmonEdgeAgentID,
			RunID:         runID,
			State:         "completed",
			CoverageState: "complete",
			LastScanAt:    time.Date(2026, 4, 14, 22, 0, 0, 0, time.UTC),
			Findings: []bumblebee.Finding{
				{FindingID: "f-" + runID, CatalogID: "CVE-2026-0001", Severity: "high"},
			},
		}
		raw, err := json.Marshal(payload)
		require.NoError(t, err)
		require.NoError(t, os.WriteFile(spoolFile, raw, 0o600))
	}

	writeScanFile("run-1")

	server := &Server{
		config:   &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
		services: []Service{spoolSvc},
		logger:   logger.NewTestLogger(),
	}
	pl := NewPushLoop(server, nil, time.Second, logger.NewTestLogger())
	pl.SetEdgeDiscoverySpool(refusingEdgeSpool(t))
	pl.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{bumblebeeGrant(t, 64)}, time.Now())

	// First poll reads run-1 from BumblebeeSpoolService, builds the edge record,
	// hits backpressure, and parks the built record in pl.bumblebeeEdge.built.
	pl.collectAllStatusesSeparated(context.Background())
	require.NotNil(t, pl.bumblebeeEdge.built)
	firstEventID := append([]byte(nil), pl.bumblebeeEdge.built.record.GetEventId()...)

	// A newer scan overwrites the spool file while the edge spool is backpressured.
	// Because polling is paused until the pending record is admitted, run-2 must
	// not replace the pending run-1 record while backpressure continues.
	writeScanFile("run-2")

	pl.collectAllStatusesSeparated(context.Background())
	require.NotNil(t, pl.bumblebeeEdge.built)
	require.Equal(t, firstEventID, pl.bumblebeeEdge.built.record.GetEventId())

	// Swap to an accepting spool: the next poll flushes run-1 with its original
	// EventId and then polls BumblebeeSpoolService to admit run-2.
	accepting := openTestEdgeSpool(t)
	pl.SetEdgeDiscoverySpool(accepting)
	pl.collectAllStatusesSeparated(context.Background())

	records := spooledRecords(t, accepting)
	require.Len(t, records, 2)
	require.Equal(t, firstEventID, records[0].GetEventId())

	var firstScan, secondScan edgev1.BumblebeeScanPayloadV1
	require.NoError(t, gproto.Unmarshal(recordBody(t, records[0]), &firstScan))
	require.NoError(t, gproto.Unmarshal(recordBody(t, records[1]), &secondScan))
	require.Equal(t, "run-1", firstScan.GetRunId())
	require.Equal(t, "run-2", secondScan.GetRunId())
}

func TestPushLoopBumblebeeEdgeCountsInvalidRecordsAndFallsBackWithoutGrant(t *testing.T) {
	t.Parallel()

	fakeSvc := &fakeBumblebeeProvider{
		status: &proto.StatusResponse{
			Available:   true,
			Message:     []byte(`{"schema_version":"serviceradar.bumblebee.scan.v1","state":"completed"}`),
			ServiceName: bumblebee.ServiceName,
			ServiceType: bumblebee.ServiceType,
		},
	}

	sp := openTestEdgeSpool(t)
	server := &Server{
		config:   &ServerConfig{AgentID: sysmonEdgeAgentID, Partition: "default"},
		services: []Service{fakeSvc},
		logger:   logger.NewTestLogger(),
	}
	pl := NewPushLoop(server, nil, time.Second, logger.NewTestLogger())
	pl.SetEdgeDiscoverySpool(sp)
	pl.edgeOutputGrants.replace(sysmonEdgeAgentID, []*proto.EdgeOutputGrant{bumblebeeGrant(t, 1)}, time.Now())

	// Missing run_id is counted as an invalid record once, not on every poll.
	pl.collectAllStatusesSeparated(context.Background())
	pl.collectAllStatusesSeparated(context.Background())
	require.Equal(t, uint64(1), edgeDrops(pl, edgeProducerBumblebee, edgeDropInvalidRecord))
	later := time.Now().Add(bumblebeeEdgeRefreshInterval + time.Minute)
	require.True(t, pl.handleBumblebeeEdgeOrPause(context.Background(), fakeSvc, fakeSvc, later))
	require.Equal(t, uint64(1), edgeDrops(pl, edgeProducerBumblebee, edgeDropInvalidRecord))

	// Exceeding capability row limit is counted as an invalid record and not truncated.
	fakeSvc.status = &proto.StatusResponse{
		Available: true,
		Message: []byte(`{
			"schema_version":"serviceradar.bumblebee.scan.v1",
			"run_id":"run-over-limit",
			"findings":[{"finding_id":"f-1"},{"finding_id":"f-2"}]
		}`),
		ServiceName: bumblebee.ServiceName,
		ServiceType: bumblebee.ServiceType,
	}
	pl.collectAllStatusesSeparated(context.Background())
	require.Equal(t, uint64(2), edgeDrops(pl, edgeProducerBumblebee, edgeDropInvalidRecord))
	require.Empty(t, spooledRecords(t, sp))

	// Without a grant, legacy status emission stays untouched.
	pl.edgeOutputGrants.replace(sysmonEdgeAgentID, nil, time.Now())
	statuses, _ := pl.collectAllStatusesSeparated(context.Background())
	foundLegacy := false
	for _, st := range statuses {
		if st.GetServiceType() == bumblebee.ServiceType && st.GetServiceName() == bumblebee.ServiceName {
			foundLegacy = true
		}
	}
	require.True(t, foundLegacy, "expected legacy bumblebee status when no grant is held")
}
