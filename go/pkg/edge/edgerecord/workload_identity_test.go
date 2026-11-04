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
	"crypto/sha256"
	"errors"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

func TestValidateWorkloadIdentityRecord(t *testing.T) {
	populated := &edgev1.WorkloadIdentitySnapshotV1{
		ObservedAtUnixNano: 1_780_000_000_000_000_000,
		Enabled:            true,
		Endpoint: &edgev1.WorkloadIdentitySnapshotEndpointV1{
			Type:   "Cri",
			Path:   "/run/containerd/containerd.sock",
			Source: "CommonPath",
		},
		Count: 2,
		Identities: []*edgev1.WorkloadIdentityContainerLookupV1{
			{
				ContainerId: "container-alpha",
				Identity: &edgev1.WorkloadIdentityRecordV1{
					ContainerId:   "container-alpha",
					PodName:       "api-0",
					PodNamespace:  "default",
					RuntimePid:    4312,
					HasRuntimePid: true,
					RuntimeSource: "Containerd",
					Confidence:    "High",
				},
			},
			{
				Identity: &edgev1.WorkloadIdentityRecordV1{
					ContainerId:   "container-beta",
					PodName:       "worker-0",
					PodNamespace:  "jobs",
					RuntimeSource: "Containerd",
					Confidence:    "Medium",
				},
			},
		},
		ContextName: "example-ctx",
		ClusterId:   "cluster-1",
		ClusterName: "example-cluster",
	}

	buildPopulated := func(rows uint32) *edgev1.EdgeRecordV1 {
		return discoveryRecord(
			t,
			contractRef{WorkloadIdentityContractID, WorkloadIdentityContractVersion},
			WorkloadIdentityProjectedWriteBytesPerRecord,
			populated,
			rows,
		)
	}

	if err := ValidateWorkloadIdentityRecord(buildPopulated(2)); err != nil {
		t.Fatalf("valid populated snapshot rejected: %v", err)
	}

	emptyDisabled := &edgev1.WorkloadIdentitySnapshotV1{
		ObservedAtUnixNano: 1_780_000_000_000_000_000,
		Enabled:            false,
		DegradationReason:  "workload identity collection disabled",
	}
	emptyRecord := discoveryRecord(
		t,
		contractRef{WorkloadIdentityContractID, WorkloadIdentityContractVersion},
		WorkloadIdentityProjectedWriteBytesPerRecord,
		emptyDisabled,
		1,
	)
	if err := ValidateWorkloadIdentityRecord(emptyRecord); err != nil {
		t.Fatalf("valid empty disabled snapshot rejected: %v", err)
	}

	withSource := discoverySourcedRecord(t, buildPopulated(2))
	if err := ValidateWorkloadIdentityRecord(withSource); !errors.Is(err, ErrDiscoverySourceAuthorization) {
		t.Fatalf("source_authorization = %v, want ErrDiscoverySourceAuthorization", err)
	}

	wrongContract := buildPopulated(2)
	wrongContract.OutputContract.ContractId = MetricsBatchContractID
	wrongContract.ProductionCapability = productionCap(t, wrongContract)
	reseal(wrongContract)
	if err := ValidateWorkloadIdentityRecord(wrongContract); !errors.Is(err, ErrContractDispatch) {
		t.Fatalf("wrong contract = %v, want ErrContractDispatch", err)
	}

	wrongFamily := buildPopulated(2)
	wrongFamily.PayloadFamily = edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RUN_EVENT_V1
	reseal(wrongFamily)
	if err := ValidateWorkloadIdentityRecord(wrongFamily); !errors.Is(err, ErrPayloadFraming) {
		t.Fatalf("wrong payload family = %v, want ErrPayloadFraming", err)
	}

	wrongRows := buildPopulated(3)
	if err := ValidateWorkloadIdentityRecord(wrongRows); !errors.Is(err, ErrDiscoveryBatch) {
		t.Fatalf("projected_row_count mismatch = %v, want ErrDiscoveryBatch", err)
	}

	unknownTrailing := buildPopulated(2)
	raw := append([]byte{}, unknownTrailing.GetPayload()...)
	raw = append(raw, 0xf8, 0x06, 0x01)
	sum := sha256.Sum256(raw)
	unknownTrailing.Payload = raw
	unknownTrailing.PayloadSha256 = sum[:]
	unknownTrailing.EncodedSize = uint32(len(raw))
	unknownTrailing.UncompressedSize = uint32(len(raw))
	reseal(unknownTrailing)
	if err := ValidateWorkloadIdentityRecord(unknownTrailing); err == nil {
		t.Fatal("unknown trailing field accepted")
	}
}

func TestValidateWorkloadIdentitySnapshotRefusesMissingContainerID(t *testing.T) {
	if err := ValidateWorkloadIdentitySnapshot(nil); !errors.Is(err, ErrDiscoveryBatch) {
		t.Fatalf("nil snapshot = %v, want ErrDiscoveryBatch", err)
	}

	missingContainerID := &edgev1.WorkloadIdentitySnapshotV1{
		Enabled: true,
		Identities: []*edgev1.WorkloadIdentityContainerLookupV1{
			{
				Identity: &edgev1.WorkloadIdentityRecordV1{
					PodName: "api-0",
				},
			},
		},
	}
	if err := ValidateWorkloadIdentitySnapshot(missingContainerID); !errors.Is(err, ErrDiscoveryBatch) {
		t.Fatalf("lookup without container_id = %v, want ErrDiscoveryBatch", err)
	}
}
