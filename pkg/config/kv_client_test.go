package config

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const testPrivateKey = `-----BEGIN PRIVATE KEY-----
MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAMAekMd4AjIonVVM
W8oH9fXIARBW94rgL92Zoz/6113HgWkhPWmc69KTIVkJDBa53SDZ5ah1bOpMJdOt
9ZPjSxEdjvcF9KPpTs7Sznz0PypGEGTPybdpzJ0rSAPr2hmiB+qvi9hLZ7TmLWMm
VA0Ptn9ySMoee8BGN2V9f4CRovFfAgMBAAECgYAIvcXz8ssiVx0u1kKy5nLwKV4L
Biu+wqhZGoSUdlMBJwEFmBYjzXwgfPtJHsxfdMjRsmMJOfL9eTfwuO0AHpkPJWow
KT2zDkQt2AsoDcso6/PIE/09XZJAB+EIbF6PLUtDZ6kL9Ft9a49684zc5Z0qUKE+
ZADfjRRV3HT9SRvEEQJBAMRPlj6TG5vdlnFXRPrkmVWD/qSH7PZg06Wj+WCUcNVr
YCJiXSPeqKVnD5jB9O5GXIZ/UdTgD9AZctdNLrBc3nkCQQD6iLjiC4znPVZaObsh
iHbIjrlZqniB5Wzn2X3CshJaJJz/OsekZGiHl35JEUdHipDUJh7/7MCdd0H5j9C2
a3iXAkABxG2n1o8zEgWes5htYc13lZ6fQJIDjc+Z+CXwlqWFZlgRNy17ey+tfYYI
bAaWdo+yrkbAUdwSlYgRJCK9d7iRAkBubsXQHfdGFqtxqfDqnxR84yygcZwc5dxT
dnMQ1x1vzqPFfUtzEy9gVU69NniM+G9OlF8lwF5HCsJyFwqQ3l6RAkEAr4SWX6P5
aNRRXZdIgnVnW8ydYrM/HqsjtnBwFwJxKm4ZBhng54g5ywVfwgbDsLkdrMH983LB
Stry7BwsPBarcA==
-----END PRIVATE KEY-----`

var (
	errKVNotReady         = errors.New("kv not ready")
	errDatasvcUnavailable = errors.New("datasvc unavailable")
)

func TestSanitizeBootstrapSourceAddsJWTPublicKey(t *testing.T) {
	tmpFile, err := os.CreateTemp("", "core-config-*.json")
	if err != nil {
		t.Fatalf("create temp file: %v", err)
	}
	t.Cleanup(func() {
		if err := os.Remove(tmpFile.Name()); err != nil {
			t.Fatalf("remove temp file: %v", err)
		}
	})

	cfgInput := models.CoreServiceConfig{
		Auth: &models.AuthConfig{
			JWTAlgorithm:     "RS256",
			JWTPrivateKeyPEM: generateTestPrivateKey(t),
			JWTKeyID:         "test-key",
		},
	}
	if auth := extractAuthConfig(&cfgInput); auth == nil {
		t.Fatalf("failed to extract auth config")
	}
	t.Logf("alg=%s priv_len=%d", cfgInput.Auth.JWTAlgorithm, len(cfgInput.Auth.JWTPrivateKeyPEM))
	if pub, err := derivePublicKeyPEM(cfgInput.Auth.JWTPrivateKeyPEM); err != nil || pub == "" {
		t.Fatalf("failed to derive public key: %v", err)
	}
	ensureJWTPublicKey(&cfgInput)
	if cfgInput.Auth.JWTPublicKeyPEM == "" {
		t.Fatalf("ensureJWTPublicKey did not populate field")
	}
	payload, err := json.Marshal(&cfgInput)
	if err != nil {
		t.Fatalf("marshal input: %v", err)
	}

	if _, err := tmpFile.Write(payload); err != nil {
		t.Fatalf("write temp file: %v", err)
	}
	if err := tmpFile.Close(); err != nil {
		t.Fatalf("close temp file: %v", err)
	}

	var cfg models.CoreServiceConfig
	data, err := sanitizeBootstrapSource(tmpFile.Name(), &cfg)
	if err != nil {
		t.Fatalf("sanitize source: %v", err)
	}
	t.Logf("sanitized: %s", data)

	var sanitized map[string]interface{}
	if err := json.Unmarshal(data, &sanitized); err != nil {
		t.Fatalf("unmarshal sanitized: %v", err)
	}

	auth, ok := sanitized["auth"].(map[string]interface{})
	if !ok {
		t.Fatalf("auth block missing")
	}

	if _, ok := auth["jwt_private_key_pem"]; ok {
		t.Fatalf("private key should be filtered")
	}

	if pub, ok := auth["jwt_public_key_pem"].(string); !ok || pub == "" {
		t.Fatalf("expected jwt_public_key_pem to be populated")
	}
}

