package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"log"

	ggrpc "github.com/carverauto/serviceradar/pkg/grpc" // Alias to avoid conflict
	"github.com/carverauto/serviceradar/pkg/models"
	mapper_proto "github.com/carverauto/serviceradar/proto/discovery" // Alias for mapper's proto
)

// MapperDiscoveryDetails matches the JSON structure in your log
type MapperDiscoveryDetails struct {
	Seeds       []string `json:"seeds"`
	Type        string   `json:"type"` // e.g., "full", "basic"
	Credentials struct {
		Version   string `json:"version"`
		Community string `json:"community"`
		// Add other SNMP v3 credentials if needed (Username, AuthProtocol, etc.)
	} `json:"credentials"`
	// Add other fields from DiscoveryParams if needed to fully configure the mapper
	Concurrency    int    `json:"concurrency,omitempty"`
	TimeoutSeconds int32  `json:"timeout_seconds,omitempty"` // Renamed to match proto
	Retries        int32  `json:"retries,omitempty"`         // Renamed to match proto
	AgentId        string `json:"agent_id,omitempty"`
	PollerId       string `json:"poller_id,omitempty"`
}

// MapperDiscoveryChecker implements checker.Checker for initiating and monitoring mapper discovery jobs.
type MapperDiscoveryChecker struct {
	mapperAddress string
	details       string // raw JSON string from config
	security      *models.SecurityConfig
	client        *ggrpc.Client // gRPC client to the mapper service
	mapperClient  mapper_proto.DiscoveryServiceClient
}

// NewMapperDiscoveryChecker creates a new instance of MapperDiscoveryChecker.
func NewMapperDiscoveryChecker(ctx context.Context, mapperAddress, details string, security *models.SecurityConfig) (*MapperDiscoveryChecker, error) {
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

// Check parses the discovery parameters from details and initiates a discovery job on the mapper.
// It returns true if the job was successfully initiated, false otherwise.
func (mdc *MapperDiscoveryChecker) Check(ctx context.Context) (bool, string) {
	var parsedDetails MapperDiscoveryDetails
	if err := json.Unmarshal([]byte(mdc.details), &parsedDetails); err != nil {
		return false, fmt.Sprintf("Failed to parse mapper discovery details: %v", err)
	}

	// Convert parsedDetails.Type string to proto.DiscoveryRequest_DiscoveryType enum
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
		return false, fmt.Sprintf("Unsupported discovery type: %s", parsedDetails.Type)
	}

	// Convert parsedDetails.Credentials.Version string to proto.SNMPCredentials_Version enum
	// var snmpVersion SNMPCredentials_Version
	var snmpVersion mapper_proto.SNMPCredentials_SNMPVersion
	switch parsedDetails.Credentials.Version {
	case "v1":
		snmpVersion = mapper_proto.SNMPCredentials_V1
	case "v2c":
		snmpVersion = mapper_proto.SNMPCredentials_V2C
	case "v3":
		snmpVersion = mapper_proto.SNMPCredentials_V3
	default:
		return false, fmt.Sprintf("Unsupported SNMP version: %s", parsedDetails.Credentials.Version)
	}

	// Construct the StartDiscoveryRequest for the mapper service
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

	log.Printf("MapperDiscoveryChecker: Sending StartDiscovery request to %s: %+v", mdc.mapperAddress, req)
	resp, err := mdc.mapperClient.StartDiscovery(ctx, req)
	if err != nil {
		return false, fmt.Sprintf("Failed to start mapper discovery: %v", err)
	}

	if !resp.Success {
		return false, fmt.Sprintf("Mapper discovery reported failure: %s", resp.Message)
	}

	// The StartDiscovery call only initiates the job.
	// For a `checker.Check` method, typically you'd report if the *check itself* was successful.
	// In this case, initiating the discovery job is the "check."
	// If you needed to report the *status of the discovery job*, you'd need a separate mechanism
	// or have this checker poll `mapper_proto.DiscoveryServiceClient.GetStatus` for the `DiscoveryId`.
	message := fmt.Sprintf("Mapper discovery job started successfully. ID: %s, Est. Duration: %d seconds. Message: %s",
		resp.DiscoveryId, resp.EstimatedDuration, resp.Message)
	return true, message
}

// Close gracefully closes the gRPC client connection to the mapper.
func (mdc *MapperDiscoveryChecker) Close() error {
	if mdc.client != nil {
		return mdc.client.Close()
	}
	return nil
}
