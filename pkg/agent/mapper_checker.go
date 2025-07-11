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

// Package agent pkg/agent/mapper_checker.go
package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/carverauto/serviceradar/pkg/config"
	ggrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	discovery "github.com/carverauto/serviceradar/proto/discovery"
)

// MapperConfig represents the configuration for the mapper service
type MapperConfig struct {
	Address string `json:"address"` // Address of the mapper service
}

type MapperDiscoveryDetails struct {
	IncludeRawData bool `json:"include_raw_data,omitempty"`
}

// MapperDiscoveryChecker implements checker.Checker for initiating and monitoring mapper discovery jobs.
type MapperDiscoveryChecker struct {
	mapperAddress string
	details       string
	security      *models.SecurityConfig
	client        *ggrpc.Client
	mapperClient  discovery.DiscoveryServiceClient
	mu            sync.Mutex
	logger        logger.Logger
}

// NewMapperDiscoveryChecker creates a new instance of MapperDiscoveryChecker.
func NewMapperDiscoveryChecker(
	ctx context.Context,
	details string,
	security *models.SecurityConfig,
	log logger.Logger,
) (*MapperDiscoveryChecker, error) {
	log.Info().Str("details", details).Msg("Creating MapperDiscoveryChecker")

	mapperConfig, err := loadMapperConfig(ctx, log)
	if err != nil {
		return nil, fmt.Errorf("failed to load mapper configuration: %w", err)
	}

	clientCfg := ggrpc.ClientConfig{
		Address:    mapperConfig.Address,
		MaxRetries: 3,
		Logger:     log,
	}

	if security != nil {
		provider, providerErr := ggrpc.NewSecurityProvider(ctx, security, log)
		if providerErr != nil {
			return nil, fmt.Errorf("failed to create security provider: %w", providerErr)
		}

		clientCfg.SecurityProvider = provider
	}

	client, err := ggrpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to mapper service: %w", err)
	}

	return &MapperDiscoveryChecker{
		mapperAddress: mapperConfig.Address,
		details:       details,
		security:      security,
		client:        client,
		mapperClient:  discovery.NewDiscoveryServiceClient(client.GetConnection()),
		logger:        log,
	}, nil
}

// loadMapperConfig loads the mapper configuration from the standard config path
func loadMapperConfig(ctx context.Context, log logger.Logger) (*MapperConfig, error) {
	configPath := filepath.Join(defaultConfigPath, "mapper.json")

	if _, err := os.Stat(configPath); err != nil {
		if os.IsNotExist(err) {
			log.Info().Str("configPath", configPath).Msg("Mapper config not found, using default address")
			return &MapperConfig{Address: "127.0.0.1:50056"}, nil
		}

		return nil, fmt.Errorf("config file error: %w", err)
	}

	var cfg MapperConfig

	cfgLoader := config.NewConfig(log)
	if err := cfgLoader.LoadAndValidate(ctx, configPath, &cfg); err != nil {
		return nil, fmt.Errorf("failed to load mapper config: %w", err)
	}

	if cfg.Address == "" {
		return nil, fmt.Errorf("mapper address cannot be empty")
	}

	log.Info().Str("configPath", configPath).Str("address", cfg.Address).Msg("Loaded mapper config")

	return &cfg, nil
}

