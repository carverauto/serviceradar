package config

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	configkv "github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/models"
)

// fakeKVStore implements kv.KVStore for unit tests.
type fakeKVStore struct {
	values       map[string][]byte
	lastPutKey   string
	lastPutValue []byte
}

func (f *fakeKVStore) Get(_ context.Context, key string) ([]byte, bool, error) {
	if f.values == nil {
		return nil, false, nil
	}

	val, ok := f.values[key]
	return val, ok, nil
}

func (f *fakeKVStore) Put(_ context.Context, key string, value []byte, _ time.Duration) error {
	if f.values == nil {
		f.values = make(map[string][]byte)
	}
	if value != nil {
		f.values[key] = append([]byte(nil), value...)
		f.lastPutValue = append([]byte(nil), value...)
	} else {
		delete(f.values, key)
		f.lastPutValue = nil
	}
	f.lastPutKey = key

	return nil
}

func (f *fakeKVStore) Create(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	if f.values == nil {
		f.values = make(map[string][]byte)
	}
	if _, exists := f.values[key]; exists {
		return configkv.ErrKeyExists
	}
	return f.Put(ctx, key, value, ttl)
}

func (f *fakeKVStore) Delete(_ context.Context, _ string) error {
	return nil
}

func (f *fakeKVStore) Watch(_ context.Context, _ string) (<-chan []byte, error) {
	return nil, nil
}

func (f *fakeKVStore) Close() error {
	return nil
}

type testTLSConfig struct {
	CertFile string `json:"cert_file"`
}

type testSecurityConfig struct {
	Mode string         `json:"mode"`
	TLS  testTLSConfig  `json:"tls"`
	Role string         `json:"role"`
	Meta map[string]any `json:"meta,omitempty"`
}

type overlayTarget struct {
	Security     testSecurityConfig `json:"security"`
	CoreSecurity testSecurityConfig `json:"core_security"`
	ServiceName  string             `json:"service_name"`
}

const (
	securityModeSpiffe = "spiffe"
	securityModeMTLS   = "mtls"
)

func TestOverlayFromKVAllowsSecurityOverrides(t *testing.T) {
	base := overlayTarget{
		Security: testSecurityConfig{
			Mode: securityModeSpiffe,
			TLS: testTLSConfig{
				CertFile: "/etc/serviceradar/certs/core.pem",
			},
			Role: "core",
		},
		CoreSecurity: testSecurityConfig{
			Mode: securityModeSpiffe,
			TLS: testTLSConfig{
				CertFile: "/etc/serviceradar/certs/poller.pem",
			},
			Role: "poller",
		},
		ServiceName: "serviceradar-core",
	}

	overlayPayload := map[string]any{
		"security": map[string]any{
			"mode": securityModeMTLS,
			"tls": map[string]any{
				"cert_file": "/tmp/kv/core.pem",
			},
		},
		"core_security": map[string]any{
			"mode": securityModeMTLS,
		},
		"service_name": "kv-overridden",
	}

	payload, err := json.Marshal(overlayPayload)
	if err != nil {
		t.Fatalf("failed to marshal overlay payload: %v", err)
	}

	store := &fakeKVStore{
		values: map[string][]byte{
			"config/core.json": payload,
		},
	}

	cfg := NewConfig(nil)
	cfg.SetKVStore(store)

	err = cfg.OverlayFromKV(context.Background(), "/etc/serviceradar/core.json", &base)
	if err != nil {
		t.Fatalf("OverlayFromKV returned error: %v", err)
	}

	if base.Security.Mode != securityModeMTLS {
		t.Fatalf("expected security.mode to update to %q, got %q", securityModeMTLS, base.Security.Mode)
	}

	if base.Security.TLS.CertFile != "/tmp/kv/core.pem" {
		t.Fatalf("expected security TLS cert_file to be overridden, got %q", base.Security.TLS.CertFile)
	}

	if base.CoreSecurity.Mode != securityModeMTLS {
		t.Fatalf("expected core_security.mode to update to %q, got %q", securityModeMTLS, base.CoreSecurity.Mode)
	}

	if base.ServiceName != "kv-overridden" {
		t.Fatalf("expected service_name field to be overridden, got %q", base.ServiceName)
	}
}