func TestSanitizeBootstrapSourceUsesFallbackPrivateKey(t *testing.T) {
	tmpFile, err := os.CreateTemp("", "core-config-masked-*.json")
	if err != nil {
		t.Fatalf("create temp file: %v", err)
	}
	t.Cleanup(func() {
		if err := os.Remove(tmpFile.Name()); err != nil {
			t.Fatalf("remove temp file: %v", err)
		}
	})
	if err := tmpFile.Close(); err != nil {
		t.Fatalf("close temp file: %v", err)
	}

	if err := os.WriteFile(tmpFile.Name(), []byte(`{"auth":{"jwt_algorithm":"RS256"}}`), 0600); err != nil {
		t.Fatalf("write masked config: %v", err)
	}

	cfgInput := models.CoreServiceConfig{
		Auth: &models.AuthConfig{
			JWTAlgorithm:     "RS256",
			JWTPrivateKeyPEM: generateTestPrivateKey(t),
			JWTKeyID:         "fallback-key",
		},
	}

	data, err := sanitizeBootstrapSource(tmpFile.Name(), &cfgInput)
	if err != nil {
		t.Fatalf("sanitize source: %v", err)
	}

	var sanitized map[string]interface{}
	if err := json.Unmarshal(data, &sanitized); err != nil {
		t.Fatalf("unmarshal sanitized: %v", err)
	}

	auth, ok := sanitized["auth"].(map[string]interface{})
	if !ok {
		t.Fatalf("auth block missing")
	}

	if _, ok := auth["jwt_private_key_pem"]; ok {
		t.Fatalf("private key should be filtered")
	}

	if pub, ok := auth["jwt_public_key_pem"].(string); !ok || pub == "" {
		t.Fatalf("expected jwt_public_key_pem to be populated from fallback")
	}
}

func TestKVManagerOverlayConfigNormalizesSecurity(t *testing.T) {
	manager := &KVManager{
		client: &fakeKVStore{
			values: map[string][]byte{
				"config/service.json": []byte(`{
					"security": {
						"tls": {
							"cert_file": "kv.pem",
							"key_file": "kv-key.pem",
							"ca_file": "kv-root.pem",
							"client_ca_file": ""
						}
					}
				}`),
			},
		},
	}

	cfg := struct {
		Security *models.SecurityConfig `json:"security"`
	}{
		Security: &models.SecurityConfig{
			CertDir: "/etc/serviceradar/certs",
			TLS: models.TLSConfig{
				CertFile: "/etc/serviceradar/certs/base.pem",
				KeyFile:  "/etc/serviceradar/certs/base-key.pem",
				CAFile:   "/etc/serviceradar/certs/base-root.pem",
			},
		},
	}

	if err := manager.OverlayConfig(context.Background(), "config/service.json", &cfg); err != nil {
		t.Fatalf("OverlayConfig returned error: %v", err)
	}

	if cfg.Security.TLS.CertFile != "/etc/serviceradar/certs/kv.pem" {
		t.Fatalf("expected normalized cert_file, got %q", cfg.Security.TLS.CertFile)
	}
	if cfg.Security.TLS.KeyFile != "/etc/serviceradar/certs/kv-key.pem" {
		t.Fatalf("expected normalized key_file, got %q", cfg.Security.TLS.KeyFile)
	}
	if cfg.Security.TLS.CAFile != kvRootCertPath {
		t.Fatalf("expected normalized ca_file, got %q", cfg.Security.TLS.CAFile)
	}
	if cfg.Security.TLS.ClientCAFile != kvRootCertPath {
		t.Fatalf("expected client_ca_file to fall back to normalized ca_file, got %q", cfg.Security.TLS.ClientCAFile)
	}
}

