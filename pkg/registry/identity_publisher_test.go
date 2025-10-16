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
	omitUpdateResp map[string]bool
	updateCalls    map[string]int
	revisionMiss   map[string]int
	deleted        map[string]int
}

type fakeKVEntry struct {
	value    []byte
	revision uint64
}

func newFakeIdentityKVClient() *fakeIdentityKVClient {
	return &fakeIdentityKVClient{
		entries:        make(map[string]*fakeKVEntry),
		failUpdateOnce: make(map[string]int),
		omitUpdateResp: make(map[string]bool),
		updateCalls:    make(map[string]int),
		revisionMiss:   make(map[string]int),
		deleted:        make(map[string]int),
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

	key := in.Key
	f.updateCalls[key]++

	if remaining, ok := f.failUpdateOnce[in.Key]; ok && remaining > 0 {
		f.failUpdateOnce[in.Key] = remaining - 1
		return nil, status.Error(codes.Aborted, "conflict")
	}

	entry, ok := f.entries[in.Key]
	if !ok {
		return nil, status.Error(codes.NotFound, "missing")
	}

	if in.Revision != entry.revision {
		f.revisionMiss[key]++
		return nil, status.Error(codes.Aborted, "revision mismatch")
	}

	entry.revision++
	entry.value = append(entry.value[:0], in.Value...)

	if f.omitUpdateResp[key] {
		return nil, nil
	}

	return &proto.UpdateResponse{Revision: entry.revision}, nil
}

func (f *fakeIdentityKVClient) Delete(_ context.Context, in *proto.DeleteRequest, _ ...grpc.CallOption) (*proto.DeleteResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	if _, ok := f.entries[in.Key]; !ok {
		return nil, status.Error(codes.NotFound, "missing")
	}

	delete(f.entries, in.Key)
	f.deleted[in.Key]++
	return &proto.DeleteResponse{}, nil
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
		require.Equal(t, identitymap.HashIdentityMetadata(update), record.MetadataHash)
		require.Equal(t, "armis-1", record.Attributes["armis_device_id"])
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
	require.Equal(t, identitymap.HashIdentityMetadata(updated), record.MetadataHash)
}

func TestIdentityPublisherUpdatesWhenAttributesChange(t *testing.T) {
	t.Parallel()

	kvClient := newFakeIdentityKVClient()
	pub := newIdentityPublisher(kvClient, identitymap.DefaultNamespace, 0, logger.NewTestLogger())

	metadata := map[string]string{"armis_device_id": "armis-attr"}
	initialRecord := &identitymap.Record{
		CanonicalDeviceID: "device-attr",
		MetadataHash: identitymap.HashIdentityMetadata(&models.DeviceUpdate{
			DeviceID: "device-attr",
			Metadata: metadata,
		}),
		Attributes: map[string]string{},
	}
	payload, err := identitymap.MarshalRecord(initialRecord)
	require.NoError(t, err)

	key := identitymap.Key{Kind: identitymap.KindDeviceID, Value: "device-attr"}.KeyPath(identitymap.DefaultNamespace)
	kvClient.entries[key] = &fakeKVEntry{value: payload, revision: 1}

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	update := &models.DeviceUpdate{DeviceID: "device-attr", Metadata: metadata}
	require.NoError(t, pub.Publish(ctx, []*models.DeviceUpdate{update}))

	entry := kvClient.entries[key]
	require.Equal(t, uint64(2), entry.revision)
	record, err := identitymap.UnmarshalRecord(entry.value)
	require.NoError(t, err)
	require.Equal(t, "armis-attr", record.Attributes["armis_device_id"])
}

func TestIdentityPublisherDeletesStaleIdentityKeys(t *testing.T) {
	t.Parallel()

	kvClient := newFakeIdentityKVClient()
	pub := newIdentityPublisher(kvClient, identitymap.DefaultNamespace, 0, logger.NewTestLogger())

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	initial := &models.DeviceUpdate{
		DeviceID:  "device-stale",
		IP:        "10.0.0.10",
		Partition: "tenant-a",
	}

	require.NoError(t, pub.Publish(ctx, []*models.DeviceUpdate{initial}))

	initialKeys := identitymap.BuildKeys(initial)
	ipKey := identitymap.Key{Kind: identitymap.KindIP, Value: initial.IP}.KeyPath(identitymap.DefaultNamespace)
	partIPKey := identitymap.Key{Kind: identitymap.KindPartitionIP, Value: "tenant-a:10.0.0.10"}.KeyPath(identitymap.DefaultNamespace)
	require.Contains(t, kvClient.entries, ipKey)
	require.Contains(t, kvClient.entries, partIPKey)
	require.Equal(t, len(initialKeys), len(kvClient.entries))

	updated := &models.DeviceUpdate{
		DeviceID:  initial.DeviceID,
		IP:        "10.0.0.11",
		Partition: initial.Partition,
	}

	require.NoError(t, pub.Publish(ctx, []*models.DeviceUpdate{updated}))

	_, ipStillPresent := kvClient.entries[ipKey]
	_, partIPStillPresent := kvClient.entries[partIPKey]
	require.False(t, ipStillPresent, "expected old IP key to be deleted")
	require.False(t, partIPStillPresent, "expected old partition IP key to be deleted")

	newKeys := identitymap.BuildKeys(updated)
	require.Equal(t, len(newKeys), len(kvClient.entries))
	require.Equal(t, int64(2), pub.metrics.deletedKeys.Load())
}
