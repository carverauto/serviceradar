package datasvc

import (
	"context"
	"testing"
	"time"

	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// fakeKeyWatcher implements jetstream.KeyWatcher for tests.
type fakeKeyWatcher struct {
	updates chan jetstream.KeyValueEntry
	stopped bool
}

func (f *fakeKeyWatcher) Updates() <-chan jetstream.KeyValueEntry { return f.updates }

func (f *fakeKeyWatcher) Stop() error {
	if !f.stopped {
		f.stopped = true
		close(f.updates)
	}

	return nil
}

// fakeEntry implements jetstream.KeyValueEntry for tests.
type fakeEntry struct{ val []byte }

func (fakeEntry) Bucket() string                  { return "" }
func (fakeEntry) Key() string                     { return "" }
func (e fakeEntry) Value() []byte                 { return e.val }
func (fakeEntry) Revision() uint64                { return 0 }
func (fakeEntry) Created() time.Time              { return time.Time{} }
func (fakeEntry) Delta() uint64                   { return 0 }
func (fakeEntry) Operation() jetstream.KeyValueOp { return jetstream.KeyValuePut }

// fakeKV implements jetstream.KeyValue using embedding and overrides Watch.
type fakeKV struct {
	jetstream.KeyValue
	watcher jetstream.KeyWatcher
	err     error
}

func (f *fakeKV) Watch(_ context.Context, _ string, _ ...jetstream.WatchOpt) (jetstream.KeyWatcher, error) {
	return f.watcher, f.err
}

func (f *fakeKV) WatchAll(ctx context.Context, opts ...jetstream.WatchOpt) (jetstream.KeyWatcher, error) {
	return f.Watch(ctx, "", opts...)
}

func (f *fakeKV) WatchFiltered(ctx context.Context, _ []string, opts ...jetstream.WatchOpt) (jetstream.KeyWatcher, error) {
	return f.Watch(ctx, "", opts...)
}

func TestNatsStoreWatch_ForwardUpdates(t *testing.T) {
	updates := make(chan jetstream.KeyValueEntry, 1)
	watcher := &fakeKeyWatcher{updates: updates}

	kv := &fakeKV{watcher: watcher}
	ns := &NATSStore{
		ctx:            context.Background(),
		kvByDomain:     map[string]jetstream.KeyValue{"": kv},
		jsByDomain:     map[string]jetstream.JetStream{"": nil}, // fake js to avoid creation
		defaultDomain:  "",
		bucketHistory:  1,
		bucketTTL:      0,
		bucketMaxBytes: 0,
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	ch, err := ns.Watch(ctx, "test-key")
	require.NoError(t, err)

	updates <- fakeEntry{val: []byte("value")}

	select {
	case v := <-ch:
		assert.Equal(t, []byte("value"), v)
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for value")
	}

	cancel()

	_, ok := <-ch
	assert.False(t, ok)
	assert.True(t, watcher.stopped)
}

func TestNatsStoreWatch_ContextCancel(t *testing.T) {
	updates := make(chan jetstream.KeyValueEntry)
	watcher := &fakeKeyWatcher{updates: updates}

	kv := &fakeKV{watcher: watcher}
	ns := &NATSStore{
		ctx:            context.Background(),
		kvByDomain:     map[string]jetstream.KeyValue{"": kv},
		jsByDomain:     map[string]jetstream.JetStream{"": nil}, // fake js to avoid creation
		defaultDomain:  "",
		bucketHistory:  1,
		bucketTTL:      0,
		bucketMaxBytes: 0,
	}

	ctx, cancel := context.WithCancel(context.Background())
	ch, err := ns.Watch(ctx, "test-key")
	require.NoError(t, err)

	cancel()

	// The main behavior we care about: the channel should be closed when context is canceled
	select {
	case _, ok := <-ch:
		assert.False(t, ok, "channel should be closed when context is canceled")
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for channel to close")
	}
}
