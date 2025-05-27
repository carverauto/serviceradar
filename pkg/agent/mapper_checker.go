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
	"github.com/carverauto/serviceradar/proto"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/config"
	ggrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	discovery "github.com/carverauto/serviceradar/proto/discovery"
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
	Concurrency    int32  `json:"concurrency,omitempty"`
	TimeoutSeconds int32  `json:"timeout_seconds,omitempty"`
	Retries        int32  `json:"retries,omitempty"`
	AgentID        string `json:"agent_id,omitempty"`
	PollerID       string `json:"poller_id,omitempty"`
}

// MapperDiscoveryChecker implements checker.Checker for initiating and monitoring mapper discovery jobs.
type MapperDiscoveryChecker struct {
	mapperAddress     string
	details           string
	security          *models.SecurityConfig
	client            *ggrpc.Client
	mapperClient      discovery.DiscoveryServiceClient
	lastDiscoveryID   string
	lastDiscoveryTime time.Time
	mu                sync.Mutex
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
		provider, err := ggrpc.NewSecurityProvider(ctx, security)
		if err != nil {
			return nil, fmt.Errorf("failed to create security provider: %w", err)
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
		return nil, fmt.Errorf("failed to load mapper config: %v", err)
	}

	if cfg.Address == "" {
		return nil, fmt.Errorf("mapper address cannot be empty")
	}

	log.Printf("Loaded mapper config from %s: address=%s", configPath, cfg.Address)
	return &cfg, nil
}

const defaultJobIntervalThreshold = 10 * time.Second

// Check parses the discovery parameters, optionally initiates a job, and returns the status/results
func (mdc *MapperDiscoveryChecker) Check(ctx context.Context, req *proto.StatusRequest) (bool, json.RawMessage) {
	mdc.mu.Lock()
	defer mdc.mu.Unlock()

	if req == nil {
		return false, jsonError("No StatusRequest provided")
	}

	// Parse discovery details
	var parsedDetails MapperDiscoveryDetails
	if err := json.Unmarshal([]byte(mdc.details), &parsedDetails); err != nil {
		return false, jsonError(fmt.Sprintf("Failed to parse mapper discovery details: %v", err))
	}

	// Map proto.StatusRequest to discovery.StatusRequest
	if parsedDetails.AgentID == "" {
		parsedDetails.AgentID = req.AgentId
		log.Printf("MapperDiscoveryChecker: Using AgentID %s from StatusRequest", req.AgentId)
	}
	if parsedDetails.PollerID == "" {
		parsedDetails.PollerID = req.PollerId
		log.Printf("MapperDiscoveryChecker: Using PollerID %s from StatusRequest", req.PollerId)
	}

	// Create discovery.StatusRequest for gRPC call
	discoveryReq := &discovery.StatusRequest{
		DiscoveryId: mdc.lastDiscoveryID,
		AgentId:     parsedDetails.AgentID,
		PollerId:    parsedDetails.PollerID,
	}

	startNewJob := mdc.shouldStartNewJob(ctx)
	if startNewJob {
		if errorMsg := mdc.startNewDiscoveryJob(ctx, &parsedDetails); errorMsg != nil {
			return false, errorMsg
		}
	}

	if mdc.lastDiscoveryID == "" {
		resp := map[string]string{
			"status":  "no_job_initiated",
			"message": "No discovery job initiated or found.",
		}
		data, _ := json.Marshal(resp)
		return false, data
	}

	return mdc.processJobResults(ctx, discoveryReq, &parsedDetails)
}

func (mdc *MapperDiscoveryChecker) startNewDiscoveryJob(
	ctx context.Context, details *MapperDiscoveryDetails) json.RawMessage {
	discoveryType, err := getDiscoveryType(details.Type)
	if err != nil {
		return jsonError(err.Error())
	}

	snmpVersion, err := getSNMPVersion(details.Credentials.Version)
	if err != nil {
		return jsonError(err.Error())
	}

	req := &discovery.DiscoveryRequest{
		Seeds: details.Seeds,
		Type:  discoveryType,
		Credentials: &discovery.SNMPCredentials{
			Version:   snmpVersion,
			Community: details.Credentials.Community,
		},
		Concurrency:    details.Concurrency,
		TimeoutSeconds: details.TimeoutSeconds,
		Retries:        details.Retries,
		AgentId:        details.AgentID,
		PollerId:       details.PollerID,
	}

	resp, err := mdc.mapperClient.StartDiscovery(ctx, req)
	if err != nil {
		return jsonError(fmt.Sprintf("Failed to start mapper discovery: %v", err))
	}

	if !resp.Success {
		return jsonError(fmt.Sprintf("Mapper discovery reported failure on start: %s", resp.Message))
	}

	mdc.lastDiscoveryID = resp.DiscoveryId
	mdc.lastDiscoveryTime = time.Now()
	log.Printf("MapperDiscoveryChecker: New discovery job %s started successfully.", mdc.lastDiscoveryID)

	return nil
}

