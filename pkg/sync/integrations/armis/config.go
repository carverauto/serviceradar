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
	const (
		bytesPerKB           = 1024
		bytesPerMB           = bytesPerKB * 1024
		maxPayloadSize       = 3 * bytesPerMB  // 3MB to stay well under gRPC 4MB limit
		maxNetworksPerChunk  = 1000            // Reduced from 10000 to stay under NATS limits
	)

	// First, try to write the whole config if it's small enough
	configJSON, err := json.Marshal(sweepConfig)
	if err != nil {
		kw.Logger.Error().
			Err(err).
			Msg("Failed to marshal sweep config")
		return fmt.Errorf("failed to marshal sweep config: %w", err)
	}

	payloadSize := len(configJSON)
	kw.Logger.Info().
		Int("payload_size_bytes", payloadSize).
		Int("network_count", len(sweepConfig.Networks)).
		Msg("Evaluating sweep config size")

	// If it fits within the limit, write as a single file
	if payloadSize <= maxPayloadSize {
		configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", kw.AgentID)
		_, err = kw.KVClient.PutMany(ctx, &proto.PutManyRequest{
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
			Int("payload_size_bytes", payloadSize).
			Msg("Successfully wrote sweep config to KV store")
		return nil
	}

	// Need to chunk the config
	kw.Logger.Info().
		Int("total_networks", len(sweepConfig.Networks)).
		Int("payload_size_mb", payloadSize/bytesPerMB).
		Msg("Large sweep config detected, writing in chunks")

	// Calculate how many chunks we need
	totalChunks := (len(sweepConfig.Networks) + maxNetworksPerChunk - 1) / maxNetworksPerChunk
	
	// Also need to split DeviceTargets proportionally if they exist
	devicesPerChunk := 0
	if len(sweepConfig.DeviceTargets) > 0 {
		devicesPerChunk = (len(sweepConfig.DeviceTargets) + totalChunks - 1) / totalChunks
	}
	
	for i := 0; i < totalChunks; i++ {
		// Calculate network range for this chunk
		netStart := i * maxNetworksPerChunk
		netEnd := netStart + maxNetworksPerChunk
		if netEnd > len(sweepConfig.Networks) {
			netEnd = len(sweepConfig.Networks)
		}

		// Calculate device target range for this chunk
		var chunkDeviceTargets []models.DeviceTarget
		if len(sweepConfig.DeviceTargets) > 0 {
			devStart := i * devicesPerChunk
			devEnd := devStart + devicesPerChunk
			if devEnd > len(sweepConfig.DeviceTargets) {
				devEnd = len(sweepConfig.DeviceTargets)
			}
			chunkDeviceTargets = sweepConfig.DeviceTargets[devStart:devEnd]
		}

		// Create chunk with subset of data
		chunkConfig := &models.SweepConfig{
			Networks:      sweepConfig.Networks[netStart:netEnd],
			DeviceTargets: chunkDeviceTargets,
			Ports:         sweepConfig.Ports,
			SweepModes:    sweepConfig.SweepModes,
			Interval:      sweepConfig.Interval,
			Concurrency:   sweepConfig.Concurrency,
			Timeout:       sweepConfig.Timeout,
		}

		chunkJSON, err := json.Marshal(chunkConfig)
		if err != nil {
			kw.Logger.Error().
				Err(err).
				Int("chunk_index", i).
				Msg("Failed to marshal sweep config chunk")
			return fmt.Errorf("failed to marshal sweep config chunk %d: %w", i, err)
		}

		chunkKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep_chunk_%d.json", kw.AgentID, i)
		_, err = kw.KVClient.PutMany(ctx, &proto.PutManyRequest{
			Entries: []*proto.KeyValueEntry{{
				Key:   chunkKey,
				Value: chunkJSON,
			}},
		})

		if err != nil {
			return fmt.Errorf("failed to write sweep config chunk %d to %s: %w", i, chunkKey, err)
		}

		kw.Logger.Debug().
			Str("chunk_key", chunkKey).
			Int("chunk_index", i).
			Int("chunk_size_bytes", len(chunkJSON)).
			Int("networks_in_chunk", netEnd-netStart).
			Int("devices_in_chunk", len(chunkDeviceTargets)).
			Msg("Successfully wrote sweep config chunk")
	}

	// Write metadata to the original sweep.json key that the agent is watching
	metadataKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", kw.AgentID)
	metadata := map[string]interface{}{
		"chunked":      true,
		"chunk_count":  totalChunks,
		"total_chunks": totalChunks,
		"timestamp":    time.Now().UTC().Format(time.RFC3339),
	}
	metadataJSON, _ := json.Marshal(metadata)
	
	_, err = kw.KVClient.PutMany(ctx, &proto.PutManyRequest{
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
		Int("total_networks", len(sweepConfig.Networks)).
		Msg("Successfully wrote chunked sweep config to KV store")

	return nil
}
