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

import "strings"

const addonTelemetryMaxDrainPerPush = 1024

// pushAddonTelemetry drains native add-on telemetry into the telemetry queue and
// spools it under the telemetry batch grant, or holds it until one is held. The
// add-on telemetry buffer counts what it drops before a drain.
func (p *PushLoop) pushAddonTelemetry() bool {
	p.server.mu.RLock()
	buffer := p.server.addonTelemetry
	p.server.mu.RUnlock()

	if buffer == nil {
		return false
	}

	envelopes, droppedDelta, droppedTotal := buffer.drain(addonTelemetryMaxDrainPerPush)
	if droppedDelta > 0 {
		p.logger.Warn().
			Uint64("dropped_since_last", droppedDelta).
			Uint64("dropped_total", droppedTotal).
			Msg("Dropped add-on telemetry before push")
	}

	items := make([]telemetryEdgeItem, 0, len(envelopes))
	for _, envelope := range envelopes {
		items = append(items, telemetryEdgeItem{
			producerType: "addon",
			producerID:   addonTelemetryProducerID(envelope.addonID),
			batch:        envelope.batch,
		})
	}
	return p.queueAndSpoolTelemetry(edgeProducerAddonTelemetry, &p.addonTelemetryEdge, items)
}

// addonTelemetryProducerID is the host-stamped telemetry producer id of an
// envelope: its add-on instance.
func addonTelemetryProducerID(addonID string) string {
	clean := strings.TrimSpace(addonID)
	if clean == "" {
		clean = unknownTelemetrySource
	}
	return clean
}
