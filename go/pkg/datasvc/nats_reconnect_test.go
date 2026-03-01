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

func runJetStreamServer(t *testing.T, opts *server.Options) *server.Server {
	t.Helper()

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
