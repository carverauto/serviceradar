package registry

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var errStubPublish = errors.New("identity publisher test boom")

type stubKVClient struct {
	received *proto.PutManyRequest
	err      error
}

func (s *stubKVClient) PutMany(_ context.Context, req *proto.PutManyRequest, _ ...grpc.CallOption) (*proto.PutManyResponse, error) {
	s.received = req
	if s.err != nil {
		return nil, s.err
	}
	return &proto.PutManyResponse{}, nil
}

func TestIdentityPublisherPublishSuccess(t *testing.T) {
	client := &stubKVClient{}

	pub := newIdentityPublisher(client, "", 0, logger.NewTestLogger())
	ctx := context.Background()

	update := &models.DeviceUpdate{
		DeviceID:  "tenant-a:1.2.3.4",
		IP:        "1.2.3.4",
		Partition: "tenant-a",
		Source:    models.DiscoverySourceArmis,
		Metadata: map[string]string{
			"armis_device_id": "armis-123",
		},
	}

	err := pub.Publish(ctx, []*models.DeviceUpdate{update})
	require.NoError(t, err)
	if assert.NotNil(t, client.received) {
		assert.Len(t, client.received.GetEntries(), 4)
	}

	expectedKeys := map[string]struct{}{
		identitymap.Key{Kind: identitymap.KindDeviceID, Value: update.DeviceID}.KeyPath(identitymap.DefaultNamespace):       {},
		identitymap.Key{Kind: identitymap.KindIP, Value: update.IP}.KeyPath(identitymap.DefaultNamespace):                   {},
		identitymap.Key{Kind: identitymap.KindPartitionIP, Value: "tenant-a:1.2.3.4"}.KeyPath(identitymap.DefaultNamespace): {},
		identitymap.Key{Kind: identitymap.KindArmisID, Value: "armis-123"}.KeyPath(identitymap.DefaultNamespace):            {},
	}

	for _, entry := range client.received.GetEntries() {
		delete(expectedKeys, entry.Key)
	}
	assert.Empty(t, expectedKeys, "missing expected keys")

	assert.Equal(t, int64(1), pub.metrics.publishBatches.Load())
	assert.Equal(t, int64(4), pub.metrics.publishedKeys.Load())
	assert.Equal(t, int64(0), pub.metrics.failures.Load())
}

func TestIdentityPublisherPublishFailure(t *testing.T) {
	client := &stubKVClient{err: errStubPublish}

	pub := newIdentityPublisher(client, "namespace", 30*time.Second, logger.NewTestLogger())
	ctx := context.Background()

	update := &models.DeviceUpdate{DeviceID: "tenant-b:5.6.7.8", IP: "5.6.7.8"}

	err := pub.Publish(ctx, []*models.DeviceUpdate{update})
	require.Error(t, err)
	assert.Equal(t, int64(0), pub.metrics.publishBatches.Load())
	assert.Equal(t, int64(0), pub.metrics.publishedKeys.Load())
	assert.Equal(t, int64(1), pub.metrics.failures.Load())
}

func TestShouldSkipIdentityPublish(t *testing.T) {
	assert.True(t, shouldSkipIdentityPublish(nil))
	assert.True(t, shouldSkipIdentityPublish(&models.DeviceUpdate{}))
	assert.True(t, shouldSkipIdentityPublish(&models.DeviceUpdate{DeviceID: "", Metadata: map[string]string{"_deleted": "true"}}))
	assert.False(t, shouldSkipIdentityPublish(&models.DeviceUpdate{DeviceID: "tenant:1.1.1.1"}))
}
