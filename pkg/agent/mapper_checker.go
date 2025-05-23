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

// Package agent pkg/agent/mapper_discovery_checker.go
package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	ggrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	mapperproto "github.com/carverauto/serviceradar/proto/discovery"
)

// MapperConfig represents the configuration for the mapper service
type MapperConfig struct {
	Address string `json:"address"` // Address of the mapper service
}

type MapperDiscoveryDetails struct {
	Seeds       []string `json:"seeds"`
	Type        string   `json:"type"` // e.g., "full", "basic"
	Credentials struct {
		Version   string `json:"version"`
		Community string `json:"community"`
	} `json:"credentials"`
	Concurrency    int    `json:"concurrency,omitempty"`
	TimeoutSeconds int32  `json:"timeout_seconds,omitempty"`
	Retries        int32  `json:"retries,omitempty"`
	AgentID        string `json:"agent_id,omitempty"`
	PollerID       string `json:"poller_id,omitempty"`
}

// MapperDiscoveryChecker implements checker.Checker for initiating and monitoring mapper discovery jobs.
type MapperDiscoveryChecker struct {
	mapperAddress string
	details       string
	security      *models.SecurityConfig
	client        *ggrpc.Client
	mapperClient  mapperproto.DiscoveryServiceClient

	// New fields for tracking discovery job state
	lastDiscoveryID   string
	lastDiscoveryTime time.Time  // When the last job was initiated or its status was last updated
	mu                sync.Mutex // Protects lastDiscoveryID and lastDiscoveryTime
}

// NewMapperDiscoveryChecker creates a new instance of MapperDiscoveryChecker.
func NewMapperDiscoveryChecker(
	ctx context.Context,
	details string,
	security *models.SecurityConfig) (*MapperDiscoveryChecker, error) {
	log.Printf("Creating MapperDiscoveryChecker with details: %s", details)

	// Load mapper configuration
	mapperConfig, err := loadMapperConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to load mapper configuration: %w", err)
	}

	log.Printf("Connecting to mapper at %s", mapperConfig.Address)

	// Build gRPC client config for connecting to the mapper service
	clientCfg := ggrpc.ClientConfig{
		Address:    mapperConfig.Address,
		MaxRetries: 3, // Can be made configurable
	}

	// Apply security configuration to the client
	if security != nil {
		provider, providerErr := ggrpc.NewSecurityProvider(ctx, security)
		if providerErr != nil {
			return nil,
				fmt.Errorf("failed to create security provider for mapper discovery client: %w", providerErr)
		}

		clientCfg.SecurityProvider = provider
	}

	// Establish the gRPC connection
	client, err := ggrpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to mapper service for discovery: %w", err)
	}

	return &MapperDiscoveryChecker{
		mapperAddress: mapperConfig.Address,
		details:       details,
		security:      security,
		client:        client,
		mapperClient:  mapperproto.NewDiscoveryServiceClient(client.GetConnection()),
	}, nil
}

// loadMapperConfig loads the mapper configuration from the standard config path
func loadMapperConfig(ctx context.Context) (*MapperConfig, error) {
	configPath := filepath.Join(defaultConfigPath, "mapper.json")

	// Check if config file exists
	if _, err := os.Stat(configPath); err != nil {
		// If file doesn't exist, return a default configuration
		if os.IsNotExist(err) {
			log.Printf("Mapper config not found at %s, using default address", configPath)

			return &MapperConfig{
				Address: "127.0.0.1:50056", // Default address
			}, nil
		}

		return nil, fmt.Errorf("config file error: %w", err)
	}

	var cfg MapperConfig

	cfgLoader := config.NewConfig()

	if err := cfgLoader.LoadAndValidate(ctx, configPath, &cfg); err != nil {
		return nil, fmt.Errorf("failed to load mapper config: %w", err)
	}

	// Validate the configuration
	if cfg.Address == "" {
		return nil, fmt.Errorf("mapper address cannot be empty")
	}

	log.Printf("Loaded mapper config from %s: address=%s", configPath, cfg.Address)

	return &cfg, nil
}

const (
	defaultJobStalenessThreshold = 10 * time.Minute // Default threshold for job staleness
)

