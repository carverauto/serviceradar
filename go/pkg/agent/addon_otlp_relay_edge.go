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
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	gproto "google.golang.org/protobuf/proto"
)

const otlpRelayDefaultMaxRows = 1024

func bindAddonOtlpRelayEdge(server *Server, p *PushLoop) {
	if server == nil || p == nil {
		return
	}

	server.mu.RLock()
	deps := server.addonOtlpRelay
	server.mu.RUnlock()

	if deps == nil {
		return
	}

	deps.bindEdge(
		p.edgeOtlpRelayTarget,
		func(reason edgeDropReason, count int, err error) {
			p.dropEdgeMetrics(edgeProducerOtlpRelay, reason, count, err)
		},
	)
}

func (p *PushLoop) edgeOtlpRelayTarget(now time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1) {
	if p == nil || p.edgeMetricsSpool == nil {
		return nil, nil
	}
	cap := p.edgeOutputGrants.current(edgerecord.OtlpRelayContractID, now)
	if cap == nil {
		return nil, nil
	}
	return p.edgeMetricsSpool, cap
}

func (p *otlpRelayPump) currentEdgeTarget(now time.Time) (edgeMetricsAppender, *edgev1.EdgeSignedCapabilityV1) {
	if p == nil || p.edgeTarget == nil {
		return nil, nil
	}
	return p.edgeTarget(now)
}

func (p *otlpRelayPump) recordEdgeDrop(reason edgeDropReason, count int, err error) {
	if p == nil || p.recordDrop == nil || count <= 0 {
		return
	}
	p.recordDrop(reason, count, err)
}

func otlpRelayCapabilityMaxRows(capability *edgev1.EdgeSignedCapabilityV1) int {
	maxRows := otlpRelayDefaultMaxRows
	if m := capability.GetProduction().GetMaxProjectedRowCount(); m > 0 && int(m) < maxRows {
		maxRows = int(m)
	}
	return maxRows
}

func otlpRelayCapabilityMaxWriteBytes(capability *edgev1.EdgeSignedCapabilityV1, maxFrameBytes int) int {
	limit := edgerecord.MaxRecordBytes
	if m := capability.GetProduction().GetMaxProjectedWriteBytes(); m > 0 && int(m) < limit {
		limit = int(m)
	}
	if maxFrameBytes > 0 && maxFrameBytes < limit {
		limit = maxFrameBytes
	}
	return limit
}

func buildOtlpRelayEdgeRecord(
	capability *edgev1.EdgeSignedCapabilityV1,
	frame *addonpb.OtlpRelayFrame,
	maxWriteBytes int,
) (edgeMetricsBuilt, error) {
	if err := edgerecord.ValidateOtlpRelayFrame(frame); err != nil {
		return edgeMetricsBuilt{}, err
	}
	payload, err := gproto.MarshalOptions{Deterministic: true}.Marshal(frame)
	if err != nil {
		return edgeMetricsBuilt{}, err
	}
	if len(payload) > maxWriteBytes {
		return edgeMetricsBuilt{}, fmt.Errorf(
			"%w: OTLP relay frame payload %d bytes exceeds max %d",
			errEdgeMetricsRecordTooLarge, len(payload), maxWriteBytes,
		)
	}
	rows := uint32(len(frame.GetBatch().GetRecords()))
	writeBytes := uint64(len(payload))
	record, err := newEdgeRecord(capability, nil, payload, rows, writeBytes)
	if err != nil {
		return edgeMetricsBuilt{}, err
	}
	if err := edgerecord.ValidateOtlpRelayRecord(record); err != nil {
		return edgeMetricsBuilt{}, err
	}
	return edgeMetricsBuilt{record: record, payload: payload}, nil
}

func validOtlpRelayTelemetryRecord(rec *addonpb.TelemetryRecord) error {
	if rec == nil {
		return fmt.Errorf("%w: nil telemetry record", edgerecord.ErrOtlpRelayFrame)
	}
	if !edgerecord.ValidOtlpRelayPayloadKind(rec.GetPayloadKind()) {
		return fmt.Errorf("%w: unsupported payload_kind %v", edgerecord.ErrOtlpRelayFrame, rec.GetPayloadKind())
	}
	if len(rec.GetPayload()) == 0 {
		return fmt.Errorf("%w: empty record payload", edgerecord.ErrOtlpRelayFrame)
	}
	return nil
}

