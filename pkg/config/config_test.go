package config

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// fakeKVStore implements kv.KVStore for unit tests.
type fakeKVStore struct {
	values map[string][]byte
}

func (f *fakeKVStore) Get(_ context.Context, key string) ([]byte, bool, error) {
	if f.values == nil {
		return nil, false, nil
	}

	val, ok := f.values[key]
	return val, ok, nil
}

func (f *fakeKVStore) Put(_ context.Context, _ string, _ []byte, _ time.Duration) error {
	return nil
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

func TestOverlayFromKVStripsSecurityBlocks(t *testing.T) {
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

	if base.Security.Mode != securityModeSpiffe {
		t.Fatalf("expected security.mode to remain %q, got %q", securityModeSpiffe, base.Security.Mode)
	}

	if base.Security.TLS.CertFile != "/etc/serviceradar/certs/core.pem" {
		t.Fatalf("expected security TLS cert_file to remain unchanged, got %q", base.Security.TLS.CertFile)
	}

	if base.CoreSecurity.Mode != securityModeSpiffe {
		t.Fatalf("expected core_security.mode to remain %q, got %q", securityModeSpiffe, base.CoreSecurity.Mode)
	}

	if base.ServiceName != "kv-overridden" {
		t.Fatalf("expected non-security field to be overridden, got %q", base.ServiceName)
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
	defer os.Remove(tmpFile.Name())

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

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate rsa key: %v", err)
	}

	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal private key: %v", err)
	}

	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
}
