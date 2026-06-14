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
	"time"

	"github.com/carverauto/serviceradar/proto"
)

func (p *PushLoop) pushSweepResults(ctx context.Context) bool {
	sweepSvc := p.findSweepResultsProvider()
	if sweepSvc == nil {
		return false
	}

	lastSequence := p.getSweepResultsSequence()
	sentAny := false
	maxIterations := 32

	for i := 0; i < maxIterations; i++ {
		response, err := sweepSvc.GetSweepResults(ctx, lastSequence)
		if err != nil {
			p.logger.Warn().Err(err).Msg("Failed to get sweep results")
			return sentAny
		}

		if response == nil {
			return sentAny
		}

		pendingSeq := response.CurrentSequence

		if !response.HasNewData || len(response.Data) == 0 {
			p.logger.Debug().
				Str("service_name", response.ServiceName).
				Str("service_type", response.ServiceType).
				Str("current_sequence", response.CurrentSequence).
				Bool("has_new_data", response.HasNewData).
				Int("data_bytes", len(response.Data)).
				Msg("No sweep results to stream")

			if pendingSeq != "" {
				p.setSweepResultsSequence(pendingSeq)
			}
			return sentAny
		}

		chunks, err := buildSweepResultsChunks(response)
		if err != nil {
			p.logger.Warn().Err(err).Msg("Failed to chunk sweep results")
			return sentAny
		}

		serviceName := response.ServiceName
		if serviceName == "" {
			serviceName = networkSweepServiceName
		}

		serviceType := response.ServiceType
		if serviceType == "" {
			serviceType = sweepType
		}

		statusChunks := p.buildResultsStatusChunks(sweepResultProtoChunks(chunks), serviceName, serviceType)
		if len(statusChunks) == 0 {
			return sentAny
		}
		for idx, chunk := range chunks {
			metricStatus, err := p.sweepMetricStatusFromMap(chunk.MetricPayload)
			if err != nil {
				p.logger.Error().
					Err(err).
					Int("chunk_index", idx).
					Str("service_name", serviceName).
					Msg("Failed to marshal sweep result metric envelope")

				return sentAny
			}
			statusChunks[idx].Services = append(statusChunks[idx].Services, metricStatus)
		}

		pushCtx, cancel := context.WithTimeout(ctx, sweepResultsStreamTimeout(len(statusChunks)))
		_, err = p.gateway.StreamStatus(pushCtx, statusChunks)
		cancel()
		if err != nil {
			p.logger.Error().Err(err).Msg("Failed to stream sweep results to gateway")
			return sentAny
		}

		if pendingSeq != "" {
			if ack, ok := sweepSvc.(interface {
				AcknowledgeSweepResults(groupID string, sequence string)
			}); ok {
				ack.AcknowledgeSweepResults(response.SweepGroupId, pendingSeq)
			}

			p.setSweepResultsSequence(pendingSeq)
			lastSequence = pendingSeq
		}

		sentAny = true
		p.logger.Info().
			Str("service_name", serviceName).
			Int("chunk_count", len(statusChunks)).
			Msg("Streamed sweep results to gateway")
	}

	if sentAny {
		p.logger.Warn().Int("max_iterations", maxIterations).Msg("Stopped sweep results push after max iterations")
	}

	return sentAny
}

func (p *PushLoop) sweepMetricStatusFromMap(payload map[string]any) (*proto.GatewayServiceStatus, error) {
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	kvStoreID := p.server.config.KVAddress
	p.server.mu.RUnlock()
	gatewayID := p.gateway.GetGatewayID()

	message, err := marshalSweepMetricEnvelopeFromMap(payload, metricEnvelopeContext{
		AgentID:   agentID,
		GatewayID: gatewayID,
		Partition: partition,
		KvStoreID: kvStoreID,
	})
	if err != nil {
		return nil, err
	}

	return &proto.GatewayServiceStatus{
		ServiceName:  networkSweepServiceName,
		ServiceType:  sweepType,
		Available:    true,
		Message:      message,
		ResponseTime: 0,
		AgentId:      agentID,
		GatewayId:    gatewayID,
		Partition:    partition,
		Source:       "sweep-metrics",
		KvStoreId:    kvStoreID,
	}, nil
}

type sweepResultsChunk struct {
	*proto.ResultsChunk
	MetricPayload map[string]any
}

