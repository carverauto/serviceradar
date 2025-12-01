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

func serviceTypePtr(st models.ServiceType) *models.ServiceType {
	return &st
}
