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

const (
	retainedSourceFlow = iota
	retainedSourcePlugin
	retainedSourceCount
)

const (
	poisonReasonInvalidArgument = iota
	poisonReasonPayloadTooLarge
	poisonReasonChunkTooLarge
	poisonReasonStreamBudgetExceeded
	poisonReasonCount
)

//nolint:gochecknoglobals // fixed bounded label dictionary
var retainedPoisonReasonNames = [poisonReasonCount]string{
	"invalid_argument",
	"payload_too_large",
	"chunk_too_large",
	"stream_budget_exceeded",
}

//nolint:gochecknoglobals // fixed bounded label dictionary
var retainedPoisonSourceNames = [retainedSourceCount]string{
	"flow-attribution",
	"plugin-result",
}

type retainedPoisonCounter struct {
	items atomic.Uint64
	bytes atomic.Uint64
}

//nolint:gochecknoglobals // process-global bounded Prometheus counters
var agentRetainedPoisonDrops [retainedSourceCount][poisonReasonCount]retainedPoisonCounter

func retainedPoisonDropReason(err error) (string, bool) {
	switch {
	case errors.Is(err, agentgateway.ErrStreamStatusChunkTooLarge):
		return retainedPoisonReasonNames[poisonReasonChunkTooLarge], true
	case errors.Is(err, agentgateway.ErrStreamStatusBudgetExceeded):
		return retainedPoisonReasonNames[poisonReasonStreamBudgetExceeded], true
	case status.Code(err) == codes.InvalidArgument:
		return retainedPoisonReasonNames[poisonReasonInvalidArgument], true
	case status.Code(err) == codes.ResourceExhausted && payloadTooLargeStatusMessage(status.Convert(err).Message()):
		return retainedPoisonReasonNames[poisonReasonPayloadTooLarge], true
	default:
		return "", false
	}
}

func payloadTooLargeStatusMessage(message string) bool {
	return message == "payload_too_large" ||
		strings.HasPrefix(message, "payload_too_large:") ||
		strings.Contains(message, "desc = payload_too_large")
}

func recordAgentRetainedPoisonDrop(source, reason string, items, bytes int) {
	sourceIndex := retainedSourceIndex(source)
	reasonIndex := retainedReasonIndex(reason)
	if sourceIndex < 0 || reasonIndex < 0 || items < 0 || bytes < 0 {
		return
	}

	agentRetainedPoisonDrops[sourceIndex][reasonIndex].items.Add(uint64(items))
	agentRetainedPoisonDrops[sourceIndex][reasonIndex].bytes.Add(uint64(bytes))
}

// AgentRetainedPoisonDropTotals returns bounded poison-drop counters for the
// Prometheus exporter and tests.
func AgentRetainedPoisonDropTotals(source, reason string) (uint64, uint64) {
	sourceIndex := retainedSourceIndex(source)
	reasonIndex := retainedReasonIndex(reason)
	if sourceIndex < 0 || reasonIndex < 0 {
		return 0, 0
	}

	counter := &agentRetainedPoisonDrops[sourceIndex][reasonIndex]
	return counter.items.Load(), counter.bytes.Load()
}

func resetAgentRetainedPoisonDropCounters() {
	for sourceIndex := 0; sourceIndex < retainedSourceCount; sourceIndex++ {
		for reasonIndex := 0; reasonIndex < poisonReasonCount; reasonIndex++ {
			agentRetainedPoisonDrops[sourceIndex][reasonIndex].items.Store(0)
			agentRetainedPoisonDrops[sourceIndex][reasonIndex].bytes.Store(0)
		}
	}
}

func retainedSourceIndex(source string) int {
	for index, candidate := range retainedPoisonSourceNames {
		if source == candidate {
			return index
		}
	}
	return -1
}

func retainedReasonIndex(reason string) int {
	for index, candidate := range retainedPoisonReasonNames {
		if reason == candidate {
			return index
		}
	}
	return -1
}
