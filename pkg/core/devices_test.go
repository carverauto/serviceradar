package core

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestEnsureServiceDeviceRegistersOnStatusSource(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry: mockRegistry,
		logger:         logger.NewTestLogger(),
	}

	serviceData := json.RawMessage(`{"status":{"host_ip":"10.0.0.5","hostname":"edge-agent"}}`)

	svc := &proto.ServiceStatus{
		ServiceName: "edge-agent",
		ServiceType: grpcServiceType,
		Source:      "status",
	}

	now := time.Now()

	gomock.InOrder(
		mockRegistry.EXPECT().
			GetCollectorCapabilities(gomock.Any(), "default:10.0.0.5").
			Return(nil, false),
		mockRegistry.EXPECT().
			SetCollectorCapabilities(gomock.Any(), gomock.AssignableToTypeOf(&models.CollectorCapability{})).
			Do(func(_ context.Context, record *models.CollectorCapability) {
				require.NotNil(t, record)
				require.Equal(t, "default:10.0.0.5", record.DeviceID)
				require.ElementsMatch(t, []string{"edge-agent", "grpc"}, record.Capabilities)
				require.Equal(t, "agent-1", record.AgentID)
				require.Equal(t, "poller-1", record.PollerID)
				require.Equal(t, "edge-agent", record.ServiceName)
			}),
		mockRegistry.EXPECT().
			ProcessBatchDeviceUpdates(gomock.Any(), gomock.Len(1)).
			DoAndReturn(func(_ context.Context, updates []*models.DeviceUpdate) error {
				require.Len(t, updates, 1)
				update := updates[0]
				require.Equal(t, models.DiscoverySourceSelfReported, update.Source)
				require.Equal(t, "default:10.0.0.5", update.DeviceID)
				require.Equal(t, "10.0.0.5", update.IP)
				require.Equal(t, "default", update.Partition)
				require.Equal(t, "agent-1", update.AgentID)
				require.Equal(t, "poller-1", update.PollerID)
				require.True(t, update.IsAvailable)

				require.NotNil(t, update.Hostname)
				require.Equal(t, "edge-agent", *update.Hostname)

				require.Equal(t, "edge-agent", update.Metadata["checker_service"])
				require.Equal(t, "edge-agent", update.Metadata["checker_service_id"])
				require.Equal(t, grpcServiceType, update.Metadata["checker_service_type"])
				require.Equal(t, "10.0.0.5", update.Metadata["checker_host_ip"])
				require.Equal(t, "agent-1", update.Metadata["collector_agent_id"])
				require.Equal(t, "poller-1", update.Metadata["collector_poller_id"])

				require.NotEmpty(t, update.Metadata["last_update"])
				return nil
			}),
	)

	server.ensureServiceDevice(
		"agent-1",
		"poller-1",
		"default",
		svc,
		serviceData,
		now,
	)

	server.flushServiceDeviceUpdates(context.Background())
}

func TestEnsureServiceDeviceSkipsResultSource(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockRegistry := registry.NewMockManager(ctrl)

	server := &Server{
		DeviceRegistry: mockRegistry,
		logger:         logger.NewTestLogger(),
	}

	serviceData := json.RawMessage(`{"status":{"host_ip":"10.0.0.5"}}`)

	svc := &proto.ServiceStatus{
		ServiceName: "edge-agent",
		ServiceType: grpcServiceType,
		Source:      "results",
	}

	server.ensureServiceDevice(
		"agent-1",
		"poller-1",
		"default",
		svc,
		serviceData,
		time.Now(),
	)

	server.flushServiceDeviceUpdates(context.Background())
}
