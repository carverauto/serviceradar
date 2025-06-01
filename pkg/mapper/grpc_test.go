package mapper

import (
	"context"
	"testing"
	"time"

	proto "github.com/carverauto/serviceradar/proto/discovery"
	"github.com/stretchr/testify/assert"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestNewGRPCDiscoveryService(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockMapper := NewMockMapper(ctrl)
	service := NewGRPCDiscoveryService(mockMapper)

	assert.NotNil(t, service)
	assert.Equal(t, mockMapper, service.engine)
}

func TestGetStatus(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockMapper := NewMockMapper(ctrl)
	service := NewGRPCDiscoveryService(mockMapper)

	ctx := context.Background()

	// Test with discovery ID
	discoveryID := "test-discovery-id"
	mockMapper.EXPECT().GetDiscoveryStatus(ctx, discoveryID).Return(&DiscoveryStatus{
		Status: DiscoveryStatusRunning,
	}, nil)

	resp, err := service.GetStatus(ctx, &proto.StatusRequest{
		DiscoveryId: discoveryID,
	})

	assert.NoError(t, err)
	assert.NotNil(t, resp)
	assert.True(t, resp.Available)
	assert.Equal(t, "running", resp.Status)
	assert.Contains(t, resp.ActiveDiscoveries, discoveryID)

	// Test without discovery ID (overall service status)
	resp, err = service.GetStatus(ctx, &proto.StatusRequest{})

	assert.NoError(t, err)
	assert.NotNil(t, resp)
	assert.True(t, resp.Available)
	assert.Equal(t, "running", resp.Status)
}

func TestGRPCStartDiscovery(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockMapper := NewMockMapper(ctrl)
	service := NewGRPCDiscoveryService(mockMapper)

	ctx := context.Background()
	discoveryID := "test-discovery-id"

	// Test with valid request
	req := &proto.DiscoveryRequest{
		Seeds:          []string{"192.168.1.1"},
		Type:           proto.DiscoveryRequest_FULL,
		Concurrency:    10,
		TimeoutSeconds: 30,
		Retries:        3,
		Credentials: &proto.SNMPCredentials{
			Version:   proto.SNMPCredentials_V2C,
			Community: "public",
		},
	}

	// Set up expectation for StartDiscovery
	mockMapper.EXPECT().StartDiscovery(ctx, gomock.Any()).DoAndReturn(
		func(_ context.Context, params *DiscoveryParams) (string, error) {
			// Verify params were converted correctly
			assert.Equal(t, req.Seeds, params.Seeds)
			assert.Equal(t, DiscoveryTypeFull, params.Type)
			assert.Equal(t, int(req.Concurrency), params.Concurrency)
			assert.Equal(t, time.Duration(req.TimeoutSeconds)*time.Second, params.Timeout)
			assert.Equal(t, int(req.Retries), params.Retries)
			assert.Equal(t, SNMPVersion2c, params.Credentials.Version)
			assert.Equal(t, req.Credentials.Community, params.Credentials.Community)
			return discoveryID, nil
		},
	)

	resp, err := service.StartDiscovery(ctx, req)

	assert.NoError(t, err)
	assert.NotNil(t, resp)
	assert.Equal(t, discoveryID, resp.DiscoveryId)
	assert.True(t, resp.Success)
	assert.NotZero(t, resp.EstimatedDuration)

	// Test with error from mapper
	mockMapper.EXPECT().StartDiscovery(ctx, gomock.Any()).Return("", assert.AnError)

	resp, err = service.StartDiscovery(ctx, req)

	assert.Error(t, err)
	assert.Nil(t, resp)
}

func TestGRPCGetDiscoveryResults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockMapper := NewMockMapper(ctrl)
	service := NewGRPCDiscoveryService(mockMapper)

	ctx := context.Background()
	discoveryID := "test-discovery-id"
	includeRawData := true

	// Create test results
	results := &DiscoveryResults{
		Status: &DiscoveryStatus{
			Status:   DiscoveryStatusCompleted,
			Progress: 100,
		},
		Devices: []*DiscoveredDevice{
			{
				IP:       "192.168.1.1",
				Hostname: "device1",
			},
		},
		Interfaces: []*DiscoveredInterface{
			{
				DeviceIP: "192.168.1.1",
				IfIndex:  1,
				IfName:   "eth0",
			},
		},
		TopologyLinks: []*TopologyLink{
			{
				LocalDeviceIP:     "192.168.1.1",
				LocalIfIndex:      1,
				NeighborChassisID: "00:11:22:33:44:55",
			},
		},
		RawData: map[string]interface{}{
			"raw1": "data1",
		},
	}

	// Set up expectation for GetDiscoveryResults
	mockMapper.EXPECT().GetDiscoveryResults(ctx, discoveryID, includeRawData).Return(results, nil)

	resp, err := service.GetDiscoveryResults(ctx, &proto.ResultsRequest{
		DiscoveryId:    discoveryID,
		IncludeRawData: includeRawData,
	})

	assert.NoError(t, err)
	assert.NotNil(t, resp)
	assert.Equal(t, discoveryID, resp.DiscoveryId)
	assert.Equal(t, proto.DiscoveryStatus_COMPLETED, resp.Status)
	assert.Equal(t, float32(100), resp.Progress)
	assert.Len(t, resp.Devices, 1)
	assert.Len(t, resp.Interfaces, 1)
	assert.Len(t, resp.Topology, 1)
	assert.Equal(t, "192.168.1.1", resp.Devices[0].Ip)
	assert.Equal(t, "device1", resp.Devices[0].Hostname)
	assert.Equal(t, "192.168.1.1", resp.Interfaces[0].DeviceIp)
	assert.Equal(t, "192.168.1.1", resp.Topology[0].LocalDeviceIp)
	assert.Equal(t, "data1", resp.Metadata["raw1"])

	// Test with error from mapper
	mockMapper.EXPECT().GetDiscoveryResults(ctx, discoveryID, includeRawData).Return(nil, assert.AnError)

	resp, err = service.GetDiscoveryResults(ctx, &proto.ResultsRequest{
		DiscoveryId:    discoveryID,
		IncludeRawData: includeRawData,
	})

	assert.Error(t, err)
	assert.Nil(t, resp)
}

