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
	"context"
	"encoding/json"
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
	shouldUseStreaming := rp.check.Type == serviceTypeSync || rp.check.Type == serviceTypeSweep ||
		rp.check.Name == serviceTypeSync || strings.Contains(rp.check.Name, serviceTypeSync)

	rp.logger.Info().
		Str("service_name", rp.check.Name).
		Str("service_type", rp.check.Type).
		Str("serviceTypeSync", serviceTypeSync).
		Bool("should_use_streaming", shouldUseStreaming).
		Bool("type_equals_sync", rp.check.Type == serviceTypeSync).
		Bool("name_equals_sync", rp.check.Name == serviceTypeSync).
		Bool("name_contains_sync", strings.Contains(rp.check.Name, serviceTypeSync)).
		Msg("Routing decision for service")

	if shouldUseStreaming {
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
		rp.logger.Info().Str("service_name", rp.check.Name).Msg("Skipping core submission for service")
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

	startTime := time.Now()
	mergedDevices, finalChunk, metadata, err := rp.processStreamChunks(ctx, stream, req.ServiceName)

	if err != nil {
		return nil, err
	}

	return rp.buildFinalResponse(req, mergedDevices, finalChunk, metadata, startTime)
}

// processStreamChunks processes all chunks from the stream and returns merged devices and final chunk
func (rp *ResultsPoller) processStreamChunks(_ context.Context,
	stream proto.AgentService_StreamResultsClient, serviceName string) ([]interface{}, *proto.ResultsChunk, map[string]interface{}, error) {
	var mergedDevices []interface{}

	var finalChunk *proto.ResultsChunk
	var sweepMetadata map[string]interface{} // Store metadata from first chunk

	chunksReceived := 0

	for {
		chunk, streamErr := stream.Recv()
		if errors.Is(streamErr, io.EOF) {
			rp.logger.Info().Str("service_name", serviceName).Int("chunks_received", chunksReceived).Msg("Stream ended normally")
			break // End of stream
		}

		if streamErr != nil {
			rp.logger.Error().Err(streamErr).
				Str("service_name", serviceName).
				Int("chunks_received", chunksReceived).
				Msg("Error receiving chunk from stream")

			return nil, nil, nil, fmt.Errorf("failed to receive chunk: %w", streamErr)
		}

		chunksReceived++

		rp.logger.Debug().
			Str("service_name", serviceName).
			Int("chunk_index", int(chunk.ChunkIndex)).
			Int("chunk_size", len(chunk.Data)).
			Bool("is_final", chunk.IsFinal).
			Msg("Received chunk")

		// Process this chunk
		chunkDevices, chunkMetadata, err := rp.processChunk(chunk, serviceName)
		if err != nil {
			return nil, nil, nil, err
		}

		// Store metadata from first chunk for sweep services
		if chunksReceived == 1 && chunkMetadata != nil {
			sweepMetadata = chunkMetadata
		}

		// Merge devices from this chunk
		mergedDevices = append(mergedDevices, chunkDevices...)

		rp.logger.Debug().
			Str("service_name", serviceName).
			Int("chunk_index", int(chunk.ChunkIndex)).
			Int("chunk_devices", len(chunkDevices)).
			Int("total_devices", len(mergedDevices)).
			Msg("Merged chunk devices")

		if chunk.IsFinal {
			finalChunk = chunk

			rp.logger.Info().Str("service_name", serviceName).Int("total_chunks", chunksReceived).Msg("Received final chunk")

			break
		}
	}

	if finalChunk == nil {
		rp.logger.Error().
			Str("service_name", serviceName).
			Int("chunks_received", chunksReceived).
			Msg("Stream completed without a final chunk")

		return nil, nil, nil, fmt.Errorf("stream completed without a final chunk")
	}

	return mergedDevices, finalChunk, sweepMetadata, nil
}

