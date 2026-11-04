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
	"errors"
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
)

// Mapper and netprobe discovery ride standing-grant contracts
// (serviceradar.mapper.*.batch, serviceradar.netprobe.discovery.batch)
// through this producer. Conversion starts from the exact JSON payloads
// the legacy builders produced for one drain. A drain the spool has not
// yet admitted is held as the family's one pending item, its built parts
// keeping the event ids they were first built with across retries, and
// the family is not drained again until it is admitted. One update that
// cannot form a valid part is dropped alone and counted, never taking its
// drain down with it.

var (
	errDiscoveryRecordTooLarge  = errors.New("discovery update exceeds the durable record body bound")
	errDiscoveryPayloadNotArray = errors.New("discovery payload is not a JSON update array")
	errDiscoveryNoValidRecord   = errors.New("no discovery update forms a valid edge record")
)

// SetEdgeDiscoverySpool connects the mapper and netprobe discovery, workload
// identity, k8s public endpoints, endpoint inventory and bumblebee scan
// producers to the sender's one open spool. Call before Start; a nil spool
// keeps them on their legacy paths.
func (p *PushLoop) SetEdgeDiscoverySpool(sp *spool.Spool) {
	if sp == nil {
		p.edgeDiscoverySpool = nil
		return
	}
	p.edgeDiscoverySpool = sp
}

// discoveryKind selects one discovery contract family.
type discoveryKind int

const (
	discoveryMapperDevices discoveryKind = iota
	discoveryMapperInterfaces
	discoveryMapperTopology
	discoveryNetprobe
)

type discoverySpec struct {
	contractID  string
	bytesPerRow uint64
	producer    edgeProducer
	validate    func(*edgev1.EdgeRecordV1) error
	batchFor    func(updates []map[string]interface{}, agentID, partition string) proto.Message
}

func (k discoveryKind) spec() discoverySpec {
	switch k {
	case discoveryMapperInterfaces:
		return discoverySpec{
			contractID:  edgerecord.MapperInterfacesContractID,
			bytesPerRow: edgerecord.MapperInterfacesProjectedWriteBytesPerRecord,
			producer:    edgeProducerMapper,
			validate:    edgerecord.ValidateMapperInterfaceRecord,
			batchFor: func(updates []map[string]interface{}, agentID, partition string) proto.Message {
				batch := &edgev1.MapperInterfaceBatchV1{AgentId: agentID, Partition: partition}
				for _, update := range updates {
					record := mapperInterfaceRecord(update)
					if batch.GatewayId == "" {
						batch.GatewayId = record.GetGatewayId()
					}
					batch.Interfaces = append(batch.Interfaces, record)
				}
				return batch
			},
		}
	case discoveryMapperTopology:
		return discoverySpec{
			contractID:  edgerecord.MapperTopologyContractID,
			bytesPerRow: edgerecord.MapperTopologyProjectedWriteBytesPerRecord,
			producer:    edgeProducerMapper,
			validate:    edgerecord.ValidateMapperTopologyRecord,
			batchFor: func(updates []map[string]interface{}, agentID, partition string) proto.Message {
				batch := &edgev1.MapperTopologyBatchV1{AgentId: agentID, Partition: partition}
				for _, update := range updates {
					record := mapperTopologyRecord(update)
					if batch.GatewayId == "" {
						batch.GatewayId = record.GetGatewayId()
					}
					batch.Links = append(batch.Links, record)
				}
				return batch
			},
		}
	case discoveryNetprobe:
		return discoverySpec{
			contractID:  edgerecord.NetprobeDiscoveryContractID,
			bytesPerRow: edgerecord.NetprobeDiscoveryProjectedWriteBytesPerRecord,
			producer:    edgeProducerNetprobe,
			validate:    edgerecord.ValidateNetprobeDiscoveryRecord,
			batchFor: func(updates []map[string]interface{}, _, _ string) proto.Message {
				batch := &edgev1.NetprobeDiscoveryBatchV1{}
				for _, update := range updates {
					batch.Records = append(batch.Records, netprobeDiscoveryRecord(update))
				}
				return batch
			},
		}
	case discoveryMapperDevices:
		// Mapper devices is the spec below.
	}
	return discoverySpec{
		contractID:  edgerecord.MapperDevicesContractID,
		bytesPerRow: edgerecord.MapperDevicesProjectedWriteBytesPerRecord,
		producer:    edgeProducerMapper,
		validate:    edgerecord.ValidateMapperDeviceRecord,
		batchFor: func(updates []map[string]interface{}, agentID, partition string) proto.Message {
			batch := &edgev1.MapperDeviceBatchV1{AgentId: agentID, Partition: partition}
			for _, update := range updates {
				record := mapperDeviceRecord(update)
				if batch.GatewayId == "" {
					batch.GatewayId = record.GetGatewayId()
				}
				batch.Devices = append(batch.Devices, record)
			}
			return batch
		},
	}
}

