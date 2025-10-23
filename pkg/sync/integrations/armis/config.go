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

// Package armis pkg/sync/integrations/armis/config.go provides the configuration for the Armis integration.
package armis

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// WriteSweepConfig generates and writes the sweep config to KV.
func (kw *DefaultKVWriter) WriteSweepConfig(ctx context.Context, sweepConfig *models.SweepConfig) error {
	// Check size and potentially chunk the config
	configJSON, err := json.Marshal(sweepConfig)
	if err != nil {
		kw.Logger.Error().
			Err(err).
			Msg("Failed to marshal sweep config")

		return fmt.Errorf("failed to marshal sweep config: %w", err)
	}

	// Try writing as a single file first
	if kw.canWriteAsSingleFile(configJSON) {
		return kw.writeSingleConfig(ctx, configJSON)
	}

	// Need to chunk the config
	return kw.writeChunkedConfig(ctx, sweepConfig, configJSON)
}

const (
	bytesPerKB           = 1024
	bytesPerMB           = bytesPerKB * 1024
	maxPayloadSize       = 3 * bytesPerMB   // 3MB to stay well under gRPC 4MB limit
	maxNetworksPerChunk  = 1000             // Reduced from 10000 to stay under NATS limits
	maxChunkPayloadBytes = 512 * bytesPerKB // Keep individual KV entries well under typical NATS payload limits
)

// canWriteAsSingleFile checks if the config can be written as a single file
func (kw *DefaultKVWriter) canWriteAsSingleFile(configJSON []byte) bool {
	payloadSize := len(configJSON)
	kw.Logger.Info().
		Int("payload_size_bytes", payloadSize).
		Msg("Evaluating sweep config size")

	return payloadSize <= maxPayloadSize
}

// writeSingleConfig writes the config as a single file
func (kw *DefaultKVWriter) writeSingleConfig(ctx context.Context, configJSON []byte) error {
	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", kw.AgentID)

	_, err := kw.KVClient.PutMany(ctx, &proto.PutManyRequest{
		Entries: []*proto.KeyValueEntry{{
			Key:   configKey,
			Value: configJSON,
		}},
	})
	if err != nil {
		return fmt.Errorf("failed to write sweep config to %s: %w", configKey, err)
	}

	kw.Logger.Info().
		Str("config_key", configKey).
		Int("payload_size_bytes", len(configJSON)).
		Msg("Successfully wrote sweep config to KV store")

	return nil
}

// writeChunkedConfig writes the config in chunks
func (kw *DefaultKVWriter) writeChunkedConfig(ctx context.Context, sweepConfig *models.SweepConfig, configJSON []byte) error {
	payloadSize := len(configJSON)
	kw.Logger.Info().
		Int("device_targets", len(sweepConfig.DeviceTargets)).
		Int("payload_size_mb", payloadSize/bytesPerMB).
		Msg("Large sweep config detected, writing in chunks")

	chunks, err := kw.buildSweepChunks(sweepConfig, configJSON)
	if err != nil {
		return err
	}

	for i, chunk := range chunks {
		if err := kw.writeSweepChunk(ctx, i, chunk); err != nil {
			return err
		}
	}

	return kw.writeChunkMetadata(ctx, len(chunks), len(sweepConfig.Networks))
}

type sweepChunk struct {
	data        []byte
	deviceCount int
}

