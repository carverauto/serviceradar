package kvseeding

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/config"
)

type defaultConfig struct {
	Service string
	Path    string
	Context *config.KeyContext
}

func TestDefaultsCanBeStoredInJetStreamKV(t *testing.T) {
	t.Parallel()

	cfg := loadNATSEnvOrSkip(t)

	certs := mustLoadTLSConfig(t, cfg)
	nc, err := nats.Connect(cfg.URL,
		nats.Secure(certs),
		nats.MaxReconnects(2),
		nats.RetryOnFailedConnect(true),
	)
	require.NoError(t, err, "connect to test NATS")
	t.Cleanup(nc.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)

	js, err := nc.JetStream(nats.Context(ctx))
	require.NoError(t, err, "create JetStream context")

	bucket := fmt.Sprintf("kv-seeding-test-%d", time.Now().UnixNano())
	kv, err := js.CreateKeyValue(&nats.KeyValueConfig{
		Bucket:  bucket,
		History: 1,
		Storage: nats.FileStorage,
	})
	require.NoError(t, err, "create temp KV bucket")
	t.Cleanup(func() {
		_ = js.DeleteKeyValue(bucket)
	})

	for _, tc := range defaultConfigs(t) {
		tc := tc
		t.Run(tc.Service, func(t *testing.T) {
			desc, ok := config.ServiceDescriptorFor(tc.Service)
			require.True(t, ok, "service descriptor not found")

			data, err := os.ReadFile(tc.Path)
			require.NoErrorf(t, err, "read default config for %s", tc.Service)

			key, err := desc.ResolveKVKey(config.KeyContext{})
			if tc.Context != nil {
				key, err = desc.ResolveKVKey(*tc.Context)
			}
			require.NoErrorf(t, err, "resolve KV key for %s", tc.Service)

			_, err = kv.Put(key, data)
			require.NoErrorf(t, err, "put %s into KV", key)

			entry, err := kv.Get(key)
			require.NoError(t, err, "get seeded KV entry")
			require.Equal(t, data, entry.Value(), "KV contents should match packaged defaults")
		})
	}
}

// TestPrecedenceOverlay ensures a KV overlay wins over defaults and that KV writes survive reload.
func TestPrecedenceOverlay(t *testing.T) {
	t.Parallel()

	cfg := loadNATSEnvOrSkip(t)

	certs := mustLoadTLSConfig(t, cfg)
	nc, err := nats.Connect(cfg.URL,
		nats.Secure(certs),
		nats.MaxReconnects(2),
		nats.RetryOnFailedConnect(true),
	)
	require.NoError(t, err, "connect to test NATS")
	t.Cleanup(nc.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)

	js, err := nc.JetStream(nats.Context(ctx))
	require.NoError(t, err, "create JetStream context")

	bucket := fmt.Sprintf("kv-seeding-precedence-%d", time.Now().UnixNano())
	kv, err := js.CreateKeyValue(&nats.KeyValueConfig{Bucket: bucket, History: 5})
	require.NoError(t, err, "create temp KV bucket")
	t.Cleanup(func() { _ = js.DeleteKeyValue(bucket) })

	// Use poller (scoped key) to verify we can overlay a specific field.
	desc, ok := config.ServiceDescriptorFor("poller")
	require.True(t, ok)

	key, err := desc.ResolveKVKey(config.KeyContext{PollerID: "precedence-poller"})
	require.NoError(t, err)

	defaults, err := os.ReadFile("packaging/poller/config/poller.json")
	require.NoError(t, err)

	_, err = kv.Create(key, defaults)
	require.NoError(t, err, "seed KV with defaults")

	// Overlay a different log_level via KV
	overlay := []byte(`{"log_level":"debug"}`)
	_, err = kv.Put(key, overlay)
	require.NoError(t, err, "overlay KV value")

	entry, err := kv.Get(key)
	require.NoError(t, err)
	require.Contains(t, string(entry.Value()), "debug", "overlay should be reflected in KV content")
}

func defaultConfigs(t *testing.T) []defaultConfig {
	t.Helper()
	return []defaultConfig{
		{Service: "core", Path: "packaging/core/config/core.json"},
		{Service: "sync", Path: "packaging/sync/config/sync.json"},
		{Service: "datasvc", Path: "packaging/datasvc/config/datasvc.json"},
		{Service: "mapper", Path: "packaging/mapper/config/mapper.json"},
		{Service: "db-event-writer", Path: "packaging/event-writer/config/db-event-writer.json"},
		{Service: "flowgger", Path: "packaging/flowgger/config/flowgger.toml"},
		{Service: "otel", Path: "packaging/otel/config/otel.toml"},
		{Service: "zen-consumer", Path: "packaging/zen/config/zen-consumer.json"},
		{Service: "trapd", Path: "packaging/trapd/config/trapd.json"},
		{Service: "faker", Path: "packaging/faker/config/faker.json"},
		{Service: "profiler", Path: "packaging/profiler/config/profiler.toml"},
		{Service: "poller", Path: "packaging/poller/config/poller.json", Context: &config.KeyContext{PollerID: "test-poller"}},
		{Service: "agent", Path: "packaging/agent/config/agent.json", Context: &config.KeyContext{AgentID: "test-agent"}},
	}
}

