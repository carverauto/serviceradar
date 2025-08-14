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
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const (
	// Maximum networks to include in a single payload
	maxNetworksInPayload = 5000
	// Hard limit for gRPC message size (4MB default, using 2MB as safety margin for large configs)
	maxGRPCPayloadSize = 2 * 1024 * 1024 // 2MB
)

// WriteSweepConfig generates and writes the sweep config to KV.
// For very large configs (>5000 networks), it uses a compressed representation.
func (kw *DefaultKVWriter) WriteSweepConfig(ctx context.Context, sweepConfig *models.SweepConfig) error {
	networkCount := len(sweepConfig.Networks)

	kw.Logger.Info().
		Int("network_count", networkCount).
		Msg("Preparing to write sweep config to KV")

	// Try writing the full config first
	configJSON, err := json.Marshal(sweepConfig)
	if err != nil {
		kw.Logger.Error().
			Err(err).
			Msg("Failed to marshal sweep config")

		return fmt.Errorf("failed to marshal sweep config: %w", err)
	}

	payloadSize := len(configJSON)

	// If the config is too large, use an alternative approach
	if payloadSize > maxGRPCPayloadSize || networkCount > maxNetworksInPayload {
		kw.Logger.Warn().
			Int("payload_size_bytes", payloadSize).
			Int("max_payload_size_bytes", maxGRPCPayloadSize).
			Int("network_count", networkCount).
			Int("max_networks", maxNetworksInPayload).
			Msg("Configuration is too large, using optimized storage approach")

		return kw.writeLargeConfig(ctx, sweepConfig)
	}

	// Write normal config
	return kw.writeNormalConfig(ctx, sweepConfig, configJSON)
}

// writeNormalConfig writes a regular-sized config
func (kw *DefaultKVWriter) writeNormalConfig(ctx context.Context, sweepConfig *models.SweepConfig, configJSON []byte) error {
	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", kw.AgentID)

	_, err := kw.KVClient.Put(ctx, &proto.PutRequest{
		Key:   configKey,
		Value: configJSON,
	})

	if err != nil {
		return fmt.Errorf("failed to write sweep config to %s: %w", configKey, err)
	}

	kw.Logger.Info().
		Str("config_key", configKey).
		Int("payload_size_bytes", len(configJSON)).
		Int("network_count", len(sweepConfig.Networks)).
		Msg("Successfully wrote normal sweep config to KV store")

	return nil
}

// writeLargeConfig writes a large config by storing individual networks as device targets
// This approach converts large network lists to individual device targets, which is more efficient
func (kw *DefaultKVWriter) writeLargeConfig(ctx context.Context, sweepConfig *models.SweepConfig) error {
	// Create a new config with networks converted to device targets
	optimizedConfig := &models.SweepConfig{
		Ports:         sweepConfig.Ports,
		SweepModes:    sweepConfig.SweepModes,
		Interval:      sweepConfig.Interval,
		Concurrency:   sweepConfig.Concurrency,
		Timeout:       sweepConfig.Timeout,
		ICMPCount:     sweepConfig.ICMPCount,
		HighPerfICMP:  sweepConfig.HighPerfICMP,
		ICMPRateLimit: sweepConfig.ICMPRateLimit,
		DeviceTargets: make([]models.DeviceTarget, 0, len(sweepConfig.Networks)+len(sweepConfig.DeviceTargets)),
	}

	// Keep existing device targets
	optimizedConfig.DeviceTargets = append(optimizedConfig.DeviceTargets, sweepConfig.DeviceTargets...)

	// Convert networks to device targets (each network becomes a device target)
	// Convert sweep modes from strings to SweepMode types
	sweepModes := make([]models.SweepMode, len(sweepConfig.SweepModes))
	for i, mode := range sweepConfig.SweepModes {
		sweepModes[i] = models.SweepMode(mode)
	}

	for _, network := range sweepConfig.Networks {
		deviceTarget := models.DeviceTarget{
			Network:    network,
			Source:     string(models.DiscoverySourceArmis), // Convert to string
			SweepModes: sweepModes,                          // Use converted sweep modes
			Metadata: map[string]string{
				"converted_from_network": "true",
				"original_network_count": fmt.Sprintf("%d", len(sweepConfig.Networks)),
				"conversion_timestamp":   fmt.Sprintf("%d", time.Now().Unix()),
			},
		}
		optimizedConfig.DeviceTargets = append(optimizedConfig.DeviceTargets, deviceTarget)
	}

	// Clear networks array since they're now in device targets
	optimizedConfig.Networks = []string{}

	// Marshal the optimized config
	configJSON, err := json.Marshal(optimizedConfig)
	if err != nil {
		return fmt.Errorf("failed to marshal optimized sweep config: %w", err)
	}

	// Check if it's still too large and apply further optimization if needed
	if len(configJSON) > maxGRPCPayloadSize {
		kw.Logger.Warn().
			Int("optimized_size_bytes", len(configJSON)).
			Int("max_size_bytes", maxGRPCPayloadSize).
			Int("device_target_count", len(optimizedConfig.DeviceTargets)).
			Msg("Optimized config still too large, applying network aggregation")

		return kw.writeAggregatedConfig(ctx, sweepConfig)
	}

	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", kw.AgentID)

	_, err = kw.KVClient.Put(ctx, &proto.PutRequest{
		Key:   configKey,
		Value: configJSON,
	})

	if err != nil {
		return fmt.Errorf("failed to write optimized sweep config to %s: %w", configKey, err)
	}

	kw.Logger.Info().
		Str("config_key", configKey).
		Int("payload_size_bytes", len(configJSON)).
		Int("original_network_count", len(sweepConfig.Networks)).
		Int("device_target_count", len(optimizedConfig.DeviceTargets)).
		Msg("Successfully wrote optimized large sweep config to KV store")

	return nil
}

