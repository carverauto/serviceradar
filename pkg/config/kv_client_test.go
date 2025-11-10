package config

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
)

const testPrivateKey = `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC+M8i0K2VJN8Vo
1RbmWbhj1u1uO7YMniiHrrYZg53kfMhfarxW8fADXOLc86GnwW7Jz/OH4YYPZ5cx
0nEl+UzmvGoK4Itsqo8j1S6/xXGsTISavQAz1jDMv7tPIS7MWLsMW8GfPpcnwT+z
FDfKy40xRbW9XAnbIj3Hguk8WObR88YkAImxuPwM6JPn9Smo5YpEKWu8hL7UL2yU
MR7qEVPzP2NIT00D7h3lTPtolmVof8gVQ2QX/8YIuDUbVqsX7T1+JkHXeWZgQymw
QMSWJcmZw5C7G9NoJ2VPStEXpUVYJ/JgQ08AzJ1eFeY4zUp4u8Fvqt++lbP04x36
eYkgEY3PAgMBAAECggEBAIjLb1ie82h5ibdQAS23vvam3HUpv2CyUAFmFihaJ6nv
FCQeQHkwnDcWEyTLxopYH6N+8ZCAY71bPV30FdRXO2aWjS8wP6l1GOuCjAxGk+KU
uW6VfEBnJltlQw3QGwxoxWYDZ0611+dIbRZwQKweq/98v2FQ7db5dO9BhH6htSs4
3exlLRJxZcnZRuD+s09Qeot0hVEgHsAHR7Mvpxv3/HCc0DSE0aaZvgt6u9fByF9H
jec19CwQe2be4ALunJRxybGHVvHTmeY+ioQNPMaP7rHjKQpH0kX7Y0ygksjO++SI
gApShvCCf+1o88QkZJWAiTzi6ZYeYJiu9S8Fxy8cTJECgYEA6iKdu0ivhkGlJ5jv
MZ1xvaCDmNUH9vNcVnUt3hJi2wIY/95vFJ/bcjxaL6iy4v90W2GZLcMxzAKrG9uY
SYWY1P5N9C1vmVdnN/39jwZ8Y4MVJtX3U9W7ijz7OQzZ1ZsC2VK+LS2NR6dSsmDo
iFue1fgdrNfkY9gW8UvlQ4vYwdsCgYEAy+YEAp8tcY8Y36ITG8/6gMV5y4MbhXgf
T0vjIDcAA9rOQdR8KeuwHzBa+wiy38dyBkgRS4yftQaaSDsCXWqGFcxNFuca/tH4
UQFvux7NVSlirhPG6oP0nU5XvuOrXc/BVmrP91iWPA7iUeW9cFWLzGImDJwpp4n/
mw6pnW1gcj0CgYBddHhuOQmHBPCvXnbsQKDi1H2WxgCHjgHJ7MOTGeGkU6sZxaUh
t6vS8NjCkgsxVYJoijTmA/lYc9iHqEVGi3K0NgoEudNdYs9GHlMsS7jCVco5VXBp
ZunFXy1+xp6etUc8qzBcEWH9oJ5BGQ6Q8mfS5mBxrQgdPUGja2x1NrpX4QKBgGtu
94CoTOZ8IAP3FCPQIdHNo0ydvb3mM0u8N0rwgFEhAYus/8IfQ1nxw5kROawrL2sC
VEre3yUPyYuoHav+1H45zAIYBhI+pAp9jP75hpo9WBQh/nQNGSZGikVEJZRQCKzF
H1mCs7khtuIVOVmCF8F4Pvj8C1XboO7qa9LaeTuNAoGAfH1Q3DXP3o8LtB2CKscn
JmB6quKJJtDZvRWh52kPlUfx0vgSpz80pmbn1t2aKPjE7bYlOiGC9+lifZnLh0kQ
3HjyGluweWv1v6dGQ/tfc9FjQqYg6poo0MwpzRk5kPn+LClKvlb3hrrZd0tBZfhT
WdnH0VBR566N5/1gNPKjRS0=
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
			JWTPrivateKeyPEM: testPrivateKey,
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
