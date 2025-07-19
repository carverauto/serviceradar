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

package poller

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// executeGetResults now routes to the correct method based on service type.
func (rp *ResultsPoller) executeGetResults(ctx context.Context) *proto.ServiceStatus {
	req := rp.buildResultsRequest()

	var results *proto.ResultsResponse

	var err error

	// Route based on service type or service name - use streaming for services that handle large datasets
	if rp.check.Type == serviceTypeSync || rp.check.Type == serviceTypeSweep ||
		rp.check.Name == serviceTypeSync || strings.Contains(rp.check.Name, serviceTypeSync) {
		rp.logger.Info().
			Str("service_name", rp.check.Name).
			Str("service_type", rp.check.Type).
			Msg("Using streaming method for large dataset service")

		results, err = rp.executeStreamResults(ctx, req)
	} else {
		rp.logger.Debug().Str("service_name", rp.check.Name).Msg("Using unary method for service")

		results, err = rp.client.GetResults(ctx, req)
	}

	if err != nil {
		return rp.handleGetResultsError(err)
	}

	if results == nil {
		rp.logger.Warn().Str("service_name", rp.check.Name).Msg("GetResults returned nil response, skipping")
		return nil
	}

	rp.logSuccessfulGetResults(results)
	rp.updateSequenceTracking(results)

	if rp.shouldSkipCoreSubmission(results) {
		return nil
	}

	return rp.convertToServiceStatus(results)
}

// executeStreamResults handles the gRPC streaming for large datasets.
func (rp *ResultsPoller) executeStreamResults(ctx context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	rp.logger.Info().Str("service_name", req.ServiceName).Str("service_type", req.ServiceType).Msg("Starting StreamResults call")

	stream, err := rp.client.StreamResults(ctx, req)
	if err != nil {
		rp.logger.Error().Err(err).Str("service_name", req.ServiceName).Msg("Failed to initiate StreamResults")
		return nil, err
	}

	var dataBuffer bytes.Buffer

	var finalChunk *proto.ResultsChunk

	startTime := time.Now()
	chunksReceived := 0

	for {
		chunk, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			rp.logger.Info().Str("service_name", req.ServiceName).Int("chunks_received", chunksReceived).Msg("Stream ended normally")
			break // End of stream
		}

		if err != nil {
			rp.logger.Error().Err(err).
				Str("service_name", req.ServiceName).
				Int("chunks_received", chunksReceived).
				Msg("Error receiving chunk from stream")

			return nil, fmt.Errorf("failed to receive chunk: %w", err)
		}

		chunksReceived++

		rp.logger.Debug().
			Str("service_name", req.ServiceName).
			Int("chunk_index", int(chunk.ChunkIndex)).
			Int("chunk_size", len(chunk.Data)).
			Bool("is_final", chunk.IsFinal).
			Msg("Received chunk")

		if _, err := dataBuffer.Write(chunk.Data); err != nil {
			rp.logger.Error().Err(err).Str("service_name", req.ServiceName).Msg("Failed to write chunk to buffer")
			return nil, fmt.Errorf("failed to write chunk to buffer: %w", err)
		}

		if chunk.IsFinal {
			finalChunk = chunk

			rp.logger.Info().Str("service_name", req.ServiceName).Int("total_chunks", chunksReceived).Msg("Received final chunk")

			break
		}
	}

	if finalChunk == nil {
		rp.logger.Error().
			Str("service_name", req.ServiceName).
			Int("chunks_received", chunksReceived).
			Msg("Stream completed without a final chunk")

		return nil, fmt.Errorf("stream completed without a final chunk")
	}

	rp.logger.Info().
		Str("service_name", req.ServiceName).
		Int("total_chunks", int(finalChunk.TotalChunks)).
		Int("data_size_bytes", dataBuffer.Len()).
		Msg("Successfully received all chunks from stream")

	// Assemble the final ResultsResponse from the chunks
	return &proto.ResultsResponse{
		Available:       true,
		Data:            dataBuffer.Bytes(),
		ServiceName:     req.ServiceName,
		ServiceType:     req.ServiceType,
		ResponseTime:    time.Since(startTime).Nanoseconds(),
		AgentId:         req.AgentId,
		PollerId:        req.PollerId,
		Timestamp:       finalChunk.Timestamp,
		CurrentSequence: finalChunk.CurrentSequence,
		HasNewData:      true, // Assume new data if we streamed
	}, nil
}

