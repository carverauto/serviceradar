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

// Package agent - flow attribution forwarding (Option A).
//
// The netprobe sidecar emits FlowAttributionEvent records on its
// flowEvents channel. This file drains those events on each push
// loop tick and forwards them to the agent-gateway inside the existing
// GatewayServiceStatus envelope, keyed by Source="flow-attribution".
//
// The core-side 5-tuple join consumer reads these batches and pairs
// them with AttributedFlowMessage records published by the host-slice
// flow collector on `flow.host-slice.<agent_id>`.
//
// Partition guard (B-4 defeater): the agent does NOT populate any
// partition field inside the batch payload. The cert-derived
// partition_id attached at the agent-gateway is the only value used
// by core; the envelope's Partition field is informational only.
package agent

import (
	"context"
	"sync/atomic"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/proto"
	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
	gproto "google.golang.org/protobuf/proto"
)

const (
	// FlowAttributionServiceName is the service_name used on
	// GatewayServiceStatus envelopes carrying flow-attribution batches.
	FlowAttributionServiceName = "flow-attribution"

	// FlowAttributionServiceType identifies the envelope as originating
	// from the passive netprobe sidecar's flow-attribution stream.
	FlowAttributionServiceType = "passive-netprobe"

	// FlowAttributionSource is the GatewayServiceStatus.Source
	// discriminator used to route batches to the core-elx
	// FlowAttributionRouter / FlowJoinCache.
	FlowAttributionSource = "flow-attribution"

	// flowAttributionMaxDrainPerPush bounds the number of
	// FlowAttributionEvents drained per push loop tick. Keeps the
	// status push payload size predictable.
	flowAttributionMaxDrainPerPush = 256
)

// agentFlowAttributionEventsForwardedTotal counts the number of
// FlowAttributionEvent records the agent has successfully forwarded
// to the gateway, surfaced as
// `agent_flow_attribution_events_forwarded_total` by the Prometheus
// exporter.
//
//nolint:gochecknoglobals // process-global Prometheus counter
var agentFlowAttributionEventsForwardedTotal atomic.Uint64

// AgentFlowAttributionEventsForwardedTotal returns the current value
// of the agent-side forwarded-events counter. Exposed for the
// Prometheus exporter and tests.
func AgentFlowAttributionEventsForwardedTotal() uint64 {
	return agentFlowAttributionEventsForwardedTotal.Load()
}

// resetAgentFlowAttributionEventsForwardedTotal is exposed for tests.
func resetAgentFlowAttributionEventsForwardedTotal() {
	agentFlowAttributionEventsForwardedTotal.Store(0)
}

