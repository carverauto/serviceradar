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
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/proto"
	gproto "google.golang.org/protobuf/proto"
)

const (
	pluginSignalTelemetryServiceName     = "plugin-telemetry"
	pluginSignalTelemetryServiceType     = "plugin"
	pluginSignalTelemetrySourcePrefix    = "plugin:"
	pluginSignalTelemetryMaxDrainPerPush = 1024
)

func (p *PushLoop) pushPluginSignals(ctx context.Context) bool {
	p.server.mu.RLock()
	pluginManager := p.server.pluginManager
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()

	if pluginManager == nil {
		return false
	}

	signals := pluginManager.DrainSignals(pluginSignalTelemetryMaxDrainPerPush)

	// One path per producer: while the agent holds the telemetry standing
	// grant, batches are spooled as durable records and never also sent on
	// the legacy status path. Without it, items the spool admitted no part
	// of go back on the legacy path.
	if capability := p.edgeTelemetryCapability(time.Now()); capability != nil {
		items := make([]telemetryEdgeItem, 0, len(signals))
		for _, signal := range signals {
			items = append(items, telemetryEdgeItem{
				producerType: "plugin",
				producerID:   pluginTelemetryProducerID(signal),
				batch:        signal.Batch,
				signal:       &signal,
			})
		}
		if dropped := p.pluginTelemetryEdge.enqueue(items); dropped > 0 {
			p.dropEdgeTelemetry(edgeProducerPluginTelemetry, edgeDropRetryBufferFull, dropped)
		}
		return p.spoolTelemetry(edgeProducerPluginTelemetry, &p.pluginTelemetryEdge, capability)
	}

	taken := p.pluginTelemetryEdge.take()
	queued := make([]PluginSignalTelemetry, 0, len(taken))
	for _, item := range taken {
		if item.signal != nil {
			queued = append(queued, *item.signal)
		}
	}
	signals = append(queued, signals...)
	if len(signals) == 0 {
		return false
	}
	// Signals the chunk build below skips (unmarshalable or oversized) are
	// dropped for good, as before; signals that made a chunk but could not
	// be delivered return to the edge queue for the next cycle.
	var chunkedSignals []PluginSignalTelemetry
	restoreUndelivered := func() {
		items := make([]telemetryEdgeItem, 0, len(chunkedSignals))
		for _, signal := range chunkedSignals {
			items = append(items, telemetryEdgeItem{
				producerType: "plugin",
				producerID:   pluginTelemetryProducerID(signal),
				batch:        signal.Batch,
				signal:       &signal,
			})
		}
		if dropped := p.pluginTelemetryEdge.restore(items); dropped > 0 {
			p.dropEdgeTelemetry(edgeProducerPluginTelemetry, edgeDropRetryBufferFull, dropped)
		}
	}

	gatewayID := p.gateway.GetGatewayID()
	runtimeMetadata := currentRuntimeMetadata()
	sourceIP := p.getSourceIP()
	chunks := make([]*proto.GatewayStatusChunk, 0, len(signals))

	for _, signal := range signals {
		status, messageByteCount, err := buildPluginSignalGatewayStatus(signal, agentID, gatewayID, partition, kvStoreID)
		if err != nil {
			p.logger.Warn().Err(err).Str("assignment_id", signal.AssignmentID).Msg("Skipping plugin telemetry batch")
			continue
		}
		if messageByteCount > addonTelemetryMaxBatchMessageBytes {
			p.logger.Warn().
				Str("assignment_id", signal.AssignmentID).
				Int("message_bytes", messageByteCount).
				Int("max_bytes", addonTelemetryMaxBatchMessageBytes).
				Msg("Skipping oversized plugin telemetry batch")
			continue
		}

		chunkedSignals = append(chunkedSignals, signal)
		chunks = append(chunks, &proto.GatewayStatusChunk{
			Services:  []*proto.GatewayServiceStatus{status},
			GatewayId: gatewayID,
			AgentId:   agentID,
			Timestamp: time.Now().UnixNano(),
			Partition: partition,
			SourceIp:  sourceIP,
			Version:   runtimeMetadata.Version,
			Hostname:  runtimeMetadata.Hostname,
			Os:        runtimeMetadata.Os,
			Arch:      runtimeMetadata.Arch,
		})
	}

	if len(chunks) == 0 {
		return false
	}

	totalChunks := int32(len(chunks))
	for i, chunk := range chunks {
		chunk.ChunkIndex = int32(i)
		chunk.TotalChunks = totalChunks
		chunk.IsFinal = int32(i) == totalChunks-1
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	resp, err := p.gateway.StreamStatus(pushCtx, chunks)
	if err != nil {
		p.logger.Error().Err(err).Int("chunk_count", len(chunks)).Msg("Failed to stream plugin telemetry")
		restoreUndelivered()
		return false
	}
	if !resp.Received {
		p.logger.Warn().Int("chunk_count", len(chunks)).Msg("Gateway did not acknowledge plugin telemetry")
		restoreUndelivered()
		return false
	}

	p.logger.Info().Int("chunk_count", len(chunks)).Msg("Streamed plugin telemetry")
	return true
}

func buildPluginSignalGatewayStatus(
	signal PluginSignalTelemetry,
	agentID, gatewayID, partition, kvStoreID string,
) (*proto.GatewayServiceStatus, int, error) {
	messageBytes, err := gproto.Marshal(signal.Batch)
	if err != nil {
		return nil, 0, err
	}

	return &proto.GatewayServiceStatus{
		ServiceName:  pluginSignalTelemetryServiceName,
		Available:    true,
		Message:      messageBytes,
		ServiceType:  pluginSignalTelemetryServiceType,
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       pluginSignalTelemetrySource(signal),
		KvStoreId:    kvStoreID,
	}, len(messageBytes), nil
}

// pluginTelemetryProducerID is the host-stamped telemetry producer id of a
// signal: the same instance the legacy status source names after `plugin:`.
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

func pluginSignalTelemetrySource(signal PluginSignalTelemetry) string {
	return fmt.Sprintf("%s%s", pluginSignalTelemetrySourcePrefix, pluginTelemetryProducerID(signal))
}