func (p *otlpRelayPump) prepareEdgeRelayFrame(
	frame *addonpb.OtlpRelayFrame,
	capability *edgev1.EdgeSignedCapabilityV1,
) ([]edgeMetricsBuilt, int, *addonpb.OtlpRelayFrame, bool) {
	if frame == nil || frame.GetRelayId() == 0 || frame.GetBatch() == nil || len(frame.GetBatch().GetRecords()) == 0 {
		p.recordEdgeDrop(edgeDropInvalidRecord, 1, edgerecord.ErrOtlpRelayFrame)
		p.logger.Warn().
			Str("addon", p.addonID).
			Uint64("relay_id", frame.GetRelayId()).
			Msg("Skipping invalid OTLP relay frame for edge spool")
		return nil, 0, nil, false
	}

	rawRecords := frame.GetBatch().GetRecords()
	validRecords := make([]*addonpb.TelemetryRecord, 0, len(rawRecords))
	for _, rec := range rawRecords {
		if err := validOtlpRelayTelemetryRecord(rec); err != nil {
			p.recordEdgeDrop(edgeDropInvalidRecord, 1, err)
			p.logger.Warn().Err(err).
				Str("addon", p.addonID).
				Uint64("relay_id", frame.GetRelayId()).
				Msg("Skipping invalid OTLP relay record for edge spool")
			continue
		}
		validRecords = append(validRecords, rec)
	}
	if len(validRecords) == 0 {
		return nil, 0, nil, false
	}

	maxRows := otlpRelayCapabilityMaxRows(capability)
	if maxRows <= 0 {
		p.recordEdgeDrop(edgeDropInvalidRecord, len(validRecords), edgerecord.ErrProductionGrant)
		return nil, 0, nil, false
	}
	maxWriteBytes := otlpRelayCapabilityMaxWriteBytes(capability, p.maxFrameBytes)

	var (
		parts          []edgeMetricsBuilt
		totalBytes     int
		remaining      = validRecords
		source         = frame.GetBatch().GetSource()
		counters       = frame.GetBatch().GetCounters()
		gatewayRecords []*addonpb.TelemetryRecord
		countersOnEdge bool
	)

	makeFrame := func(slice []*addonpb.TelemetryRecord, partCounters *addonpb.TelemetryCounters) *addonpb.OtlpRelayFrame {
		recordsCopy := append([]*addonpb.TelemetryRecord(nil), slice...)
		return &addonpb.OtlpRelayFrame{
			RelayId: frame.GetRelayId(),
			Batch: &addonpb.TelemetryBatch{
				Source:   source,
				Records:  recordsCopy,
				Counters: partCounters,
			},
		}
	}

	for len(remaining) > 0 {
		limit := min(len(remaining), maxRows)
		countersForPart := counters
		if countersOnEdge {
			countersForPart = nil
		}

		if fullBuilt, err := buildOtlpRelayEdgeRecord(capability, makeFrame(remaining[:limit], countersForPart), maxWriteBytes); err == nil {
			parts = append(parts, fullBuilt)
			totalBytes += len(fullBuilt.payload)
			if countersForPart != nil {
				countersOnEdge = true
			}
			remaining = remaining[limit:]
			continue
		} else if limit == 1 {
			p.noteEdgeRecordDeferredToGateway(frame, remaining[0], maxWriteBytes, err)
			gatewayRecords = append(gatewayRecords, remaining[0])
			remaining = remaining[1:]
			continue
		}

		headBuilt, headErr := buildOtlpRelayEdgeRecord(capability, makeFrame(remaining[:1], countersForPart), maxWriteBytes)
		if headErr != nil {
			p.noteEdgeRecordDeferredToGateway(frame, remaining[0], maxWriteBytes, headErr)
			gatewayRecords = append(gatewayRecords, remaining[0])
			remaining = remaining[1:]
			continue
		}

		count, built := longestPrefix(limit, func(k int) (edgeMetricsBuilt, error) {
			if k == 1 {
				return headBuilt, nil
			}
			if k == limit {
				return edgeMetricsBuilt{}, errEdgeMetricsRecordTooLarge
			}
			return buildOtlpRelayEdgeRecord(capability, makeFrame(remaining[:k], countersForPart), maxWriteBytes)
		})
		if count == 0 {
			count = 1
			built = headBuilt
		}
		parts = append(parts, built)
		totalBytes += len(built.payload)
		if countersForPart != nil {
			countersOnEdge = true
		}
		remaining = remaining[count:]
	}

	var gatewayFrame *addonpb.OtlpRelayFrame
	if len(gatewayRecords) > 0 {
		var gatewayCounters *addonpb.TelemetryCounters
		if !countersOnEdge {
			gatewayCounters = counters
		}
		gatewayFrame = makeFrame(gatewayRecords, gatewayCounters)
	}
	if len(parts) == 0 && gatewayFrame == nil {
		return nil, 0, nil, false
	}
	return parts, totalBytes, gatewayFrame, true
}

func (p *otlpRelayPump) noteEdgeRecordDeferredToGateway(
	frame *addonpb.OtlpRelayFrame,
	rec *addonpb.TelemetryRecord,
	maxWriteBytes int,
	err error,
) {
	if p == nil || p.logger == nil {
		return
	}
	p.logger.Info().Err(err).
		Str("addon", p.addonID).
		Uint64("relay_id", frame.GetRelayId()).
		Int("record_bytes", len(rec.GetPayload())).
		Int("max_bytes", maxWriteBytes).
		Msg("OTLP relay record exceeds the edge record cap; sending it on the gateway status path")
}

func (p *otlpRelayPump) appendEdgeRelayParts(
	spoolApp edgeMetricsAppender,
	parts []edgeMetricsBuilt,
) ([]edgeMetricsBuilt, error) {
	for i, part := range parts {
		rows := int(part.record.GetProjectedRowCount())
		body, err := edgerecord.CanonicalRecordBytes(part.record)
		if err != nil {
			p.recordEdgeDrop(edgeDropRefused, rows, err)
			continue
		}
		if err := appendEdgeMetricsRecord(spoolApp, part.record, body); err != nil {
			if permanentSpoolRefusal(err) || errors.Is(err, spool.ErrEventIDLength) {
				p.recordEdgeDrop(sweepPermanentDropReason(err), rows, err)
				continue
			}
			return parts[i:], err
		}
	}
	return nil, nil
}
