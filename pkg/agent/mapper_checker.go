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
	"github.com/carverauto/serviceradar/pkg/config"
	ggrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	discovery "github.com/carverauto/serviceradar/proto/discovery"
	"log"
	"os"
	"path/filepath"
	"sync"
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
}

// NewMapperDiscoveryChecker creates a new instance of MapperDiscoveryChecker.
func NewMapperDiscoveryChecker(
	ctx context.Context,
	details string,
	security *models.SecurityConfig,
) (*MapperDiscoveryChecker, error) {
	log.Printf("Creating MapperDiscoveryChecker with details: %s", details)

	mapperConfig, err := loadMapperConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to load mapper configuration: %w", err)
	}

	clientCfg := ggrpc.ClientConfig{
		Address:    mapperConfig.Address,
		MaxRetries: 3,
	}

	if security != nil {
		provider, providerErr := ggrpc.NewSecurityProvider(ctx, security)
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
	}, nil
}

// loadMapperConfig loads the mapper configuration from the standard config path
func loadMapperConfig(ctx context.Context) (*MapperConfig, error) {
	configPath := filepath.Join(defaultConfigPath, "mapper.json")

	if _, err := os.Stat(configPath); err != nil {
		if os.IsNotExist(err) {
			log.Printf("Mapper config not found at %s, using default address", configPath)
			return &MapperConfig{Address: "127.0.0.1:50056"}, nil
		}

		return nil, fmt.Errorf("config file error: %w", err)
	}

	var cfg MapperConfig

	cfgLoader := config.NewConfig()
	if err := cfgLoader.LoadAndValidate(ctx, configPath, &cfg); err != nil {
		return nil, fmt.Errorf("failed to load mapper config: %w", err)
	}

	if cfg.Address == "" {
		return nil, fmt.Errorf("mapper address cannot be empty")
	}

	log.Printf("Loaded mapper config from %s: address=%s", configPath, cfg.Address)

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
			log.Printf("MapperDiscoveryChecker: Failed to parse details JSON: %v. Details: %s. Using defaults.", err, req.Details)
			// Continue with default IncludeRawData = false
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

	log.Printf("MapperDiscoveryChecker: Requesting latest cached results. AgentID: %s, PollerID: %s, IncludeRaw: %t",
		agentIDForMapperCall, pollerIDForMapperCall, checkerDetails.IncludeRawData)

	// Call the new gRPC method (ensure your proto client 'mdc.mapperClient' has this method)
	resultsResp, err := mdc.mapperClient.GetLatestCachedResults(ctx, latestResultsReq)
	if err != nil {
		errMsg := fmt.Sprintf("Failed to get latest cached discovery results from mapper: %v", err)
		log.Printf("MapperDiscoveryChecker: %s", errMsg)
		return false, jsonError(errMsg) // Checker is unavailable if gRPC call fails
	}

	// Process the ResultsResponse from the mapper
	var isDataUsable bool // Indicates if the data itself is complete/useful
	var responseData json.RawMessage

	if resultsResp.Error != "" {
		errMsg := fmt.Sprintf("Mapper reported error for latest cached results: %s", resultsResp.Error)
		log.Printf("MapperDiscoveryChecker: %s", errMsg)
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
			log.Printf("MapperDiscoveryChecker: Mapper status is RUNNING. Progress: %.1f%%", resultsResp.Progress)
			isDataUsable = len(resultsResp.Devices) > 0 // Usable if some devices are present
			_, responseData = mdc.formatProgressStatus(resultsResp)
		case discovery.DiscoveryStatus_PENDING:
			// Mapper's job is pending, or no data cached yet.
			log.Printf("MapperDiscoveryChecker: Mapper status is PENDING. No significant data expected.")
			isDataUsable = false
			_, responseData = mdc.formatProgressStatus(resultsResp)
		case discovery.DiscoveryStatus_FAILED:
			// The mapper's last discovery attempt failed. Service is up, but data is problematic.
			errMsg := fmt.Sprintf("Latest cached discovery from mapper shows FAILED status: %s", resultsResp.Error)
			log.Printf("MapperDiscoveryChecker: %s", errMsg)
			isDataUsable = false
			responseData = jsonError(errMsg)
		default: // UNKNOWN, CANCELED by mapper internally, etc.
			errMsg := fmt.Sprintf("Mapper returned unhandled or no-data status: %s. Error: %s", resultsResp.Status, resultsResp.Error)
			log.Printf("MapperDiscoveryChecker: %s", errMsg)
			isDataUsable = false
			responseData = jsonError(errMsg)
		}
	}

	log.Printf("MapperDiscoveryChecker: Reporting. Mapper Status: %s, IsDataUsableByAgent: %v, Devices: %d",
		resultsResp.Status, isDataUsable, len(resultsResp.Devices))

	// The first boolean (overall checker availability) is true because the mapper service responded.
	// The 'responseData' carries the actual status of the discovery data.
	return true, responseData
}

// formatProgressStatus formats in-progress or partial discovery results.
// The first boolean it returns indicates if the data is considered complete and usable by the agent (typically false for progress).
func (mdc *MapperDiscoveryChecker) formatProgressStatus(resultsResp *discovery.ResultsResponse) (bool, json.RawMessage) {
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
		log.Printf("MapperDiscoveryChecker: Failed to marshal progress status: %v", err)
		return false, jsonError(fmt.Sprintf("Failed to marshal progress status: %v", err))
	}

	// For progress, data is not considered fully "usable" in the sense of being complete.
	// However, if status is RUNNING and there's data, it might be partially usable.
	isDataUsable := resultsResp.Status == discovery.DiscoveryStatus_RUNNING && len(resultsResp.Devices) > 0

	return isDataUsable, data
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
		log.Printf("MapperDiscoveryChecker: Failed to marshal SNMP discovery results payload: %v", err)
		return false, jsonError(fmt.Sprintf("Failed to marshal SNMP discovery results payload: %v", err))
	}

	// Data is considered usable if the status is COMPLETED and there are devices.
	isDataUsable := resultsResp.Status == discovery.DiscoveryStatus_COMPLETED && len(resultsResp.Devices) > 0

	log.Printf("MapperDiscoveryChecker: Formatted final results. Mapper Status: %s, IsDataUsableByAgent: %v. Devices: %d",
		resultsResp.Status, isDataUsable, len(resultsResp.Devices))

	return isDataUsable, data
}

// Close gracefully closes the gRPC client connection to the mapper.
func (mdc *MapperDiscoveryChecker) Close() error {
	if mdc.client != nil {
		return mdc.client.Close()
	}

	return nil
}