func TestOverlayFromKVNormalizesSecurityPaths(t *testing.T) {
	base := struct {
		Security *models.SecurityConfig `json:"security"`
	}{
		Security: &models.SecurityConfig{
			Mode:    securityModeSpiffe,
			CertDir: "/etc/serviceradar/certs",
			TLS: models.TLSConfig{
				CertFile: "/etc/serviceradar/certs/base.pem",
				KeyFile:  "/etc/serviceradar/certs/base-key.pem",
				CAFile:   "/etc/serviceradar/certs/base-root.pem",
			},
		},
	}

	overlayPayload := map[string]any{
		"security": map[string]any{
			"tls": map[string]any{
				"cert_file":      "kv-core.pem",
				"key_file":       "kv-core-key.pem",
				"ca_file":        "kv-root.pem",
				"client_ca_file": "",
			},
		},
	}

	payload, err := json.Marshal(overlayPayload)
	if err != nil {
		t.Fatalf("failed to marshal overlay payload: %v", err)
	}

	store := &fakeKVStore{
		values: map[string][]byte{
			"config/core.json": payload,
		},
	}

	cfg := NewConfig(nil)
	cfg.SetKVStore(store)

	err = cfg.OverlayFromKV(context.Background(), "/etc/serviceradar/core.json", &base)
	if err != nil {
		t.Fatalf("OverlayFromKV returned error: %v", err)
	}

	expected := "/etc/serviceradar/certs/kv-core.pem"
	if base.Security.TLS.CertFile != expected {
		t.Fatalf("expected normalized cert_file %q, got %q", expected, base.Security.TLS.CertFile)
	}

	if base.Security.TLS.KeyFile != "/etc/serviceradar/certs/kv-core-key.pem" {
		t.Fatalf("expected normalized key_file, got %q", base.Security.TLS.KeyFile)
	}

	if base.Security.TLS.CAFile != kvRootCertPath {
		t.Fatalf("expected normalized ca_file, got %q", base.Security.TLS.CAFile)
	}

	if base.Security.TLS.ClientCAFile != base.Security.TLS.CAFile {
		t.Fatalf("expected client_ca_file to fall back to CA file; got %q (ca %q)", base.Security.TLS.ClientCAFile, base.Security.TLS.CAFile)
	}
}

type authWrapper struct {
	Auth *models.AuthConfig `json:"auth"`
	Name string             `json:"name"`
}

func TestLoadAndValidateWithSourceKVOverlaysFile(t *testing.T) {
	t.Setenv("CONFIG_SOURCE", "kv")

	tmpFile, err := os.CreateTemp("", "core-config-*.json")
	if err != nil {
		t.Fatalf("create temp file: %v", err)
	}
	t.Cleanup(func() {
		if closeErr := tmpFile.Close(); closeErr != nil {
			t.Fatalf("close temp file: %v", closeErr)
		}
		if removeErr := os.Remove(tmpFile.Name()); removeErr != nil {
			t.Fatalf("remove temp file: %v", removeErr)
		}
	})

	privateKey := generateTestPrivateKeyPEM(t)
	filePayload := authWrapper{
		Auth: &models.AuthConfig{
			JWTAlgorithm:     "RS256",
			JWTPrivateKeyPEM: privateKey,
			JWTKeyID:         "file-kid",
		},
		Name: "file-default",
	}
	writeJSON(t, tmpFile.Name(), filePayload)

	kvPayload := map[string]any{
		"auth": map[string]any{
			"jwt_algorithm": "RS256",
			"jwt_key_id":    "kv-kid",
		},
		"name": "kv-name",
	}
	kvBytes, err := json.Marshal(kvPayload)
	if err != nil {
		t.Fatalf("marshal kv payload: %v", err)
	}

	store := &fakeKVStore{
		values: map[string][]byte{
			"config/" + filepath.Base(tmpFile.Name()): kvBytes,
		},
	}

	cfg := NewConfig(nil)
	cfg.SetKVStore(store)

	var result authWrapper
	if err := cfg.LoadAndValidate(context.Background(), tmpFile.Name(), &result); err != nil {
		t.Fatalf("LoadAndValidate returned error: %v", err)
	}

	if result.Name != "kv-name" {
		t.Fatalf("expected name to be overridden by KV, got %q", result.Name)
	}

	if result.Auth == nil {
		t.Fatalf("auth block missing")
	}

	if result.Auth.JWTKeyID != "kv-kid" {
		t.Fatalf("expected jwt_key_id to be overridden, got %q", result.Auth.JWTKeyID)
	}

	if result.Auth.JWTPrivateKeyPEM != privateKey {
		t.Fatalf("expected JWTPrivateKeyPEM to remain from file defaults")
	}
}