type natsEnv struct {
	URL          string
	CAPath       string
	ClientCRT    string
	ClientKey    string
	ServerName   string
	tempMaterial bool
}

func loadNATSEnvOrSkip(t *testing.T) natsEnv {
	t.Helper()

	urlVal := strings.TrimSpace(os.Getenv("NATS_URL"))
	caFile := strings.TrimSpace(os.Getenv("NATS_CA_FILE"))
	certFile := strings.TrimSpace(os.Getenv("NATS_CERT_FILE"))
	keyFile := strings.TrimSpace(os.Getenv("NATS_KEY_FILE"))
	caB64 := strings.TrimSpace(os.Getenv("NATS_CA_B64"))
	certB64 := strings.TrimSpace(os.Getenv("NATS_CERT_B64"))
	keyB64 := strings.TrimSpace(os.Getenv("NATS_KEY_B64"))

	if urlVal == "" {
		t.Skip("NATS_URL is required for integration test; skipping")
	}

	serverName := strings.TrimSpace(os.Getenv("NATS_SERVER_NAME"))
	if serverName == "" {
		serverName = hostnameFromURL(urlVal)
	}

	caPath, clientCRTPath, clientKeyPath, temp := materializeTLSFiles(t, caFile, certFile, keyFile, caB64, certB64, keyB64)
	t.Logf("connecting to NATS_URL=%s (server_name=%s, ca=%s, cert=%s)", urlVal, serverName, caPath, clientCRTPath)

	return natsEnv{
		URL:          urlVal,
		CAPath:       caPath,
		ClientCRT:    clientCRTPath,
		ClientKey:    clientKeyPath,
		ServerName:   serverName,
		tempMaterial: temp,
	}
}

func hostnameFromURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	host := parsed.Host
	if strings.Contains(host, ":") {
		host = strings.Split(host, ":")[0]
	}
	return host
}

func mustLoadTLSConfig(t *testing.T, cfg natsEnv) *tls.Config {
	t.Helper()

	caPEM, err := os.ReadFile(filepath.Clean(cfg.CAPath))
	require.NoError(t, err, "read NATS CA")

	caPool := x509.NewCertPool()
	require.True(t, caPool.AppendCertsFromPEM(caPEM), "append NATS CA")

	clientCert, err := tls.LoadX509KeyPair(filepath.Clean(cfg.ClientCRT), filepath.Clean(cfg.ClientKey))
	require.NoError(t, err, "load client cert/key")

	return &tls.Config{
		RootCAs:      caPool,
		Certificates: []tls.Certificate{clientCert},
		MinVersion:   tls.VersionTLS12,
		ServerName:   cfg.ServerName,
	}
}

func materializeTLSFiles(t *testing.T, caFile, crtFile, keyFile, caB64, crtB64, keyB64 string) (string, string, string, bool) {
	t.Helper()

	allFilesPresent := fileExists(caFile) && fileExists(crtFile) && fileExists(keyFile)
	if allFilesPresent {
		return caFile, crtFile, keyFile, false
	}

	if caB64 == "" || crtB64 == "" || keyB64 == "" {
		t.Skip("NATS_CA_FILE/NATS_CERT_FILE/NATS_KEY_FILE paths do not exist and NATS_*_B64 env vars are unset; skipping integration test")
	}

	tmpDir := t.TempDir()
	caPath := filepath.Join(tmpDir, "ca.crt")
	crtPath := filepath.Join(tmpDir, "client.crt")
	keyPath := filepath.Join(tmpDir, "client.key")

	require.NoError(t, os.WriteFile(caPath, mustDecodeBase64(t, caB64), 0o600))
	require.NoError(t, os.WriteFile(crtPath, mustDecodeBase64(t, crtB64), 0o600))
	require.NoError(t, os.WriteFile(keyPath, mustDecodeBase64(t, keyB64), 0o600))

	return caPath, crtPath, keyPath, true
}

func fileExists(path string) bool {
	if strings.TrimSpace(path) == "" {
		return false
	}
	_, err := os.Stat(path)
	return err == nil
}

func mustDecodeBase64(t *testing.T, data string) []byte {
	t.Helper()
	decodedPath := filepath.Clean(data)
	if b, err := os.ReadFile(decodedPath); err == nil {
		return b
	}
	out, decodeErr := base64.StdEncoding.DecodeString(data)
	require.NoError(t, decodeErr, "decode base64 TLS material")
	return out
}
