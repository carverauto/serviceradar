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
	"fmt"
	"strings"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// The discovery output contracts: mapper device/interface/topology batches,
// netprobe discovery, and sync pages. All five are agent-scheduled standing
// grants, so their records carry no source authorization. The typed bodies
// are proto/edge/v1/json_producer_batches.proto, which maps the legacy JSON
// update payloads field for field; the projectors rebuild those payloads and
// hand them to the same ingestors the legacy status path reached, so the
// DIRE invariants downstream of ingestion are untouched.
const (
	MapperDevicesContractID             = "serviceradar.mapper.devices.batch"
	MapperDevicesContractVersion uint32 = 1

	MapperInterfacesContractID             = "serviceradar.mapper.interfaces.batch"
	MapperInterfacesContractVersion uint32 = 1

	MapperTopologyContractID             = "serviceradar.mapper.topology.batch"
	MapperTopologyContractVersion uint32 = 1

	NetprobeDiscoveryContractID             = "serviceradar.netprobe.discovery.batch"
	NetprobeDiscoveryContractVersion uint32 = 1

	SyncPageContractID             = "serviceradar.sync.page.batch"
	SyncPageContractVersion uint32 = 1

	// The projected write costs below must match write_bytes_per_row for
	// these contracts in core's ServiceRadar.Edge.ContractCatalog. Device
	// updates fan out through identity resolution and device writes, so
	// they carry the plugin-results cost; interface, topology and netprobe
	// rows are single-destination writes at the telemetry cost.
	MapperDevicesProjectedWriteBytesPerRecord     = 16_384
	MapperInterfacesProjectedWriteBytesPerRecord  = 8_192
	MapperTopologyProjectedWriteBytesPerRecord    = 8_192
	NetprobeDiscoveryProjectedWriteBytesPerRecord = 8_192
	SyncPageProjectedWriteBytesPerRecord          = 16_384
)

var (
	// ErrDiscoveryBatch is returned for a discovery body that breaks a
	// contract's payload rules.
	ErrDiscoveryBatch = errors.New("edgerecord: invalid discovery batch")
	// ErrDiscoverySourceAuthorization is returned when a discovery record
	// carries a source authorization, which a standing grant never issues.
	ErrDiscoverySourceAuthorization = errors.New("edgerecord: discovery record carries a source authorization")
)

func validateDiscoveryRecord(
	r *edgev1.EdgeRecordV1,
	ref contractRef,
	body interface {
		Reset()
		proto.Message
	},
	validate func() (int, error),
) error {
	if err := decodeStandingGrantRecord(r, ref, ErrDiscoverySourceAuthorization, body); err != nil {
		return err
	}
	rows, err := validate()
	if err != nil {
		return err
	}
	if uint64(r.GetProjectedRowCount()) != uint64(rows) {
		return fmt.Errorf("%w: projected_row_count %d for %d rows",
			ErrDiscoveryBatch, r.GetProjectedRowCount(), rows)
	}
	return nil
}

// ValidateMapperDeviceBatch enforces the mapper device payload rules: a
// host-stamped agent id, at least one device, and per device an identity
// anchor (device id or ip), which is what the sync ingestion pipeline keys
// a mapper device update on.
func ValidateMapperDeviceBatch(batch *edgev1.MapperDeviceBatchV1) error {
	if batch == nil || strings.TrimSpace(batch.GetAgentId()) == "" {
		return fmt.Errorf("%w: mapper device batch has no agent id", ErrDiscoveryBatch)
	}
	if len(batch.GetDevices()) == 0 {
		return fmt.Errorf("%w: mapper device batch is empty", ErrDiscoveryBatch)
	}
	for i, device := range batch.GetDevices() {
		if strings.TrimSpace(device.GetDeviceId()) == "" && strings.TrimSpace(device.GetIp()) == "" {
			return fmt.Errorf("%w: mapper device %d has no device id or ip", ErrDiscoveryBatch, i)
		}
	}
	return nil
}

// ValidateMapperDeviceRecord is ValidateMapperDeviceBatch composed over a
// whole edge record.
func ValidateMapperDeviceRecord(r *edgev1.EdgeRecordV1) error {
	var batch edgev1.MapperDeviceBatchV1
	return validateDiscoveryRecord(r,
		contractRef{MapperDevicesContractID, MapperDevicesContractVersion}, &batch,
		func() (int, error) { return len(batch.GetDevices()), ValidateMapperDeviceBatch(&batch) })
}

// ValidateMapperInterfaceBatch enforces the mapper interface payload rules:
// a host-stamped agent id, at least one interface, and per interface a
// parent device anchor and an interface anchor, matching what
// MapperResultsIngestor.normalize_interface/1 requires to attach the row.
func ValidateMapperInterfaceBatch(batch *edgev1.MapperInterfaceBatchV1) error {
	if batch == nil || strings.TrimSpace(batch.GetAgentId()) == "" {
		return fmt.Errorf("%w: mapper interface batch has no agent id", ErrDiscoveryBatch)
	}
	if len(batch.GetInterfaces()) == 0 {
		return fmt.Errorf("%w: mapper interface batch is empty", ErrDiscoveryBatch)
	}
	for i, iface := range batch.GetInterfaces() {
		if strings.TrimSpace(iface.GetDeviceId()) == "" && strings.TrimSpace(iface.GetDeviceIp()) == "" {
			return fmt.Errorf("%w: mapper interface %d has no device id or ip", ErrDiscoveryBatch, i)
		}
		if strings.TrimSpace(iface.GetIfName()) == "" && iface.GetIfIndex() == 0 {
			return fmt.Errorf("%w: mapper interface %d has no name or index", ErrDiscoveryBatch, i)
		}
	}
	return nil
}

