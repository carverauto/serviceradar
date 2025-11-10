package models

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestAuthConfigMarshalJSONFormatsDuration(t *testing.T) {
	cfg := &AuthConfig{
		JWTExpiration: 2 * time.Hour,
	}

	data, err := json.Marshal(cfg)
	if err != nil {
		t.Fatalf("marshal auth config: %v", err)
	}

	if want := `"jwt_expiration":"2h0m0s"`; !strings.Contains(string(data), want) {
		t.Fatalf("expected JSON to contain %s, got %s", want, string(data))
	}
}

func TestAuthConfigUnmarshalJSONAcceptsDurationString(t *testing.T) {
	var cfg AuthConfig
	payload := `{"jwt_expiration":"90s"}`

	if err := json.Unmarshal([]byte(payload), &cfg); err != nil {
		t.Fatalf("unmarshal auth config: %v", err)
	}

	if cfg.JWTExpiration != 90*time.Second {
		t.Fatalf("expected 90s duration, got %v", cfg.JWTExpiration)
	}
}

func TestAuthConfigUnmarshalJSONAcceptsDurationNumber(t *testing.T) {
	var cfg AuthConfig
	payload := `{"jwt_expiration": 5000000000}`

	if err := json.Unmarshal([]byte(payload), &cfg); err != nil {
		t.Fatalf("unmarshal auth config number: %v", err)
	}

	if cfg.JWTExpiration != 5*time.Second {
		t.Fatalf("expected 5s duration, got %v", cfg.JWTExpiration)
	}
}
