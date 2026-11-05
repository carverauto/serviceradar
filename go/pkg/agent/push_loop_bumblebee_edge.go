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
	"crypto/sha256"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/bumblebee"
	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

type bumblebeePendingRecord struct {
	record *edgev1.EdgeRecordV1
	body   []byte
	hash   [32]byte
}

// bumblebeeEdgeRefreshInterval is how long an admitted scan is deduplicated
// before it is re-emitted, so core re-runs device resolution and risk
// contribution for an unchanged scan. A dropped scan is never re-emitted.
const bumblebeeEdgeRefreshInterval = 15 * time.Minute

type bumblebeeEdgeState struct {
	mu          sync.Mutex
	built       *bumblebeePendingRecord
	handledHash [32]byte
	hasHandled  bool
	admittedAt  time.Time
}

func (s *bumblebeeEdgeState) markHandled(hash [32]byte, admittedAt time.Time) {
	s.handledHash = hash
	s.hasHandled = true
	s.admittedAt = admittedAt
}

func (s *bumblebeeEdgeState) alreadyHandled(hash [32]byte, now time.Time) bool {
	if !s.hasHandled || s.handledHash != hash {
		return false
	}
	return s.admittedAt.IsZero() || now.Sub(s.admittedAt) < bumblebeeEdgeRefreshInterval
}

func isBumblebeeService(svc Service) bool {
	routing, ok := svc.(StatusRoutingProvider)
	return ok && strings.TrimSpace(routing.StatusServiceType()) == bumblebee.ServiceType
}

func (p *PushLoop) edgeBumblebeeCapability(now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	if p == nil || p.edgeDiscoverySpool == nil {
		return nil
	}
	return p.edgeOutputGrants.current(edgerecord.BumblebeeScanContractID, now)
}

func (p *PushLoop) bumblebeeAgentID() string {
	if p == nil || p.server == nil {
		return ""
	}
	p.server.mu.RLock()
	defer p.server.mu.RUnlock()
	if p.server.config == nil {
		return ""
	}
	return strings.TrimSpace(p.server.config.AgentID)
}

func bumblebeeMaxRows(capability *edgev1.EdgeSignedCapabilityV1) uint64 {
	claims := capability.GetProduction()
	return min(
		uint64(claims.GetMaxProjectedRowCount()),
		claims.GetMaxProjectedWriteBytes()/edgerecord.BumblebeeScanProjectedWriteBytesPerRecord,
	)
}

// routeBumblebeeEdgeStatus carries the bumblebee scan service on the edge-record
// path, which is its only path. A pending scan is appended first and keeps the
// service unpolled while the spool refuses it; without a grant the service is
// not polled either, so its spooled scan waits on disk for one.
func (p *PushLoop) routeBumblebeeEdgeStatus(
	ctx context.Context,
	svc Service,
	provider SweepStatusProvider,
	now time.Time,
) {
	p.bumblebeeEdge.mu.Lock()
	defer p.bumblebeeEdge.mu.Unlock()

	if p.bumblebeeEdge.built != nil {
		if p.edgeDiscoverySpool == nil || !p.tryFlushPendingBumblebeeEdgeLocked(now) {
			return
		}
	}

	capability := p.edgeBumblebeeCapability(now)
	if capability == nil {
		p.holdForGrant(edgeProducerBumblebee)
		return
	}

	var status *proto.StatusResponse
	var err error
	if metricProvider, ok := svc.(SweepStatusMetricPayloadProvider); ok {
		status, _, err = metricProvider.GetStatusWithMetricPayload(ctx)
	} else {
		status, err = provider.GetStatus(ctx)
	}
	if err != nil {
		p.logger.Warn().Err(err).Str("service", svc.Name()).Msg("Failed to get status from service")
		return
	}
	if status == nil {
		p.logger.Warn().Str("service", svc.Name()).Msg("Status provider returned nil response")
		return
	}
	p.forwardStatusAddonTelemetry(svc, status)
	p.emitBumblebeeEdgeLocked(status, capability, now)
}

func (p *PushLoop) tryFlushPendingBumblebeeEdgeLocked(now time.Time) bool {
	pending := p.bumblebeeEdge.built
	if pending == nil {
		return true
	}
	if _, err := p.edgeDiscoverySpool.AppendFlow(
		edgeAdmissionFlow(pending.record),
		pending.record.GetEventId(),
		pending.body,
	); err != nil {
		if permanentSpoolRefusal(err) {
			p.dropEdgeMetrics(edgeProducerBumblebee, edgeDropRefused, 1, err)
			p.bumblebeeEdge.markHandled(pending.hash, time.Time{})
			p.bumblebeeEdge.built = nil
			return true
		}
		p.logger.Warn().
			Err(err).
			Str("contract_id", edgerecord.BumblebeeScanContractID).
			Msg("Edge spool still backpressured for bumblebee scan; keeping bumblebee spool polling paused")
		return false
	}
	p.bumblebeeEdge.markHandled(pending.hash, now)
	p.bumblebeeEdge.built = nil
	return true
}

func (p *PushLoop) emitBumblebeeEdgeLocked(
	status *proto.StatusResponse,
	capability *edgev1.EdgeSignedCapabilityV1,
	now time.Time,
) {
	if status == nil || len(status.GetMessage()) == 0 {
		return
	}
	hash := sha256.Sum256(status.GetMessage())
	if p.bumblebeeEdge.alreadyHandled(hash, now) {
		return
	}

	scan, err := bumblebeeScanPayloadFromJSON(status.GetMessage(), p.bumblebeeAgentID())
	if err != nil {
		p.dropEdgeMetrics(edgeProducerBumblebee, edgeDropInvalidRecord, 1, err)
		p.bumblebeeEdge.markHandled(hash, time.Time{})
		return
	}

	rows := int(edgerecord.BumblebeeScanRows(scan))
	maxRows := bumblebeeMaxRows(capability)
	record, body, _, err := edgeBatchRecord(
		scan,
		capability,
		rows,
		maxRows,
		edgerecord.BumblebeeScanProjectedWriteBytesPerRecord,
		errDiscoveryRecordTooLarge,
		edgerecord.ValidateBumblebeeScanRecord,
	)
	if err != nil {
		p.dropEdgeMetrics(edgeProducerBumblebee, edgeDropInvalidRecord, 1, err)
		p.bumblebeeEdge.markHandled(hash, time.Time{})
		return
	}

	if _, err := p.edgeDiscoverySpool.AppendFlow(
		edgeAdmissionFlow(record),
		record.GetEventId(),
		body,
	); err != nil {
		if permanentSpoolRefusal(err) {
			p.dropEdgeMetrics(edgeProducerBumblebee, edgeDropRefused, 1, err)
			p.bumblebeeEdge.markHandled(hash, time.Time{})
			return
		}
		p.bumblebeeEdge.built = &bumblebeePendingRecord{
			record: record,
			body:   body,
			hash:   hash,
		}
		p.logger.Warn().
			Err(err).
			Str("contract_id", edgerecord.BumblebeeScanContractID).
			Msg("Edge spool could not admit bumblebee scan; pausing bumblebee spool polling until admitted")
		return
	}

	p.bumblebeeEdge.markHandled(hash, now)
}
