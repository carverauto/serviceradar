package config

import (
	"context"
	"encoding/json"
	"testing"
	"time"
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

func TestOverlayFromKVStripsSecurityBlocks(t *testing.T) {
	base := overlayTarget{
		Security: testSecurityConfig{
			Mode: "spiffe",
			TLS: testTLSConfig{
				CertFile: "/etc/serviceradar/certs/core.pem",
			},
			Role: "core",
		},
		CoreSecurity: testSecurityConfig{
			Mode: "spiffe",
			TLS: testTLSConfig{
				CertFile: "/etc/serviceradar/certs/poller.pem",
			},
			Role: "poller",
		},
		ServiceName: "serviceradar-core",
	}

	overlayPayload := map[string]any{
		"security": map[string]any{
			"mode": "mtls",
			"tls": map[string]any{
				"cert_file": "/tmp/kv/core.pem",
			},
		},
		"core_security": map[string]any{
			"mode": "mtls",
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

	if base.Security.Mode != "spiffe" {
		t.Fatalf("expected security.mode to remain 'spiffe', got %q", base.Security.Mode)
	}

	if base.Security.TLS.CertFile != "/etc/serviceradar/certs/core.pem" {
		t.Fatalf("expected security TLS cert_file to remain unchanged, got %q", base.Security.TLS.CertFile)
	}

	if base.CoreSecurity.Mode != "spiffe" {
		t.Fatalf("expected core_security.mode to remain 'spiffe', got %q", base.CoreSecurity.Mode)
	}

	if base.ServiceName != "kv-overridden" {
		t.Fatalf("expected non-security field to be overridden, got %q", base.ServiceName)
	}
}
