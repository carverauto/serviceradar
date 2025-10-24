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
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// WriteSweepConfig generates and writes the sweep config to KV.
func (kw *DefaultKVWriter) WriteSweepConfig(ctx context.Context, sweepConfig *models.SweepConfig) error {
	configJSON, err := json.Marshal(sweepConfig)
	if err != nil {
		kw.Logger.Error().
			Err(err).
			Msg("Failed to marshal sweep config")

		return fmt.Errorf("failed to marshal sweep config: %w", err)
	}

	if kw.DataClient != nil {
		if err := kw.writeObjectConfig(ctx, configJSON); err == nil {
			return nil
		} else {
			kw.Logger.Warn().
				Err(err).
				Str("agent_id", kw.AgentID).
				Msg("Falling back to KV entries after DataService upload failure")
		}
	}

	// Try writing as a single file first
	if kw.canWriteAsSingleFile(configJSON) {
		return kw.writeSingleConfig(ctx, configJSON)
	}

	return ErrSweepUploadFallbackExceeded
}

const (
	bytesPerKB      = 1024
	bytesPerMB      = bytesPerKB * 1024
	maxPayloadSize  = 3 * bytesPerMB // 3MB to stay well under gRPC 4MB limit
	objectChunkSize = 256 * bytesPerKB
)

var (
	// ErrSweepUploadFallbackExceeded indicates both object and KV uploads failed due to size constraints.
	ErrSweepUploadFallbackExceeded = errors.New("sweep config exceeds KV payload limits and DataService upload failed")
	// ErrDataServiceObjectInfoMissing indicates the DataService response lacked object metadata.
	ErrDataServiceObjectInfoMissing = errors.New("DataService response missing object info")
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

func (kw *DefaultKVWriter) writeObjectConfig(ctx context.Context, configJSON []byte) error {
	objectKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", kw.AgentID)

	stream, err := kw.DataClient.UploadObject(ctx)
	if err != nil {
		return fmt.Errorf("failed to open DataService stream: %w", err)
	}

	hash := sha256.Sum256(configJSON)
	metadata := &proto.ObjectMetadata{
		Key:         objectKey,
		ContentType: "application/json",
		TotalSize:   int64(len(configJSON)),
		Sha256:      hex.EncodeToString(hash[:]),
		Attributes: map[string]string{
			"agent_id": kw.AgentID,
			"service":  "sweep",
		},
	}

	chunkSize := objectChunkSize
	if chunkSize <= 0 {
		chunkSize = len(configJSON)
	}
	if chunkSize == 0 {
		chunkSize = 1
	}

	for idx, offset := 0, 0; offset < len(configJSON); idx++ {
		end := offset + chunkSize
		if end > len(configJSON) {
			end = len(configJSON)
		}

		chunk := &proto.ObjectUploadChunk{
			Data:       configJSON[offset:end],
			ChunkIndex: uint32(idx),
			IsFinal:    end == len(configJSON),
		}

		if idx == 0 {
			chunk.Metadata = metadata
		}

		if err := stream.Send(chunk); err != nil {
			return fmt.Errorf("failed to stream sweep config chunk %d: %w", idx, err)
		}

		offset = end
	}

	resp, err := stream.CloseAndRecv()
	if err != nil {
		return fmt.Errorf("failed to finalize sweep config upload: %w", err)
	}

	info := resp.GetInfo()
	if info == nil {
		return fmt.Errorf("%w: %s", ErrDataServiceObjectInfoMissing, objectKey)
	}

	storedMeta := info.GetMetadata()
	contentType := "application/json"
	if storedMeta != nil && storedMeta.GetContentType() != "" {
		contentType = storedMeta.GetContentType()
	}

	metadataJSON, err := json.Marshal(map[string]interface{}{
		"storage":      "data_service",
		"object_key":   objectKey,
		"content_type": contentType,
		"sha256":       info.GetSha256(),
		"total_size":   info.GetSize(),
		"chunks":       info.GetChunks(),
		"updated_at":   time.Now().UTC().Format(time.RFC3339),
	})
	if err != nil {
		return fmt.Errorf("failed to marshal sweep metadata pointer: %w", err)
	}

	if _, err := kw.KVClient.PutMany(ctx, &proto.PutManyRequest{
		Entries: []*proto.KeyValueEntry{{
			Key:   objectKey,
			Value: metadataJSON,
		}},
	}); err != nil {
		return fmt.Errorf("failed to write sweep metadata pointer to KV: %w", err)
	}

	kw.Logger.Info().
		Str("object_key", objectKey).
		Int("payload_size_bytes", len(configJSON)).
		Uint64("chunks", info.GetChunks()).
		Msg("Successfully wrote sweep config to DataService object store")

	return nil
}
