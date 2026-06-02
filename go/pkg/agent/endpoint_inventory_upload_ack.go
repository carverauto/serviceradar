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
	"errors"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/endpointinventory"
	"github.com/carverauto/serviceradar/proto"
)

var errGatewayStatusNotAcknowledged = errors.New("gateway did not acknowledge status push")

func (p *PushLoop) recordEndpointInventoryUploadSuccesses(statuses []*proto.GatewayServiceStatus) {
	payloads := endpointInventoryUploadPayloads(statuses)
	if len(payloads) == 0 {
		return
	}

	cfg, err := p.endpointInventoryCommandConfig()
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to resolve endpoint inventory upload ack config")
		return
	}

	now := time.Now().UTC()
	for _, payload := range payloads {
		if err := endpointinventory.MarkUploadSucceeded(cfg, &payload, now); err != nil &&
			!errors.Is(err, endpointinventory.ErrNoPendingUpload) {
			p.logger.Warn().Err(err).Str("scan_id", payload.ScanID).Msg("Failed to mark endpoint inventory upload succeeded")
		}
	}
}

func (p *PushLoop) recordEndpointInventoryUploadFailures(statuses []*proto.GatewayServiceStatus, cause error) {
	payloads := endpointInventoryUploadPayloads(statuses)
	if len(payloads) == 0 {
		return
	}

	cfg, err := p.endpointInventoryCommandConfig()
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to resolve endpoint inventory upload retry config")
		return
	}

	now := time.Now().UTC()
	for _, payload := range payloads {
		if err := endpointinventory.MarkUploadFailed(cfg, &payload, now, cause); err != nil &&
			!errors.Is(err, endpointinventory.ErrNoPendingUpload) {
			p.logger.Warn().Err(err).Str("scan_id", payload.ScanID).Msg("Failed to mark endpoint inventory upload failed")
		}
	}
}

func endpointInventoryUploadPayloads(statuses []*proto.GatewayServiceStatus) []endpointinventory.ScanPayload {
	payloads := make([]endpointinventory.ScanPayload, 0, 1)
	for _, status := range statuses {
		if status == nil ||
			status.ServiceName != endpointinventory.ServiceName ||
			status.ServiceType != endpointinventory.ServiceType ||
			len(status.Message) == 0 {
			continue
		}

		var payload endpointinventory.ScanPayload
		if err := json.Unmarshal(status.Message, &payload); err != nil {
			continue
		}
		if endpointinventory.PayloadRequiresFullUpload(&payload) {
			payloads = append(payloads, payload)
		}
	}

	return payloads
}
