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
	"sync"
	"time"

	ggrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	mapper_proto "github.com/carverauto/serviceradar/proto/discovery"
)

type MapperDiscoveryDetails struct {
	Seeds       []string `json:"seeds"`
	Type        string   `json:"type"` // e.g., "full", "basic"
	Credentials struct {
		Version   string `json:"version"`
		Community string `json:"community"`
	} `json:"credentials"`
	Concurrency    int    `json:"concurrency,omitempty"`
	TimeoutSeconds int32  `json:"timeout_seconds,omitempty"` // Renamed to match proto
	Retries        int32  `json:"retries,omitempty"`         // Renamed to match proto
	AgentId        string `json:"agent_id,omitempty"`
	PollerId       string `json:"poller_id,omitempty"`
}

// MapperDiscoveryChecker implements checker.Checker for initiating and monitoring mapper discovery jobs.
type MapperDiscoveryChecker struct {
	mapperAddress string
	details       string
	security      *models.SecurityConfig
	client        *ggrpc.Client
	mapperClient  mapper_proto.DiscoveryServiceClient

	// New fields for tracking discovery job state
	lastDiscoveryID   string
	lastDiscoveryTime time.Time  // When the last job was initiated or its status was last updated
	mu                sync.Mutex // Protects lastDiscoveryID and lastDiscoveryTime
}

// NewMapperDiscoveryChecker creates a new instance of MapperDiscoveryChecker.
func NewMapperDiscoveryChecker(
	ctx context.Context,
	mapperAddress, details string,
	security *models.SecurityConfig) (*MapperDiscoveryChecker, error) {
	log.Printf("Creating MapperDiscoveryChecker for mapper at %s with details: %s", mapperAddress, details)

	// Build gRPC client config for connecting to the mapper service
	clientCfg := ggrpc.ClientConfig{
		Address:    mapperAddress,
		MaxRetries: 3, // Can be made configurable
	}

	// Apply security configuration to the client
	if security != nil {
		provider, err := ggrpc.NewSecurityProvider(ctx, security)
		if err != nil {
			return nil, fmt.Errorf("failed to create security provider for mapper discovery client: %w", err)
		}

		clientCfg.SecurityProvider = provider
	}

	// Establish the gRPC connection
	client, err := ggrpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to mapper service for discovery: %w", err)
	}

	return &MapperDiscoveryChecker{
		mapperAddress: mapperAddress,
		details:       details,
		security:      security,
		client:        client,
		mapperClient:  mapper_proto.NewDiscoveryServiceClient(client.GetConnection()),
	}, nil
}

const (
	defaultJobStalenessThreshold = 10 * time.Minute // Default threshold for job staleness
)

