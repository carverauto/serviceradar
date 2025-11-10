package config

import (
	"context"
	"encoding/json"
	"os"
	"testing"

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

func TestSanitizeBootstrapSourceAddsJWTPublicKey(t *testing.T) {
	tmpFile, err := os.CreateTemp("", "core-config-*.json")
	if err != nil {
		t.Fatalf("create temp file: %v", err)
	}
	defer os.Remove(tmpFile.Name())

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
	_ = tmpFile.Close()

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
	defer os.Remove(tmpFile.Name())

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
	if cfg.Security.TLS.CAFile != "/etc/serviceradar/certs/kv-root.pem" {
		t.Fatalf("expected normalized ca_file, got %q", cfg.Security.TLS.CAFile)
	}
	if cfg.Security.TLS.ClientCAFile != "/etc/serviceradar/certs/kv-root.pem" {
		t.Fatalf("expected client_ca_file to fall back to normalized ca_file, got %q", cfg.Security.TLS.ClientCAFile)
	}
}

func generateTestPrivateKey(t *testing.T) string {
	t.Helper()

	return testPrivateKey
}
