/*
 * Copyright 2025 Carver Automation Corporation.
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
	"encoding/json"
	"fmt"
	"strings"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

func (p *PushLoop) pushMapperResults(ctx context.Context) bool {
	p.server.mu.RLock()
	mapperSvc := p.server.mapperService
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	p.server.mu.RUnlock()

	if mapperSvc == nil {
		return false
	}

	updates, ok := mapperSvc.DrainResults(1000)
	if !ok || len(updates) == 0 {
		return false
	}

	payload, err := buildMapperResultsPayload(updates, agentID, partition)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to build mapper results payload")
		return false
	}

	if len(payload) == 0 {
		return false
	}

	seq := fmt.Sprintf("%d", time.Now().UnixNano())

	response := mapperResultsResponse(payload, seq, "mapper", mapperServiceType)
	chunks := []*proto.ResultsChunk{{
		Data:            response.Data,
		IsFinal:         true,
		ChunkIndex:      0,
		TotalChunks:     1,
		CurrentSequence: response.CurrentSequence,
		Timestamp:       response.Timestamp,
	}}

	statusChunks := p.buildResultsStatusChunks(chunks, response.ServiceName, response.ServiceType)
	if len(statusChunks) == 0 {
		return false
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	_, err = p.gateway.StreamStatus(pushCtx, statusChunks)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream mapper results to gateway")
		return false
	}

	p.logger.Info().
		Int("update_count", len(updates)).
		Msg("Streamed mapper results to gateway")

	return true
}

func (p *PushLoop) pushNetprobeResults(ctx context.Context) bool {
	p.server.mu.RLock()
	netprobeSidecar := p.server.netprobeSidecar
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	collectorIP := p.server.config.HostIP
	p.server.mu.RUnlock()

	if netprobeSidecar == nil {
		return false
	}

	fingerprintEvents := netprobeSidecar.DrainEvents(1000)
	dpiEvents := netprobeSidecar.DrainDPIEvents(1000)
	processSnapshots := netprobeSidecar.DrainProcessSnapshots(1000)
	if len(fingerprintEvents) == 0 && len(dpiEvents) == 0 && len(processSnapshots) == 0 {
		return false
	}

	opts := agentnetprobe.TranslationOptions{
		AgentID:     agentID,
		GatewayID:   p.gateway.GetGatewayID(),
		CollectorIP: collectorIP,
	}
	updates := make([]map[string]any, 0, len(fingerprintEvents)+len(dpiEvents)+len(processSnapshots))
	for _, event := range fingerprintEvents {
		device, err := agentnetprobe.FingerprintEventToDiscoveredDevice(event, opts)
		if err != nil {
			p.logger.Warn().Err(err).Msg("Skipping invalid netprobe fingerprint event")
			continue
		}

		update := map[string]any{
			"ip":         device.GetIp(),
			"agent_id":   agentID,
			"gateway_id": opts.GatewayID,
			"partition":  partition,
			"source":     netprobeDiscoverySource(device.GetMetadata()),
			"metadata":   device.GetMetadata(),
			"timestamp":  time.Now().UTC().Format(time.RFC3339Nano),
		}
		updates = append(updates, update)
	}
	for _, event := range dpiEvents {
		device, err := agentnetprobe.DpiEventToDiscoveredDevice(event, opts)
		if err != nil {
			p.logger.Warn().Err(err).Msg("Skipping invalid netprobe DPI event")
			continue
		}

		update := map[string]any{
			"ip":         device.GetIp(),
			"agent_id":   agentID,
			"gateway_id": opts.GatewayID,
			"partition":  partition,
			"source":     string(models.DiscoverySourcePassiveNetprobe),
			"metadata":   device.GetMetadata(),
			"timestamp":  time.Now().UTC().Format(time.RFC3339Nano),
		}
		updates = append(updates, update)
	}
	for _, snapshot := range processSnapshots {
		device, err := agentnetprobe.ProcessSnapshotToDiscoveredDevice(snapshot, opts)
		if err != nil {
			p.logger.Warn().Err(err).Msg("Skipping invalid netprobe process snapshot")
			continue
		}

		update := map[string]any{
			"ip":         device.GetIp(),
			"agent_id":   agentID,
			"gateway_id": opts.GatewayID,
			"partition":  partition,
			"source":     string(models.DiscoverySourcePassiveNetprobe),
			"metadata":   device.GetMetadata(),
			"timestamp":  time.Now().UTC().Format(time.RFC3339Nano),
		}
		updates = append(updates, update)
	}
	if len(updates) == 0 {
		return false
	}

	payload, err := json.Marshal(updates)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to marshal netprobe results")
		return false
	}

	seq := fmt.Sprintf("%d", time.Now().UnixNano())
	response := mapperResultsResponse(
		payload,
		seq,
		string(models.DiscoverySourcePassiveNetprobe),
		string(models.DiscoverySourcePassiveNetprobe),
	)
	chunks := []*proto.ResultsChunk{{
		Data:            response.Data,
		IsFinal:         true,
		ChunkIndex:      0,
		TotalChunks:     1,
		CurrentSequence: response.CurrentSequence,
		Timestamp:       response.Timestamp,
	}}
	statusChunks := p.buildResultsStatusChunks(chunks, response.ServiceName, response.ServiceType)
	if len(statusChunks) == 0 {
		return false
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	if _, err := p.gateway.StreamStatus(pushCtx, statusChunks); err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream netprobe results to gateway")
		return false
	}

	p.logger.Info().
		Int("fingerprint_event_count", len(fingerprintEvents)).
		Int("dpi_event_count", len(dpiEvents)).
		Int("process_snapshot_count", len(processSnapshots)).
		Int("update_count", len(updates)).
		Msg("Streamed netprobe results to gateway")

	return true
}

func netprobeDiscoverySource(metadata map[string]string) string {
	if metadata != nil {
		if source := strings.TrimSpace(metadata["discovery_source"]); source != "" {
			return source
		}
		if source := strings.TrimSpace(metadata["source"]); source != "" {
			return source
		}
	}

	return string(models.DiscoverySourcePassiveNetprobe)
}

func (p *PushLoop) pushMapperInterfaces(ctx context.Context) bool {
	return p.pushMapperDerivedResults(
		ctx,
		func(svc *MapperService) ([]map[string]interface{}, bool) {
			return svc.DrainInterfaces(1000)
		},
		buildMapperInterfacePayload,
		"mapper_interfaces",
		"interface_count",
	)
}

func (p *PushLoop) pushMapperTopology(ctx context.Context) bool {
	return p.pushMapperDerivedResults(
		ctx,
		func(svc *MapperService) ([]map[string]interface{}, bool) {
			return svc.DrainTopology(1000)
		},
		buildMapperTopologyPayload,
		"mapper_topology",
		"topology_count",
	)
}

func (p *PushLoop) pushMapperDerivedResults(
	ctx context.Context,
	drain func(*MapperService) ([]map[string]interface{}, bool),
	buildPayload func([]map[string]interface{}, string, string) ([]byte, error),
	serviceType string,
	countField string,
) bool {
	p.server.mu.RLock()
	mapperSvc := p.server.mapperService
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	p.server.mu.RUnlock()

	if mapperSvc == nil {
		return false
	}

	updates, ok := drain(mapperSvc)
	if !ok || len(updates) == 0 {
		return false
	}

	payload, err := buildPayload(updates, agentID, partition)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to build mapper payload")
		return false
	}

	if len(payload) == 0 {
		return false
	}

	seq := fmt.Sprintf("%d", time.Now().UnixNano())
	response := mapperResultsResponse(payload, seq, "mapper", serviceType)
	chunks := []*proto.ResultsChunk{{
		Data:            response.Data,
		IsFinal:         true,
		ChunkIndex:      0,
		TotalChunks:     1,
		CurrentSequence: response.CurrentSequence,
		Timestamp:       response.Timestamp,
	}}

	statusChunks := p.buildResultsStatusChunks(chunks, response.ServiceName, response.ServiceType)
	if len(statusChunks) == 0 {
		return false
	}

	pushCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	_, err = p.gateway.StreamStatus(pushCtx, statusChunks)
	if err != nil {
		p.logger.Error().Err(err).Msg("Failed to stream mapper results to gateway")
		return false
	}

	p.logger.Info().Int(countField, len(updates)).Msg("Streamed mapper results to gateway")

	return true
}
