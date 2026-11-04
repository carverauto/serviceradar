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
	"strings"
	"time"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/proto"
)

var errK8sPublicEndpointsRecordTooLarge = errors.New("k8s public endpoints snapshot exceeds the durable record body bound")

type k8sPublicEndpointsBuiltItem struct {
	record  *edgev1.EdgeRecordV1
	body    []byte
	hash    [32]byte
	hasHash bool
}

type k8sPublicEndpointsEdgeQueue struct {
	built        *k8sPublicEndpointsBuiltItem
	lastSentHash [32]byte
	hasLastSent  bool
}

func (p *PushLoop) edgeK8sPublicEndpointsCapability(now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	if p == nil || p.edgeDiscoverySpool == nil {
		return nil
	}
	return p.edgeOutputGrants.current(edgerecord.K8sPublicEndpointsContractID, now)
}

func isK8sPublicEndpointsService(svc Service) bool {
	if svc == nil {
		return false
	}
	if strings.TrimSpace(svc.Name()) == K8sPublicEndpointsServiceName {
		return true
	}
	if routing, ok := svc.(StatusRoutingProvider); ok {
		return strings.TrimSpace(routing.StatusServiceType()) == K8sPublicEndpointsServiceType
	}
	return false
}

func (p *PushLoop) flushPendingK8sPublicEndpointsEdge() bool {
	q := &p.k8sPublicEndpointsEdge
	if q.built == nil {
		return true
	}
	if !p.appendK8sPublicEndpointsBuilt(q.built) {
		return false
	}
	if q.built.hasHash {
		q.lastSentHash = q.built.hash
		q.hasLastSent = true
	}
	q.built = nil
	return true
}

func (p *PushLoop) appendK8sPublicEndpointsBuilt(built *k8sPublicEndpointsBuiltItem) bool {
	if built == nil || built.record == nil {
		return true
	}
	if _, err := p.edgeDiscoverySpool.AppendFlow(
		edgeAdmissionFlow(built.record),
		built.record.GetEventId(),
		built.body,
	); err != nil {
		p.logger.Warn().Err(err).Msg("Failed to spool k8s public endpoints snapshot; will retry")
		return false
	}
	return true
}

func (p *PushLoop) spoolK8sPublicEndpointsStatus(
	statusResp *proto.StatusResponse,
	capability *edgev1.EdgeSignedCapabilityV1,
	cfg *ServerConfig,
) {
	if statusResp == nil || !statusResp.GetAvailable() || len(statusResp.GetMessage()) == 0 {
		return
	}

	sum := sha256.Sum256(statusResp.GetMessage())
	q := &p.k8sPublicEndpointsEdge
	if q.hasLastSent && q.lastSentHash == sum {
		return
	}

	agentID := ""
	if cfg != nil {
		agentID = cfg.AgentID
	}

	snap, err := k8sPublicEndpointsSnapshotFromJSON(statusResp.GetMessage(), agentID)
	if err != nil {
		p.dropEdgeTelemetry(edgeProducerK8sPublicEndpoints, edgeDropInvalidRecord, 1)
		p.logger.Warn().Err(err).Msg("Dropping k8s public endpoints snapshot that cannot be decoded")
		return
	}

	record, body, err := buildK8sPublicEndpointsEdgeRecord(snap, capability)
	if err != nil {
		p.dropEdgeTelemetry(edgeProducerK8sPublicEndpoints, edgeDropInvalidRecord, 1)
		p.logger.Warn().Err(err).Msg("Dropping k8s public endpoints snapshot that cannot form an edge record")
		return
	}

	built := &k8sPublicEndpointsBuiltItem{
		record:  record,
		body:    body,
		hash:    sum,
		hasHash: true,
	}
	if p.appendK8sPublicEndpointsBuilt(built) {
		q.lastSentHash = sum
		q.hasLastSent = true
		return
	}
	q.built = built
}

func buildK8sPublicEndpointsEdgeRecord(
	snap *edgev1.K8SPublicEndpointsSnapshotV1,
	capability *edgev1.EdgeSignedCapabilityV1,
) (*edgev1.EdgeRecordV1, []byte, error) {
	rows := edgerecord.K8sPublicEndpointsSnapshotRows(snap)
	maxRows := k8sPublicEndpointsMaxRows(capability)
	record, body, _, err := edgeBatchRecord(
		snap,
		capability,
		rows,
		maxRows,
		edgerecord.K8sPublicEndpointsProjectedWriteBytesPerRecord,
		errK8sPublicEndpointsRecordTooLarge,
		edgerecord.ValidateK8sPublicEndpointsRecord,
	)
	return record, body, err
}

func k8sPublicEndpointsMaxRows(capability *edgev1.EdgeSignedCapabilityV1) uint64 {
	claims := capability.GetProduction()
	return min(
		uint64(claims.GetMaxProjectedRowCount()),
		claims.GetMaxProjectedWriteBytes()/edgerecord.K8sPublicEndpointsProjectedWriteBytesPerRecord,
	)
}
