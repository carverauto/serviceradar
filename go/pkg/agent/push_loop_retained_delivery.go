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
	"strings"
	"sync/atomic"

	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// retainedSource is the retained-delivery stream a poison drop came from.
type retainedSource int

const (
	retainedSourceFlow retainedSource = iota
	retainedSourcePlugin
	retainedSourceCount
)

// label is the source's Prometheus label value.
func (s retainedSource) label() string {
	return [retainedSourceCount]string{
		retainedSourceFlow:   "flow-attribution",
		retainedSourcePlugin: "plugin-result",
	}[s]
}

// poisonReason is why a retained window was dropped as permanently invalid.
type poisonReason int

const (
	poisonReasonInvalidArgument poisonReason = iota
	poisonReasonPayloadTooLarge
	poisonReasonChunkTooLarge
	poisonReasonStreamBudgetExceeded
	poisonReasonCount
)

// label is the reason's Prometheus label value.
func (r poisonReason) label() string {
	return [poisonReasonCount]string{
		poisonReasonInvalidArgument:      "invalid_argument",
		poisonReasonPayloadTooLarge:      "payload_too_large",
		poisonReasonChunkTooLarge:        "chunk_too_large",
		poisonReasonStreamBudgetExceeded: "stream_budget_exceeded",
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
	// flowAttributionForwarded counts FlowAttributionEvent records the gateway
	// acknowledged (agent_flow_attribution_events_forwarded_total).
	flowAttributionForwarded atomic.Uint64
	// flowAttributionQuarantined counts single events that cannot fit in an
	// otherwise empty delivery window. Quarantining the poison event lets
	// later attribution records continue in order.
	flowAttributionQuarantined atomic.Uint64
	poisonDrops                [retainedSourceCount][poisonReasonCount]retainedPoisonCounter
}

func retainedPoisonDropReason(err error) (poisonReason, bool) {
	switch {
	case errors.Is(err, agentgateway.ErrStreamStatusChunkTooLarge):
		return poisonReasonChunkTooLarge, true
	case errors.Is(err, agentgateway.ErrStreamStatusBudgetExceeded):
		return poisonReasonStreamBudgetExceeded, true
	case status.Code(err) == codes.InvalidArgument:
		return poisonReasonInvalidArgument, true
	case status.Code(err) == codes.ResourceExhausted && payloadTooLargeStatusMessage(status.Convert(err).Message()):
		return poisonReasonPayloadTooLarge, true
	default:
		return 0, false
	}
}

func payloadTooLargeStatusMessage(message string) bool {
	return message == "payload_too_large" ||
		strings.HasPrefix(message, "payload_too_large:") ||
		strings.Contains(message, "desc = payload_too_large")
}

func (t *retainedDeliveryTelemetry) recordPoisonDrop(source retainedSource, reason poisonReason, items, bytes int) {
	if items < 0 || bytes < 0 {
		return
	}

	counter := &t.poisonDrops[source][reason]
	counter.items.Add(uint64(items))
	counter.bytes.Add(uint64(bytes))
}

// poisonDropTotals returns the items and bytes dropped for one source and
// reason.
func (t *retainedDeliveryTelemetry) poisonDropTotals(source retainedSource, reason poisonReason) (uint64, uint64) {
	counter := &t.poisonDrops[source][reason]
	return counter.items.Load(), counter.bytes.Load()
}