func TestKVManagerStartWatchReloadsOnAnyChange(t *testing.T) {
	initialKV := []byte(`{"listen_addr":":8080","logging":{"level":"info"}}`)
	store := newWatchKVStore(initialKV)
	manager := &KVManager{client: store}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cfg := &watcherTestConfig{
		ListenAddr: ":8080",
		Logging: &logger.Config{
			Level: "info",
		},
	}

	reloads := make(chan struct{}, 2)
	manager.StartWatch(ctx, "config/agent/test.json", cfg, logger.NewTestLogger(), func() {
		reloads <- struct{}{}
	})

	store.waitForWatch(t)

	store.emit([]byte(`{"listen_addr":":9090"}`))

	select {
	case <-reloads:
	case <-time.After(150 * time.Millisecond):
		t.Fatalf("timed out waiting for reload triggered by listen_addr change")
	}

	if cfg.ListenAddr != ":9090" {
		t.Fatalf("expected config to apply listen_addr change, got %q", cfg.ListenAddr)
	}

	store.emit([]byte(`{"listen_addr":":9090"}`))

	select {
	case <-reloads:
		t.Fatalf("unexpected reload when config payload did not change")
	case <-time.After(75 * time.Millisecond):
	}
}

type watcherTestConfig struct {
	ListenAddr string         `json:"listen_addr"`
	Logging    *logger.Config `json:"logging,omitempty" hot:"reload"`
}

type watchKVStore struct {
	mu        sync.Mutex
	value     []byte
	watchCh   chan []byte
	ready     chan struct{}
	readyOnce sync.Once
}

func newWatchKVStore(initial []byte) *watchKVStore {
	return &watchKVStore{
		value: append([]byte(nil), initial...),
		ready: make(chan struct{}),
	}
}

func (s *watchKVStore) Get(_ context.Context, _ string) ([]byte, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.value == nil {
		return nil, false, nil
	}
	return append([]byte(nil), s.value...), true, nil
}

func (s *watchKVStore) Put(_ context.Context, _ string, value []byte, _ time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if value == nil {
		s.value = nil
		return nil
	}
	s.value = append([]byte(nil), value...)
	return nil
}

func (s *watchKVStore) Create(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	return s.Put(ctx, key, value, ttl)
}

func (s *watchKVStore) Delete(_ context.Context, _ string) error {
	return nil
}

func (s *watchKVStore) Watch(ctx context.Context, _ string) (<-chan []byte, error) {
	s.mu.Lock()
	if s.watchCh == nil {
		s.watchCh = make(chan []byte, 1)
		s.readyOnce.Do(func() {
			close(s.ready)
		})
	}
	ch := s.watchCh
	s.mu.Unlock()

	go func() {
		<-ctx.Done()
		s.mu.Lock()
		if s.watchCh != nil {
			close(s.watchCh)
			s.watchCh = nil
		}
		s.mu.Unlock()
	}()

	return ch, nil
}

func (s *watchKVStore) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.watchCh != nil {
		close(s.watchCh)
		s.watchCh = nil
	}
	return nil
}

func (s *watchKVStore) emit(data []byte) {
	s.mu.Lock()
	if data != nil {
		s.value = append([]byte(nil), data...)
	}
	ch := s.watchCh
	s.mu.Unlock()
	if ch != nil {
		ch <- append([]byte(nil), data...)
	}
}

func (s *watchKVStore) waitForWatch(t *testing.T) {
	t.Helper()
	select {
	case <-s.ready:
	case <-time.After(time.Second):
		t.Fatalf("watch channel was not initialized")
	}
}

func TestKVManagerPutIfAbsent(t *testing.T) {
	manager := &KVManager{
		client: &fakeKVStore{
			values: map[string][]byte{},
		},
	}
	ctx := context.Background()

	created, err := manager.PutIfAbsent(ctx, "config/example.json", []byte(`{"foo":"bar"}`), 0)
	if err != nil {
		t.Fatalf("PutIfAbsent returned error: %v", err)
	}
	if !created {
		t.Fatalf("expected key to be created")
	}

	created, err = manager.PutIfAbsent(ctx, "config/example.json", []byte(`{"foo":"baz"}`), 0)
	if err != nil {
		t.Fatalf("PutIfAbsent returned error when key exists: %v", err)
	}
	if created {
		t.Fatalf("expected PutIfAbsent to report existing key")
	}
}