func TestGetLatestCachedResults(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// This test is more complex because it requires access to the internal state of DiscoveryEngine
	// We'll create a real DiscoveryEngine with a mock publisher
	mockPublisher := NewMockPublisher(ctrl)
	engine, err := NewDiscoveryEngine(&Config{
		Workers:       2,
		MaxActiveJobs: 5,
		Timeout:       30 * time.Second,
	}, mockPublisher)
	assert.NoError(t, err)

	service := NewGRPCDiscoveryService(engine)
	ctx := context.Background()

	// Add a completed job to the engine
	discoveryID := "test-discovery-id"
	discoveryEngine := engine.(*DiscoveryEngine)
	discoveryEngine.completedJobs = map[string]*DiscoveryResults{
		discoveryID: {
			Status: &DiscoveryStatus{
				Status:   DiscoveryStatusCompleted,
				EndTime:  time.Now(),
				Progress: 100,
			},
			Devices: []*DiscoveredDevice{
				{
					IP:       "192.168.1.1",
					Hostname: "device1",
				},
			},
		},
	}

	// Test getting latest cached results
	resp, err := service.GetLatestCachedResults(ctx, &proto.GetLatestCachedResultsRequest{
		IncludeRawData: true,
	})

	assert.NoError(t, err)
	assert.NotNil(t, resp)
	assert.Equal(t, discoveryID, resp.DiscoveryId)
	assert.Equal(t, proto.DiscoveryStatus_COMPLETED, resp.Status)
	assert.Len(t, resp.Devices, 1)
	assert.Equal(t, "192.168.1.1", resp.Devices[0].Ip)

	// Test with no completed jobs
	discoveryEngine.completedJobs = map[string]*DiscoveryResults{}

	resp, err = service.GetLatestCachedResults(ctx, &proto.GetLatestCachedResultsRequest{})

	assert.Error(t, err)
	assert.Nil(t, resp)
	assert.Equal(t, codes.NotFound, status.Code(err))
}

