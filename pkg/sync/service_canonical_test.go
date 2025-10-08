package sync

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

func TestHydrateCanonicalUpdates(t *testing.T) {
	ctrl := gomock.NewController(t)
	t.Cleanup(ctrl.Finish)

	mockKV := NewMockKVClient(ctrl)

	service := &SimpleSyncService{
		kvClient: mockKV,
		logger:   logger.NewTestLogger(),
	}

	update := &models.DeviceUpdate{
		DeviceID: "default:10.0.0.1",
		Metadata: map[string]string{
			"armis_device_id": "123",
		},
	}

	record := &identitymap.Record{
		CanonicalDeviceID: "default:canonical-123",
		Partition:         "default",
		MetadataHash:      "hash-123",
		Attributes:        map[string]string{"hostname": "device-123"},
	}

	payload, err := identitymap.MarshalRecord(record)
	require.NoError(t, err)

	mockKV.EXPECT().
		BatchGet(gomock.Any(), gomock.Any()).
		DoAndReturn(func(_ context.Context, req *proto.BatchGetRequest, _ ...grpc.CallOption) (*proto.BatchGetResponse, error) {
			require.NotEmpty(t, req.GetKeys())
			require.Contains(t, req.GetKeys(), "device_canonical_map/armis-id/123")
			return &proto.BatchGetResponse{
				Results: []*proto.BatchGetEntry{
					{
						Key:      "device_canonical_map/armis-id/123",
						Found:    true,
						Value:    payload,
						Revision: 7,
					},
				},
			}, nil
		})

	err = service.hydrateCanonicalUpdates(context.Background(), map[string][]*models.DeviceUpdate{
		"armis": {update},
	})
	require.NoError(t, err)

	require.Equal(t, "default:canonical-123", update.Metadata["canonical_device_id"])
	require.Equal(t, "default", update.Metadata["canonical_partition"])
	require.Equal(t, "hash-123", update.Metadata["canonical_metadata_hash"])
	require.Equal(t, "device-123", update.Metadata["canonical_hostname"])
	require.Equal(t, "7", update.Metadata["canonical_revision"])
}
