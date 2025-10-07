package registry

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

type fakeIdentityKVClient struct {
	mu             sync.Mutex
	entries        map[string]*fakeKVEntry
	failUpdateOnce map[string]int
}

type fakeKVEntry struct {
	value    []byte
	revision uint64
}

func newFakeIdentityKVClient() *fakeIdentityKVClient {
	return &fakeIdentityKVClient{
		entries:        make(map[string]*fakeKVEntry),
		failUpdateOnce: make(map[string]int),
	}
}

func (f *fakeIdentityKVClient) Get(_ context.Context, in *proto.GetRequest, _ ...grpc.CallOption) (*proto.GetResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	entry, ok := f.entries[in.Key]
	if !ok {
		return &proto.GetResponse{Found: false}, nil
	}

	valueCopy := append([]byte(nil), entry.value...)
	return &proto.GetResponse{Value: valueCopy, Found: true, Revision: entry.revision}, nil
}

func (f *fakeIdentityKVClient) PutIfAbsent(_ context.Context, in *proto.PutRequest, _ ...grpc.CallOption) (*proto.PutResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	if _, exists := f.entries[in.Key]; exists {
		return nil, status.Error(codes.AlreadyExists, "exists")
	}

	f.entries[in.Key] = &fakeKVEntry{value: append([]byte(nil), in.Value...), revision: 1}
	return &proto.PutResponse{}, nil
}

func (f *fakeIdentityKVClient) Update(_ context.Context, in *proto.UpdateRequest, _ ...grpc.CallOption) (*proto.UpdateResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	if remaining, ok := f.failUpdateOnce[in.Key]; ok && remaining > 0 {
		f.failUpdateOnce[in.Key] = remaining - 1
		return nil, status.Error(codes.Aborted, "conflict")
	}

	entry, ok := f.entries[in.Key]
	if !ok {
		return nil, status.Error(codes.NotFound, "missing")
	}

	if in.Revision != entry.revision {
		return nil, status.Error(codes.Aborted, "revision mismatch")
	}

	entry.revision++
	entry.value = append(entry.value[:0], in.Value...)
	return &proto.UpdateResponse{Revision: entry.revision}, nil
}

func TestIdentityPublisherPublishesNewEntries(t *testing.T) {
	t.Parallel()

	kvClient := newFakeIdentityKVClient()
	pub := newIdentityPublisher(kvClient, identitymap.DefaultNamespace, 0, logger.NewTestLogger())

	update := &models.DeviceUpdate{
		DeviceID:  "device-1",
		IP:        "10.0.0.10",
		Partition: "tenant-a",
		Metadata: map[string]string{
			"armis_device_id": "armis-1",
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	require.NoError(t, pub.Publish(ctx, []*models.DeviceUpdate{update}))

	expectedKeys := identitymap.BuildKeys(update)
	require.Len(t, kvClient.entries, len(expectedKeys))
	require.Equal(t, int64(len(expectedKeys)), pub.metrics.publishedKeys.Load())

	for _, key := range expectedKeys {
		entry, ok := kvClient.entries[key.KeyPath(identitymap.DefaultNamespace)]
		require.Truef(t, ok, "missing key %s", key)

		record, err := identitymap.UnmarshalRecord(entry.value)
		require.NoError(t, err)
		require.Equal(t, update.DeviceID, record.CanonicalDeviceID)
		require.Equal(t, identitymap.HashMetadata(update.Metadata), record.MetadataHash)
	}
}

func TestIdentityPublisherSkipsUnchangedRecords(t *testing.T) {
	t.Parallel()

	kvClient := newFakeIdentityKVClient()
	pub := newIdentityPublisher(kvClient, identitymap.DefaultNamespace, 0, logger.NewTestLogger())

	update := &models.DeviceUpdate{
		DeviceID: "device-static",
		Metadata: map[string]string{"armis_device_id": "armis-static"},
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	require.NoError(t, pub.Publish(ctx, []*models.DeviceUpdate{update}))

	initialKeys := len(kvClient.entries)
	initialWrites := pub.metrics.publishedKeys.Load()

	require.NoError(t, pub.Publish(ctx, []*models.DeviceUpdate{update}))

	for _, entry := range kvClient.entries {
		require.Equal(t, uint64(1), entry.revision)
	}
	require.Len(t, kvClient.entries, initialKeys)
	require.Equal(t, initialWrites, pub.metrics.publishedKeys.Load())
}

func TestIdentityPublisherRetriesOnCASConflict(t *testing.T) {
	t.Parallel()

	kvClient := newFakeIdentityKVClient()
	pub := newIdentityPublisher(kvClient, identitymap.DefaultNamespace, 0, logger.NewTestLogger())

	initial := &models.DeviceUpdate{DeviceID: "device-conflict"}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	require.NoError(t, pub.Publish(ctx, []*models.DeviceUpdate{initial}))

	conflictKey := identitymap.Key{Kind: identitymap.KindDeviceID, Value: initial.DeviceID}.KeyPath(identitymap.DefaultNamespace)
	kvClient.failUpdateOnce[conflictKey] = 1

	updated := &models.DeviceUpdate{
		DeviceID: initial.DeviceID,
		Metadata: map[string]string{"armis_device_id": "armis-new"},
	}

	require.NoError(t, pub.Publish(ctx, []*models.DeviceUpdate{updated}))

	entry := kvClient.entries[conflictKey]
	require.Equal(t, uint64(2), entry.revision)
	record, err := identitymap.UnmarshalRecord(entry.value)
	require.NoError(t, err)
	require.Equal(t, identitymap.HashMetadata(updated.Metadata), record.MetadataHash)
}
