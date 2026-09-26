package datasvc

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"sync"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

const (
	envKVMaxBytes     = "SERVICERADAR_JS_KV_SERVICERADAR_DATASVC_MAX_BYTES"
	envKVReplicas     = "SERVICERADAR_JS_KV_SERVICERADAR_DATASVC_REPLICAS"
	envObjectMaxBytes = "SERVICERADAR_JS_OBJ_SERVICERADAR_OBJECTS_MAX_BYTES"
	envObjectReplicas = "SERVICERADAR_JS_OBJ_SERVICERADAR_OBJECTS_REPLICAS"

	kib = 1024
	mib = 1024 * kib
)

func sizingTestConfig() *Config {
	sec := func() *models.SecurityConfig {
		return &models.SecurityConfig{
			Mode: models.SecurityMode("mtls"),
			TLS: models.TLSConfig{
				CertFile: "cert.pem",
				KeyFile:  "key.pem",
				CAFile:   "ca.pem",
			},
		}
	}

	return &Config{
		ListenAddr:    "127.0.0.1:0",
		NATSURL:       "nats://127.0.0.1:4222",
		NATSCredsFile: "/etc/serviceradar/creds/platform.creds",
		Security:      sec(),
		NATSSecurity:  sec(),
	}
}

// clearSizingEnv blanks every size variable so the host environment cannot leak
// into a test; an empty value counts as unset.
func clearSizingEnv(t *testing.T) {
	t.Helper()

	for _, name := range []string{envKVMaxBytes, envKVReplicas, envObjectMaxBytes, envObjectReplicas} {
		t.Setenv(name, "")
	}
}

func TestConfigValidateJetStreamSizingPrecedence(t *testing.T) {
	type sizing struct {
		bucketMaxBytes      int64
		objectStoreBytes    int64
		bucketReplicas      int
		objectStoreReplicas int
	}

	tests := []struct {
		name string
		json sizing
		env  map[string]string
		want sizing
	}{
		{
			name: "compiled defaults when neither JSON nor environment sets a size",
			want: sizing{
				bucketMaxBytes:      0,
				objectStoreBytes:    defaultObjectStoreBytes,
				bucketReplicas:      1,
				objectStoreReplicas: 1,
			},
		},
		{
			name: "JSON overrides the compiled defaults",
			json: sizing{bucketMaxBytes: 3 * mib, objectStoreBytes: 5 * mib, bucketReplicas: 3},
			want: sizing{bucketMaxBytes: 3 * mib, objectStoreBytes: 5 * mib, bucketReplicas: 3, objectStoreReplicas: 3},
		},
		{
			name: "environment overrides JSON",
			json: sizing{bucketMaxBytes: 3 * mib, objectStoreBytes: 5 * mib, bucketReplicas: 3},
			env: map[string]string{
				envKVMaxBytes:     "1048576",
				envObjectMaxBytes: "2097152",
				envKVReplicas:     "1",
				envObjectReplicas: "2",
			},
			want: sizing{bucketMaxBytes: 1 * mib, objectStoreBytes: 2 * mib, bucketReplicas: 1, objectStoreReplicas: 2},
		},
		{
			name: "environment overrides the compiled defaults",
			env: map[string]string{
				envKVMaxBytes:     "1048576",
				envObjectMaxBytes: "2097152",
				envObjectReplicas: "3",
			},
			want: sizing{bucketMaxBytes: 1 * mib, objectStoreBytes: 2 * mib, bucketReplicas: 1, objectStoreReplicas: 3},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearSizingEnv(t)
			for name, value := range tt.env {
				t.Setenv(name, value)
			}

			cfg := sizingTestConfig()
			cfg.BucketMaxBytes = tt.json.bucketMaxBytes
			cfg.ObjectStoreBytes = tt.json.objectStoreBytes
			cfg.JetStreamReplicas = tt.json.bucketReplicas

			require.NoError(t, cfg.Validate())
			// Validate runs at bootstrap and again in NewServer; the result must not drift.
			require.NoError(t, cfg.Validate())

			got := sizing{
				bucketMaxBytes:      cfg.BucketMaxBytes,
				objectStoreBytes:    cfg.ObjectStoreBytes,
				bucketReplicas:      cfg.BucketReplicas,
				objectStoreReplicas: cfg.ObjectStoreReplicas,
			}
			require.Equal(t, tt.want, got)
		})
	}
}

