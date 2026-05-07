package agent

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestArmisAccessTokenUsesFormEncodedSecretKey(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != armisAccessTokenPath {
			t.Fatalf("path = %q, want %q", r.URL.Path, armisAccessTokenPath)
		}
		if r.Method != http.MethodPost {
			t.Fatalf("method = %q, want POST", r.Method)
		}
		if got := r.Header.Get("Content-Type"); got != "application/x-www-form-urlencoded" {
			t.Fatalf("content-type = %q", got)
		}
		if got := r.Header.Get("Accept"); got != "application/json" {
			t.Fatalf("accept = %q", got)
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read body: %v", err)
		}
		if got := string(body); got != "secret_key=secret-value" {
			t.Fatalf("body = %q", got)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"access_token":"token-123"},"success":true}`))
	}))
	defer server.Close()

	client := &armisClient{endpoint: server.URL}
	token, err := client.accessToken(context.Background(), map[string]string{
		"api_key":    "ignored-key",
		"api_secret": "secret-value",
	})
	if err != nil {
		t.Fatalf("accessToken returned error: %v", err)
	}
	if token != "token-123" {
		t.Fatalf("token = %q", token)
	}
}

func TestArmisAccessTokenIncludesErrorBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "Invalid secret key", http.StatusBadRequest)
	}))
	defer server.Close()

	client := &armisClient{endpoint: server.URL}
	_, err := client.accessToken(context.Background(), map[string]string{"secret_key": "bad"})
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "400 Bad Request") || !strings.Contains(err.Error(), "Invalid secret key") {
		t.Fatalf("error = %q", err)
	}
}

func TestArmisSecretKeyPreference(t *testing.T) {
	got := armisSecretKey(map[string]string{
		"secret_key": "  preferred ",
		"api_secret": "secondary",
		"api_key":    "last",
	})
	if got != "preferred" {
		t.Fatalf("secret key = %q", got)
	}
}
