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

package sync

import (
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/poller"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/test/bufconn"
)

// TestPollerSyncIntegration tests the full integration between poller and sync agent
func TestPollerSyncIntegration(t *testing.T) {
	// Create an in-memory gRPC server for the sync agent
	lis := bufconn.Listen(1024 * 1024)
	defer lis.Close()

	// Create test data that the sync integration will return
	hostname := "integration-test-device"
	mac := "00:50:56:aa:bb:cc"
	testSweepResults := []*models.SweepResult{
		{
			AgentID:         "test-agent",
			PollerID:        "test-poller",
			Partition:       "default",
			DiscoverySource: "netbox",
			IP:              "192.168.100.10",
			MAC:             &mac,
			Hostname:        &hostname,
			Timestamp:       time.Now(),
			Available:       true,
			Metadata: map[string]string{
				"netbox_device_id": "999",
				"role":             "test-devices",
				"site":             "test-site",
			},
		},
	}

	// Create sync service with mock integration
	syncConfig := &Config{
		Sources: map[string]*models.SourceConfig{
			"netbox": {
				Type:        "netbox",
				Endpoint:    "http://test-netbox.example.com",
				Prefix:      "netbox/",
				Credentials: map[string]string{"api_token": "test-token"},
			},
		},
		AgentID:      "test-agent",
		PollerID:     "test-poller",
		ListenAddr:   ":0",
		PollInterval: models.Duration(5 * time.Second),
		StreamName:   "devices",
		Subject:      "discovery.devices",
		NATSURL:      "nats://localhost:4222",
	}

	registry := map[string]IntegrationFactory{
		"netbox": func(_ context.Context, _ *models.SourceConfig) Integration {
			return &testIntegration{
				data:   map[string][]byte{"test-device": []byte("test-data")},
				events: testSweepResults,
			}
		},
	}

	syncer, err := New(context.Background(), syncConfig, &testKVClient{}, nil, nil, registry, nil, nil)
	require.NoError(t, err)

	// Run initial sync to populate results
	err = syncer.Sync(context.Background())
	require.NoError(t, err)

	// Start gRPC server for sync agent
	server := grpc.NewServer()
	proto.RegisterAgentServiceServer(server, syncer)

	go func() {
		if err := server.Serve(lis); err != nil {
			t.Logf("Sync agent server failed: %v", err)
		}
	}()
	defer server.Stop()

	// Create poller configuration that points to our sync agent
	pollerConfig := &poller.Config{
		PollerID:     "test-poller",
		Partition:    "default",
		PollInterval: models.Duration(1 * time.Second),
		Agents: map[string]poller.AgentConfig{
			"sync-agent": {
				Address: "bufnet", // Will be intercepted by our custom dialer
				Checks: []poller.Check{
					{
						Name: "netbox-discovery",
						Type: "sweep",
					},
				},
			},
		},
	}

	// Create mock clock for controlled timing
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()
	mockClock := poller.NewMockClock(ctrl)

	// Create poller with custom PollFunc to capture results
	var capturedStatuses []*proto.ServiceStatus
	
	testPoller, err := poller.New(context.Background(), pollerConfig, mockClock)
	require.NoError(t, err)

	// Override the PollFunc to capture the results instead of sending to core
	testPoller.PollFunc = func(ctx context.Context) error {
		// Create client connection to sync agent
		conn, err := grpc.DialContext(
			ctx,
			"bufnet",
			grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
				return lis.Dial()
			}),
			grpc.WithTransportCredentials(insecure.NewCredentials()),
		)
		if err != nil {
			return err
		}
		defer conn.Close()

		client := proto.NewAgentServiceClient(conn)

		// Call GetStatus on the sync agent
		req := &proto.StatusRequest{
			ServiceName: "netbox-discovery",
			ServiceType: "sweep",
			PollerId:    "test-poller",
		}

		resp, err := client.GetStatus(ctx, req)
		if err != nil {
			return err
		}

		// Capture the response for verification
		status := &proto.ServiceStatus{
			ServiceName:  req.ServiceName,
			Available:    resp.Available,
			Message:      resp.Message,
			ServiceType:  resp.ServiceType,
			AgentId:      resp.AgentId,
			PollerId:     "test-poller",
		}

		capturedStatuses = append(capturedStatuses, status)
		return nil
	}

	// Execute one poll cycle
	err = testPoller.PollFunc(context.Background())
	require.NoError(t, err)

	// Verify we captured the expected status
	require.Len(t, capturedStatuses, 1)
	status := capturedStatuses[0]

	assert.Equal(t, "netbox-discovery", status.ServiceName)
	assert.True(t, status.Available)
	assert.Equal(t, "sweep", status.ServiceType)
	assert.Equal(t, "test-agent", status.AgentId)
	assert.Equal(t, "test-poller", status.PollerId)

	// Parse the message to verify it contains our test device
	var response map[string]interface{}
	err = json.Unmarshal(status.Message, &response)
	require.NoError(t, err)

	assert.Equal(t, "Discovery sync completed", response["message"])

	hosts, ok := response["hosts"].([]interface{})
	require.True(t, ok)
	require.Len(t, hosts, 1)

	host, ok := hosts[0].(map[string]interface{})
	require.True(t, ok)
	assert.Equal(t, "192.168.100.10", host["host"])
	assert.Equal(t, true, host["available"])
	assert.Equal(t, "00:50:56:aa:bb:cc", host["mac"])
	assert.Equal(t, "integration-test-device", host["hostname"])

	metadata, ok := host["metadata"].(map[string]interface{})
	require.True(t, ok)
	assert.Equal(t, "999", metadata["netbox_device_id"])
	assert.Equal(t, "test-devices", metadata["role"])
	assert.Equal(t, "test-site", metadata["site"])
}