// Check parses the discovery parameters, optionally initiates a job, and returns the status/results
func (mdc *MapperDiscoveryChecker) Check(ctx context.Context, req *proto.StatusRequest) (bool, json.RawMessage) {
	mdc.mu.Lock()
	defer mdc.mu.Unlock()

	if req == nil {
		return false, jsonError("No StatusRequest provided for MapperDiscoveryChecker")
	}

	var checkerDetails MapperDiscoveryDetails

	if req.Details != "" { // req.Details is the JSON string from the checker's configuration
		if err := json.Unmarshal([]byte(req.Details), &checkerDetails); err != nil {
			mdc.logger.Warn().Err(err).Str("details", req.Details).Msg("Failed to parse details JSON, using defaults")
		}
	}

	agentIDForMapperCall := req.AgentId
	pollerIDForMapperCall := req.PollerId

	// Construct the request for the new/modified gRPC method
	latestResultsReq := &discovery.GetLatestCachedResultsRequest{ // Assuming this new request type
		AgentId:        agentIDForMapperCall,
		PollerId:       pollerIDForMapperCall,
		IncludeRawData: checkerDetails.IncludeRawData,
	}

	mdc.logger.Info().Str("agentID", agentIDForMapperCall).Str("pollerID", pollerIDForMapperCall).Bool("includeRaw", checkerDetails.IncludeRawData).Msg("Requesting latest cached results")

	// Call the new gRPC method (ensure your proto client 'mdc.mapperClient' has this method)
	resultsResp, err := mdc.mapperClient.GetLatestCachedResults(ctx, latestResultsReq)
	if err != nil {
		errMsg := fmt.Sprintf("Failed to get latest cached discovery results from mapper: %v", err)
		mdc.logger.Error().Err(err).Msg("Failed to get latest cached discovery results from mapper")

		return false, jsonError(errMsg) // Checker is unavailable if gRPC call fails
	}

	// Process the ResultsResponse from the mapper
	var isDataUsable bool // Indicates if the data itself is complete/useful

	var responseData json.RawMessage

	if resultsResp.Error != "" {
		errMsg := fmt.Sprintf("Mapper reported error for latest cached results: %s", resultsResp.Error)
		mdc.logger.Error().Str("error", resultsResp.Error).Msg("Mapper reported error for latest cached results")
		// Mapper service is up (it responded), but there's an application error with the data.
		isDataUsable = false
		responseData = jsonError(errMsg)
	} else {
		switch resultsResp.Status {
		case discovery.DiscoveryStatus_COMPLETED:
			// Data is complete from mapper's perspective.
			// 'isDataUsable' can further check if devices were actually found.
			isDataUsable, responseData = mdc.formatFinalResults(resultsResp, agentIDForMapperCall, pollerIDForMapperCall)
		case discovery.DiscoveryStatus_RUNNING:
			// Mapper is actively running its scheduled job. Data might be partial or from a previous run.
			mdc.logger.Info().Float32("progress", resultsResp.Progress).Msg("Mapper status is RUNNING")

			isDataUsable = len(resultsResp.Devices) > 0 // Usable if some devices are present
			responseData = mdc.formatProgressStatus(resultsResp)
		case discovery.DiscoveryStatus_PENDING:
			// Mapper's job is pending, or no data cached yet.
			mdc.logger.Info().Msg("Mapper status is PENDING. No significant data expected.")

			isDataUsable = false
			responseData = mdc.formatProgressStatus(resultsResp)
		case discovery.DiscoveryStatus_FAILED:
			// The mapper's last discovery attempt failed. Service is up, but data is problematic.
			errMsg := fmt.Sprintf("Latest cached discovery from mapper shows FAILED status: %s", resultsResp.Error)
			mdc.logger.Error().Str("error", resultsResp.Error).Msg("Latest cached discovery from mapper shows FAILED status")

			isDataUsable = false
			responseData = jsonError(errMsg)
		case discovery.DiscoveryStatus_UNKNOWN:
			// The mapper returned an unknown status.
			errMsg := fmt.Sprintf("Mapper returned UNKNOWN status. Error: %s", resultsResp.Error)
			mdc.logger.Error().Str("error", resultsResp.Error).Msg("Mapper returned UNKNOWN status")

			isDataUsable = false
			responseData = jsonError(errMsg)
		case discovery.DiscoveryStatus_CANCELED:
			// The mapper's discovery was canceled.
			errMsg := fmt.Sprintf("Mapper discovery was CANCELED. Error: %s", resultsResp.Error)
			mdc.logger.Warn().Str("error", resultsResp.Error).Msg("Mapper discovery was CANCELED")

			isDataUsable = false
			responseData = jsonError(errMsg)
		default:
			errMsg := fmt.Sprintf("Mapper returned unhandled status: %s. Error: %s", resultsResp.Status, resultsResp.Error)
			mdc.logger.Error().Str("status", resultsResp.Status.String()).Str("error", resultsResp.Error).Msg("Mapper returned unhandled status")

			isDataUsable = false
			responseData = jsonError(errMsg)
		}
	}

	mdc.logger.Info().Str("status", resultsResp.Status.String()).Bool("isDataUsable", isDataUsable).Int("devices", len(resultsResp.Devices)).Msg("Reporting mapper discovery results")

	// The first boolean (overall checker availability) is true because the mapper service responded.
	// The 'responseData' carries the actual status of the discovery data.
	return true, responseData
}

