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
	"time"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// EdgeRecordTrustSnapshot returns immutable verification policy received through
// authenticated configuration. Nil means producers must retain work and retry.
func (p *PushLoop) EdgeRecordTrustSnapshot() *edgerecord.TrustSnapshot {
	return p.edgeRecordTrust.Load()
}

// Full configuration replaces the entire policy. NotModified is handled before
// this boundary and retains its installed snapshot; the server's version hash
// covers all key statuses and authority fences, not just output grant bytes.
func (p *PushLoop) applyEdgeRecordTrust(response *proto.AgentConfigResponse, sequence uint64) {
	snapshot, err := edgerecord.ParseTrustDocument(response.GetEdgeRecordTrustDocument(), []byte(p.edgeAuthenticatedAgentID()), sequence)
	if err != nil {
		p.edgeRecordTrust.Store(nil)
		if len(response.GetEdgeRecordTrustDocument()) != 0 {
			p.logger.Warn().Err(err).Msg("Edge record verification policy unavailable; retaining producer work")
		}
		return
	}
	p.edgeRecordTrust.Store(snapshot)
}

func (p *PushLoop) edgeAuthenticatedAgentID() string {
	if p.server == nil {
		return ""
	}
	p.server.mu.RLock()
	defer p.server.mu.RUnlock()
	if p.server.config == nil {
		return ""
	}
	return p.server.config.AgentID
}

func (p *PushLoop) currentEdgeOutputGrant(contract string, now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	if p.EdgeRecordTrustSnapshot() == nil {
		return nil
	}
	return p.edgeOutputGrants.current(contract, now)
}
