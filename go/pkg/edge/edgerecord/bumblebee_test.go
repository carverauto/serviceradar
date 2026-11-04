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

package edgerecord

import (
	"errors"
	"testing"

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func TestValidateBumblebeeScanRecord(t *testing.T) {
	t.Parallel()

	t.Run("accepts a scan with findings and JSON maps", func(t *testing.T) {
		t.Parallel()

		scan := &edgev1.BumblebeeScanPayloadV1{
			SchemaVersion:        "bumblebee.endpoint_scan.v1",
			AgentId:              "agent-1",
			RunId:                "run-1",
			ScannerVersion:       "0.2.0",
			CatalogSnapshotRef:   "2026.04.14.1",
			State:                "completed",
			CoverageState:        "complete",
			AttemptedRootCount:   1,
			ScannedRootCount:     1,
			RootCovered:          true,
			AttemptedRoots:       []string{"/"},
			ScannedRoots:         []string{"/"},
			LastScanAt:           "2026-04-14T22:00:00Z",
			LastSuccessfulScanAt: "2026-04-14T22:00:00Z",
			MetadataJson:         []byte(`{"profile":"default"}`),
			Findings: []*edgev1.BumblebeeFindingV1{
				{
					FindingId:      "finding-1",
					CatalogId:      "CVE-2026-0001",
					Severity:       "high",
					RiskScore:      80,
					HasRiskScore:   true,
					Ecosystem:      "cargo",
					PackageName:    "demo",
					PackageVersion: "1.2.3",
					EvidenceJson:   []byte(`{"path":"/opt/demo"}`),
					Confidence:     "high",
					MetadataJson:   []byte(`{"source":"lockfile"}`),
				},
			},
		}

		if got := BumblebeeScanRows(scan); got != 1 {
			t.Fatalf("BumblebeeScanRows() = %d, want 1", got)
		}
		record := discoveryRecord(t,
			contractRef{BumblebeeScanContractID, BumblebeeScanContractVersion},
			BumblebeeScanProjectedWriteBytesPerRecord,
			scan,
			BumblebeeScanRows(scan),
		)
		if err := ValidateBumblebeeScanRecord(record); err != nil {
			t.Fatalf("ValidateBumblebeeScanRecord() = %v", err)
		}
	})

	t.Run("accepts a completed zero-finding scan with projected_row_count 1", func(t *testing.T) {
		t.Parallel()

		scan := &edgev1.BumblebeeScanPayloadV1{
			SchemaVersion: "bumblebee.endpoint_scan.v1",
			AgentId:       "agent-1",
			RunId:         "run-empty",
			State:         "completed",
			CoverageState: "complete",
		}

		if got := BumblebeeScanRows(scan); got != 1 {
			t.Fatalf("BumblebeeScanRows() = %d, want 1", got)
		}
		record := discoveryRecord(t,
			contractRef{BumblebeeScanContractID, BumblebeeScanContractVersion},
			BumblebeeScanProjectedWriteBytesPerRecord,
			scan,
			BumblebeeScanRows(scan),
		)
		if err := ValidateBumblebeeScanRecord(record); err != nil {
			t.Fatalf("ValidateBumblebeeScanRecord() = %v", err)
		}
	})

	t.Run("refuses missing agent_id, missing run_id, missing finding id, invalid JSON, row-count mismatch, and source authorization", func(t *testing.T) {
		t.Parallel()

		if err := ValidateBumblebeeScan(nil); !errors.Is(err, ErrDiscoveryBatch) {
			t.Fatalf("nil scan = %v, want ErrDiscoveryBatch", err)
		}
		if err := ValidateBumblebeeScan(&edgev1.BumblebeeScanPayloadV1{RunId: "run-1"}); !errors.Is(err, ErrDiscoveryBatch) {
			t.Fatalf("missing agent_id = %v, want ErrDiscoveryBatch", err)
		}
		if err := ValidateBumblebeeScan(&edgev1.BumblebeeScanPayloadV1{AgentId: "agent-1"}); !errors.Is(err, ErrDiscoveryBatch) {
			t.Fatalf("missing run_id = %v, want ErrDiscoveryBatch", err)
		}
		if err := ValidateBumblebeeScan(&edgev1.BumblebeeScanPayloadV1{
			AgentId:      "agent-1",
			RunId:        "run-1",
			MetadataJson: []byte(`["not-an-object"]`),
		}); !errors.Is(err, ErrDiscoveryBatch) {
			t.Fatalf("non-object metadata_json = %v, want ErrDiscoveryBatch", err)
		}
		if err := ValidateBumblebeeScan(&edgev1.BumblebeeScanPayloadV1{
			AgentId: "agent-1",
			RunId:   "run-1",
			Findings: []*edgev1.BumblebeeFindingV1{
				{CatalogId: "CVE-2026-0001"},
			},
		}); !errors.Is(err, ErrDiscoveryBatch) {
			t.Fatalf("finding without id = %v, want ErrDiscoveryBatch", err)
		}
		if err := ValidateBumblebeeScan(&edgev1.BumblebeeScanPayloadV1{
			AgentId: "agent-1",
			RunId:   "run-1",
			Findings: []*edgev1.BumblebeeFindingV1{
				{FindingId: "f-1", EvidenceJson: []byte(`null`)},
			},
		}); !errors.Is(err, ErrDiscoveryBatch) {
			t.Fatalf("null evidence_json = %v, want ErrDiscoveryBatch", err)
		}
		if err := ValidateBumblebeeScan(&edgev1.BumblebeeScanPayloadV1{
			AgentId: "agent-1",
			RunId:   "run-1",
			Findings: []*edgev1.BumblebeeFindingV1{
				{Id: "f-1", MetadataJson: []byte(`{invalid`)},
			},
		}); !errors.Is(err, ErrDiscoveryBatch) {
			t.Fatalf("invalid finding metadata_json = %v, want ErrDiscoveryBatch", err)
		}

		valid := &edgev1.BumblebeeScanPayloadV1{
			AgentId: "agent-1",
			RunId:   "run-1",
			Findings: []*edgev1.BumblebeeFindingV1{
				{FindingId: "f-1"},
			},
		}
		wrongRows := discoveryRecord(t,
			contractRef{BumblebeeScanContractID, BumblebeeScanContractVersion},
			BumblebeeScanProjectedWriteBytesPerRecord,
			valid,
			2,
		)
		if err := ValidateBumblebeeScanRecord(wrongRows); !errors.Is(err, ErrDiscoveryBatch) {
			t.Fatalf("row count mismatch = %v, want ErrDiscoveryBatch", err)
		}

		withSource := discoverySourcedRecord(t, proto.Clone(discoveryRecord(t,
			contractRef{BumblebeeScanContractID, BumblebeeScanContractVersion},
			BumblebeeScanProjectedWriteBytesPerRecord,
			valid,
			1,
		)).(*edgev1.EdgeRecordV1))
		if err := ValidateBumblebeeScanRecord(withSource); !errors.Is(err, ErrDiscoverySourceAuthorization) {
			t.Fatalf("source authorization = %v, want ErrDiscoverySourceAuthorization", err)
		}
	})
}