func TestConvertInterfaceToProto(t *testing.T) {
	iface := &DiscoveredInterface{
		DeviceIP:      "192.168.1.1",
		DeviceID:      "device1",
		IfIndex:       1,
		IfName:        "eth0",
		IfDescr:       "Ethernet 0",
		IfAlias:       "External",
		IfSpeed:       1000000000,
		IfPhysAddress: "00:11:22:33:44:55",
		IPAddresses:   []string{"192.168.1.1/24"},
		IfAdminStatus: 1,
		IfOperStatus:  1,
		IfType:        6,
		Metadata:      map[string]string{"key": "value"},
	}

	protoIface, valid := convertInterfaceToProto(iface)

	assert.True(t, valid)
	assert.Equal(t, iface.DeviceIP, protoIface.DeviceIp)
	assert.Equal(t, iface.DeviceID, protoIface.DeviceId)
	assert.Equal(t, iface.IfIndex, protoIface.IfIndex)
	assert.Equal(t, iface.IfName, protoIface.IfName)
	assert.Equal(t, iface.IfDescr, protoIface.IfDescr)
	assert.Equal(t, iface.IfAlias, protoIface.IfAlias)
	assert.Equal(t, iface.IfSpeed, protoIface.IfSpeed.Value)
	assert.Equal(t, iface.IfPhysAddress, protoIface.IfPhysAddress)
	assert.Equal(t, iface.IPAddresses, protoIface.IpAddresses)
	assert.Equal(t, iface.IfAdminStatus, protoIface.IfAdminStatus)
	assert.Equal(t, iface.IfOperStatus, protoIface.IfOperStatus)
	assert.Equal(t, iface.IfType, protoIface.IfType)
	assert.Equal(t, iface.Metadata, protoIface.Metadata)
}

func TestConvertDeviceToProto(t *testing.T) {
	device := &DiscoveredDevice{
		IP:          "192.168.1.1",
		MAC:         "00:11:22:33:44:55",
		Hostname:    "device1",
		SysDescr:    "Test Device",
		SysObjectID: "1.3.6.1.4.1.9.1.1",
		SysContact:  "admin",
		SysLocation: "datacenter",
		Uptime:      3600,
		Metadata:    map[string]string{"key": "value"},
	}

	protoDevice := convertDeviceToProto(device)

	assert.Equal(t, device.IP, protoDevice.Ip)
	assert.Equal(t, device.MAC, protoDevice.Mac)
	assert.Equal(t, device.Hostname, protoDevice.Hostname)
	assert.Equal(t, device.SysDescr, protoDevice.SysDescr)
	assert.Equal(t, device.SysObjectID, protoDevice.SysObjectId)
	assert.Equal(t, device.SysContact, protoDevice.SysContact)
	assert.Equal(t, device.SysLocation, protoDevice.SysLocation)
	assert.Equal(t, device.Uptime, protoDevice.Uptime)
	assert.Equal(t, device.Metadata, protoDevice.Metadata)
}

func TestConvertTopologyLinkToProto(t *testing.T) {
	link := &TopologyLink{
		Protocol:           "lldp",
		LocalDeviceIP:      "192.168.1.1",
		LocalDeviceID:      "device1",
		LocalIfIndex:       1,
		LocalIfName:        "eth0",
		NeighborChassisID:  "00:11:22:33:44:55",
		NeighborPortID:     "Gi0/1",
		NeighborPortDescr:  "GigabitEthernet0/1",
		NeighborSystemName: "neighbor1",
		NeighborMgmtAddr:   "192.168.1.2",
		Metadata:           map[string]string{"key": "value"},
	}

	protoLink := convertTopologyLinkToProto(link)

	assert.Equal(t, link.Protocol, protoLink.Protocol)
	assert.Equal(t, link.LocalDeviceIP, protoLink.LocalDeviceIp)
	assert.Equal(t, link.LocalDeviceID, protoLink.LocalDeviceId)
	assert.Equal(t, link.LocalIfIndex, protoLink.LocalIfIndex)
	assert.Equal(t, link.LocalIfName, protoLink.LocalIfName)
	assert.Equal(t, link.NeighborChassisID, protoLink.NeighborChassisId)
	assert.Equal(t, link.NeighborPortID, protoLink.NeighborPortId)
	assert.Equal(t, link.NeighborPortDescr, protoLink.NeighborPortDescr)
	assert.Equal(t, link.NeighborSystemName, protoLink.NeighborSystemName)
	assert.Equal(t, link.NeighborMgmtAddr, protoLink.NeighborMgmtAddr)
	assert.Equal(t, link.Metadata, protoLink.Metadata)
}

