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
	bytesPerKB          = 1024
	bytesPerMB          = bytesPerKB * 1024
	maxPayloadSize      = 3 * bytesPerMB // 3MB to stay well under gRPC 4MB limit
	maxNetworksPerChunk = 1000           // Reduced from 10000 to stay under NATS limits
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
		Int("total_networks", len(sweepConfig.Networks)).
		Int("payload_size_mb", payloadSize/bytesPerMB).
		Msg("Large sweep config detected, writing in chunks")

	// Calculate chunks based on device targets (networks array is now empty)
	totalChunks := 1 // Default to 1 chunk
	devicesPerChunk := len(sweepConfig.DeviceTargets)

	if len(sweepConfig.DeviceTargets) > maxNetworksPerChunk {
		totalChunks = (len(sweepConfig.DeviceTargets) + maxNetworksPerChunk - 1) / maxNetworksPerChunk
		devicesPerChunk = (len(sweepConfig.DeviceTargets) + totalChunks - 1) / totalChunks
	}

	// Write all chunks
	for i := 0; i < totalChunks; i++ {
		if err := kw.writeConfigChunk(ctx, sweepConfig, i, totalChunks, devicesPerChunk); err != nil {
			return err
		}
	}

	// Write metadata
	return kw.writeChunkMetadata(ctx, totalChunks, len(sweepConfig.Networks))
}

// writeConfigChunk writes a single chunk of the config
func (kw *DefaultKVWriter) writeConfigChunk(
	ctx context.Context,
	sweepConfig *models.SweepConfig,
	chunkIndex int,
	_ int, // totalChunks
	devicesPerChunk int) error { //nolint:wsl // function signature requires multiline format
	// Networks array is empty - only process device targets

	// Calculate device target range for this chunk
	var chunkDeviceTargets []models.DeviceTarget

	if len(sweepConfig.DeviceTargets) > 0 {
		devStart := chunkIndex * devicesPerChunk
		devEnd := devStart + devicesPerChunk

		if devEnd > len(sweepConfig.DeviceTargets) {
			devEnd = len(sweepConfig.DeviceTargets)
		}

		chunkDeviceTargets = sweepConfig.DeviceTargets[devStart:devEnd]
	}

	// Create chunk with subset of data
	chunkConfig := &models.SweepConfig{
		Networks:      []string{}, // Always empty - using DeviceTargets only
		DeviceTargets: chunkDeviceTargets,
		Ports:         sweepConfig.Ports,
		SweepModes:    sweepConfig.SweepModes,
		Interval:      sweepConfig.Interval,
		Concurrency:   sweepConfig.Concurrency,
		Timeout:       sweepConfig.Timeout,
	}

	chunkJSON, marshalErr := json.Marshal(chunkConfig)
	if marshalErr != nil {
		kw.Logger.Error().
			Err(marshalErr).
			Int("chunk_index", chunkIndex).
			Msg("Failed to marshal sweep config chunk")

		return fmt.Errorf("failed to marshal sweep config chunk %d: %w", chunkIndex, marshalErr)
	}

	chunkKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep_chunk_%d.json", kw.AgentID, chunkIndex)

	_, err := kw.KVClient.PutMany(ctx, &proto.PutManyRequest{
		Entries: []*proto.KeyValueEntry{{
			Key:   chunkKey,
			Value: chunkJSON,
		}},
	})
	if err != nil {
		return fmt.Errorf("failed to write sweep config chunk %d to %s: %w", chunkIndex, chunkKey, err)
	}

	kw.Logger.Debug().
		Str("chunk_key", chunkKey).
		Int("chunk_index", chunkIndex).
		Int("chunk_size_bytes", len(chunkJSON)).
		Int("devices_in_chunk", len(chunkDeviceTargets)).
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