func (mdc *MapperDiscoveryChecker) shouldStartNewJob(ctx context.Context) bool {
	if mdc.lastDiscoveryID == "" || time.Since(mdc.lastDiscoveryTime) > defaultJobIntervalThreshold {
		return true
	}

	statusResp, err := mdc.mapperClient.GetStatus(ctx, &discovery.StatusRequest{DiscoveryId: mdc.lastDiscoveryID})
	if err != nil {
		log.Printf("MapperDiscoveryChecker: Failed to get status for job %s (%v), attempting new job.",
			mdc.lastDiscoveryID, err)
		return true
	}

	switch statusResp.Status {
	case "FAILED", "CANCELED":
		log.Printf("MapperDiscoveryChecker: Last discovery job %s is %s, initiating new job.",
			mdc.lastDiscoveryID, statusResp.Status)
		return true
	}

	return false
}

func (mdc *MapperDiscoveryChecker) processJobResults(
	ctx context.Context,
	discoveryReq *discovery.StatusRequest,
	details *MapperDiscoveryDetails) (bool, json.RawMessage) {
	resultsReq := &discovery.ResultsRequest{DiscoveryId: discoveryReq.DiscoveryId}

	resultsResp, err := mdc.mapperClient.GetDiscoveryResults(ctx, resultsReq)
	if err != nil {
		return false, jsonError(fmt.Sprintf("Failed to get discovery results: %v", err))
	}

	if resultsResp.Error != "" {
		return false, jsonError(resultsResp.Error)
	}

	if resultsResp.Status == discovery.DiscoveryStatus_FAILED {
		return false, jsonError(fmt.Sprintf("Discovery job %s failed: %s",
			mdc.lastDiscoveryID, resultsResp.Error))
	}

	if resultsResp.Status != discovery.DiscoveryStatus_COMPLETED {
		return mdc.formatProgressStatus(resultsResp)
	}

	return mdc.formatFinalResults(resultsResp, details)
}

func (mdc *MapperDiscoveryChecker) formatProgressStatus(resultsResp *discovery.ResultsResponse) (bool, json.RawMessage) {
	resp := map[string]interface{}{
		"status":               resultsResp.Status,
		"discovery_id":         resultsResp.DiscoveryId,
		"progress":             resultsResp.Progress,
		"devices_found":        len(resultsResp.Devices),
		"interfaces_found":     len(resultsResp.Interfaces),
		"topology_links_found": len(resultsResp.Topology),
		"message": fmt.Sprintf("Mapper discovery job %s is still %s (progress: %.1f%%, "+
			"devices: %d, interfaces: %d, links: %d).",
			mdc.lastDiscoveryID, resultsResp.Status, resultsResp.Progress,
			len(resultsResp.Devices), len(resultsResp.Interfaces), len(resultsResp.Topology)),
		"error": resultsResp.Error,
	}

	data, err := json.Marshal(resp)
	if err != nil {
		return false, jsonError(fmt.Sprintf("Failed to marshal progress status: %v", err))
	}

	return true, data
}

func (mdc *MapperDiscoveryChecker) formatFinalResults(
	resultsResp *discovery.ResultsResponse, details *MapperDiscoveryDetails) (bool, json.RawMessage) {
	payload := models.SNMPDiscoveryDataPayload{
		Devices:    resultsResp.Devices,
		Interfaces: resultsResp.Interfaces,
		Topology:   resultsResp.Topology,
		AgentID:    details.AgentID,
		PollerID:   details.PollerID,
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return false, jsonError(fmt.Sprintf("Failed to marshal SNMP discovery results payload: %v", err))
	}

	available := resultsResp.Status == discovery.DiscoveryStatus_COMPLETED

	log.Printf("MapperDiscoveryChecker: Reporting job %s status: %s, available: %v. Found devices: %d, interfaces: %d, links: %d",
		mdc.lastDiscoveryID, resultsResp.Status, available,
		len(resultsResp.Devices), len(resultsResp.Interfaces), len(resultsResp.Topology))

	return available, data
}

func getDiscoveryType(typeStr string) (discovery.DiscoveryRequest_DiscoveryType, error) {
	switch typeStr {
	case "full":
		return discovery.DiscoveryRequest_FULL, nil
	case "basic":
		return discovery.DiscoveryRequest_BASIC, nil
	case "interfaces":
		return discovery.DiscoveryRequest_INTERFACES, nil
	case "topology":
		return discovery.DiscoveryRequest_TOPOLOGY, nil
	default:
		return 0, fmt.Errorf("unsupported discovery type: %s", typeStr)
	}
}

func getSNMPVersion(versionStr string) (discovery.SNMPCredentials_SNMPVersion, error) {
	switch versionStr {
	case "v1":
		return discovery.SNMPCredentials_V1, nil
	case "v2c":
		return discovery.SNMPCredentials_V2C, nil
	case "v3":
		return discovery.SNMPCredentials_V3, nil
	default:
		return 0, fmt.Errorf("unsupported SNMP version: %s", versionStr)
	}
}

// Close gracefully closes the gRPC client connection to the mapper.
func (mdc *MapperDiscoveryChecker) Close() error {
	if mdc.client != nil {
		return mdc.client.Close()
	}
	return nil
}