// ValidateMapperInterfaceRecord is ValidateMapperInterfaceBatch composed
// over a whole edge record.
func ValidateMapperInterfaceRecord(r *edgev1.EdgeRecordV1) error {
	var batch edgev1.MapperInterfaceBatchV1
	return validateDiscoveryRecord(r,
		contractRef{MapperInterfacesContractID, MapperInterfacesContractVersion}, &batch,
		func() (int, error) { return len(batch.GetInterfaces()), ValidateMapperInterfaceBatch(&batch) })
}

// ValidateMapperTopologyBatch enforces the mapper topology payload rules: a
// host-stamped agent id, at least one link, and per link a local device
// anchor, matching MapperResultsIngestor.normalize_topology/1.
func ValidateMapperTopologyBatch(batch *edgev1.MapperTopologyBatchV1) error {
	if batch == nil || strings.TrimSpace(batch.GetAgentId()) == "" {
		return fmt.Errorf("%w: mapper topology batch has no agent id", ErrDiscoveryBatch)
	}
	if len(batch.GetLinks()) == 0 {
		return fmt.Errorf("%w: mapper topology batch is empty", ErrDiscoveryBatch)
	}
	for i, link := range batch.GetLinks() {
		if strings.TrimSpace(link.GetLocalDeviceId()) == "" && strings.TrimSpace(link.GetLocalDeviceIp()) == "" {
			return fmt.Errorf("%w: mapper topology link %d has no local device", ErrDiscoveryBatch, i)
		}
	}
	return nil
}

// ValidateMapperTopologyRecord is ValidateMapperTopologyBatch composed over
// a whole edge record.
func ValidateMapperTopologyRecord(r *edgev1.EdgeRecordV1) error {
	var batch edgev1.MapperTopologyBatchV1
	return validateDiscoveryRecord(r,
		contractRef{MapperTopologyContractID, MapperTopologyContractVersion}, &batch,
		func() (int, error) { return len(batch.GetLinks()), ValidateMapperTopologyBatch(&batch) })
}

// ValidateNetprobeDiscoveryBatch enforces the netprobe payload rules: at
// least one record, and per record the subject ip and the originating agent
// id, which the sync ingestion pipeline keys a netprobe update on.
func ValidateNetprobeDiscoveryBatch(batch *edgev1.NetprobeDiscoveryBatchV1) error {
	if batch == nil || len(batch.GetRecords()) == 0 {
		return fmt.Errorf("%w: netprobe discovery batch is empty", ErrDiscoveryBatch)
	}
	for i, record := range batch.GetRecords() {
		if strings.TrimSpace(record.GetIp()) == "" {
			return fmt.Errorf("%w: netprobe record %d has no ip", ErrDiscoveryBatch, i)
		}
		if strings.TrimSpace(record.GetAgentId()) == "" {
			return fmt.Errorf("%w: netprobe record %d has no agent id", ErrDiscoveryBatch, i)
		}
	}
	return nil
}

// ValidateNetprobeDiscoveryRecord is ValidateNetprobeDiscoveryBatch composed
// over a whole edge record.
func ValidateNetprobeDiscoveryRecord(r *edgev1.EdgeRecordV1) error {
	var batch edgev1.NetprobeDiscoveryBatchV1
	return validateDiscoveryRecord(r,
		contractRef{NetprobeDiscoveryContractID, NetprobeDiscoveryContractVersion}, &batch,
		func() (int, error) { return len(batch.GetRecords()), ValidateNetprobeDiscoveryBatch(&batch) })
}

// SyncPageRows is the projected row count of a sync page: its device count,
// or one for a control-only page.
func SyncPageRows(batch *edgev1.SyncPageBatchV1) int {
	rows := len(batch.GetDevices())
	if rows == 0 && batch.GetControlMarker() != nil {
		return 1
	}
	return rows
}

// ValidateSyncPageBatch enforces the sync page payload rules: run tracking
// metadata naming the sync run, at least one device unless the page is the
// collection-final control marker, and per device an identity anchor. The
// population guard and conflicting-identity refusal stay where they are
// today, inside the sync ingestion pipeline the projector feeds.
func ValidateSyncPageBatch(batch *edgev1.SyncPageBatchV1) error {
	if batch == nil {
		return fmt.Errorf("%w: empty sync page", ErrDiscoveryBatch)
	}
	meta := batch.GetSyncMeta()
	if meta == nil || strings.TrimSpace(meta.GetSyncRunId()) == "" {
		return fmt.Errorf("%w: sync page has no sync run id", ErrDiscoveryBatch)
	}
	if len(batch.GetDevices()) == 0 && batch.GetControlMarker() == nil {
		return fmt.Errorf("%w: sync page has no devices or control marker", ErrDiscoveryBatch)
	}
	for i, device := range batch.GetDevices() {
		if strings.TrimSpace(device.GetDeviceId()) == "" &&
			strings.TrimSpace(device.GetUid()) == "" &&
			strings.TrimSpace(device.GetIp()) == "" &&
			strings.TrimSpace(device.GetMac()) == "" {
			return fmt.Errorf("%w: sync device %d has no identity anchor", ErrDiscoveryBatch, i)
		}
	}
	return nil
}

// ValidateSyncPageRecord is ValidateSyncPageBatch composed over a whole edge
// record.
func ValidateSyncPageRecord(r *edgev1.EdgeRecordV1) error {
	var batch edgev1.SyncPageBatchV1
	return validateDiscoveryRecord(r,
		contractRef{SyncPageContractID, SyncPageContractVersion}, &batch,
		func() (int, error) { return SyncPageRows(&batch), ValidateSyncPageBatch(&batch) })
}
