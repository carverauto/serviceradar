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
	if len(signals) == 0 {
		return false
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
		return false
	}
	if !resp.Received {
		p.logger.Warn().Int("chunk_count", len(chunks)).Msg("Gateway did not acknowledge plugin telemetry")
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

func pluginSignalTelemetrySource(signal PluginSignalTelemetry) string {
	clean := strings.TrimSpace(signal.AssignmentID)
	if clean == "" {
		clean = strings.TrimSpace(signal.PluginID)
	}
	if clean == "" {
		clean = unknownTelemetrySource
	}
	return fmt.Sprintf("%s%s", pluginSignalTelemetrySourcePrefix, clean)
}