// Check parses the discovery parameters, optionally initiates a job,
// and returns the status/results of the discovery.
func (mdc *MapperDiscoveryChecker) Check(ctx context.Context) (available bool, statusJSON string) {
	mdc.mu.Lock()
	defer mdc.mu.Unlock()

	var parsedDetails *MapperDiscoveryDetails

	if err := json.Unmarshal([]byte(mdc.details), &parsedDetails); err != nil {
		available = false
		statusJSON = fmt.Sprintf(`{"error": "Failed to parse mapper discovery details: %v"}`, err)

		return available, statusJSON
	}

	// Check if we need to start a new job
	startNewJob := mdc.shouldStartNewJob(ctx)

	if startNewJob {
		errorMsg := mdc.startNewDiscoveryJob(ctx, parsedDetails)
		if errorMsg != "" {
			available = false
			statusJSON = errorMsg

			return available, statusJSON
		}
	}

	// Get the current status or results of the managed job
	if mdc.lastDiscoveryID == "" {
		available = false
		statusJSON = `{"status": "no_job_initiated", "message": "No discovery job initiated or found."}`

		return available, statusJSON
	}

	return mdc.processJobResults(ctx, parsedDetails)
}

// shouldStartNewJob determines if a new discovery job should be started
func (mdc *MapperDiscoveryChecker) shouldStartNewJob(ctx context.Context) bool {
	// A simple heuristic: if no job, or last job is very old (e.g., > 10 minutes from last update/start)
	const jobStalenessThreshold = defaultJobStalenessThreshold

	if mdc.lastDiscoveryID == "" || time.Since(mdc.lastDiscoveryTime) > jobStalenessThreshold {
		return true
	}

	// Check the status of the last job to see if it's completed or failed
	statusResp, err := mdc.mapperClient.GetStatus(ctx,
		&mapperproto.StatusRequest{DiscoveryId: mdc.lastDiscoveryID})
	if err != nil {
		// If we can't get status, assume it's stale/failed and try to restart
		log.Printf("MapperDiscoveryChecker: Failed to get status for job %s (%v), "+
			"attempting new job.", mdc.lastDiscoveryID, err)

		return true
	}

	switch statusResp.Status {
	case mapperproto.DiscoveryStatus_FAILED.String(), mapperproto.DiscoveryStatus_CANCELED.String():
		log.Printf("MapperDiscoveryChecker: Last discovery job %s is %s, "+
			"initiating new job.", mdc.lastDiscoveryID, statusResp.Status)

		return true
	}

	return false
}

// getDiscoveryType converts a string discovery type to the corresponding proto enum
func getDiscoveryType(typeStr string) (mapperproto.DiscoveryRequest_DiscoveryType, error) {
	switch typeStr {
	case "full":
		return mapperproto.DiscoveryRequest_FULL, nil
	case "basic":
		return mapperproto.DiscoveryRequest_BASIC, nil
	case "interfaces":
		return mapperproto.DiscoveryRequest_INTERFACES, nil
	case "topology":
		return mapperproto.DiscoveryRequest_TOPOLOGY, nil
	default:
		return 0, fmt.Errorf("unsupported discovery type: %s", typeStr)
	}
}

// getSNMPVersion converts a string SNMP version to the corresponding proto enum
func getSNMPVersion(versionStr string) (mapperproto.SNMPCredentials_SNMPVersion, error) {
	switch versionStr {
	case "v1":
		return mapperproto.SNMPCredentials_V1, nil
	case "v2c":
		return mapperproto.SNMPCredentials_V2C, nil
	case "v3":
		return mapperproto.SNMPCredentials_V3, nil
	default:
		return 0, fmt.Errorf("unsupported SNMP version: %s", versionStr)
	}
}

// startNewDiscoveryJob initiates a new discovery job
func (mdc *MapperDiscoveryChecker) startNewDiscoveryJob(ctx context.Context, details *MapperDiscoveryDetails) string {
	log.Printf("MapperDiscoveryChecker: Initiating new discovery job.")

	discoveryType, err := getDiscoveryType(details.Type)
	if err != nil {
		return fmt.Sprintf(`{"error": %q}`, err.Error())
	}

	snmpVersion, err := getSNMPVersion(details.Credentials.Version)
	if err != nil {
		return fmt.Sprintf(`{"error": %q}`, err.Error())
	}

	req := &mapperproto.DiscoveryRequest{
		Seeds: details.Seeds,
		Type:  discoveryType,
		Credentials: &mapperproto.SNMPCredentials{
			Version:   snmpVersion,
			Community: details.Credentials.Community,
		},
		Concurrency:    int32(details.Concurrency),
		TimeoutSeconds: details.TimeoutSeconds,
		Retries:        details.Retries,
		AgentId:        details.AgentID,
		PollerId:       details.PollerID,
	}

	resp, err := mdc.mapperClient.StartDiscovery(ctx, req)
	if err != nil {
		return fmt.Sprintf(`{"error": "Failed to start mapper discovery: %v"}`, err)
	}

	if !resp.Success {
		return fmt.Sprintf(`{"error": "Mapper discovery reported failure on start: %s"}`, resp.Message)
	}

	mdc.lastDiscoveryID = resp.DiscoveryId
	mdc.lastDiscoveryTime = time.Now() // Mark new job started

	log.Printf("MapperDiscoveryChecker: New discovery job %s started successfully.", mdc.lastDiscoveryID)

	return ""
}