func TestConvertResultsToProto(t *testing.T) {
	discoveryID := "test-discovery-id"
	includeRawData := true

	results := &DiscoveryResults{
		Status: &DiscoveryStatus{
			Status:   DiscoveryStatusCompleted,
			Progress: 100,
			Error:    "no error",
		},
		Devices: []*DiscoveredDevice{
			{
				IP:       "192.168.1.1",
				Hostname: "device1",
			},
		},
		Interfaces: []*DiscoveredInterface{
			{
				DeviceIP: "192.168.1.1",
				IfIndex:  1,
				IfName:   "eth0",
				IfSpeed:  1000000000,
			},
		},
		TopologyLinks: []*TopologyLink{
			{
				LocalDeviceIP:     "192.168.1.1",
				LocalIfIndex:      1,
				NeighborChassisID: "00:11:22:33:44:55",
			},
		},
		RawData: map[string]interface{}{
			"raw1": "data1",
			"raw2": 123, // This should be skipped as it's not a string
		},
	}

	resp, err := convertResultsToProto(results, discoveryID, includeRawData)

	assert.NoError(t, err)
	assert.Equal(t, discoveryID, resp.DiscoveryId)
	assert.Equal(t, proto.DiscoveryStatus_COMPLETED, resp.Status)
	assert.Equal(t, float32(100), resp.Progress)
	assert.Equal(t, "no error", resp.Error)
	assert.Len(t, resp.Devices, 1)
	assert.Len(t, resp.Interfaces, 1)
	assert.Len(t, resp.Topology, 1)
	assert.Equal(t, "192.168.1.1", resp.Devices[0].Ip)
	assert.Equal(t, "device1", resp.Devices[0].Hostname)
	assert.Equal(t, "192.168.1.1", resp.Interfaces[0].DeviceIp)
	assert.Equal(t, uint64(1000000000), resp.Interfaces[0].IfSpeed.Value)
	assert.Equal(t, "192.168.1.1", resp.Topology[0].LocalDeviceIp)
	assert.Equal(t, "data1", resp.Metadata["raw1"])
	_, exists := resp.Metadata["raw2"]
	assert.False(t, exists, "Non-string raw data should be skipped")
}

