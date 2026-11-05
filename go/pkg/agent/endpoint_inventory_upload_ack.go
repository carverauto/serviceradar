/*
 * Copyright 2025 Carver Automation Corporation.
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
	"encoding/json"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	"github.com/carverauto/serviceradar/proto"
)

const endpointInventoryReconcileFloorDirective = "endpoint_inventory.reconcile_floor"

type endpointInventoryGatewayDirective struct {
	ReconcileFloor bool   `json:"reconcile_floor"`
	UploadReason   string `json:"upload_reason"`
	Message        string `json:"message"`
}

// applyEndpointInventoryDirectives records the endpoint inventory reconcile
// requests a status push response carries. They are control directives: scan
// payloads themselves travel only as edge records.
func (p *PushLoop) applyEndpointInventoryDirectives(resp *proto.GatewayStatusResponse) {
	directives := endpointInventoryGatewayDirectives(resp)
	if len(directives) == 0 {
		return
	}

	cfg, err := p.endpointInventoryCommandConfig()
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to resolve endpoint inventory directive config")
		return
	}

	now := time.Now().UTC()
	for _, directive := range directives {
		reason := directive.Message
		if reason == "" {
			reason = directive.UploadReason
		}
		if err := endpointinventory.MarkServerReconcileRequested(cfg, now, reason); err != nil {
			p.logger.Warn().Err(err).Msg("Failed to record endpoint inventory reconcile directive")
		}
	}
}

func endpointInventoryGatewayDirectives(resp *proto.GatewayStatusResponse) []endpointInventoryGatewayDirective {
	if resp == nil {
		return nil
	}

	directives := make([]endpointInventoryGatewayDirective, 0, 1)
	for _, directive := range resp.GetDirectives() {
		if directive == nil || !isEndpointInventoryDirective(directive) {
			continue
		}

		payload := endpointInventoryGatewayDirective{}
		if len(directive.GetPayloadJson()) > 0 {
			if err := json.Unmarshal(directive.GetPayloadJson(), &payload); err != nil {
				continue
			}
		}
		if !payload.ReconcileFloor && directive.GetDirectiveType() != endpointInventoryReconcileFloorDirective {
			continue
		}

		directives = append(directives, payload)
	}

	return directives
}

func isEndpointInventoryDirective(directive *proto.GatewayStatusDirective) bool {
	return directive.GetServiceName() == endpointinventory.ServiceName ||
		directive.GetServiceType() == endpointinventory.ServiceType ||
		strings.HasPrefix(directive.GetDirectiveType(), "endpoint_inventory.")
}
