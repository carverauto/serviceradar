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
	"sync"
	"time"

	gproto "google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	"github.com/carverauto/serviceradar/proto"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// edgeOutputGrantDeliveryMargin is how long before its expiry a standing grant
// stops being used for new records. A record must still be inside its grant's
// window when the gateway admits it, so the margin leaves every record time to be
// delivered; core re-issues grants long before this point.
const edgeOutputGrantDeliveryMargin = time.Hour

var errInvalidEdgeOutputGrant = errors.New("invalid edge output grant")

// edgeOutputGrants holds the standing output grants of the last applied agent
// config, one per output contract. Each config response replaces the whole set,
// so an empty list withdraws every grant. Grants are not persisted: after a
// restart producers hold their data until the first config arrives, which
// enrollment fetches before the first push.
type edgeOutputGrants struct {
	mu     sync.RWMutex
	grants map[string]*edgev1.EdgeSignedCapabilityV1 // by contract id
}

// replace installs the valid grants of a config response and returns why each
// refused entry was refused. A refused entry withdraws that contract's grant.
func (g *edgeOutputGrants) replace(agentID string, entries []*proto.EdgeOutputGrant, now time.Time) []error {
	next := make(map[string]*edgev1.EdgeSignedCapabilityV1, len(entries))
	var refused []error
	for _, entry := range entries {
		capability, err := validateEdgeOutputGrant(agentID, entry, now.UnixNano())
		if err != nil {
			refused = append(refused, err)
			continue
		}
		if _, dup := next[entry.GetContractId()]; dup {
			refused = append(refused, fmt.Errorf("%w: duplicate grant for %s", errInvalidEdgeOutputGrant, entry.GetContractId()))
			delete(next, entry.GetContractId())
			continue
		}
		next[entry.GetContractId()] = capability
	}

	g.mu.Lock()
	g.grants = next
	g.mu.Unlock()
	return refused
}

// current is the grant a producer may emit a new record of contractID under at
// now, or nil when there is none: no grant, not yet valid, or inside the delivery
// margin before its expiry.
func (g *edgeOutputGrants) current(contractID string, now time.Time) *edgev1.EdgeSignedCapabilityV1 {
	g.mu.RLock()
	capability := g.grants[contractID]
	g.mu.RUnlock()
	if capability == nil {
		return nil
	}
	ns := now.UnixNano()
	if ns < capability.GetNotBeforeUnixNano() ||
		ns >= capability.GetExpiresAtUnixNano()-int64(edgeOutputGrantDeliveryMargin) {
		return nil
	}
	return capability
}

// validateEdgeOutputGrant is the intake gate of one standing grant: a structurally
// valid production capability whose claims name the entry's contract, this agent
// as origin and producer, and the durable bulk lane, and that has not expired.
// Signatures are verified by the gateway, as for sweep leases.
func validateEdgeOutputGrant(agentID string, entry *proto.EdgeOutputGrant, nowUnixNano int64) (*edgev1.EdgeSignedCapabilityV1, error) {
	var capability edgev1.EdgeSignedCapabilityV1
	if err := gproto.Unmarshal(entry.GetProductionCapability(), &capability); err != nil {
		return nil, fmt.Errorf("%w: %s: decode: %w", errInvalidEdgeOutputGrant, entry.GetContractId(), err)
	}
	if err := edgerecord.ValidateCapability(&capability, edgev1.EdgeCapabilityPurpose_EDGE_CAPABILITY_PURPOSE_PRODUCTION); err != nil {
		return nil, fmt.Errorf("%w: %s: %w", errInvalidEdgeOutputGrant, entry.GetContractId(), err)
	}

	claims := capability.GetProduction()
	var reason string
	switch {
	case claims.GetContractId() != entry.GetContractId() || claims.GetContractVersion() != entry.GetContractVersion():
		reason = "claims name another contract"
	case string(claims.GetOriginPrincipalId()) != agentID || string(claims.GetProducerInstanceId()) != agentID:
		reason = "claims name another agent"
	case claims.GetOriginKind() != edgev1.EdgeOriginKind_EDGE_ORIGIN_KIND_AGENT:
		reason = "origin is not an agent"
	case claims.GetRouteProfile() != edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1 ||
		claims.GetTrafficClass() != edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_BULK:
		reason = "lane is not durable bulk"
	case nowUnixNano >= capability.GetExpiresAtUnixNano():
		reason = "grant window has ended"
	default:
		return &capability, nil
	}
	return nil, fmt.Errorf("%w: %s: %s", errInvalidEdgeOutputGrant, entry.GetContractId(), reason)
}

// applyEdgeOutputGrants installs the grants of a config response. It runs for
// every applied response, so a withdrawal takes effect immediately.
func (p *PushLoop) applyEdgeOutputGrants(configResp *proto.AgentConfigResponse) {
	// Without an agent identity no grant can name this agent, so every entry is
	// refused and any installed grant is withdrawn.
	var agentID string
	if p.server != nil {
		p.server.mu.RLock()
		if p.server.config != nil {
			agentID = p.server.config.AgentID
		}
		p.server.mu.RUnlock()
	}

	for _, err := range p.edgeOutputGrants.replace(agentID, configResp.GetEdgeOutputGrants(), time.Now()) {
		p.logger.Warn().Err(err).Msg("Refused edge output grant")
	}
}
