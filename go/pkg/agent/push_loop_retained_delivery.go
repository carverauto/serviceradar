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

import "sync/atomic"

// retainedPoisonSource is the source label of every poison drop: flow
// attribution is the one retained-delivery stream that quarantines.
const retainedPoisonSource = "flow-attribution"

// poisonReason is why a retained window was dropped as permanently invalid.
type poisonReason int

const (
	poisonReasonInvalidArgument poisonReason = iota
	poisonReasonPayloadTooLarge
	poisonReasonCount
)

// label is the reason's Prometheus label value.
func (r poisonReason) label() string {
	return [poisonReasonCount]string{
		poisonReasonInvalidArgument: "invalid_argument",
		poisonReasonPayloadTooLarge: "payload_too_large",
	}[r]
}

type retainedPoisonCounter struct {
	items atomic.Uint64
	bytes atomic.Uint64
}

// retainedDeliveryTelemetry holds the agent's retained-delivery counters,
// which the Prometheus exporter reads. The Server owns the one instance; its
// zero value is ready to use.
type retainedDeliveryTelemetry struct {
	// flowAttributionForwarded counts FlowAttributionEvent records the edge
	// spool admitted (agent_flow_attribution_events_forwarded_total).
	flowAttributionForwarded atomic.Uint64
	// flowAttributionQuarantined counts single events that cannot fit in an
	// otherwise empty delivery window. Quarantining the poison event lets
	// later attribution records continue in order.
	flowAttributionQuarantined atomic.Uint64
	poisonDrops                [poisonReasonCount]retainedPoisonCounter
}

func (t *retainedDeliveryTelemetry) recordPoisonDrop(reason poisonReason, items, bytes int) {
	if items < 0 || bytes < 0 {
		return
	}

	counter := &t.poisonDrops[reason]
	counter.items.Add(uint64(items))
	counter.bytes.Add(uint64(bytes))
}

// poisonDropTotals returns the items and bytes dropped for one reason.
func (t *retainedDeliveryTelemetry) poisonDropTotals(reason poisonReason) (uint64, uint64) {
	counter := &t.poisonDrops[reason]
	return counter.items.Load(), counter.bytes.Load()
}