func (rp *ResultsPoller) buildResultsRequest() *proto.ResultsRequest {
	req := &proto.ResultsRequest{
		ServiceName:  rp.check.Name,
		ServiceType:  rp.check.Type,
		AgentId:      rp.agentName,
		PollerId:     rp.pollerID,
		Details:      rp.check.Details,
		LastSequence: rp.lastSequence,
	}

	rp.logger.Debug().
		Str("service_name", rp.check.Name).
		Str("service_type", rp.check.Type).
		Str("agent_name", rp.agentName).
		Str("poller_id", rp.pollerID).
		Msg("Executing GetResults call")

	return req
}

func (rp *ResultsPoller) handleGetResultsError(err error) *proto.ServiceStatus {
	if status.Code(err) == codes.Unimplemented {
		rp.logger.Debug().
			Str("service_name", rp.check.Name).
			Str("service_type", rp.check.Type).
			Str("agent_name", rp.agentName).
			Msg("Service does not support GetResults - skipping")

		return nil
	}

	rp.logger.Error().
		Err(err).
		Str("service_name", rp.check.Name).
		Str("service_type", rp.check.Type).
		Str("agent_name", rp.agentName).
		Str("poller_id", rp.pollerID).
		Msg("GetResults call failed")

	return &proto.ServiceStatus{
		ServiceName: rp.check.Name,
		Available:   false,
		Message:     []byte(fmt.Sprintf(`{"error": "GetResults failed: %v"}`, err)),
		ServiceType: rp.check.Type,
		PollerId:    rp.pollerID,
		AgentId:     rp.agentName,
		Source:      "results",
	}
}

func (rp *ResultsPoller) logSuccessfulGetResults(results *proto.ResultsResponse) {
	rp.logger.Debug().
		Str("service_name", rp.check.Name).
		Str("service_type", rp.check.Type).
		Str("agent_name", rp.agentName).
		Bool("available", results.Available).
		Str("current_sequence", results.CurrentSequence).
		Bool("has_new_data", results.HasNewData).
		Int("data_length", len(results.Data)).
		Msg("GetResults call processed successfully")
}

func (rp *ResultsPoller) updateSequenceTracking(results *proto.ResultsResponse) {
	if results.CurrentSequence != "" {
		rp.lastSequence = results.CurrentSequence
	}
}

func (rp *ResultsPoller) shouldSkipCoreSubmission(results *proto.ResultsResponse) bool {
	if rp.check.Name == serviceTypeSync || strings.Contains(rp.check.Name, serviceTypeSync) {
		if !results.HasNewData {
			rp.logger.Debug().
				Str("service_name", rp.check.Name).
				Msg("Sync service has no new data, but submitting full list to core for state reconciliation.")
		}

		return false
	}

	if !results.HasNewData && rp.check.Type == serviceTypeSweep {
		rp.logger.Debug().
			Str("service_name", rp.check.Name).
			Str("service_type", rp.check.Type).
			Str("sequence", results.CurrentSequence).
			Msg("No new data from sweep service, skipping core submission")

		return true
	}

	return false
}

func (rp *ResultsPoller) convertToServiceStatus(results *proto.ResultsResponse) *proto.ServiceStatus {
	if rp.check.Name == serviceTypeSync || strings.Contains(rp.check.Name, serviceTypeSync) {
		rp.logger.Info().
			Str("service_name", rp.check.Name).
			Str("service_type", rp.check.Type).
			Bool("has_new_data", results.HasNewData).
			Str("sequence", results.CurrentSequence).
			Int("data_length", len(results.Data)).
			Msg("Converting sync service results to ServiceStatus for core submission")
	}

	return &proto.ServiceStatus{
		ServiceName:  rp.check.Name,
		Available:    results.Available,
		Message:      results.Data,
		ServiceType:  rp.check.Type,
		ResponseTime: results.ResponseTime,
		AgentId:      results.AgentId,
		PollerId:     rp.pollerID,
		Source:       "results",
	}
}