// processJobResults gets and processes the results of the current job.
func (mdc *MapperDiscoveryChecker) processJobResults(
	ctx context.Context, details *MapperDiscoveryDetails) (available bool, statusJSON string) {
	resultsResp, err := mdc.mapperClient.GetDiscoveryResults(ctx, &mapperproto.ResultsRequest{
		DiscoveryId:    mdc.lastDiscoveryID,
		IncludeRawData: false, // Typically don't send raw data to core unless specifically needed
	})
	if err != nil {
		available = false
		statusJSON = fmt.Sprintf(`{"error": "Failed to get mapper discovery results for job %s: %v"}`,
			mdc.lastDiscoveryID, err)

		return available, statusJSON
	}

	// Update lastDiscoveryTime based on job's end time if available, otherwise current time
	if resultsResp.GetStatus() == mapperproto.DiscoveryStatus_COMPLETED ||
		resultsResp.GetStatus() == mapperproto.DiscoveryStatus_FAILED ||
		resultsResp.GetStatus() == mapperproto.DiscoveryStatus_CANCELED {
		mdc.lastDiscoveryTime = time.Now() // Update last check time for staleness
	}

	// If the job is still running, report its progress
	if resultsResp.Status != mapperproto.DiscoveryStatus_COMPLETED &&
		resultsResp.Status != mapperproto.DiscoveryStatus_FAILED &&
		resultsResp.Status != mapperproto.DiscoveryStatus_CANCELED {
		return mdc.formatProgressStatus(resultsResp)
	}

	return mdc.formatFinalResults(resultsResp, details)
}

// formatProgressStatus formats the status of an in-progress job.
func (mdc *MapperDiscoveryChecker) formatProgressStatus(resultsResp *mapperproto.ResultsResponse) (available bool, statusJSON string) {
	msg := fmt.Sprintf("Mapper discovery job %s is still %s "+
		"(progress: %.1f%%, devices: %d, interfaces: %d, links: %d).",
		mdc.lastDiscoveryID, resultsResp.Status.String(), resultsResp.Progress,
		len(resultsResp.Devices), len(resultsResp.Interfaces), len(resultsResp.Topology))
	statusBytes, _ := json.Marshal(map[string]interface{}{
		"status":               resultsResp.Status.String(),
		"discovery_id":         resultsResp.DiscoveryId,
		"progress":             resultsResp.Progress,
		"devices_found":        len(resultsResp.Devices),
		"interfaces_found":     len(resultsResp.Interfaces),
		"topology_links_found": len(resultsResp.Topology),
		"message":              msg,
		"error":                resultsResp.Error,
	})

	available = true
	statusJSON = string(statusBytes)

	return available, statusJSON
}

// formatFinalResults formats the final results of a completed job.
func (mdc *MapperDiscoveryChecker) formatFinalResults(
	resultsResp *mapperproto.ResultsResponse, details *MapperDiscoveryDetails) (available bool, payloadJSON string) {
	// If job completed/failed/canceled, prepare the full SNMPDiscoveryDataPayload
	payload := models.SNMPDiscoveryDataPayload{
		Devices:    resultsResp.Devices,
		Interfaces: resultsResp.Interfaces,
		Topology:   resultsResp.Topology,
		AgentID:    details.AgentID,  // Propagate original agent ID
		PollerID:   details.PollerID, // Propagate original poller ID
	}

	jsonBytes, err := json.Marshal(payload)
	if err != nil {
		available = false
		payloadJSON = fmt.Sprintf(`{"error": "Failed to marshal SNMP discovery results payload: %v"}`, err)

		return available, payloadJSON
	}

	// Report availability based on job outcome
	available = resultsResp.Status == mapperproto.DiscoveryStatus_COMPLETED
	payloadJSON = string(jsonBytes)

	log.Printf("MapperDiscoveryChecker: Reporting job %s status: %s, available: %v. "+
		"Found devices: %d, interfaces: %d, links: %d",
		mdc.lastDiscoveryID, resultsResp.Status.String(), available,
		len(resultsResp.Devices), len(resultsResp.Interfaces), len(resultsResp.Topology))

	return available, payloadJSON
}

// Close gracefully closes the gRPC client connection to the mapper.
func (mdc *MapperDiscoveryChecker) Close() error {
	if mdc.client != nil {
		return mdc.client.Close()
	}

	return nil
}