// TestPollerSyncWithMultipleSources tests integration with multiple discovery sources
func TestPollerSyncWithMultipleSources(t *testing.T) {
	lis := bufconn.Listen(1024 * 1024)
	defer lis.Close()

	// Create test data from multiple sources
	netboxHostname := "netbox-device"
	armisHostname := "armis-device"
	netboxMAC := "00:50:56:11:22:33"

	netboxResults := []*models.SweepResult{
		{
			IP:              "192.168.1.10",
			MAC:             &netboxMAC,
			Hostname:        &netboxHostname,
			Available:       true,
			DiscoverySource: "netbox",
			Metadata: map[string]string{
				"source": "netbox",
				"id":     "100",
			},
		},
	}

	armisResults := []*models.SweepResult{
		{
			IP:              "192.168.1.11",
			MAC:             nil,
			Hostname:        &armisHostname,
			Available:       true,
			DiscoverySource: "armis",
			Metadata: map[string]string{
				"source": "armis",
				"risk":   "low",
			},
		},
	}

	syncConfig := &Config{
		Sources: map[string]*models.SourceConfig{
			"netbox": {
				Type:        "netbox",
				Endpoint:    "http://netbox.example.com",
				Prefix:      "netbox/",
				Credentials: map[string]string{"api_token": "token"},
			},
			"armis": {
				Type:        "armis",
				Endpoint:    "http://armis.example.com",
				Prefix:      "armis/",
				Credentials: map[string]string{"api_key": "key"},
			},
		},
		AgentID:      "multi-agent",
		PollerID:     "multi-poller",
		PollInterval: models.Duration(5 * time.Second),
		StreamName:   "devices",
		Subject:      "discovery.devices",
		NATSURL:      "nats://localhost:4222",
	}

	registry := map[string]IntegrationFactory{
		"netbox": func(_ context.Context, _ *models.SourceConfig) Integration {
			return &testIntegration{
				data:   map[string][]byte{},
				events: netboxResults,
			}
		},
		"armis": func(_ context.Context, _ *models.SourceConfig) Integration {
			return &testIntegration{
				data:   map[string][]byte{},
				events: armisResults,
			}
		},
	}

	syncer, err := New(context.Background(), syncConfig, &testKVClient{}, nil, nil, registry, nil, nil)
	require.NoError(t, err)

	// Run sync to combine results from both sources
	err = syncer.Sync(context.Background())
	require.NoError(t, err)

	// Start gRPC server
	server := grpc.NewServer()
	proto.RegisterAgentServiceServer(server, syncer)

	go func() {
		if err := server.Serve(lis); err != nil {
			t.Logf("Server failed: %v", err)
		}
	}()
	defer server.Stop()

	// Test GetStatus returns combined results
	conn, err := grpc.DialContext(
		context.Background(),
		"bufnet",
		grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
			return lis.Dial()
		}),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	require.NoError(t, err)
	defer conn.Close()

	client := proto.NewAgentServiceClient(conn)

	req := &proto.StatusRequest{
		ServiceName: "multi-discovery",
		ServiceType: "sweep",
	}

	resp, err := client.GetStatus(context.Background(), req)
	require.NoError(t, err)

	// Parse response and verify we have results from both sources
	var response map[string]interface{}
	err = json.Unmarshal(resp.Message, &response)
	require.NoError(t, err)

	hosts, ok := response["hosts"].([]interface{})
	require.True(t, ok)
	assert.Len(t, hosts, 2) // Should have devices from both sources

	// Verify we have one netbox and one armis device
	var netboxFound, armisFound bool
	for _, hostInterface := range hosts {
		host, ok := hostInterface.(map[string]interface{})
		require.True(t, ok)

		metadata, ok := host["metadata"].(map[string]interface{})
		require.True(t, ok)

		source, ok := metadata["source"].(string)
		require.True(t, ok)

		switch source {
		case "netbox":
			netboxFound = true
			assert.Equal(t, "192.168.1.10", host["host"])
			assert.Equal(t, "netbox-device", host["hostname"])
			assert.Contains(t, host, "mac")
		case "armis":
			armisFound = true
			assert.Equal(t, "192.168.1.11", host["host"])
			assert.Equal(t, "armis-device", host["hostname"])
			assert.NotContains(t, host, "mac") // Armis device has no MAC
		}
	}

	assert.True(t, netboxFound, "Should have found netbox device")
	assert.True(t, armisFound, "Should have found armis device")
}

// Test helper implementations

type testIntegration struct {
	data   map[string][]byte
	events []*models.SweepResult
}

func (t *testIntegration) Fetch(ctx context.Context) (map[string][]byte, []*models.SweepResult, error) {
	return t.data, t.events, nil
}

type testKVClient struct{}

func (t *testKVClient) Put(ctx context.Context, req *proto.PutRequest, opts ...grpc.CallOption) (*proto.PutResponse, error) {
	return &proto.PutResponse{}, nil
}

func (t *testKVClient) Get(ctx context.Context, req *proto.GetRequest, opts ...grpc.CallOption) (*proto.GetResponse, error) {
	return &proto.GetResponse{}, nil
}

func (t *testKVClient) Delete(ctx context.Context, req *proto.DeleteRequest, opts ...grpc.CallOption) (*proto.DeleteResponse, error) {
	return &proto.DeleteResponse{}, nil
}

func (t *testKVClient) PutMany(ctx context.Context, req *proto.PutManyRequest, opts ...grpc.CallOption) (*proto.PutManyResponse, error) {
	return &proto.PutManyResponse{}, nil
}

func (t *testKVClient) Watch(ctx context.Context, req *proto.WatchRequest, opts ...grpc.CallOption) (proto.KVService_WatchClient, error) {
	return nil, nil // Not needed for these tests
}