func TestLoadAndValidateWithSourceKVFileMissingFallsBack(t *testing.T) {
	t.Setenv("CONFIG_SOURCE", "kv")

	kvPayload := authWrapper{
		Auth: &models.AuthConfig{
			JWTSecret:    "secret",
			JWTAlgorithm: "HS256",
		},
		Name: "kv-only",
	}
	kvBytes, err := json.Marshal(kvPayload)
	if err != nil {
		t.Fatalf("marshal kv payload: %v", err)
	}

	store := &fakeKVStore{
		values: map[string][]byte{
			"config/core.json": kvBytes,
		},
	}

	cfg := NewConfig(nil)
	cfg.SetKVStore(store)

	var result authWrapper
	if err := cfg.LoadAndValidate(context.Background(), "/etc/serviceradar/core.json", &result); err != nil {
		t.Fatalf("LoadAndValidate returned error: %v", err)
	}

	if result.Name != "kv-only" {
		t.Fatalf("expected KV payload to load when file missing, got %q", result.Name)
	}
}

func TestLoadAndValidateWithExplicitAgentKVKey(t *testing.T) {
	t.Setenv("CONFIG_SOURCE", "kv")

	store := &fakeKVStore{
		values: map[string][]byte{
			"agents/test-agent/checkers/foo.json": []byte(`{"name":"foo","type":"grpc","address":"localhost:1"}`),
		},
	}

	cfg := NewConfig(nil)
	cfg.SetKVStore(store)

	type checkerCfg struct {
		Name string `json:"name"`
		Type string `json:"type"`
	}

	var result checkerCfg
	if err := cfg.LoadAndValidate(context.Background(), "agents/test-agent/checkers/foo.json", &result); err != nil {
		t.Fatalf("LoadAndValidate returned error: %v", err)
	}

	if result.Name != "foo" || result.Type != "grpc" {
		t.Fatalf("expected KV payload to populate struct, got %+v", result)
	}
}

func TestOverlayFromKVNormalizesNumericDurations(t *testing.T) {
	type webhook struct {
		Cooldown string `json:"cooldown"`
	}

	type webhookCfg struct {
		Name     string    `json:"name"`
		Webhooks []webhook `json:"webhooks"`
	}

	base := webhookCfg{
		Name: "file-default",
		Webhooks: []webhook{
			{Cooldown: "5m0s"},
		},
	}

	store := &fakeKVStore{
		values: map[string][]byte{
			"config/core.json": []byte(`{"name":"kv-value","webhooks":[{"cooldown":900000000000}]}`),
		},
	}

	cfg := NewConfig(nil)
	cfg.SetKVStore(store)

	if err := cfg.OverlayFromKV(context.Background(), "/etc/serviceradar/core.json", &base); err != nil {
		t.Fatalf("OverlayFromKV returned error: %v", err)
	}

	if base.Name != "kv-value" {
		t.Fatalf("expected name to be overridden, got %q", base.Name)
	}

	if len(base.Webhooks) == 0 || base.Webhooks[0].Cooldown != "15m0s" {
		t.Fatalf("expected numeric cooldown to normalize to 15m0s, got %+v", base.Webhooks)
	}

	if store.lastPutKey != "config/core.json" {
		t.Fatalf("expected KV entry to be rewritten, got %q", store.lastPutKey)
	}

	if store.lastPutValue == nil || !bytes.Contains(store.lastPutValue, []byte("\"cooldown\":\"15m0s\"")) {
		t.Fatalf("expected rewritten KV value to contain normalized cooldown, got %s", store.lastPutValue)
	}
}

func writeJSON(t *testing.T, path string, value interface{}) {
	t.Helper()

	data, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal json: %v", err)
	}

	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatalf("write json: %v", err)
	}
}

func generateTestPrivateKeyPEM(t *testing.T) string {
	t.Helper()

	return testPrivateKey
}
