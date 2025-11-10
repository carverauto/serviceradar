package core

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	nooptrace "go.opentelemetry.io/otel/trace/noop"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	identitymappb "github.com/carverauto/serviceradar/proto/identitymap/v1"
)

type fakeIdentityKV struct {
	getFn         func(ctx context.Context, in *proto.GetRequest) (*proto.GetResponse, error)
	putIfAbsentFn func(ctx context.Context, in *proto.PutRequest) (*proto.PutResponse, error)
	updateFn      func(ctx context.Context, in *proto.UpdateRequest) (*proto.UpdateResponse, error)
	putCalls      int
}

func (f *fakeIdentityKV) Get(ctx context.Context, in *proto.GetRequest, _ ...grpc.CallOption) (*proto.GetResponse, error) {
	if f.getFn != nil {
		return f.getFn(ctx, in)
	}
	return &proto.GetResponse{}, nil
}

func (f *fakeIdentityKV) PutIfAbsent(ctx context.Context, in *proto.PutRequest, _ ...grpc.CallOption) (*proto.PutResponse, error) {
	f.putCalls++
	if f.putIfAbsentFn != nil {
		return f.putIfAbsentFn(ctx, in)
	}
	return &proto.PutResponse{}, nil
}

func (f *fakeIdentityKV) Update(ctx context.Context, in *proto.UpdateRequest, _ ...grpc.CallOption) (*proto.UpdateResponse, error) {
	if f.updateFn != nil {
		return f.updateFn(ctx, in)
	}
	return &proto.UpdateResponse{}, nil
}

func (f *fakeIdentityKV) Delete(ctx context.Context, in *proto.DeleteRequest, _ ...grpc.CallOption) (*proto.DeleteResponse, error) {
	return &proto.DeleteResponse{}, nil
}

func TestGetCanonicalDevice_FromKV(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	rec := &identitymap.Record{
		CanonicalDeviceID: "tenant:device-1",
		Partition:         "tenant",
		MetadataHash:      "deadbeef",
		UpdatedAt:         now,
	}
	payload, err := identitymap.MarshalRecord(rec)
	require.NoError(t, err)

	kv := &fakeIdentityKV{
		getFn: func(_ context.Context, _ *proto.GetRequest) (*proto.GetResponse, error) {
			return &proto.GetResponse{Value: payload, Found: true, Revision: 42}, nil
		},
	}

	server := &Server{
		identityKVClient: kv,
		logger:           logger.NewTestLogger(),
		tracer:           nooptrace.NewTracerProvider().Tracer("test"),
	}

	req := &proto.GetCanonicalDeviceRequest{
		IdentityKeys: []*identitymappb.IdentityKey{
			identitymap.Key{Kind: identitymap.KindDeviceID, Value: "tenant:device-1"}.ToProto(),
		},
	}

	resp, err := server.GetCanonicalDevice(context.Background(), req)
	require.NoError(t, err)
	require.True(t, resp.GetFound())
	require.Equal(t, uint64(42), resp.GetRevision())
	require.Equal(t, "tenant:device-1", resp.GetRecord().GetCanonicalDeviceId())
	require.False(t, resp.GetHydrated())
}

func TestGetCanonicalDevice_FallbackHydratesKV(t *testing.T) {
	t.Parallel()

	ctrl := gomock.NewController(t)
	t.Cleanup(ctrl.Finish)

	mockDB := db.NewMockService(ctrl)

	device := &models.UnifiedDevice{
		DeviceID:         "tenant:device-2",
		IP:               "10.10.0.5",
		Metadata:         &models.DiscoveredField[map[string]string]{Value: map[string]string{"armis_device_id": "armis-2"}},
		DiscoverySources: []models.DiscoverySourceInfo{{Source: models.DiscoverySourceArmis}},
	}

	mockDB.EXPECT().GetUnifiedDevice(gomock.Any(), "tenant:device-2").Return(device, nil)

	kv := &fakeIdentityKV{}

	server := &Server{
		DB:               mockDB,
		identityKVClient: kv,
		logger:           logger.NewTestLogger(),
		tracer:           nooptrace.NewTracerProvider().Tracer("test"),
	}

	req := &proto.GetCanonicalDeviceRequest{
		IdentityKeys: []*identitymappb.IdentityKey{
			identitymap.Key{Kind: identitymap.KindDeviceID, Value: "tenant:device-2"}.ToProto(),
		},
	}

	resp, err := server.GetCanonicalDevice(context.Background(), req)
	require.NoError(t, err)
	require.True(t, resp.GetFound())
	require.True(t, resp.GetHydrated())
	require.Equal(t, "tenant:device-2", resp.GetRecord().GetCanonicalDeviceId())
	require.Equal(t, 1, kv.putCalls)
}
