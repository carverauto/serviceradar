package config

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"os"
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
)

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

func generateTestPrivateKey(t *testing.T) string {
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
