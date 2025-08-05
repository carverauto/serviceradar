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

	// Log payload size for monitoring large configurations
	payloadSize := len(configJSON)
	kw.Logger.Info().
		Int("payload_size_bytes", payloadSize).
		Int("network_count", len(sweepConfig.Networks)).
		Msg("Writing sweep config to KV")

	// Warn if payload is approaching gRPC limits (default 4MB)
	const (
		bytesPerKB           = 1024
		bytesPerMB           = bytesPerKB * 1024
		warningSizeThreshold = 2 * bytesPerMB // 2MB
	)

	if payloadSize > warningSizeThreshold {
		kw.Logger.Warn().
			Int("payload_size_mb", payloadSize/bytesPerMB).
			Int("network_count", len(sweepConfig.Networks)).
			Msg("Large sweep config detected - consider chunking if performance issues occur")
	}

	// Use a configurable key, defaulting to "config/agentID/network-sweep"
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
