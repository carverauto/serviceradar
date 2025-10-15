package registry

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

// This regression test ensures we do not cache a stale revision when the KV Update
// RPC omits a revision in its response.
func TestIdentityPublisherCachesStaleRevisionWithoutUpdateResponse(t *testing.T) {
	t.Parallel()

	kvClient := newFakeIdentityKVClient()
	pub := newIdentityPublisher(kvClient, identitymap.DefaultNamespace, 0, logger.NewTestLogger())

	key := identitymap.Key{Kind: identitymap.KindDeviceID, Value: "device-revision"}.KeyPath(identitymap.DefaultNamespace)

	existingRecord := &identitymap.Record{
		CanonicalDeviceID: "device-revision",
		MetadataHash: identitymap.HashIdentityMetadata(&models.DeviceUpdate{
			DeviceID: "device-revision",
			Metadata: map[string]string{"armis_device_id": "armis-old"},
		}),
		Attributes: map[string]string{"armis_device_id": "armis-old"},
	}

	payload, err := identitymap.MarshalRecord(existingRecord)
	require.NoError(t, err)

	kvClient.entries[key] = &fakeKVEntry{value: payload, revision: 1}
	kvClient.omitUpdateResp[key] = true

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	first := &models.DeviceUpdate{
		DeviceID: "device-revision",
		Metadata: map[string]string{"armis_device_id": "armis-new"},
	}
	require.NoError(t, pub.Publish(ctx, []*models.DeviceUpdate{first}))

	second := &models.DeviceUpdate{
		DeviceID: "device-revision",
		Metadata: map[string]string{"armis_device_id": "armis-newer"},
	}
	require.NoError(t, pub.Publish(ctx, []*models.DeviceUpdate{second}))

	require.Zero(t, kvClient.revisionMiss[key], "unexpected revision mismatch: stale revision cached after Update without response")
}
