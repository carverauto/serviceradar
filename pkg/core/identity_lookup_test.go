package core

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	nooptrace "go.opentelemetry.io/otel/trace/noop"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	identitymappb "github.com/carverauto/serviceradar/proto/identitymap/v1"
)

func TestGetCanonicalDevice_FromDB(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	t.Cleanup(ctrl.Finish)

	mockDB := db.NewMockService(ctrl)

	device := &models.UnifiedDevice{
		DeviceID:         "tenant:device-1",
		IP:               "10.10.0.5",
		Metadata:         &models.DiscoveredField[map[string]string]{Value: map[string]string{"armis_device_id": "armis-1"}},
		DiscoverySources: []models.DiscoverySourceInfo{{Source: models.DiscoverySourceArmis}},
	}

	mockDB.EXPECT().GetUnifiedDevice(gomock.Any(), "tenant:device-1").Return(device, nil)

	server := &Server{
		DB:     mockDB,
		logger: logger.NewTestLogger(),
		tracer: nooptrace.NewTracerProvider().Tracer("test"),
	}

	req := &proto.GetCanonicalDeviceRequest{
		IdentityKeys: []*identitymappb.IdentityKey{
			identitymap.Key{Kind: identitymap.KindDeviceID, Value: "tenant:device-1"}.ToProto(),
		},
	}

	resp, err := server.GetCanonicalDevice(context.Background(), req)
	require.NoError(t, err)
	require.True(t, resp.GetFound())
	require.Equal(t, "tenant:device-1", resp.GetRecord().GetCanonicalDeviceId())
}

func TestGetCanonicalDevice_NotFound(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	t.Cleanup(ctrl.Finish)

	mockDB := db.NewMockService(ctrl)

	mockDB.EXPECT().GetUnifiedDevice(gomock.Any(), "nonexistent").Return(nil, nil)

	server := &Server{
		DB:     mockDB,
		logger: logger.NewTestLogger(),
		tracer: nooptrace.NewTracerProvider().Tracer("test"),
	}

	req := &proto.GetCanonicalDeviceRequest{
		IdentityKeys: []*identitymappb.IdentityKey{
			identitymap.Key{Kind: identitymap.KindDeviceID, Value: "nonexistent"}.ToProto(),
		},
	}

	resp, err := server.GetCanonicalDevice(context.Background(), req)
	require.NoError(t, err)
	require.False(t, resp.GetFound())
}

func TestGetCanonicalDevice_ByIP(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	t.Cleanup(ctrl.Finish)

	mockDB := db.NewMockService(ctrl)

	device := &models.UnifiedDevice{
		DeviceID:         "sr:12345678-1234-1234-1234-123456789abc",
		IP:               "192.168.1.100",
		Metadata:         &models.DiscoveredField[map[string]string]{Value: map[string]string{}},
		DiscoverySources: []models.DiscoverySourceInfo{{Source: models.DiscoverySourceSweep}},
	}

	mockDB.EXPECT().GetUnifiedDevicesByIPsOrIDs(gomock.Any(), []string{"192.168.1.100"}, nil).Return([]*models.UnifiedDevice{device}, nil)

	server := &Server{
		DB:     mockDB,
		logger: logger.NewTestLogger(),
		tracer: nooptrace.NewTracerProvider().Tracer("test"),
	}

	req := &proto.GetCanonicalDeviceRequest{
		IdentityKeys: []*identitymappb.IdentityKey{
			identitymap.Key{Kind: identitymap.KindIP, Value: "192.168.1.100"}.ToProto(),
		},
	}

	resp, err := server.GetCanonicalDevice(context.Background(), req)
	require.NoError(t, err)
	require.True(t, resp.GetFound())
	require.Equal(t, "sr:12345678-1234-1234-1234-123456789abc", resp.GetRecord().GetCanonicalDeviceId())
}

func TestGetCanonicalDevice_InvalidRequest(t *testing.T) {
	t.Parallel()

	server := &Server{
		logger: logger.NewTestLogger(),
		tracer: nooptrace.NewTracerProvider().Tracer("test"),
	}

	// Test nil request
	resp, err := server.GetCanonicalDevice(context.Background(), nil)
	require.Error(t, err)
	require.Nil(t, resp)

	// Test empty keys
	resp, err = server.GetCanonicalDevice(context.Background(), &proto.GetCanonicalDeviceRequest{})
	require.Error(t, err)
	require.Nil(t, resp)
}
