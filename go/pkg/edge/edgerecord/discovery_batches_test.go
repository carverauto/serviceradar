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

	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// discoveryRecord is a valid edge record over batch for contract, with its
// projected row count equal to rows.
func discoveryRecord(
	t *testing.T,
	contractID string,
	version uint32,
	bytesPerRow uint64,
	batch proto.Message,
	rows uint32,
) *edgev1.EdgeRecordV1 {
	t.Helper()
	payload, err := proto.MarshalOptions{Deterministic: true}.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(payload)
	r := validRecord(t)
	r.OutputContract.ContractId = contractID
	r.OutputContract.ContractVersion = version
	r.Payload, r.PayloadSha256 = payload, sum[:]
	r.EncodedSize, r.UncompressedSize = uint32(len(payload)), uint32(len(payload))
	r.ProjectedRowCount, r.ProjectedWriteBytes = rows, uint64(rows)*bytesPerRow
	r.ProductionCapability = productionCap(t, r)
	reseal(r)
	return r
}

func discoverySourcedRecord(t *testing.T, r *edgev1.EdgeRecordV1) *edgev1.EdgeRecordV1 {
	t.Helper()
	ctx, scope := mustUUID(t), mustUUID(t)
	r.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
		Kind:       edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
		Capability: sourceCap(t, r, ctx, scope, edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK),
		ContextId:  ctx, ScopeId: scope, ScopeSha256: d32(0xAA),
	}
	reseal(r)
	return r
}

func TestValidateDiscoveryRecords(t *testing.T) {
	mapperDevices := &edgev1.MapperDeviceBatchV1{
		AgentId: "agent-edge-01",
		Devices: []*edgev1.MapperDeviceRecordV1{
			{DeviceId: "sr:00000000-0000-4000-8000-000000000101", Ip: "192.0.2.10"},
		},
	}
	mapperInterfaces := &edgev1.MapperInterfaceBatchV1{
		AgentId: "agent-edge-01",
		Interfaces: []*edgev1.MapperInterfaceRecordV1{
			{DeviceIp: "192.0.2.10", IfIndex: 3, IfName: "xe-0/0/0"},
		},
	}
	mapperTopology := &edgev1.MapperTopologyBatchV1{
		AgentId: "agent-edge-01",
		Links: []*edgev1.MapperTopologyLinkRecordV1{
			{LocalDeviceIp: "192.0.2.10", Protocol: "LLDP"},
		},
	}
	netprobe := &edgev1.NetprobeDiscoveryBatchV1{
		Records: []*edgev1.NetprobeDiscoveryRecordV1{
			{Ip: "192.0.2.44", AgentId: "agent-edge-01", Source: "passive-netprobe"},
		},
	}
	syncPage := &edgev1.SyncPageBatchV1{
		SyncMeta: &edgev1.SyncMetaV1{SyncServiceId: "svc-1", SyncRunId: "run-1", ChunkIndex: 0},
		Devices: []*edgev1.SyncDeviceRecordV1{
			{Uid: "src-device-1", Ip: "192.0.2.60"},
		},
	}
	syncControl := &edgev1.SyncPageBatchV1{
		SyncMeta:      &edgev1.SyncMetaV1{SyncServiceId: "svc-1", SyncRunId: "run-1", IsFinal: true},
		ControlMarker: &edgev1.SyncControlMarkerV1{ControlType: "collection_final"},
	}

	cases := []struct {
		name     string
		build    func(rows uint32) *edgev1.EdgeRecordV1
		validate func(*edgev1.EdgeRecordV1) error
	}{
		{"mapper devices", func(rows uint32) *edgev1.EdgeRecordV1 {
			return discoveryRecord(t, MapperDevicesContractID, MapperDevicesContractVersion, MapperDevicesProjectedWriteBytesPerRecord, mapperDevices, rows)
		}, ValidateMapperDeviceRecord},
		{"mapper interfaces", func(rows uint32) *edgev1.EdgeRecordV1 {
			return discoveryRecord(t, MapperInterfacesContractID, MapperInterfacesContractVersion, MapperInterfacesProjectedWriteBytesPerRecord, mapperInterfaces, rows)
		}, ValidateMapperInterfaceRecord},
		{"mapper topology", func(rows uint32) *edgev1.EdgeRecordV1 {
			return discoveryRecord(t, MapperTopologyContractID, MapperTopologyContractVersion, MapperTopologyProjectedWriteBytesPerRecord, mapperTopology, rows)
		}, ValidateMapperTopologyRecord},
		{"netprobe", func(rows uint32) *edgev1.EdgeRecordV1 {
			return discoveryRecord(t, NetprobeDiscoveryContractID, NetprobeDiscoveryContractVersion, NetprobeDiscoveryProjectedWriteBytesPerRecord, netprobe, rows)
		}, ValidateNetprobeDiscoveryRecord},
		{"sync page", func(rows uint32) *edgev1.EdgeRecordV1 {
			return discoveryRecord(t, SyncPageContractID, SyncPageContractVersion, SyncPageProjectedWriteBytesPerRecord, syncPage, rows)
		}, ValidateSyncPageRecord},
		{"sync control page", func(rows uint32) *edgev1.EdgeRecordV1 {
			return discoveryRecord(t, SyncPageContractID, SyncPageContractVersion, SyncPageProjectedWriteBytesPerRecord, syncControl, rows)
		}, ValidateSyncPageRecord},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			valid := tc.build(1)
			if err := tc.validate(valid); err != nil {
				t.Fatalf("valid record: %v", err)
			}

			if err := tc.validate(tc.build(2)); !errors.Is(err, ErrDiscoveryBatch) {
				t.Fatalf("row count mismatch: got %v", err)
			}

			sourced := discoverySourcedRecord(t, proto.Clone(valid).(*edgev1.EdgeRecordV1))
			if err := tc.validate(sourced); !errors.Is(err, ErrDiscoverySourceAuthorization) {
				t.Fatalf("source authorization: got %v", err)
			}

			other := proto.Clone(valid).(*edgev1.EdgeRecordV1)
			other.OutputContract.ContractId = MetricsBatchContractID
			other.ProductionCapability = productionCap(t, other)
			reseal(other)
			if err := tc.validate(other); err == nil {
				t.Fatal("wrong contract accepted")
			}
		})
	}
}