func (p *PushLoop) discoveryQueue(kind discoveryKind) *discoveryEdgeQueue {
	switch kind {
	case discoveryMapperInterfaces:
		return &p.mapperInterfacesEdge
	case discoveryMapperTopology:
		return &p.mapperTopologyEdge
	case discoveryNetprobe:
		return &p.netprobeEdge
	case discoveryMapperDevices:
		// Mapper devices is the queue below.
	}
	return &p.mapperDevicesEdge
}

func (p *PushLoop) discoveryCapability(kind discoveryKind, now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	if p == nil || p.edgeDiscoverySpool == nil {
		return nil
	}
	return p.edgeOutputGrants.current(kind.spec().contractID, now)
}

// discoveryBuiltItem is one drain expanded into its spooled parts.
type discoveryBuiltItem struct {
	records []*edgev1.EdgeRecordV1
	bodies  [][]byte
	next    int
}

// discoveryEdgeQueue holds a discovery family's one drain the spool has
// not yet fully admitted. Only the push loop goroutine touches it.
type discoveryEdgeQueue struct {
	built *discoveryBuiltItem
}

func (p *PushLoop) appendDiscoveryBuilt(built *discoveryBuiltItem) bool {
	for built.next < len(built.records) {
		record := built.records[built.next]
		if _, err := p.edgeDiscoverySpool.AppendFlow(edgeAdmissionFlow(record), record.GetEventId(), built.bodies[built.next]); err != nil {
			p.logger.Warn().Err(err).Msg("Failed to spool discovery part; will retry")
			return false
		}
		built.next++
	}
	return true
}

// buildDiscoveryItem converts one drain's payloads and packs their
// updates into valid records. A head update that cannot form a valid part,
// for any reason, is dropped alone (counted) and packing continues.
func buildDiscoveryItem(
	spec discoverySpec,
	payloads [][]byte,
	capability *edgev1.EdgeSignedCapabilityV1,
	agentID, partition string,
) (built *discoveryBuiltItem, dropped int, err error) {
	updates := make([]map[string]interface{}, 0, len(payloads))
	for _, payload := range payloads {
		updates = append(updates, decodeUpdateArray(payload)...)
	}
	if len(updates) == 0 {
		return nil, 0, errDiscoveryPayloadNotArray
	}
	built = &discoveryBuiltItem{}
	for len(updates) > 0 {
		n, record, body := longestDiscoveryPrefix(spec, updates, capability, agentID, partition)
		if n == 0 {
			dropped++
			updates = updates[1:]
			continue
		}
		built.records = append(built.records, record)
		built.bodies = append(built.bodies, body)
		updates = updates[n:]
	}
	if len(built.records) == 0 {
		return nil, dropped, errDiscoveryNoValidRecord
	}
	return built, dropped, nil
}

func longestDiscoveryPrefix(
	spec discoverySpec,
	updates []map[string]interface{},
	capability *edgev1.EdgeSignedCapabilityV1,
	agentID, partition string,
) (int, *edgev1.EdgeRecordV1, []byte) {
	maxRows := discoveryMaxRows(spec, capability)
	limit := len(updates)
	if uint64(limit) > maxRows {
		limit = int(maxRows)
	}

	bestN := 0
	var bestRecord *edgev1.EdgeRecordV1
	var bestBody []byte
	lo, hi := 1, limit
	for lo <= hi {
		mid := lo + (hi-lo)/2
		batch := spec.batchFor(updates[:mid], agentID, partition)
		record, body, _, err := edgeBatchRecord(
			batch, capability, mid, maxRows, spec.bytesPerRow,
			errDiscoveryRecordTooLarge, spec.validate)
		if err == nil {
			bestN, bestRecord, bestBody = mid, record, body
			lo = mid + 1
			continue
		}
		hi = mid - 1
	}
	return bestN, bestRecord, bestBody
}

func discoveryMaxRows(spec discoverySpec, capability *edgev1.EdgeSignedCapabilityV1) uint64 {
	claims := capability.GetProduction()
	return min(uint64(claims.GetMaxProjectedRowCount()),
		claims.GetMaxProjectedWriteBytes()/spec.bytesPerRow)
}