func TestConfigValidateRejectsInvalidJetStreamEnv(t *testing.T) {
	tests := []struct {
		variable string
		value    string
	}{
		{envKVMaxBytes, "abc"},
		{envKVMaxBytes, "0"},
		{envKVMaxBytes, "-1073741824"},
		{envKVMaxBytes, "1.5"},
		{envObjectMaxBytes, "4G"},
		{envObjectMaxBytes, "0"},
		{envKVReplicas, "zero"},
		{envKVReplicas, "0"},
		{envObjectReplicas, "-1"},
		{envObjectReplicas, "6"},
	}

	for _, tt := range tests {
		t.Run(fmt.Sprintf("%s=%s", tt.variable, tt.value), func(t *testing.T) {
			clearSizingEnv(t)
			t.Setenv(tt.variable, tt.value)

			err := sizingTestConfig().Validate()
			require.ErrorIs(t, err, errJetStreamEnvInvalid)
			require.ErrorContains(t, err, tt.variable)
		})
	}
}

// syncBuffer is a log destination that is safe to read while NATS client
// goroutines may still be logging.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()

	return b.buf.String()
}

func captureLog(t *testing.T) *syncBuffer {
	t.Helper()

	out := &syncBuffer{}
	prev := log.Writer()
	log.SetOutput(out)
	t.Cleanup(func() { log.SetOutput(prev) })

	return out
}

func streamInfo(ctx context.Context, t *testing.T, js jetstream.JetStream, name string) *jetstream.StreamInfo {
	t.Helper()

	stream, err := js.Stream(ctx, name)
	require.NoError(t, err)

	info, err := stream.Info(ctx)
	require.NoError(t, err)

	return info
}

// TestStateBucketReconcileMaxBytes covers the discard-new rule for the datasvc
// KV bucket and object store: a configured cap is applied when the stored data
// fits and held (logged, unchanged) when it does not, so the bucket keeps
// accepting writes.
func TestStateBucketReconcileMaxBytes(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping embedded JetStream test in short mode")
	}

	const unlimited = -1

	tests := []struct {
		name       string
		objects    bool  // object store when true, KV bucket otherwise
		initialCap int64 // 0 creates the bucket without max_bytes
		payload    int
		configured int64
		wantCap    int64
		wantHeld   bool
	}{
		{name: "kv shrinks when the data fits", initialCap: 256 * kib, payload: 4 * kib, configured: 64 * kib, wantCap: 64 * kib},
		{name: "kv holds its cap when stored exceeds configured", initialCap: 256 * kib, payload: 48 * kib, configured: 16 * kib, wantCap: 256 * kib, wantHeld: true},
		{name: "unlimited kv over the cap stays unlimited", payload: 48 * kib, configured: 16 * kib, wantCap: unlimited, wantHeld: true},
		{name: "unlimited kv gains the cap when the data fits", payload: 4 * kib, configured: 64 * kib, wantCap: 64 * kib},
		{name: "object store shrinks when the data fits", objects: true, initialCap: 256 * kib, payload: 4 * kib, configured: 64 * kib, wantCap: 64 * kib},
		{name: "object store holds its cap when stored exceeds configured", objects: true, initialCap: 256 * kib, payload: 48 * kib, configured: 16 * kib, wantCap: 256 * kib, wantHeld: true},
		{name: "unlimited object store over the cap stays unlimited", objects: true, payload: 48 * kib, configured: 16 * kib, wantCap: unlimited, wantHeld: true},
		{name: "unlimited object store gains the cap when the data fits", objects: true, payload: 4 * kib, configured: 64 * kib, wantCap: 64 * kib},
	}

	srv := runJetStreamServer(t, &server.Options{Host: "127.0.0.1", Port: -1, JetStream: true})
	t.Cleanup(srv.Shutdown)

	nc, err := nats.Connect(srv.ClientURL())
	require.NoError(t, err)
	t.Cleanup(nc.Close)

	js, err := jetstream.New(nc)
	require.NoError(t, err)

	for i, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()

			bucket := fmt.Sprintf("state-bucket-%d", i)
			creator := &NATSStore{
				bucket:              bucket,
				bucketHistory:       1,
				bucketReplicas:      1,
				objectStoreReplicas: 1,
				bucketMaxBytes:      tt.initialCap,
				objectStoreBytes:    tt.initialCap,
			}

			// Chunks of 4 KiB so the KV entries stay well under the server's max payload.
			chunk := bytes.Repeat([]byte("x"), 4*kib)

			var streamName string
			var write func(key string, data []byte) error
			var read func(key string) ([]byte, error)

			if tt.objects {
				streamName = objectStoreStreamName(bucket)
				obj, createErr := js.CreateObjectStore(ctx, creator.objectStoreConfig(bucket))
				require.NoError(t, createErr)

				write = func(key string, data []byte) error { _, putErr := obj.PutBytes(ctx, key, data); return putErr }
				read = func(key string) ([]byte, error) { return obj.GetBytes(ctx, key) }
			} else {
				streamName = kvStreamName(bucket)
				kv, createErr := js.CreateKeyValue(ctx, creator.keyValueConfig())
				require.NoError(t, createErr)

				write = func(key string, data []byte) error { _, putErr := kv.Put(ctx, key, data); return putErr }
				read = func(key string) ([]byte, error) {
					entry, getErr := kv.Get(ctx, key)
					if getErr != nil {
						return nil, getErr
					}
					return entry.Value(), nil
				}
			}

			for n := 0; n < tt.payload/len(chunk); n++ {
				require.NoError(t, write(fmt.Sprintf("seed-%d", n), chunk))
			}

			before := streamInfo(ctx, t, js, streamName)
			if tt.wantHeld {
				require.Greater(t, before.State.Bytes, uint64(tt.configured), "fixture must store more than the configured cap")
			} else {
				require.LessOrEqual(t, before.State.Bytes, uint64(tt.configured), "fixture must fit the configured cap")
			}

			logs := captureLog(t)
			store := &NATSStore{
				bucket:              bucket,
				bucketReplicas:      1,
				objectStoreReplicas: 1,
				bucketMaxBytes:      tt.configured,
				objectStoreBytes:    tt.configured,
			}
			if tt.objects {
				require.NoError(t, store.reconcileObjectStoreStreamLocked(ctx, js, bucket))
			} else {
				require.NoError(t, store.reconcileKVStreamLocked(ctx, js))
			}

			after := streamInfo(ctx, t, js, streamName)
			require.Equal(t, tt.wantCap, after.Config.MaxBytes)
			require.NotEqual(t, int64(after.State.Bytes), after.Config.MaxBytes, "max_bytes must never be set to the stored size")
			require.Equal(t, before.State.Msgs, after.State.Msgs, "reconcile must not remove stored data")

			if tt.wantHeld {
				out := logs.String()
				require.Contains(t, out, fmt.Sprintf("configured max_bytes=%d", tt.configured))
				require.Contains(t, out, fmt.Sprintf("%d bytes stored", before.State.Bytes))
				require.Contains(t, out, fmt.Sprintf("keeping max_bytes=%d", before.Config.MaxBytes))
			}

			// The bucket still accepts writes and still serves what it held.
			require.NoError(t, write("after-reconcile", chunk))
			got, err := read("seed-0")
			require.NoError(t, err)
			require.Equal(t, chunk, got)
		})
	}
}

