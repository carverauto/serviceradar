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
	"strings"
	"time"
)

const pluginSignalTelemetryMaxDrainPerPush = 1024

// pushPluginSignals drains plugin telemetry signals into the telemetry queue and
// spools them under the telemetry batch grant. The plugin manager's signal
// buffer drops when full, so signals are drained into the bounded queue even
// without a grant; overflow while waiting for one is counted as awaiting_grant.
func (p *PushLoop) pushPluginSignals() bool {
	p.server.mu.RLock()
	pluginManager := p.server.pluginManager
	p.server.mu.RUnlock()

	if pluginManager == nil {
		return false
	}

	signals := pluginManager.DrainSignals(pluginSignalTelemetryMaxDrainPerPush)
	items := make([]telemetryEdgeItem, 0, len(signals))
	for _, signal := range signals {
		items = append(items, telemetryEdgeItem{
			producerType: "plugin",
			producerID:   pluginTelemetryProducerID(signal),
			batch:        signal.Batch,
		})
	}
	return p.queueAndSpoolTelemetry(edgeProducerPluginTelemetry, &p.pluginTelemetryEdge, items)
}

// pluginTelemetryProducerID is the host-stamped telemetry producer id of a
// signal: its assignment, else its plugin.
func pluginTelemetryProducerID(signal PluginSignalTelemetry) string {
	clean := strings.TrimSpace(signal.AssignmentID)
	if clean == "" {
		clean = strings.TrimSpace(signal.PluginID)
	}
	if clean == "" {
		clean = unknownTelemetrySource
	}
	return clean
}

// queueAndSpoolTelemetry queues drained telemetry items and spools the queue
// under the telemetry batch grant, or holds it until one is held.
func (p *PushLoop) queueAndSpoolTelemetry(producer edgeProducer, queue *telemetryEdgeQueue, items []telemetryEdgeItem) bool {
	capability := p.edgeTelemetryCapability(time.Now())
	reason := edgeDropRetryBufferFull
	if capability == nil {
		reason = edgeDropAwaitingGrant
	}
	if dropped := queue.enqueue(items); dropped > 0 {
		p.dropEdgeTelemetry(producer, reason, dropped)
	}
	if capability == nil {
		p.holdForGrant(producer)
		return false
	}
	return p.spoolTelemetry(producer, queue, capability)
}
