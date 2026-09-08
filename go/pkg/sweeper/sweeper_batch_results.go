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
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func (s *NetworkSweeper) processBatchedResults(ctx context.Context, batch []models.Result) error {
	if len(batch) == 0 {
		return nil
	}

	// Pre-allocate context with timeout for the entire batch
	batchCtx, cancel := context.WithTimeout(ctx, time.Duration(len(batch))*defaultResultTimeout)
	defer cancel()

	// Track batch statistics
	errors := 0
	aggregated := 0
	deviceRegistryUpdates := 0

	// Process each result in the batch
	for i := range batch {
		result := &batch[i]

		// Process basic result handling (store, processor)
		if err := s.processBasicResult(batchCtx, result); err != nil {
			s.logger.Error().Err(err).
				Str("host", result.Target.Host).
				Msg("Failed to process basic result in batch")

			errors++

			continue
		}

		// Check if this result should be aggregated for a multi-IP device
		if s.shouldAggregateResult(result) {
			s.addResultToAggregator(result)

			aggregated++

			continue // Don't process immediately through device registry
		}

		// Process through unified device registry for non-aggregated results
		if s.deviceRegistry != nil {
			if err := s.processDeviceRegistry(result); err != nil {
				s.logger.Error().Err(err).
					Str("host", result.Target.Host).
					Msg("Failed to process result through device registry in batch")

				errors++

				continue
			}

			deviceRegistryUpdates++
		}
	}

	// Log only on errors to reduce log volume at scale
	if errors > 0 {
		s.logger.Warn().
			Int("batchSize", len(batch)).
			Int("errors", errors).
			Int("aggregated", aggregated).
			Int("deviceRegistryUpdates", deviceRegistryUpdates).
			Msg("Batch result processing completed with errors")
	}

	return nil
}

// prepareDeviceAggregators initializes result aggregators for devices with multiple IPs
func (s *NetworkSweeper) prepareDeviceAggregators(targets []models.Target) {
	s.resultsMu.Lock()
	defer s.resultsMu.Unlock()

	// Clear previous aggregators
	s.deviceResults = make(map[string]*DeviceResultAggregator)

	// Group targets by device
	deviceTargets := make(map[string][]models.Target)
	deviceMetadata := make(map[string]map[string]interface{})

	for _, target := range targets {
		deviceID := s.extractDeviceID(target)
		if deviceID != "" {
			deviceTargets[deviceID] = append(deviceTargets[deviceID], target)

			if len(deviceMetadata[deviceID]) == 0 && target.Metadata != nil {
				deviceMetadata[deviceID] = target.Metadata
			}
		}
	}

	// Create aggregators for devices with multiple IPs
	for deviceID, targets := range deviceTargets {
		if len(targets) <= 1 {
			continue
		}

		expectedIPs := make([]string, 0, len(targets))
		for _, t := range targets {
			expectedIPs = append(expectedIPs, t.Host)
		}

		agentID, gatewayID, partition := s.extractAgentInfoFromMetadata(deviceMetadata[deviceID])

		s.deviceResults[deviceID] = &DeviceResultAggregator{
			DeviceID:    deviceID,
			Results:     make([]*models.Result, 0, len(targets)),
			ExpectedIPs: expectedIPs,
			Metadata:    deviceMetadata[deviceID],
			AgentID:     agentID,
			GatewayID:   gatewayID,
			Partition:   partition,
		}

		s.logger.Debug().
			Str("deviceID", deviceID).
			Strs("expectedIPs", expectedIPs).
			Msg("Created device result aggregator for multi-IP device")
	}
}

// extractDeviceID extracts a unique device identifier from target metadata
func (*NetworkSweeper) extractDeviceID(target models.Target) string {
	if target.Metadata == nil {
		return ""
	}

	// Try armis_device_id first
	if armisID, ok := target.Metadata["armis_device_id"]; ok {
		switch v := armisID.(type) {
		case string:
			if v != "" {
				return "armis:" + v
			}
		case int:
			return fmt.Sprintf("armis:%d", v)
		case int64:
			return fmt.Sprintf("armis:%d", v)
		case float64:
			return fmt.Sprintf("armis:%d", int64(v))
		}
	}

	// Try integration_id
	if integrationID, ok := target.Metadata["integration_id"]; ok {
		switch v := integrationID.(type) {
		case string:
			if v != "" {
				return "integration:" + v
			}
		case int:
			return fmt.Sprintf("integration:%d", v)
		case int64:
			return fmt.Sprintf("integration:%d", v)
		case float64:
			return fmt.Sprintf("integration:%d", int64(v))
		}
	}

	return ""
}