// Check parses the discovery parameters, optionally initiates a job,
// and returns the status/results of the discovery.
func (mdc *MapperDiscoveryChecker) Check(ctx context.Context) (bool, string) {
	mdc.mu.Lock()
	defer mdc.mu.Unlock()

	var parsedDetails MapperDiscoveryDetails

	if err := json.Unmarshal([]byte(mdc.details), &parsedDetails); err != nil {
		return false, fmt.Sprintf(`{"error": "Failed to parse mapper discovery details: %v"}`, err)
	}

	// Determine if we need to start a new discovery job
	// A simple heuristic: if no job, or last job is very old (e.g., > 10 minutes from last update/start)
	const jobStalenessThreshold = defaultJobStalenessThreshold

	startNewJob := false

	if mdc.lastDiscoveryID == "" || time.Since(mdc.lastDiscoveryTime) > jobStalenessThreshold {
		startNewJob = true
	} else {
		// Check the status of the last job to see if it's completed or failed
		statusResp, err := mdc.mapperClient.GetStatus(ctx,
			&mapper_proto.StatusRequest{DiscoveryId: mdc.lastDiscoveryID})
		if err != nil {
			// If we can't get status, assume it's stale/failed and try to restart
			log.Printf("MapperDiscoveryChecker: Failed to get status for job %s (%v), "+
				"attempting new job.", mdc.lastDiscoveryID, err)

			startNewJob = true
		} else {
			switch statusResp.Status {
			case mapper_proto.DiscoveryStatus_FAILED.String(), mapper_proto.DiscoveryStatus_CANCELED.String():
				log.Printf("MapperDiscoveryChecker: Last discovery job %s is %s, "+
					"initiating new job.", mdc.lastDiscoveryID, statusResp.Status)

				startNewJob = true
			}
		}
	}

	if startNewJob {
		log.Printf("MapperDiscoveryChecker: Initiating new discovery job.")

		var discoveryType mapper_proto.DiscoveryRequest_DiscoveryType

		switch parsedDetails.Type {
		case "full":
			discoveryType = mapper_proto.DiscoveryRequest_FULL
		case "basic":
			discoveryType = mapper_proto.DiscoveryRequest_BASIC
		case "interfaces":
			discoveryType = mapper_proto.DiscoveryRequest_INTERFACES
		case "topology":
			discoveryType = mapper_proto.DiscoveryRequest_TOPOLOGY
		default:
			return false, fmt.Sprintf(`{"error": "Unsupported discovery type: %s"}`, parsedDetails.Type)
		}

		var snmpVersion mapper_proto.SNMPCredentials_SNMPVersion

		switch parsedDetails.Credentials.Version {
		case "v1":
			snmpVersion = mapper_proto.SNMPCredentials_V1
		case "v2c":
			snmpVersion = mapper_proto.SNMPCredentials_V2C
		case "v3":
			snmpVersion = mapper_proto.SNMPCredentials_V3
		default:
			return false, fmt.Sprintf(`{"error": "Unsupported SNMP version: %s"}`,
				parsedDetails.Credentials.Version)
		}

		req := &mapper_proto.DiscoveryRequest{
			Seeds: parsedDetails.Seeds,
			Type:  discoveryType,
			Credentials: &mapper_proto.SNMPCredentials{
				Version:   snmpVersion,
				Community: parsedDetails.Credentials.Community,
				// Add other SNMP v3 credentials here from parsedDetails if your config includes them
			},
			Concurrency:    int32(parsedDetails.Concurrency),
			TimeoutSeconds: parsedDetails.TimeoutSeconds,
			Retries:        parsedDetails.Retries,
			AgentId:        parsedDetails.AgentId,
			PollerId:       parsedDetails.PollerId,
		}

		resp, err := mdc.mapperClient.StartDiscovery(ctx, req)
		if err != nil {
			return false, fmt.Sprintf(`{"error": "Failed to start mapper discovery: %v"}`, err)
		}

		if !resp.Success {
			return false,
				fmt.Sprintf(`{"error": "Mapper discovery reported failure on start: %s"}`, resp.Message)
		}

		mdc.lastDiscoveryID = resp.DiscoveryId
		mdc.lastDiscoveryTime = time.Now() // Mark new job started

		log.Printf("MapperDiscoveryChecker: New discovery job %s started successfully.", mdc.lastDiscoveryID)
	}

	// Now, get the current status or results of the managed job
	if mdc.lastDiscoveryID == "" {
		return false, `{"status": "no_job_initiated", "message": "No discovery job initiated or found."}`
	}

	resultsResp, err := mdc.mapperClient.GetDiscoveryResults(ctx, &mapper_proto.ResultsRequest{
		DiscoveryId:    mdc.lastDiscoveryID,
		IncludeRawData: false, // Typically don't send raw data to core unless specifically needed
	})
	if err != nil {
		return false, fmt.Sprintf(`{"error": "Failed to get mapper discovery results for job %s: %v"}`,
			mdc.lastDiscoveryID, err)
	}

	// Update lastDiscoveryTime based on job's end time if available, otherwise current time
	if resultsResp.GetStatus() == mapper_proto.DiscoveryStatus_COMPLETED ||
		resultsResp.GetStatus() == mapper_proto.DiscoveryStatus_FAILED ||
		resultsResp.GetStatus() == mapper_proto.DiscoveryStatus_CANCELED {
		mdc.lastDiscoveryTime = time.Now() // Update last check time for staleness
	}

	// If the job is still running, report its progress
	if resultsResp.Status != mapper_proto.DiscoveryStatus_COMPLETED &&
		resultsResp.Status != mapper_proto.DiscoveryStatus_FAILED &&
		resultsResp.Status != mapper_proto.DiscoveryStatus_CANCELED {
		msg := fmt.Sprintf("Mapper discovery job %s is still %s "+
			"(progress: %.1f%%, devices: %d, interfaces: %d, links: %d).",
			mdc.lastDiscoveryID, resultsResp.Status.String(), resultsResp.Progress,
			len(resultsResp.Devices), len(resultsResp.Interfaces), len(resultsResp.Topology))
		statusJson, _ := json.Marshal(map[string]interface{}{
			"status":               resultsResp.Status.String(),
			"discovery_id":         resultsResp.DiscoveryId,
			"progress":             resultsResp.Progress,
			"devices_found":        len(resultsResp.Devices),
			"interfaces_found":     len(resultsResp.Interfaces),
			"topology_links_found": len(resultsResp.Topology),
			"message":              msg,
			"error":                resultsResp.Error,
		})

		// Report as available if the mapper service itself is healthy and job is processing
		return true, string(statusJson)
	}

	// If job completed/failed/canceled, prepare the full SNMPDiscoveryDataPayload
	payload := models.SNMPDiscoveryDataPayload{
		Devices:    resultsResp.Devices,
		Interfaces: resultsResp.Interfaces,
		Topology:   resultsResp.Topology,
		AgentID:    parsedDetails.AgentId,  // Propagate original agent ID
		PollerID:   parsedDetails.PollerId, // Propagate original poller ID
	}

	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return false, fmt.Sprintf(`{"error": "Failed to marshal SNMP discovery results payload: %v"}`, err)
	}

	// Report availability based on job outcome
	available := resultsResp.Status == mapper_proto.DiscoveryStatus_COMPLETED

	log.Printf("MapperDiscoveryChecker: Reporting job %s status: %s, available: %v. "+
		"Found devices: %d, interfaces: %d, links: %d",
		mdc.lastDiscoveryID, resultsResp.Status.String(), available,
		len(resultsResp.Devices), len(resultsResp.Interfaces), len(resultsResp.Topology))

	return available, string(payloadJSON)
}

// Close gracefully closes the gRPC client connection to the mapper.
func (mdc *MapperDiscoveryChecker) Close() error {
	if mdc.client != nil {
		return mdc.client.Close()
	}

	return nil
}