// processChunk processes a single chunk and returns the devices from it and any metadata
func (rp *ResultsPoller) processChunk(chunk *proto.ResultsChunk, serviceName string) ([]interface{}, map[string]interface{}, error) {
	var chunkDevices []interface{}

	var chunkMetadata map[string]interface{}

	if len(chunk.Data) > 0 {
		// First try to parse as array (legacy format)
		if unmarshalErr := json.Unmarshal(chunk.Data, &chunkDevices); unmarshalErr != nil {
			// If that fails, try to parse as object with hosts field (new format)
			var chunkData map[string]interface{}
			if objErr := json.Unmarshal(chunk.Data, &chunkData); objErr != nil {
				rp.logger.Error().Err(unmarshalErr).
					Str("service_name", serviceName).
					Int("chunk_index", int(chunk.ChunkIndex)).
					Msg("Failed to parse chunk data as JSON array or object")

				return nil, nil, fmt.Errorf("failed to parse chunk data: %w", unmarshalErr)
			}
			
			// Extract hosts from the object
			if hostsInterface, ok := chunkData["hosts"]; ok {
				if hosts, ok := hostsInterface.([]interface{}); ok {
					chunkDevices = hosts
				} else {
					return nil, nil, fmt.Errorf("hosts field is not an array in chunk data")
				}
			} else {
				return nil, nil, fmt.Errorf("no hosts field found in chunk data")
			}
			
			// Store metadata (excluding hosts array)
			chunkMetadata = make(map[string]interface{})
			for key, value := range chunkData {
				if key != "hosts" {
					chunkMetadata[key] = value
				}
			}
		}
	}

	return chunkDevices, chunkMetadata, nil
}

// buildFinalResponse constructs the final ResultsResponse from merged data
func (rp *ResultsPoller) buildFinalResponse(
	req *proto.ResultsRequest,
	mergedDevices []interface{},
	finalChunk *proto.ResultsChunk,
	metadata map[string]interface{},
	startTime time.Time,
) (*proto.ResultsResponse, error) {
	var mergedData []byte
	var err error
	
	// For sweep services, we need to reconstruct the original object format
	if req.ServiceType == "sweep" && metadata != nil {
		// Reconstruct the sweep object with preserved metadata and merged hosts
		sweepObject := make(map[string]interface{})
		for key, value := range metadata {
			sweepObject[key] = value
		}
		sweepObject["hosts"] = mergedDevices
		mergedData, err = json.Marshal(sweepObject)
	} else {
		// For other services, marshal the devices directly
		mergedData, err = json.Marshal(mergedDevices)
	}
	
	if err != nil {
		rp.logger.Error().Err(err).
			Str("service_name", req.ServiceName).
			Int("total_devices", len(mergedDevices)).
			Msg("Failed to marshal merged data")

		return nil, fmt.Errorf("failed to marshal merged data: %w", err)
	}

	rp.logger.Info().
		Str("service_name", req.ServiceName).
		Int("total_chunks", int(finalChunk.TotalChunks)).
		Int("total_devices", len(mergedDevices)).
		Int("data_size_bytes", len(mergedData)).
		Msg("Successfully received and merged all chunks from stream")

	// Assemble the final ResultsResponse from the chunks
	return &proto.ResultsResponse{
		Available:       true,
		Data:            mergedData,
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
	rp.logger.Info().
		Str("service_name", rp.check.Name).
		Str("service_type", rp.check.Type).
		Msg("convertToServiceStatus called")

	// Determine the correct service type for core processing
	serviceType := rp.check.Type
	if rp.check.Name == serviceTypeSync || strings.Contains(rp.check.Name, serviceTypeSync) {
		serviceType = serviceTypeSync // Convert to "sync" for consistent core processing
		rp.logger.Info().
			Str("service_name", rp.check.Name).
			Str("original_service_type", rp.check.Type).
			Str("converted_service_type", serviceType).
			Bool("has_new_data", results.HasNewData).
			Str("sequence", results.CurrentSequence).
			Int("data_length", len(results.Data)).
			Msg("Converting sync service results to ServiceStatus for core submission")
	}

	return &proto.ServiceStatus{
		ServiceName:  rp.check.Name,
		Available:    results.Available,
		Message:      results.Data,
		ServiceType:  serviceType,
		ResponseTime: results.ResponseTime,
		AgentId:      results.AgentId,
		PollerId:     rp.pollerID,
		Source:       "results",
	}
}
