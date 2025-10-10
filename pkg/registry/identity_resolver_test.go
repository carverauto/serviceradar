package registry

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

type fakeBatchGetter struct {
	results map[string]*proto.BatchGetEntry
}

func (f *fakeBatchGetter) BatchGet(_ context.Context, req *proto.BatchGetRequest, _ ...grpc.CallOption) (*proto.BatchGetResponse, error) {
	resp := &proto.BatchGetResponse{Results: make([]*proto.BatchGetEntry, 0, len(req.GetKeys()))}
	for _, key := range req.GetKeys() {
		if entry, ok := f.results[key]; ok {
			resp.Results = append(resp.Results, entry)
		} else {
			resp.Results = append(resp.Results, &proto.BatchGetEntry{Key: key, Found: false})
		}
	}
	return resp, nil
}

func TestIdentityResolverHydratesCanonicalDeviceID(t *testing.T) {
	record := &identitymap.Record{
		CanonicalDeviceID: "default:canonical-123",
		Partition:         "default",
		MetadataHash:      "abc123",
		Attributes: map[string]string{
			"hostname":         "device-123",
			"armis_device_id":  "armis-123",
			"mac":              "AA:BB:CC:DD:EE:FF",
			"integration_type": "armis",
		},
	}
	payload, err := identitymap.MarshalRecord(record)
	require.NoError(t, err)

	key := identitymap.Key{Kind: identitymap.KindArmisID, Value: "armis-123"}.KeyPath(identitymap.DefaultNamespace)
	kv := &fakeBatchGetter{
		results: map[string]*proto.BatchGetEntry{
			key: {
				Key:      key,
				Found:    true,
				Value:    payload,
				Revision: 9,
			},
		},
	}

	resolver := &identityResolver{
		kv:        kv,
		namespace: identitymap.DefaultNamespace,
		logger:    logger.NewTestLogger(),
	}

	update := &models.DeviceUpdate{
		DeviceID:  "default:10.0.0.10",
		Partition: "default",
		MAC:       nil,
		Metadata: map[string]string{
			"armis_device_id": "armis-123",
		},
	}

	err = resolver.hydrateCanonical(context.Background(), []*models.DeviceUpdate{update})
	require.NoError(t, err)

	require.Equal(t, "default:canonical-123", update.DeviceID)
	require.Equal(t, "default", update.Metadata["canonical_partition"])
	require.Equal(t, "default:canonical-123", update.Metadata["canonical_device_id"])
	require.Equal(t, "device-123", update.Metadata["canonical_hostname"])
	require.Equal(t, "9", update.Metadata["canonical_revision"])
	require.Equal(t, "armis-123", update.Metadata["armis_device_id"])
	require.Equal(t, "armis", update.Metadata["integration_type"])
	require.NotNil(t, update.MAC)
	require.Equal(t, "AA:BB:CC:DD:EE:FF", *update.MAC)
}