func TestShouldUseKVFromEnv(t *testing.T) {
	t.Setenv("CONFIG_SOURCE", "kv")
	t.Setenv("KV_ADDRESS", "serviceradar-datasvc:50057")
	t.Setenv("KV_SEC_MODE", "spiffe")
	t.Setenv("KV_TRUST_DOMAIN", "carverauto.dev")
	t.Setenv("KV_SERVER_SPIFFE_ID", "spiffe://carverauto.dev/ns/demo/sa/serviceradar-datasvc")

	if !ShouldUseKVFromEnv() {
		t.Fatalf("expected spiffe configuration to be detected")
	}

	t.Setenv("KV_SEC_MODE", "mtls")
	t.Setenv("KV_CERT_FILE", "/etc/serviceradar/certs/agent.pem")
	t.Setenv("KV_KEY_FILE", "/etc/serviceradar/certs/agent-key.pem")
	t.Setenv("KV_CA_FILE", "/etc/serviceradar/certs/root.pem")

	if !ShouldUseKVFromEnv() {
		t.Fatalf("expected mtls configuration to be detected")
	}

	t.Setenv("KV_SEC_MODE", "unknown")
	if ShouldUseKVFromEnv() {
		t.Fatalf("unexpected success for unsupported security mode")
	}
}

func TestNewKVManagerFromEnvWithRetryEventuallySucceeds(t *testing.T) {
	t.Setenv("CONFIG_SOURCE", "kv")
	t.Setenv("KV_ADDRESS", "serviceradar-datasvc:50057")
	t.Setenv("KV_SEC_MODE", "spiffe")
	t.Setenv("KV_TRUST_DOMAIN", "carverauto.dev")
	t.Setenv("KV_SERVER_SPIFFE_ID", "spiffe://carverauto.dev/ns/demo/sa/serviceradar-datasvc")
	t.Setenv("KV_CONNECT_TIMEOUT", "2s")
	t.Setenv("KV_CONNECT_RETRY_BASE", "10ms")
	t.Setenv("KV_CONNECT_RETRY_MAX", "20ms")

	failures := 2
	attempts := 0
	ctx := withKVClientFactory(context.Background(), func(context.Context, models.ServiceRole) (kv.KVStore, error) {
		attempts++
		if attempts <= failures {
			return nil, errKVNotReady
		}
		return &fakeKVStore{}, nil
	})

	manager, err := NewKVManagerFromEnvWithRetry(ctx, models.RoleAgent, nil)
	if err != nil {
		t.Fatalf("expected success after retries, got error: %v", err)
	}
	if manager == nil {
		t.Fatalf("expected manager after retries")
	}
	if attempts != failures+1 {
		t.Fatalf("expected %d attempts, got %d", failures+1, attempts)
	}
}

func TestNewKVManagerFromEnvWithRetryTimesOut(t *testing.T) {
	t.Setenv("CONFIG_SOURCE", "kv")
	t.Setenv("KV_ADDRESS", "serviceradar-datasvc:50057")
	t.Setenv("KV_SEC_MODE", "spiffe")
	t.Setenv("KV_TRUST_DOMAIN", "carverauto.dev")
	t.Setenv("KV_SERVER_SPIFFE_ID", "spiffe://carverauto.dev/ns/demo/sa/serviceradar-datasvc")
	t.Setenv("KV_CONNECT_TIMEOUT", "50ms")
	t.Setenv("KV_CONNECT_RETRY_BASE", "5ms")
	t.Setenv("KV_CONNECT_RETRY_MAX", "5ms")

	attempts := 0
	ctx := withKVClientFactory(context.Background(), func(context.Context, models.ServiceRole) (kv.KVStore, error) {
		attempts++
		return nil, errDatasvcUnavailable
	})

	_, err := NewKVManagerFromEnvWithRetry(ctx, models.RoleAgent, nil)
	if err == nil {
		t.Fatalf("expected timeout error")
	}
	if !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("expected timeout error, got %v", err)
	}
	if attempts < 2 {
		t.Fatalf("expected multiple attempts before timeout, got %d", attempts)
	}
}

func generateTestPrivateKey(t *testing.T) string {
	t.Helper()

	return testPrivateKey
}
