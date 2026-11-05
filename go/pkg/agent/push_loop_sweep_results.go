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

// pushSweepResults spools the sweep results responses of unleased groups as
// edge records under the unleased results and metrics grants. A response with
// records still waiting for spool room finishes first, whatever the grants now
// are. Without both grants no further response is read: the sweep service
// keeps its completed cycles until the grants are held.
func (p *PushLoop) pushSweepResults(ctx context.Context) bool {
	sweepSvc := p.findSweepResultsProvider()
	if sweepSvc == nil {
		return false
	}

	pending, sentAny := p.finishSweepResultsEdge(sweepSvc)
	if pending {
		return sentAny
	}

	resultsGrant, metricsGrant := p.sweepResultsEdgeGrants(time.Now())
	if resultsGrant == nil {
		p.holdForGrant(edgeProducerSweepResults)
		return sentAny
	}

	lastSequence := p.getSweepResultsSequence()
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
				Msg("No sweep results to spool")

			if pendingSeq != "" {
				p.setSweepResultsSequence(pendingSeq)
			}
			return sentAny
		}

		pending, sent := p.pushSweepResultsEdge(sweepSvc, response, resultsGrant, metricsGrant)
		sentAny = sentAny || sent
		if pending {
			return sentAny
		}

		if pendingSeq != "" {
			lastSequence = pendingSeq
		}
	}

	if sentAny {
		p.logger.Warn().Int("max_iterations", maxIterations).Msg("Stopped sweep results push after max iterations")
	}

	return sentAny
}

// acknowledgeSweepResults marks a group's results sequence delivered, for a
// provider that tracks delivery per group.
func acknowledgeSweepResults(sweepSvc SweepResultsProvider, groupID, sequence string) {
	if sequence == "" {
		return
	}
	if ack, ok := sweepSvc.(interface {
		AcknowledgeSweepResults(groupID string, sequence string)
	}); ok {
		ack.AcknowledgeSweepResults(groupID, sequence)
	}
}

type sweepResultsChunk struct {
	*proto.ResultsChunk
	MetricPayload map[string]any
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

		// Chunking is transport-only. Emit each report-level summary once,
		// while preserving its fields in the status JSON for every chunk.
		if chunkIndex > 0 {
			for _, field := range []string{"total_hosts", "available_hosts", "sequence"} {
				delete(chunkData, field)
			}
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
