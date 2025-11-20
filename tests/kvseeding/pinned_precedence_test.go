package kvseeding

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/config"
)

// TestPinnedOverridesKV ensures a pinned file can override KV and default config.
func TestPinnedOverridesKV(t *testing.T) {
	t.Parallel()

	env := loadNATSEnvOrSkip(t)
	tlsCfg := mustLoadTLSConfig(t, env)

	nc, err := nats.Connect(env.URL,
		nats.Secure(tlsCfg),
		nats.MaxReconnects(2),
		nats.RetryOnFailedConnect(true),
	)
	require.NoError(t, err, "connect to NATS")
	t.Cleanup(nc.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)

	js, err := nc.JetStream(nats.Context(ctx))
	require.NoError(t, err, "create JetStream")

	bucket := fmt.Sprintf("kv-pinned-%d", time.Now().UnixNano())
	kv, err := js.CreateKeyValue(&nats.KeyValueConfig{Bucket: bucket, History: 5})
	require.NoError(t, err, "create KV bucket")
	t.Cleanup(func() { _ = js.DeleteKeyValue(bucket) })

	desc, ok := config.ServiceDescriptorFor("core")
	require.True(t, ok, "core descriptor present")

	key, err := desc.ResolveKVKey(config.KeyContext{})
	require.NoError(t, err)

	defaults, err := os.ReadFile("packaging/core/config/core.json")
	require.NoError(t, err)

	_, err = kv.Create(key, defaults)
	require.NoError(t, err, "seed defaults into KV")

	kvOverride := []byte(`{"log_level":"debug"}`)
	_, err = kv.Put(key, kvOverride)
	require.NoError(t, err, "overlay KV log_level")

	entry, err := kv.Get(key)
	require.NoError(t, err, "fetch KV overlay")

	var cfg map[string]interface{}
	require.NoError(t, json.Unmarshal(defaults, &cfg))
	require.NoError(t, config.MergeOverlayBytes(&cfg, entry.Value()))

	pinnedDir := t.TempDir()
	pinnedPath := filepath.Join(pinnedDir, "core+pinned.json")
	pinnedPayload := []byte(`{"log_level":"warn","http_listen_addr":"0.0.0.0:9999"}`)
	require.NoError(t, os.WriteFile(pinnedPath, pinnedPayload, 0o600))

	loader := config.NewConfig(nil)
	require.NoError(t, loader.OverlayPinned(ctx, pinnedPath, &cfg))

	require.Equal(t, "warn", strings.ToLower(cfg["log_level"].(string)), "pinned should override KV and defaults")
	require.Equal(t, "0.0.0.0:9999", cfg["http_listen_addr"].(string), "pinned should inject new fields")
}
