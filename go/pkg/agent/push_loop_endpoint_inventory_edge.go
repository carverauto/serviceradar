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
	"crypto/sha256"
	"errors"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

var errEndpointInventoryRecordTooLarge = errors.New("endpoint inventory scan exceeds the durable record body bound")

type endpointInventoryBuiltItem struct {
	record      *edgev1.EdgeRecordV1
	body        []byte
	payloadHash [32]byte
	scanPayload *endpointinventory.ScanPayload
}

type endpointInventoryEdgeQueue struct {
	lastSentHash    [32]byte
	hasLastSentHash bool
	built           *endpointInventoryBuiltItem
}

func isEndpointInventoryService(svc Service) bool {
	if svc == nil {
		return false
	}
	if _, ok := svc.(*EndpointInventorySpoolService); ok {
		return true
	}
	return svc.Name() == endpointinventory.ServiceName
}

func (p *PushLoop) edgeEndpointInventoryCapability(now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	if p == nil || p.edgeDiscoverySpool == nil {
		return nil
	}
	return p.edgeOutputGrants.current(edgerecord.EndpointInventoryContractID, now)
}

func (p *PushLoop) flushEndpointInventoryEdge(now time.Time) bool {
	if p == nil {
		return true
	}
	built := p.endpointInventoryEdge.built
	if built == nil {
		return true
	}
	if p.edgeDiscoverySpool == nil {
		return false
	}
	return p.appendEndpointInventoryBuilt(built, now)
}

func (p *PushLoop) emitEndpointInventoryEdgeStatus(
	status *proto.StatusResponse,
	capability *edgev1.EdgeSignedCapabilityV1,
	now time.Time,
) {
	if p == nil || status == nil || len(status.GetMessage()) == 0 {
		return
	}
	if capability == nil || p.edgeDiscoverySpool == nil {
		return
	}

	if p.endpointInventoryEdge.built != nil {
		if !p.appendEndpointInventoryBuilt(p.endpointInventoryEdge.built, now) {
			return
		}
	}

	payloadHash := sha256.Sum256(status.GetMessage())
	if p.endpointInventoryEdge.hasLastSentHash && p.endpointInventoryEdge.lastSentHash == payloadHash {
		return
	}

	protoScan, scanPayload, err := convertEndpointInventoryScanPayload(status.GetMessage(), p.agentID())
	if err != nil {
		p.dropEdgeTelemetry(edgeProducerEndpointInventory, edgeDropInvalidRecord, 1)
		p.logger.Warn().Err(err).Msg("Dropping endpoint inventory payload that failed edge conversion")
		p.recordEndpointInventoryEdgeTerminalDrop(payloadHash, scanPayload, err, now)
		return
	}

	claims := capability.GetProduction()
	maxRows := min(
		uint64(claims.GetMaxProjectedRowCount()),
		claims.GetMaxProjectedWriteBytes()/edgerecord.EndpointInventoryProjectedWriteBytesPerRecord,
	)
	record, body, _, err := edgeBatchRecord(
		protoScan,
		capability,
		edgerecord.EndpointInventoryScanRows(protoScan),
		maxRows,
		edgerecord.EndpointInventoryProjectedWriteBytesPerRecord,
		errEndpointInventoryRecordTooLarge,
		edgerecord.ValidateEndpointInventoryRecord,
	)
	if err != nil {
		p.dropEdgeTelemetry(edgeProducerEndpointInventory, edgeDropInvalidRecord, 1)
		p.logger.Warn().Err(err).Msg("Dropping endpoint inventory scan that cannot form an edge record")
		p.recordEndpointInventoryEdgeTerminalDrop(payloadHash, scanPayload, err, now)
		return
	}

	built := &endpointInventoryBuiltItem{
		record:      record,
		body:        body,
		payloadHash: payloadHash,
		scanPayload: scanPayload,
	}
	if !p.appendEndpointInventoryBuilt(built, now) {
		p.endpointInventoryEdge.built = built
	}
}

func (p *PushLoop) appendEndpointInventoryBuilt(built *endpointInventoryBuiltItem, now time.Time) bool {
	if _, err := p.edgeDiscoverySpool.AppendFlow(
		edgeAdmissionFlow(built.record),
		built.record.GetEventId(),
		built.body,
	); err != nil {
		if permanentSpoolRefusal(err) {
			p.dropEdgeTelemetry(edgeProducerEndpointInventory, edgeDropRefused, 1)
			p.endpointInventoryEdge.built = nil
			p.recordEndpointInventoryEdgeTerminalDrop(built.payloadHash, built.scanPayload, err, now)
			return true
		}
		p.logger.Warn().Err(err).Msg("Failed to spool endpoint inventory edge record; will retry")
		return false
	}

	p.endpointInventoryEdge.lastSentHash = built.payloadHash
	p.endpointInventoryEdge.hasLastSentHash = true
	p.endpointInventoryEdge.built = nil
	p.ackEndpointInventoryEdgeUpload(built.scanPayload, now)
	return true
}

func (p *PushLoop) recordEndpointInventoryEdgeTerminalDrop(
	payloadHash [32]byte,
	payload *endpointinventory.ScanPayload,
	cause error,
	failedAt time.Time,
) {
	p.endpointInventoryEdge.lastSentHash = payloadHash
	p.endpointInventoryEdge.hasLastSentHash = true
	if !endpointinventory.PayloadRequiresFullUpload(payload) {
		return
	}
	cfg, err := p.endpointInventoryCommandConfig()
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to load endpoint inventory config for edge upload failure")
		return
	}
	if err := endpointinventory.MarkUploadFailed(cfg, payload, failedAt, cause); err != nil &&
		!errors.Is(err, endpointinventory.ErrNoPendingUpload) {
		p.logger.Warn().Err(err).Str("scan_id", payload.ScanID).Msg("Failed to mark endpoint inventory edge upload failed")
	}
}

func (p *PushLoop) ackEndpointInventoryEdgeUpload(
	payload *endpointinventory.ScanPayload,
	uploadedAt time.Time,
) {
	if p == nil || !endpointinventory.PayloadRequiresFullUpload(payload) {
		return
	}
	cfg, err := p.endpointInventoryCommandConfig()
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to load endpoint inventory config for edge upload ack")
		return
	}
	if err := endpointinventory.MarkUploadSucceeded(cfg, payload, uploadedAt); err != nil &&
		!errors.Is(err, endpointinventory.ErrNoPendingUpload) {
		p.logger.Warn().Err(err).Str("scan_id", payload.ScanID).Msg("Failed to acknowledge endpoint inventory edge upload")
	}
}