func (kw *DefaultKVWriter) buildSweepChunks(sweepConfig *models.SweepConfig, configJSON []byte) ([]sweepChunk, error) {
	targets := sweepConfig.DeviceTargets

	if len(targets) == 0 {
		data, err := kw.marshalChunkConfig(sweepConfig, nil, 0)
		if err != nil {
			return nil, err
		}
		return []sweepChunk{{data: data, deviceCount: 0}}, nil
	}

	avgBytesPerDevice := len(configJSON) / len(targets)
	if avgBytesPerDevice <= 0 {
		avgBytesPerDevice = 1
	}

	devicesPerChunk := maxChunkPayloadBytes / avgBytesPerDevice
	if devicesPerChunk < 1 {
		devicesPerChunk = 1
	}
	if devicesPerChunk > maxNetworksPerChunk {
		devicesPerChunk = maxNetworksPerChunk
	}

	chunks := make([]sweepChunk, 0, (len(targets)+devicesPerChunk-1)/devicesPerChunk)

	for start := 0; start < len(targets); {
		end := start + devicesPerChunk
		if end > len(targets) {
			end = len(targets)
		}

		for {
			chunkTargets := targets[start:end]
			chunkIdx := len(chunks)

			data, err := kw.marshalChunkConfig(sweepConfig, chunkTargets, chunkIdx)
			if err != nil {
				return nil, err
			}

			if len(data) <= maxChunkPayloadBytes || len(chunkTargets) <= 1 {
				if len(data) > maxChunkPayloadBytes {
					kw.Logger.Warn().
						Int("chunk_index", chunkIdx).
						Int("chunk_size_bytes", len(data)).
						Str("agent_id", kw.AgentID).
						Msg("Single-device chunk exceeds target size limit")
				}

				chunks = append(chunks, sweepChunk{
					data:        data,
					deviceCount: len(chunkTargets),
				})

				start = end
				break
			}

			// Reduce the chunk size and retry to keep us under the payload limit.
			newLen := len(chunkTargets) / 2
			if newLen < 1 {
				newLen = 1
			}

			kw.Logger.Debug().
				Int("attempted_devices", len(chunkTargets)).
				Int("chunk_size_bytes", len(data)).
				Int("reduced_devices", newLen).
				Msg("Chunk size exceeded limit, reducing device batch")

			end = start + newLen
		}
	}

	return chunks, nil
}

func (kw *DefaultKVWriter) marshalChunkConfig(base *models.SweepConfig, targets []models.DeviceTarget, chunkIndex int) ([]byte, error) {
	chunkConfig := &models.SweepConfig{
		Networks:      []string{},
		DeviceTargets: targets,
		Ports:         base.Ports,
		SweepModes:    base.SweepModes,
		Interval:      base.Interval,
		Concurrency:   base.Concurrency,
		Timeout:       base.Timeout,
	}

	chunkJSON, err := json.Marshal(chunkConfig)
	if err != nil {
		kw.Logger.Error().
			Err(err).
			Int("chunk_index", chunkIndex).
			Int("device_count", len(targets)).
			Msg("Failed to marshal sweep config chunk")

		return nil, fmt.Errorf("failed to marshal sweep config chunk %d: %w", chunkIndex, err)
	}

	return chunkJSON, nil
}

func (kw *DefaultKVWriter) writeSweepChunk(ctx context.Context, chunkIndex int, chunk sweepChunk) error {
	chunkKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep_chunk_%d.json", kw.AgentID, chunkIndex)

	_, err := kw.KVClient.PutMany(ctx, &proto.PutManyRequest{
		Entries: []*proto.KeyValueEntry{{
			Key:   chunkKey,
			Value: chunk.data,
		}},
	})
	if err != nil {
		return fmt.Errorf("failed to write sweep config chunk %d to %s: %w", chunkIndex, chunkKey, err)
	}

	kw.Logger.Debug().
		Str("chunk_key", chunkKey).
		Int("chunk_index", chunkIndex).
		Int("chunk_size_bytes", len(chunk.data)).
		Int("devices_in_chunk", chunk.deviceCount).
		Msg("Successfully wrote sweep config chunk")

	return nil
}

// writeChunkMetadata writes the metadata file that tells the agent about chunks
func (kw *DefaultKVWriter) writeChunkMetadata(ctx context.Context, totalChunks, totalNetworks int) error {
	metadataKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", kw.AgentID)
	metadata := map[string]interface{}{
		"chunked":      true,
		"chunk_count":  totalChunks,
		"total_chunks": totalChunks,
		"timestamp":    time.Now().UTC().Format(time.RFC3339),
	}
	metadataJSON, _ := json.Marshal(metadata)

	_, err := kw.KVClient.PutMany(ctx, &proto.PutManyRequest{
		Entries: []*proto.KeyValueEntry{{
			Key:   metadataKey,
			Value: metadataJSON,
		}},
	})
	if err != nil {
		kw.Logger.Warn().
			Err(err).
			Msg("Failed to write sweep metadata, agent may not detect chunked config")
	}

	kw.Logger.Info().
		Int("total_chunks", totalChunks).
		Int("total_networks", totalNetworks).
		Msg("Successfully wrote chunked sweep config to KV store")

	return nil
}