// TestNewNATSStoreCreatesAbsentBucketsWithEnvSizes drives the startup path:
// Validate resolves the environment over JSON, and the buckets that do not
// exist yet are created with the resolved caps and replicas.
func TestNewNATSStoreCreatesAbsentBucketsWithEnvSizes(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping embedded JetStream test in short mode")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	srv := runJetStreamServer(t, &server.Options{Host: "127.0.0.1", Port: -1, JetStream: true})
	t.Cleanup(srv.Shutdown)

	clearSizingEnv(t)
	t.Setenv(envKVMaxBytes, "98304")
	t.Setenv(envObjectMaxBytes, "163840")
	// A single embedded server cannot place R3; the JSON asks for 3 and the
	// environment's 1 has to win for bucket creation to succeed at all.
	t.Setenv(envKVReplicas, "1")
	t.Setenv(envObjectReplicas, "1")

	cfg := sizingTestConfig()
	cfg.BucketMaxBytes = 1 * mib
	cfg.ObjectStoreBytes = 2 * mib
	cfg.JetStreamReplicas = 3
	require.NoError(t, cfg.Validate())

	// Talk to the embedded server without the TLS material Validate required.
	cfg.NATSURL = srv.ClientURL()
	cfg.NATSSecurity = nil
	cfg.NATSCredsFile = ""

	store, err := NewNATSStore(ctx, cfg)
	require.NoError(t, err)
	t.Cleanup(func() { _ = store.Close() })

	nc, err := nats.Connect(srv.ClientURL())
	require.NoError(t, err)
	t.Cleanup(nc.Close)

	js, err := jetstream.New(nc)
	require.NoError(t, err)

	kvInfo := streamInfo(ctx, t, js, "KV_serviceradar-datasvc")
	require.EqualValues(t, 98304, kvInfo.Config.MaxBytes)
	require.Equal(t, 1, kvInfo.Config.Replicas)

	objInfo := streamInfo(ctx, t, js, "OBJ_serviceradar-objects")
	require.EqualValues(t, 163840, objInfo.Config.MaxBytes)
	require.Equal(t, 1, objInfo.Config.Replicas)
	require.Equal(t, jetstream.DiscardNew, objInfo.Config.Discard)
}