// pushFlowAttribution drains buffered FlowAttributionEvents from the
// netprobe sidecar, packs them into a FlowAttributionEventBatch, and
// streams the batch to the agent-gateway as a single
// GatewayServiceStatus with Source=FlowAttributionSource. Returns
// true if a batch was sent.
//
// Returns false when:
//   - the netprobe sidecar is not attached (e.g. host-network
//     visibility disabled);
//   - no events were available to drain;
//   - marshaling or transport failed (errors are logged).
func (p *PushLoop) pushFlowAttribution(ctx context.Context) bool {
	p.server.mu.RLock()
	netprobeSidecar := p.server.netprobeSidecar
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()

	if netprobeSidecar == nil {
		return false
	}

	batchStart := time.Now().UTC()
	events := netprobeSidecar.DrainFlowAttributionEvents(flowAttributionMaxDrainPerPush)
	if len(events) == 0 {
		return false
	}
	batchEnd := time.Now().UTC()

	// Observe the cumulative drop counter; commit the baseline only after
	// a successful StreamStatus ack so a transport failure doesn't lose
	// the delta — the next push will replay it.
	cumulativeDropped, dropped := observeFlowAttributionDropped(netprobeSidecar)

	gatewayID := p.gateway.GetGatewayID()

	status, messageBytes, err := buildFlowAttributionGatewayStatus(
		events,
		batchStart,
		batchEnd,
		dropped,
		agentID,
		gatewayID,
		partition,
		kvStoreID,
	)
	if err != nil {
		p.logger.Error().Err(err).
			Int("event_count", len(events)).
			Msg("Failed to marshal flow attribution batch")
		return false
	}

	runtimeMetadata := currentRuntimeMetadata()
	chunk := &proto.GatewayStatusChunk{
		Services:    []*proto.GatewayServiceStatus{status},
		GatewayId:   gatewayID,
		AgentId:     agentID,
		Timestamp:   time.Now().UnixNano(),
		Partition:   partition,
		SourceIp:    p.getSourceIP(),
		Version:     runtimeMetadata.Version,
		Hostname:    runtimeMetadata.Hostname,
		Os:          runtimeMetadata.Os,
		Arch:        runtimeMetadata.Arch,
		ChunkIndex:  0,
		TotalChunks: 1,
		IsFinal:     true,
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	resp, err := p.gateway.StreamStatus(pushCtx, []*proto.GatewayStatusChunk{chunk})
	if err != nil {
		p.logger.Error().Err(err).
			Int("event_count", len(events)).
			Msg("Failed to stream flow attribution batch to gateway")
		return false
	}

	if !resp.Received {
		p.logger.Warn().
			Int("event_count", len(events)).
			Msg("Gateway did not acknowledge flow attribution batch")
		return false
	}

	agentFlowAttributionEventsForwardedTotal.Add(uint64(len(events)))

	// Gateway acked — safe to advance the dropped-counter baseline now.
	// On any earlier `return false`, the baseline stays unmoved so the
	// next push replays the unreported delta.
	commitFlowAttributionDropped(cumulativeDropped)

	p.logger.Info().
		Int("event_count", len(events)).
		Int("message_bytes", len(messageBytes)).
		Uint32("dropped_since_last", dropped).
		Msg("Streamed flow attribution batch to gateway")

	return true
}

// buildFlowAttributionGatewayStatus packs the drained events into a
// FlowAttributionEventBatch, marshals it, and wraps the bytes in a
// GatewayServiceStatus envelope. Pure / no IO so it can be unit-tested
// without spinning up a real gateway client.
//
// The batch deliberately carries NO partition field — core uses the
// cert-derived partition from the gateway envelope. The envelope's
// Partition is informational only.
func buildFlowAttributionGatewayStatus(
	events []*netprobepb.FlowAttributionEvent,
	batchStart, batchEnd time.Time,
	droppedSinceLast uint32,
	agentID, gatewayID, partition, kvStoreID string,
) (*proto.GatewayServiceStatus, []byte, error) {
	// Always include the events field (empty repeated is preserved by
	// proto.Marshal automatically); never omit conditionally.
	batch := &netprobepb.FlowAttributionEventBatch{
		Events:             events,
		BatchStartUnixNano: batchStart.UnixNano(),
		BatchEndUnixNano:   batchEnd.UnixNano(),
		DroppedSinceLast:   droppedSinceLast,
	}

	messageBytes, err := gproto.Marshal(batch)
	if err != nil {
		return nil, nil, err
	}

	status := &proto.GatewayServiceStatus{
		ServiceName:  FlowAttributionServiceName,
		Available:    true,
		Message:      messageBytes,
		ServiceType:  FlowAttributionServiceType,
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       FlowAttributionSource,
		KvStoreId:    kvStoreID,
	}
	return status, messageBytes, nil
}

// observeFlowAttributionDropped reads the cumulative drop counter from
// the netprobe sidecar's IPC client and returns (cumulative, delta
// since the previous successful push). It does NOT advance the
// baseline — callers must invoke commitFlowAttributionDropped with the
// returned cumulative value only after the gateway has acked the batch.
// A transport failure leaves the baseline unmoved so the next push
// replays the unreported delta.
//
// Tracked per-process; resets across agent restarts but is consistent
// with the rest of the agent's counter conventions.
func observeFlowAttributionDropped(s *agentnetprobe.Sidecar) (cumulative uint64, delta uint32) {
	cumulative = s.DroppedFlowAttributionEvents()
	prev := lastDroppedFlowAttribution.Load()
	if cumulative < prev {
		// Counter wrapped or client was replaced. Treat the current
		// value as the delta and let the commit reset the baseline.
		return cumulative, clampToUint32(cumulative)
	}
	return cumulative, clampToUint32(cumulative - prev)
}

// commitFlowAttributionDropped advances the dropped-counter baseline
// after a successful gateway ack. Idempotent: a second commit with the
// same cumulative value is a no-op via CompareAndSwap semantics.
func commitFlowAttributionDropped(cumulative uint64) {
	// Plain Store is sufficient — only one push goroutine reaches here
	// at a time per agent, and a later observe will pick up further
	// drops naturally.
	lastDroppedFlowAttribution.Store(cumulative)
}

// lastDroppedFlowAttribution holds the previously-observed cumulative
// drop count so the next batch can publish a delta. Package-level
// because the counter on the netprobe client is also process-global.
//
//nolint:gochecknoglobals // process-global baseline for cumulative-counter delta
var lastDroppedFlowAttribution atomic.Uint64

func clampToUint32(v uint64) uint32 {
	const maxU32 uint64 = 1<<32 - 1
	if v > maxU32 {
		return uint32(maxU32)
	}
	return uint32(v)
}
