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
	addonTelemetryServiceName          = "addon-telemetry"
	addonTelemetryServiceType          = "native-addon"
	addonTelemetrySourcePrefix         = "addon:"
	addonTelemetryMaxDrainPerPush      = 1024
	addonTelemetryMaxBatchMessageBytes = 6 * 1024 * 1024
)

func (p *PushLoop) pushAddonTelemetry(ctx context.Context) bool {
	p.server.mu.RLock()
	buffer := p.server.addonTelemetry
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()

	if buffer == nil {
		return false
	}

	envelopes, droppedDelta, droppedTotal := buffer.drain(addonTelemetryMaxDrainPerPush)
	if len(envelopes) == 0 {
		if droppedDelta > 0 {
			p.logger.Warn().
				Uint64("dropped_since_last", droppedDelta).
				Uint64("dropped_total", droppedTotal).
				Msg("Dropped add-on telemetry before push")
		}
		return false
	}

	gatewayID := p.gateway.GetGatewayID()
	runtimeMetadata := currentRuntimeMetadata()
	sourceIP := p.getSourceIP()
	chunks := make([]*proto.GatewayStatusChunk, 0, len(envelopes))

	for _, envelope := range envelopes {
		status, messageByteCount, err := buildAddonTelemetryGatewayStatus(envelope, agentID, gatewayID, partition, kvStoreID)
		if err != nil {
			p.logger.Warn().Err(err).Str("addon", envelope.addonID).Msg("Skipping add-on telemetry batch")
			continue
		}
		if messageByteCount > addonTelemetryMaxBatchMessageBytes {
			p.logger.Warn().
				Str("addon", envelope.addonID).
				Int("message_bytes", messageByteCount).
				Int("max_bytes", addonTelemetryMaxBatchMessageBytes).
				Msg("Skipping oversized add-on telemetry batch")
			continue
		}

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
		p.logger.Error().Err(err).Int("chunk_count", len(chunks)).Msg("Failed to stream add-on telemetry")
		return false
	}
	if !resp.Received {
		p.logger.Warn().Int("chunk_count", len(chunks)).Msg("Gateway did not acknowledge add-on telemetry")
		return false
	}

	logEvent := p.logger.Info().Int("chunk_count", len(chunks))
	if droppedDelta > 0 {
		logEvent = logEvent.
			Uint64("dropped_since_last", droppedDelta).
			Uint64("dropped_total", droppedTotal)
	}
	logEvent.Msg("Streamed add-on telemetry")
	return true
}

func buildAddonTelemetryGatewayStatus(
	envelope addonTelemetryEnvelope,
	agentID, gatewayID, partition, kvStoreID string,
) (*proto.GatewayServiceStatus, int, error) {
	messageBytes, err := gproto.Marshal(envelope.batch)
	if err != nil {
		return nil, 0, err
	}

	return &proto.GatewayServiceStatus{
		ServiceName:  addonTelemetryServiceName,
		Available:    true,
		Message:      messageBytes,
		ServiceType:  addonTelemetryServiceType,
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       addonTelemetrySource(envelope.addonID),
		KvStoreId:    kvStoreID,
	}, len(messageBytes), nil
}

func addonTelemetrySource(addonID string) string {
	clean := strings.TrimSpace(addonID)
	if clean == "" {
		clean = unknownTelemetrySource
	}
	return fmt.Sprintf("%s%s", addonTelemetrySourcePrefix, clean)
}
