package datasvc

import (
	"context"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/require"
)

func TestNATSStoreReconnectsAfterConnectionClosure(t *testing.T) {
	t.Parallel()

	if testing.Short() {
		t.Skip("skipping reconnect test in short mode")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	opts := &server.Options{
		Host:      "127.0.0.1",
		Port:      -1,
		JetStream: true,
	}

	srv := runJetStreamServer(t, opts)
	t.Cleanup(func() {
		if srv != nil {
			srv.Shutdown()
		}
	})

	url := srv.ClientURL()

	addr, ok := srv.Addr().(*net.TCPAddr)
	require.True(t, ok, "expected TCP address from embedded NATS server")

	optsCopy := *opts
	optsCopy.Port = addr.Port

	var attempts atomic.Int32

	store := &NATSStore{
		ctx:            ctx,
		natsURL:        url,
		bucket:         "test-kv",
		defaultDomain:  "",
		bucketHistory:  1,
		bucketTTL:      0,
		bucketMaxBytes: 0,
		jsByDomain:     make(map[string]jetstream.JetStream),
		kvByDomain:     make(map[string]jetstream.KeyValue),
	}

	store.connectFn = func() (*nats.Conn, error) {
		attempts.Add(1)
		return nats.Connect(url,
			nats.MaxReconnects(1),
			nats.RetryOnFailedConnect(true),
			nats.ReconnectWait(50*time.Millisecond),
		)
	}

	kv, err := store.getKVForDomain(ctx, "")
	require.NoError(t, err, "initial kv acquisition failed")

	_, err = kv.Put(ctx, "foo", []byte("bar"))
	require.NoError(t, err, "initial kv put failed")

	srv.Shutdown()

	require.Eventually(t, func() bool {
		store.mu.Lock()
		defer store.mu.Unlock()
		if store.nc == nil {
			return true
		}
		return store.nc.Status() == nats.CLOSED
	}, 5*time.Second, 50*time.Millisecond, "connection did not transition to CLOSED")

	// Restart JetStream on the same port.
	srv = runJetStreamServer(t, &optsCopy)
	url = srv.ClientURL()
	store.mu.Lock()
	store.natsURL = url
	store.mu.Unlock()

	require.Eventually(t, func() bool {
		kv, err = store.getKVForDomain(ctx, "")
		if err != nil {
			return false
		}
		_, err = kv.Put(ctx, "foo", []byte("baz"))
		return err == nil
	}, 10*time.Second, 100*time.Millisecond, "store did not recover after reconnect")

	require.GreaterOrEqual(t, attempts.Load(), int32(2), "expected at least two connection attempts")

	require.NoError(t, store.Close())
}

func TestObjectStoreConfigIncludesMaxBytes(t *testing.T) {
	t.Parallel()

	store := &NATSStore{objectStoreBytes: 4096, jetstreamReplicas: 3}

	cfg := store.objectStoreConfig("bounded-objects")
	require.Equal(t, "bounded-objects", cfg.Bucket)
	require.EqualValues(t, 4096, cfg.MaxBytes)
	require.Equal(t, 3, cfg.Replicas)
}

func TestObjectStoreReconciliationSetsDiscardNew(t *testing.T) {
	t.Parallel()

	if testing.Short() {
		t.Skip("skipping embedded JetStream test in short mode")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	srv := runJetStreamServer(t, &server.Options{
		Host:      "127.0.0.1",
		Port:      -1,
		JetStream: true,
	})
	defer srv.Shutdown()

	nc, err := nats.Connect(srv.ClientURL())
	require.NoError(t, err)
	defer nc.Close()

	js, err := jetstream.New(nc)
	require.NoError(t, err)

	store := &NATSStore{objectStoreBytes: 4096, jetstreamReplicas: 1}

	_, err = js.CreateObjectStore(ctx, store.objectStoreConfig("bounded-objects"))
	require.NoError(t, err)

	stream, err := js.Stream(ctx, "OBJ_bounded-objects")
	require.NoError(t, err)

	info, err := stream.Info(ctx)
	require.NoError(t, err)
	require.Equal(t, jetstream.DiscardNew, info.Config.Discard)

	info.Config.Discard = jetstream.DiscardOld
	_, err = js.UpdateStream(ctx, info.Config)
	require.NoError(t, err)

	stream, err = js.Stream(ctx, "OBJ_bounded-objects")
	require.NoError(t, err)

	info, err = stream.Info(ctx)
	require.NoError(t, err)
	require.Equal(t, jetstream.DiscardOld, info.Config.Discard)

	require.NoError(t, store.reconcileObjectStoreStreamLocked(ctx, js, "bounded-objects"))

	stream, err = js.Stream(ctx, "OBJ_bounded-objects")
	require.NoError(t, err)

	info, err = stream.Info(ctx)
	require.NoError(t, err)
	require.Equal(t, jetstream.DiscardNew, info.Config.Discard)
	require.EqualValues(t, 4096, info.Config.MaxBytes)
}

func TestKeyValueConfigIncludesReplicas(t *testing.T) {
	t.Parallel()

	store := &NATSStore{
		bucket:            "test-kv",
		bucketHistory:     1,
		jetstreamReplicas: 3,
		bucketMaxBytes:    2048,
	}

	cfg := store.keyValueConfig()
	require.Equal(t, "test-kv", cfg.Bucket)
	require.EqualValues(t, 1, cfg.History)
	require.Equal(t, 3, cfg.Replicas)
	require.EqualValues(t, 2048, cfg.MaxBytes)
}

func runJetStreamServer(t *testing.T, opts *server.Options) *server.Server {
	t.Helper()

	if opts.StoreDir == "" {
		opts.StoreDir = t.TempDir()
	}

	srv, err := server.NewServer(opts)
	require.NoError(t, err)

	go srv.Start()

	if !srv.ReadyForConnections(10 * time.Second) {
		srv.Shutdown()
		t.Fatalf("embedded NATS server not ready for connections")
	}

	require.Eventually(t, func() bool {
		return srv.JetStreamEnabled()
	}, 5*time.Second, 50*time.Millisecond, "embedded NATS server not ready for JetStream")

	return srv
}
