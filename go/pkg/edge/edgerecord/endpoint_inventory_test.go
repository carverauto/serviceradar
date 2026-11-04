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

func TestValidateEndpointInventoryRecord(t *testing.T) {
	validScan := &edgev1.EndpointInventoryScanPayloadV1{
		SchemaVersion:  "serviceradar.endpoint_inventory.v1",
		AgentId:        "agent-dusk-01",
		ScanId:         "scan-01",
		State:          "scanned",
		CoverageState:  "complete",
		PackageCount:   2,
		PackageSetHash: "pkg-hash-01",
		ArtifactHash:   "art-hash-01",
		UploadReason:   "changed",
		MetadataJson:   []byte(`{"reason":"initial_scan"}`),
	}

	buildRecord := func(t *testing.T, rows uint32) *edgev1.EdgeRecordV1 {
		t.Helper()
		return discoveryRecord(
			t,
			contractRef{EndpointInventoryContractID, EndpointInventoryContractVersion},
			EndpointInventoryProjectedWriteBytesPerRecord,
			validScan,
			rows,
		)
	}

	t.Run("accepts a valid standing-grant record", func(t *testing.T) {
		r := buildRecord(t, uint32(EndpointInventoryScanRows(validScan)))
		if err := ValidateEndpointInventoryRecord(r); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
	})

	t.Run("rejects projected row count mismatch", func(t *testing.T) {
		r := buildRecord(t, 2)
		if err := ValidateEndpointInventoryRecord(r); !errors.Is(err, ErrDiscoveryBatch) {
			t.Fatalf("expected %v, got %v", ErrDiscoveryBatch, err)
		}
	})

	t.Run("rejects source authorization on standing-grant contract", func(t *testing.T) {
		valid := buildRecord(t, 1)
		sourced := discoverySourcedRecord(t, proto.Clone(valid).(*edgev1.EdgeRecordV1))
		if err := ValidateEndpointInventoryRecord(sourced); !errors.Is(err, ErrDiscoverySourceAuthorization) {
			t.Fatalf("expected ErrDiscoverySourceAuthorization, got %v", err)
		}
	})

	t.Run("rejects wrong contract id", func(t *testing.T) {
		valid := buildRecord(t, 1)
		other := proto.Clone(valid).(*edgev1.EdgeRecordV1)
		other.OutputContract.ContractId = MetricsBatchContractID
		other.ProductionCapability = productionCap(t, other)
		reseal(other)
		if err := ValidateEndpointInventoryRecord(other); err == nil {
			t.Fatal("expected contract mismatch error")
		}
	})

	t.Run("rejects scan payload validation errors", func(t *testing.T) {
		cases := []struct {
			name string
			scan *edgev1.EndpointInventoryScanPayloadV1
		}{
			{
				name: "nil scan",
				scan: nil,
			},
			{
				name: "missing agent_id",
				scan: &edgev1.EndpointInventoryScanPayloadV1{
					ScanId: "scan-01",
				},
			},
			{
				name: "missing scan_id",
				scan: &edgev1.EndpointInventoryScanPayloadV1{
					AgentId: "agent-dusk-01",
				},
			},
			{
				name: "metadata_json not a JSON object",
				scan: &edgev1.EndpointInventoryScanPayloadV1{
					AgentId:      "agent-dusk-01",
					ScanId:       "scan-01",
					MetadataJson: []byte(`["not-an-object"]`),
				},
			},
		}

		for _, tc := range cases {
			t.Run(tc.name, func(t *testing.T) {
				if err := ValidateEndpointInventoryScan(tc.scan); !errors.Is(err, ErrDiscoveryBatch) {
					t.Fatalf("expected %v, got %v", ErrDiscoveryBatch, err)
				}
			})
		}
	})
}
