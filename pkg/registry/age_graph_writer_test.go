package registry

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestBuildAgeGraphParams_DeviceCollectorsAndEdges(t *testing.T) {
	host := "router1"
	params := buildAgeGraphParams([]*models.DeviceUpdate{
		{
			DeviceID: "sr:device-1",
			IP:       "192.168.1.10",
			AgentID:  "docker-agent",
			PollerID: "docker-poller",
			Hostname: &host,
		},
	})

	require.NotNil(t, params)
	assert.Len(t, params.Devices, 1)
	assert.Equal(t, "sr:device-1", params.Devices[0].ID)
	assert.Len(t, params.Collectors, 2, "agent and poller collectors should be present")
	assert.Len(t, params.ReportedBy, 2, "device should have edges to both collectors")
	assert.Empty(t, params.Services)
}

func TestBuildAgeGraphParams_AgentCollectorOnly(t *testing.T) {
	host := "agent-host"
	params := buildAgeGraphParams([]*models.DeviceUpdate{
		{
			DeviceID:    models.GenerateServiceDeviceID(models.ServiceTypeAgent, "docker-agent"),
			ServiceType: serviceTypePtr(models.ServiceTypeAgent),
			IP:          "172.18.0.5",
			PollerID:    "docker-poller",
			Hostname:    &host,
		},
	})

	require.NotNil(t, params)
	assert.Empty(t, params.Devices, "service devices should not create Device nodes")
	assert.Len(t, params.Collectors, 2, "agent collector plus parent poller collector")
	assert.Len(t, params.ReportedBy, 1, "agent should link back to its poller")
	assert.Empty(t, params.Services)
}

func TestBuildAgeGraphParams_ServiceAttachedToCollector(t *testing.T) {
	params := buildAgeGraphParams([]*models.DeviceUpdate{
		{
			DeviceID:    models.GenerateServiceDeviceID(models.ServiceTypeSync, "sync"),
			ServiceType: serviceTypePtr(models.ServiceTypeSync),
			AgentID:     "docker-agent",
		},
	})

	require.NotNil(t, params)
	assert.Len(t, params.Services, 1)
	assert.Equal(t, models.GenerateServiceDeviceID(models.ServiceTypeAgent, "docker-agent"), params.Services[0].CollectorID)
	assert.Len(t, params.Collectors, 1, "collector host should be created to anchor HOSTS_SERVICE")
	assert.Empty(t, params.Devices)
}

func TestBuildAgeGraphParams_CheckerTargets(t *testing.T) {
	host := "target"
	params := buildAgeGraphParams([]*models.DeviceUpdate{
		{
			DeviceID: "default:10.0.0.5",
			IP:       "10.0.0.5",
			AgentID:  "docker-agent",
			Hostname: &host,
			Metadata: map[string]string{
				"checker_service":      "sysmon",
				"checker_service_type": "grpc",
			},
		},
	})

	require.NotNil(t, params)
	require.Len(t, params.Targets, 1)
	assert.Equal(t, models.GenerateServiceDeviceID(models.ServiceTypeChecker, "sysmon@docker-agent"), params.Targets[0].ServiceID)
	assert.Len(t, params.Services, 1, "checker service node should be created")
	assert.Len(t, params.Collectors, 1, "host collector should be present for HOSTS_SERVICE")
}

func TestBuildInterfaceParams(t *testing.T) {
	ifaces := []*models.DiscoveredInterface{
		{
			DeviceID:      "sr:device-1",
			IfIndex:       1,
			IfName:        "eth0",
			IfDescr:       "uplink",
			IfAlias:       "alias",
			IfPhysAddress: "aa:bb:cc",
			IPAddresses:   []string{"10.0.0.1", "10.0.0.1", "  "},
		},
		{
			DeviceID: "sr:device-1",
			IfIndex:  2,
			// IfName empty -> use ifindex
		},
	}

	params := buildInterfaceParams(ifaces)
	require.Len(t, params, 2)

	assert.Equal(t, "sr:device-1/eth0", params[0].ID)
	assert.Equal(t, []string{"10.0.0.1"}, params[0].IPAddresses)
	assert.Equal(t, "sr:device-1/ifindex:2", params[1].ID)
	assert.Equal(t, int32(2), params[1].IfIndex)
}

func serviceTypePtr(st models.ServiceType) *models.ServiceType {
	return &st
}
