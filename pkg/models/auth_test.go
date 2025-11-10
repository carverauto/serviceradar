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

func TestAuthConfigUnmarshalJSONRejectsDurationNumber(t *testing.T) {
	var cfg AuthConfig
	payload := `{"jwt_expiration": 5000000000}`

	err := json.Unmarshal([]byte(payload), &cfg)
	if err == nil {
		t.Fatalf("expected error when using numeric jwt_expiration")
	}
	if !strings.Contains(err.Error(), "duration string") {
		t.Fatalf("expected duration string error, got %v", err)
	}
}