func TestValidateDiscoveryBatchRules(t *testing.T) {
	if err := ValidateMapperDeviceBatch(&edgev1.MapperDeviceBatchV1{AgentId: "a"}); !errors.Is(err, ErrDiscoveryBatch) {
		t.Fatalf("empty mapper device batch: %v", err)
	}
	if err := ValidateMapperDeviceBatch(&edgev1.MapperDeviceBatchV1{
		Devices: []*edgev1.MapperDeviceRecordV1{{Ip: "192.0.2.1"}},
	}); !errors.Is(err, ErrDiscoveryBatch) {
		t.Fatalf("mapper device batch without agent: %v", err)
	}
	if err := ValidateMapperInterfaceBatch(&edgev1.MapperInterfaceBatchV1{
		AgentId:    "a",
		Interfaces: []*edgev1.MapperInterfaceRecordV1{{DeviceIp: "192.0.2.1"}},
	}); !errors.Is(err, ErrDiscoveryBatch) {
		t.Fatalf("mapper interface without name/index: %v", err)
	}
	if err := ValidateMapperTopologyBatch(&edgev1.MapperTopologyBatchV1{
		AgentId: "a",
		Links:   []*edgev1.MapperTopologyLinkRecordV1{{Protocol: "LLDP"}},
	}); !errors.Is(err, ErrDiscoveryBatch) {
		t.Fatalf("mapper link without local device: %v", err)
	}
	if err := ValidateNetprobeDiscoveryBatch(&edgev1.NetprobeDiscoveryBatchV1{
		Records: []*edgev1.NetprobeDiscoveryRecordV1{{AgentId: "a"}},
	}); !errors.Is(err, ErrDiscoveryBatch) {
		t.Fatalf("netprobe record without ip: %v", err)
	}
	if err := ValidateSyncPageBatch(&edgev1.SyncPageBatchV1{
		Devices: []*edgev1.SyncDeviceRecordV1{{Ip: "192.0.2.1"}},
	}); !errors.Is(err, ErrDiscoveryBatch) {
		t.Fatalf("sync page without run meta: %v", err)
	}
	if err := ValidateSyncPageBatch(&edgev1.SyncPageBatchV1{
		SyncMeta: &edgev1.SyncMetaV1{SyncRunId: "run-1"},
		Devices:  []*edgev1.SyncDeviceRecordV1{{Hostname: "anchorless.example.com"}},
	}); !errors.Is(err, ErrDiscoveryBatch) {
		t.Fatalf("sync device without anchor: %v", err)
	}
}
