package integrations

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

// ArmisIntegration manages the Armis API integration.
type ArmisIntegration struct {
	config   models.SourceConfig
	kvClient proto.KVServiceClient // Add gRPC client for KV writes
	grpcConn *grpc.ClientConn      // Connection to reuse
}

// NewArmisIntegration creates a new ArmisIntegration with a gRPC client.
func NewArmisIntegration(ctx context.Context, config models.SourceConfig, kvClient proto.KVServiceClient, grpcConn *grpc.ClientConn) *ArmisIntegration {
	return &ArmisIntegration{
		config:   config,
		kvClient: kvClient,
		grpcConn: grpcConn,
	}
}

// Device represents an Armis device.
type Device struct {
	DeviceID  string `json:"device_id"`
	IPAddress string `json:"ip_address"`
}

// DeviceResponse represents the Armis API response.
type DeviceResponse struct {
	Devices []Device `json:"devices"`
	Total   int      `json:"total"`
	Page    int      `json:"page"`
	PerPage int      `json:"per_page"`
}

// SweepConfig defines the network sweep tool configuration.
type SweepConfig struct {
	Networks      []string `json:"networks"`
	Ports         []int    `json:"ports"`
	SweepModes    []string `json:"sweep_modes"`
	Interval      string   `json:"interval"`
	Concurrency   int      `json:"concurrency"`
	Timeout       string   `json:"timeout"`
	IcmpCount     int      `json:"icmp_count"`
	HighPerfIcmp  bool     `json:"high_perf_icmp"`
	IcmpRateLimit int      `json:"icmp_rate_limit"`
}

// Fetch retrieves devices from Armis and generates sweep config.
func (a *ArmisIntegration) Fetch(ctx context.Context) (map[string][]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, a.config.Endpoint+"?page=1&per_page=10", nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("Authorization", "Bearer "+a.config.Credentials["api_key"])

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err := resp.Body.Close(); err != nil {
			log.Printf("Failed to close response body: %v", err)
		}
	}()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	var deviceResp DeviceResponse
	if err := json.NewDecoder(resp.Body).Decode(&deviceResp); err != nil {
		return nil, err
	}

	// Store individual devices
	data := make(map[string][]byte)
	ips := make([]string, 0, len(deviceResp.Devices))
	for _, device := range deviceResp.Devices {
		value, err := json.Marshal(device)
		if err != nil {
			return nil, err
		}
		data[device.DeviceID] = value // e.g., "device-1" -> {"device_id":"device-1","ip_address":"192.168.1.1"}
		ips = append(ips, device.IPAddress+"/32")
	}

	log.Printf("Fetched %d devices from Armis", len(deviceResp.Devices))

	// Generate and write sweep config
	sweepConfig := SweepConfig{
		Networks:      ips,
		Ports:         []int{22, 80, 443, 3306, 5432, 6379, 8080, 8443},
		SweepModes:    []string{"icmp", "tcp"},
		Interval:      "5m",
		Concurrency:   100,
		Timeout:       "10s",
		IcmpCount:     1,
		HighPerfIcmp:  true,
		IcmpRateLimit: 5000,
	}
	configJSON, err := json.Marshal(sweepConfig)
	if err != nil {
		log.Printf("Failed to marshal sweep config: %v", err)
		return data, nil // Continue with device data even if config fails
	}

	_, err = a.kvClient.Put(ctx, &proto.PutRequest{
		Key:   "config/serviceradar-agent/network-sweep",
		Value: configJSON,
	})
	if err != nil {
		log.Printf("Failed to write sweep config: %v", err)
		return data, nil // Continue with device data
	}
	log.Println("Wrote sweep config to config/serviceradar-agent/network-sweep")

	return data, nil
}
