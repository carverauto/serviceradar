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
	"sync/atomic"

	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
)

const defaultAddonTelemetryQueueSize = 1024

type addonTelemetryEnvelope struct {
	addonID string
	batch   *addonpb.TelemetryBatch
}

type addonTelemetryBuffer struct {
	queue        chan addonTelemetryEnvelope
	droppedDelta atomic.Uint64
	droppedTotal atomic.Uint64
}

func newAddonTelemetryBuffer(capacity int) *addonTelemetryBuffer {
	if capacity <= 0 {
		capacity = defaultAddonTelemetryQueueSize
	}
	return &addonTelemetryBuffer{
		queue: make(chan addonTelemetryEnvelope, capacity),
	}
}

func (b *addonTelemetryBuffer) enqueue(addonID string, batch *addonpb.TelemetryBatch) {
	if b == nil || batch == nil {
		return
	}

	select {
	case b.queue <- addonTelemetryEnvelope{addonID: addonID, batch: batch}:
	default:
		b.droppedDelta.Add(1)
		b.droppedTotal.Add(1)
	}
}

func (b *addonTelemetryBuffer) drain(max int) ([]addonTelemetryEnvelope, uint64, uint64) {
	if b == nil {
		return nil, 0, 0
	}
	if max <= 0 {
		max = len(b.queue)
	}

	envelopes := make([]addonTelemetryEnvelope, 0, max)
	for len(envelopes) < max {
		select {
		case envelope := <-b.queue:
			envelopes = append(envelopes, envelope)
		default:
			return envelopes, b.droppedDelta.Swap(0), b.droppedTotal.Load()
		}
	}

	return envelopes, b.droppedDelta.Swap(0), b.droppedTotal.Load()
}

func (s *Server) handleAddonTelemetry(addonID string, batch *addonpb.TelemetryBatch) {
	if s == nil {
		return
	}
	s.addonTelemetry.enqueue(addonID, batch)
}