// formatProgressStatus formats in-progress or partial discovery results.
func (mdc *MapperDiscoveryChecker) formatProgressStatus(resultsResp *discovery.ResultsResponse) json.RawMessage {
	message := fmt.Sprintf("Mapper discovery status: %s (progress: %.1f%%). Devices: %d, Interfaces: %d, Links: %d.",
		resultsResp.Status, resultsResp.Progress,
		len(resultsResp.Devices), len(resultsResp.Interfaces), len(resultsResp.Topology))
	if resultsResp.Error != "" {
		message += " Error: " + resultsResp.Error
	}

	resp := map[string]interface{}{
		"status":               resultsResp.Status.String(), // Use String() for enum to get "PENDING", "RUNNING", etc.
		"discovery_id":         resultsResp.DiscoveryId,     // Mapper's internal ID for the job that produced the cache
		"progress":             resultsResp.Progress,
		"devices_found":        len(resultsResp.Devices),
		"interfaces_found":     len(resultsResp.Interfaces),
		"topology_links_found": len(resultsResp.Topology),
		"message":              message,
		"error":                resultsResp.Error,
	}

	data, err := json.Marshal(resp)
	if err != nil {
		mdc.logger.Error().Err(err).Msg("Failed to marshal progress status")
		return jsonError(fmt.Sprintf("Failed to marshal progress status: %v", err))
	}

	return data
}

func (mdc *MapperDiscoveryChecker) formatFinalResults(
	resultsResp *discovery.ResultsResponse,
	requestingAgentID string,
	requestingPollerID string) (bool, json.RawMessage) {
	// The AgentID and PollerID in the SNMPDiscoveryDataPayload should ideally reflect the context
	// of the data generation. If the mapper's ResultsResponse includes this (e.g., in metadata),
	// it should be used. Otherwise, using the requesting agent/poller IDs provides retrieval context.
	payload := models.SNMPDiscoveryDataPayload{
		Devices:    resultsResp.Devices,
		Interfaces: resultsResp.Interfaces,
		Topology:   resultsResp.Topology,
		AgentID:    requestingAgentID,  // Context of who is requesting/retrieving the cache
		PollerID:   requestingPollerID, // Context of who is requesting/retrieving the cache
	}

	data, err := json.Marshal(payload)
	if err != nil {
		mdc.logger.Error().Err(err).Msg("Failed to marshal SNMP discovery results payload")
		return false, jsonError(fmt.Sprintf("Failed to marshal SNMP discovery results payload: %v", err))
	}

	// Data is considered usable if the status is COMPLETED and there are devices.
	isDataUsable := resultsResp.Status == discovery.DiscoveryStatus_COMPLETED && len(resultsResp.Devices) > 0

	mdc.logger.Info().Str("status", resultsResp.Status.String()).Bool("isDataUsable", isDataUsable).Int("devices", len(resultsResp.Devices)).Msg("Formatted final results")

	return isDataUsable, data
}

// Close gracefully closes the gRPC client connection to the mapper.
func (mdc *MapperDiscoveryChecker) Close() error {
	if mdc.client != nil {
		return mdc.client.Close()
	}

	return nil
}
