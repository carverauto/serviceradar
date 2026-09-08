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

package sweeper

import (
	"context"
	"fmt"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func (s *NetworkSweeper) processResult(ctx context.Context, result *models.Result) error {
	ctx, cancel := context.WithTimeout(ctx, defaultResultTimeout)
	defer cancel()

	// Process basic result handling
	if err := s.processBasicResult(ctx, result); err != nil {
		return err
	}

	// Check if this result should be aggregated for a multi-IP device
	if s.shouldAggregateResult(result) {
		s.addResultToAggregator(result)
		return nil // Don't process immediately through device registry
	}

	// Process through unified device registry for all results (both available and unavailable)
	if s.deviceRegistry != nil {
		if err := s.processDeviceRegistry(result); err != nil {
			// Log error but don't fail the entire operation
			s.logger.Error().Err(err).Str("host", result.Target.Host).Msg("Failed to process sweep result through device registry")
		}
	}

	return nil
}

// processBasicResult handles the basic processing and saving of the result.
func (s *NetworkSweeper) processBasicResult(ctx context.Context, result *models.Result) error {
	// Process through existing pipeline
	if err := s.processor.Process(result); err != nil {
		return fmt.Errorf("processor error: %w", err)
	}

	if err := s.store.SaveResult(ctx, result); err != nil {
		return fmt.Errorf("store error: %w", err)
	}

	return nil
}

const (
	defaultName = "default"
)

// extractAgentInfo extracts agent/gateway/partition information from config and metadata.
func (s *NetworkSweeper) extractAgentInfo(result *models.Result) (agentID, gatewayID, partition string) {
	// Get agent/gateway info from config first, then try metadata
	agentID = defaultName
	gatewayID = defaultName
	partition = defaultName

	// Use config values if available
	if s.config.AgentID != "" {
		agentID = s.config.AgentID
	}

	if s.config.GatewayID != "" {
		gatewayID = s.config.GatewayID
	}

	if s.config.Partition != "" {
		partition = s.config.Partition
	}

	// Extract from metadata if available (metadata can override config)
	if result.Target.Metadata != nil {
		if id, ok := result.Target.Metadata["agent_id"].(string); ok && id != "" {
			agentID = id
		}

		if id, ok := result.Target.Metadata["gateway_id"].(string); ok && id != "" {
			gatewayID = id
		}

		if p, ok := result.Target.Metadata["partition"].(string); ok && p != "" {
			partition = p
		}
	}

	return agentID, gatewayID, partition
}

// createDeviceUpdate creates a DeviceUpdate from a Result.
func (*NetworkSweeper) createDeviceUpdate(result *models.Result, agentID, gatewayID, partition string) *models.DeviceUpdate {
	// Always generate a valid device ID with partition
	deviceID := fmt.Sprintf("%s:%s", partition, result.Target.Host)

	return &models.DeviceUpdate{
		AgentID:     agentID,
		GatewayID:   gatewayID,
		Partition:   partition,
		DeviceID:    deviceID,
		Source:      models.DiscoverySourceSweep,
		IP:          result.Target.Host,
		Timestamp:   result.LastSeen,
		IsAvailable: result.Available,
		Metadata:    make(map[string]string),
		Confidence:  models.GetSourceConfidence(models.DiscoverySourceSweep),
	}
}

// convertMetadataToStringMap converts metadata to a string map.
func convertMetadataToStringMap(deviceUpdate *models.DeviceUpdate, metadata map[string]interface{}) {
	if metadata == nil {
		return
	}

	for key, value := range metadata {
		if strVal, ok := value.(string); ok {
			deviceUpdate.Metadata[key] = strVal
		} else {
			deviceUpdate.Metadata[key] = fmt.Sprintf("%v", value)
		}
	}
}

// addAdditionalMetadata adds additional metadata to the DeviceUpdate.
func addAdditionalMetadata(deviceUpdate *models.DeviceUpdate, result *models.Result) {
	// Add sweep mode to metadata
	deviceUpdate.Metadata["sweep_mode"] = string(result.Target.Mode)
	if result.Target.Port > 0 {
		deviceUpdate.Metadata["port"] = fmt.Sprintf("%d", result.Target.Port)
	}

	// Add timing metadata
	deviceUpdate.Metadata["response_time"] = result.RespTime.String()
	deviceUpdate.Metadata["packet_loss"] = fmt.Sprintf("%.2f", result.PacketLoss)
}

// processDeviceRegistry processes the sweep result through the device registry.
func (s *NetworkSweeper) processDeviceRegistry(result *models.Result) error {
	agentID, gatewayID, partition := s.extractAgentInfo(result)
	deviceUpdate := s.createDeviceUpdate(result, agentID, gatewayID, partition)

	// Convert metadata to string map
	convertMetadataToStringMap(deviceUpdate, result.Target.Metadata)

	// Add additional metadata
	addAdditionalMetadata(deviceUpdate, result)

	// Use background context to avoid cancellation
	bgCtx := context.Background()

	return s.deviceRegistry.UpdateDevice(bgCtx, deviceUpdate)
}