// writeAggregatedConfig handles truly massive configs by aggregating individual IPs into larger network blocks
func (kw *DefaultKVWriter) writeAggregatedConfig(ctx context.Context, sweepConfig *models.SweepConfig) error {
	kw.Logger.Info().
		Int("original_network_count", len(sweepConfig.Networks)).
		Msg("Writing aggregated config for extremely large configuration")

	// Group individual IPs by their /24 networks to reduce the total number of entries
	networkMap := make(map[string]int) // network -> count of IPs in that network

	var otherNetworks []string // networks that aren't /32 IPs

	for _, network := range sweepConfig.Networks {
		if strings.HasSuffix(network, "/32") {
			// This is an individual IP, group it by /24
			ip := strings.TrimSuffix(network, "/32")
			parts := strings.Split(ip, ".")

			if len(parts) == 4 {
				subnet := fmt.Sprintf("%s.%s.%s.0/24", parts[0], parts[1], parts[2])
				networkMap[subnet]++
			} else {
				otherNetworks = append(otherNetworks, network)
			}
		} else {
			// Keep non-/32 networks as-is
			otherNetworks = append(otherNetworks, network)
		}
	}

	// Convert grouped networks back to a list
	aggregatedNetworks := make([]string, 0, len(networkMap)+len(otherNetworks))
	aggregatedNetworks = append(aggregatedNetworks, otherNetworks...)

	totalAggregatedIPs := 0

	for subnet, count := range networkMap {
		aggregatedNetworks = append(aggregatedNetworks, subnet)
		totalAggregatedIPs += count
	}

	kw.Logger.Info().
		Int("original_networks", len(sweepConfig.Networks)).
		Int("aggregated_networks", len(aggregatedNetworks)).
		Int("total_aggregated_ips", totalAggregatedIPs).
		Int("reduction_ratio", len(sweepConfig.Networks)/len(aggregatedNetworks)).
		Msg("Aggregated individual IPs into subnet blocks")

	// Create aggregated config
	aggregatedConfig := &models.SweepConfig{
		Networks:      aggregatedNetworks,
		Ports:         sweepConfig.Ports,
		SweepModes:    sweepConfig.SweepModes,
		Interval:      sweepConfig.Interval,
		Concurrency:   sweepConfig.Concurrency,
		Timeout:       sweepConfig.Timeout,
		ICMPCount:     sweepConfig.ICMPCount,
		HighPerfICMP:  sweepConfig.HighPerfICMP,
		ICMPRateLimit: sweepConfig.ICMPRateLimit,
		DeviceTargets: sweepConfig.DeviceTargets, // Keep existing device targets
	}

	// Marshal and check size
	configJSON, err := json.Marshal(aggregatedConfig)
	if err != nil {
		return fmt.Errorf("failed to marshal aggregated sweep config: %w", err)
	}

	// Final size check
	if len(configJSON) > maxGRPCPayloadSize {
		kw.Logger.Error().
			Int("final_size_bytes", len(configJSON)).
			Int("max_size_bytes", maxGRPCPayloadSize).
			Int("aggregated_network_count", len(aggregatedNetworks)).
			Msg("Even aggregated config exceeds size limits - configuration is too large")

		return fmt.Errorf(
			"configuration exceeds maximum size even after aggregation (%d bytes > %d bytes limit) with %d networks - manual intervention required",
			len(configJSON), maxGRPCPayloadSize, len(aggregatedNetworks))
	}

	configKey := fmt.Sprintf("agents/%s/checkers/sweep/sweep.json", kw.AgentID)

	_, err = kw.KVClient.Put(ctx, &proto.PutRequest{
		Key:   configKey,
		Value: configJSON,
	})

	if err != nil {
		return fmt.Errorf("failed to write aggregated sweep config to %s: %w", configKey, err)
	}

	kw.Logger.Info().
		Str("config_key", configKey).
		Int("payload_size_bytes", len(configJSON)).
		Int("original_network_count", len(sweepConfig.Networks)).
		Int("aggregated_network_count", len(aggregatedNetworks)).
		Float64("size_reduction_percent", float64(len(sweepConfig.Networks)-len(aggregatedNetworks))/float64(len(sweepConfig.Networks))*100).
		Msg("Successfully wrote aggregated sweep config to KV store")

	return nil
}