func sweepResultProtoChunks(chunks []*sweepResultsChunk) []*proto.ResultsChunk {
	result := make([]*proto.ResultsChunk, 0, len(chunks))
	for _, chunk := range chunks {
		if chunk == nil {
			continue
		}
		result = append(result, chunk.ResultsChunk)
	}
	return result
}

func buildSweepResultsChunks(response *proto.ResultsResponse) ([]*sweepResultsChunk, error) {
	if response == nil {
		return nil, nil
	}

	if len(response.Data) == 0 {
		return nil, nil
	}

	maxChunkSize, maxHostsPerChunk := sweepResultsChunkLimits()

	var sweepData map[string]any
	if err := json.Unmarshal(response.Data, &sweepData); err != nil {
		return nil, fmt.Errorf("parse sweep data: %w", err)
	}

	if len(response.Data) <= maxChunkSize {
		return []*sweepResultsChunk{{
			ResultsChunk: &proto.ResultsChunk{
				Data:            response.Data,
				IsFinal:         true,
				ChunkIndex:      0,
				TotalChunks:     1,
				CurrentSequence: response.CurrentSequence,
				Timestamp:       response.Timestamp,
			},
			MetricPayload: sweepData,
		}}, nil
	}

	hostsInterface, ok := sweepData["hosts"]
	if !ok {
		return nil, errSweepMissingHosts
	}

	hosts, ok := hostsInterface.([]interface{})
	if !ok {
		return nil, errSweepHostsNotArray
	}

	totalHosts := len(hosts)

	metadata := make(map[string]interface{})
	for key, value := range sweepData {
		if key != "hosts" {
			metadata[key] = value
		}
	}

	baseData := make(map[string]interface{}, len(metadata))
	for key, value := range metadata {
		baseData[key] = value
	}
	baseData["hosts"] = []interface{}{}

	baseBytes, err := json.Marshal(baseData)
	if err != nil {
		return nil, fmt.Errorf("marshal sweep metadata: %w", err)
	}

	baseSize := len(baseBytes) - 2
	if baseSize < 0 {
		baseSize = len(baseBytes)
	}

	hostSizes := make([]int, totalHosts)
	for i, host := range hosts {
		hostBytes, err := json.Marshal(host)
		if err != nil {
			return nil, fmt.Errorf("marshal sweep host %d: %w", i, err)
		}
		hostSizes[i] = len(hostBytes)
	}

	type hostRange struct {
		start int
		end   int
	}

	var ranges []hostRange
	start := 0
	currentSize := baseSize + 2

	for i, hostSize := range hostSizes {
		additional := hostSize
		if i > start {
			additional++
		}

		if (currentSize+additional > maxChunkSize || i-start >= maxHostsPerChunk) && i > start {
			ranges = append(ranges, hostRange{start: start, end: i})
			start = i
			currentSize = baseSize + 2
			additional = hostSize
		}

		currentSize += additional
	}

	if start < totalHosts {
		ranges = append(ranges, hostRange{start: start, end: totalHosts})
	}

	totalChunks := len(ranges)
	chunks := make([]*sweepResultsChunk, 0, totalChunks)

	for chunkIndex, chunkRange := range ranges {
		chunkHosts := hosts[chunkRange.start:chunkRange.end]

		chunkData := make(map[string]interface{}, len(metadata))
		for key, value := range metadata {
			chunkData[key] = value
		}
		chunkData["hosts"] = chunkHosts

		chunkBytes, err := json.Marshal(chunkData)
		if err != nil {
			return nil, fmt.Errorf("marshal sweep chunk %d: %w", chunkIndex, err)
		}

		chunks = append(chunks, &sweepResultsChunk{
			ResultsChunk: &proto.ResultsChunk{
				Data:            chunkBytes,
				IsFinal:         chunkIndex == totalChunks-1,
				ChunkIndex:      int32(chunkIndex),
				TotalChunks:     int32(totalChunks),
				CurrentSequence: response.CurrentSequence,
				Timestamp:       response.Timestamp,
			},
			MetricPayload: chunkData,
		})
	}

	return chunks, nil
}

func sweepResultsStreamTimeout(chunkCount int) time.Duration {
	if chunkCount <= 0 {
		return minSweepResultsStreamTimeout
	}

	timeout := minSweepResultsStreamTimeout + time.Duration(chunkCount)*sweepResultsTimeoutPerChunk
	if timeout > maxSweepResultsStreamTimeout {
		return maxSweepResultsStreamTimeout
	}

	return timeout
}