func TestProtoToDiscoveryType(t *testing.T) {
	tests := []struct {
		name     string
		protoTyp proto.DiscoveryRequest_DiscoveryType
		expected DiscoveryType
	}{
		{
			name:     "FULL",
			protoTyp: proto.DiscoveryRequest_FULL,
			expected: DiscoveryTypeFull,
		},
		{
			name:     "BASIC",
			protoTyp: proto.DiscoveryRequest_BASIC,
			expected: DiscoveryTypeBasic,
		},
		{
			name:     "INTERFACES",
			protoTyp: proto.DiscoveryRequest_INTERFACES,
			expected: DiscoveryTypeInterfaces,
		},
		{
			name:     "TOPOLOGY",
			protoTyp: proto.DiscoveryRequest_TOPOLOGY,
			expected: DiscoveryTypeTopology,
		},
		{
			name:     "Unknown",
			protoTyp: proto.DiscoveryRequest_DiscoveryType(999),
			expected: DiscoveryTypeFull, // Default
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := protoToDiscoveryType(tt.protoTyp)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestProtoToSNMPCredentials(t *testing.T) {
	// Test with nil credentials
	result := protoToSNMPCredentials(nil)
	assert.NotNil(t, result)
	assert.Equal(t, SNMPVersion2c, result.Version)

	// Test with v1 credentials
	creds := &proto.SNMPCredentials{
		Version:   proto.SNMPCredentials_V1,
		Community: "public",
	}
	result = protoToSNMPCredentials(creds)
	assert.Equal(t, SNMPVersion1, result.Version)
	assert.Equal(t, "public", result.Community)

	// Test with v2c credentials
	creds = &proto.SNMPCredentials{
		Version:   proto.SNMPCredentials_V2C,
		Community: "private",
	}
	result = protoToSNMPCredentials(creds)
	assert.Equal(t, SNMPVersion2c, result.Version)
	assert.Equal(t, "private", result.Community)

	// Test with v3 credentials
	creds = &proto.SNMPCredentials{
		Version:         proto.SNMPCredentials_V3,
		Username:        "user",
		AuthProtocol:    "SHA",
		AuthPassword:    "authpass",
		PrivacyProtocol: "AES",
		PrivacyPassword: "privpass",
	}
	result = protoToSNMPCredentials(creds)
	assert.Equal(t, SNMPVersion3, result.Version)
	assert.Equal(t, "user", result.Username)
	assert.Equal(t, "SHA", result.AuthProtocol)
	assert.Equal(t, "authpass", result.AuthPassword)
	assert.Equal(t, "AES", result.PrivacyProtocol)
	assert.Equal(t, "privpass", result.PrivacyPassword)

	// Test with target-specific credentials
	targetCreds := &proto.SNMPCredentials{
		Version:   proto.SNMPCredentials_V2C,
		Community: "target-community",
	}
	creds = &proto.SNMPCredentials{
		Version:        proto.SNMPCredentials_V2C,
		Community:      "default-community",
		TargetSpecific: map[string]*proto.SNMPCredentials{"192.168.1.1": targetCreds},
	}
	result = protoToSNMPCredentials(creds)
	assert.Equal(t, SNMPVersion2c, result.Version)
	assert.Equal(t, "default-community", result.Community)
	assert.NotNil(t, result.TargetSpecific)
	assert.Contains(t, result.TargetSpecific, "192.168.1.1")
	assert.Equal(t, "target-community", result.TargetSpecific["192.168.1.1"].Community)
}

func TestStatusTypeToString(t *testing.T) {
	tests := []struct {
		status   DiscoveryStatusType
		expected string
	}{
		{DiscoveryStatusPending, "pending"},
		{DiscoveryStatusRunning, "running"},
		{DiscoveryStatusCompleted, "completed"},
		{DiscoveryStatusFailed, "failed"},
		{DiscoverStatusCanceled, "canceled"},
		{DiscoveryStatusUnknown, "unknown"},
	}

	for _, tt := range tests {
		t.Run(string(tt.status), func(t *testing.T) {
			result := statusTypeToString(tt.status)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestStatusTypeToProtoStatus(t *testing.T) {
	tests := []struct {
		status   DiscoveryStatusType
		expected proto.DiscoveryStatus
	}{
		{DiscoveryStatusPending, proto.DiscoveryStatus_PENDING},
		{DiscoveryStatusRunning, proto.DiscoveryStatus_RUNNING},
		{DiscoveryStatusCompleted, proto.DiscoveryStatus_COMPLETED},
		{DiscoveryStatusFailed, proto.DiscoveryStatus_FAILED},
		{DiscoverStatusCanceled, proto.DiscoveryStatus_CANCELED},
		{DiscoveryStatusUnknown, proto.DiscoveryStatus_UNKNOWN},
		{DiscoveryStatusType("invalid"), proto.DiscoveryStatus_UNKNOWN},
	}

	for _, tt := range tests {
		t.Run(string(tt.status), func(t *testing.T) {
			result := statusTypeToProtoStatus(tt.status)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestEstimateDuration(t *testing.T) {
	tests := []struct {
		name   string
		params *DiscoveryParams
		check  func(t *testing.T, duration int32)
	}{
		{
			name: "Basic discovery",
			params: &DiscoveryParams{
				Seeds: []string{"192.168.1.1", "192.168.1.2"},
				Type:  DiscoveryTypeBasic,
			},
			check: func(t *testing.T, duration int32) {
				// Basic formula: (seeds * 10 * timePerDeviceBasic) / concurrency * overhead
				// With default values: (2 * 10 * 2) / 10 * 1.2 = 4.8 -> 4
				assert.Equal(t, int32(4), duration)
			},
		},
		{
			name: "Full discovery",
			params: &DiscoveryParams{
				Seeds: []string{"192.168.1.1", "192.168.1.2", "192.168.1.3"},
				Type:  DiscoveryTypeFull,
			},
			check: func(t *testing.T, duration int32) {
				// (3 * 10 * 10) / 10 * 1.2 = 36
				assert.Equal(t, int32(36), duration)
			},
		},
		{
			name: "Custom concurrency",
			params: &DiscoveryParams{
				Seeds:       []string{"192.168.1.1", "192.168.1.2"},
				Type:        DiscoveryTypeBasic,
				Concurrency: 5,
			},
			check: func(t *testing.T, duration int32) {
				// (2 * 10 * 2) / 5 * 1.2 = 9.6 -> 9
				assert.Equal(t, int32(9), duration)
			},
		},
		{
			name: "Zero concurrency (should use default)",
			params: &DiscoveryParams{
				Seeds:       []string{"192.168.1.1", "192.168.1.2"},
				Type:        DiscoveryTypeBasic,
				Concurrency: 0,
			},
			check: func(t *testing.T, duration int32) {
				// (2 * 10 * 2) / 10 * 1.2 = 4.8 -> 4
				assert.Equal(t, int32(4), duration)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			duration := estimateDuration(tt.params)
			tt.check(t, duration)
		})
	}
}
