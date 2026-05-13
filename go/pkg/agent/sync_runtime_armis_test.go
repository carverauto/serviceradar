package agent

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

const testArmisDeviceQuery = "in:devices"

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

func TestArmisSearchUsesRawAccessToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != armisSearchPath {
			t.Fatalf("path = %q, want %q", r.URL.Path, armisSearchPath)
		}
		if r.Method != http.MethodGet {
			t.Fatalf("method = %q, want GET", r.Method)
		}
		if got := r.Header.Get("Authorization"); got != "token-123" {
			t.Fatalf("authorization = %q, want raw access token", got)
		}
		if got := r.Header.Get("Accept"); got != "application/json" {
			t.Fatalf("accept = %q", got)
		}
		if got := r.URL.Query().Get("aql"); got != testArmisDeviceQuery {
			t.Fatalf("aql = %q", got)
		}
		if got := r.URL.Query().Get("from"); got != "10" {
			t.Fatalf("from = %q", got)
		}
		if got := r.URL.Query().Get("length"); got != "25" {
			t.Fatalf("length = %q", got)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"count":0,"next":0,"prev":null,"results":[],"total":0},"success":true}`))
	}))
	defer server.Close()

	client := &armisClient{endpoint: server.URL}
	resp, err := client.search(context.Background(), "token-123", testArmisDeviceQuery, 10, 25)
	if err != nil {
		t.Fatalf("search returned error: %v", err)
	}
	if resp == nil || !resp.Success {
		t.Fatalf("search response = %#v", resp)
	}
}

func TestArmisSearchOmitsFromOnFirstPage(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := r.URL.Query()["from"]; ok {
			t.Fatalf("from query param should be omitted on first page, got %q", r.URL.RawQuery)
		}
		if got := r.URL.Query().Get("aql"); got != testArmisDeviceQuery {
			t.Fatalf("aql = %q", got)
		}
		if got := r.URL.Query().Get("length"); got != "100" {
			t.Fatalf("length = %q", got)
		}

		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"count":0,"next":0,"prev":null,"results":[],"total":0},"success":true}`))
	}))
	defer server.Close()

	client := &armisClient{endpoint: server.URL}
	resp, err := client.search(context.Background(), "token-123", testArmisDeviceQuery, 0, 100)
	if err != nil {
		t.Fatalf("search returned error: %v", err)
	}
	if resp == nil || !resp.Success {
		t.Fatalf("search response = %#v", resp)
	}
}

func TestArmisSearchErrorIncludesBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "bad aql", http.StatusBadRequest)
	}))
	defer server.Close()

	client := &armisClient{endpoint: server.URL}
	_, err := client.search(context.Background(), "token-123", testArmisDeviceQuery, 0, 100)
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "400 Bad Request") || !strings.Contains(err.Error(), "bad aql") {
		t.Fatalf("error = %q", err)
	}
}

func TestConfiguredArmisQueriesDropsBlankQueries(t *testing.T) {
	got := configuredArmisQueries([]models.QueryConfig{
		{Label: "blank"},
		{Label: "spaces", Query: "   "},
		{Label: "devices", Query: testArmisDeviceQuery},
	})

	if len(got) != 1 {
		t.Fatalf("query count = %d, want 1", len(got))
	}
	if got[0].Label != "devices" || got[0].Query != testArmisDeviceQuery {
		t.Fatalf("query = %#v", got[0])
	}
}

func TestScheduledSyncRunPrefersDiscoveryInterval(t *testing.T) {
	interval, kind, ok := scheduledSyncRun(models.SourceConfig{
		PollInterval:      models.Duration(5 * time.Minute),
		DiscoveryInterval: models.Duration(time.Hour),
	})

	if !ok {
		t.Fatal("expected schedule")
	}
	if interval != time.Hour {
		t.Fatalf("interval = %v, want 1h", interval)
	}
	if kind != "discovery" {
		t.Fatalf("kind = %q, want discovery", kind)
	}
}

func TestScheduledSyncRunFallsBackToPollInterval(t *testing.T) {
	interval, kind, ok := scheduledSyncRun(models.SourceConfig{
		PollInterval: models.Duration(5 * time.Minute),
	})

	if !ok {
		t.Fatal("expected schedule")
	}
	if interval != 5*time.Minute {
		t.Fatalf("interval = %v, want 5m", interval)
	}
	if kind != "poll" {
		t.Fatalf("kind = %q, want poll", kind)
	}
}

func TestClaimInitialSyncRunThrottlesRecentSameConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sync-runtime-runs.json")
	now := time.Date(2026, 5, 13, 3, 0, 0, 0, time.UTC)

	claimed, err := claimInitialSyncRun(path, "source-a:hash-a", time.Hour, now)
	if err != nil {
		t.Fatalf("first claim returned error: %v", err)
	}
	if !claimed {
		t.Fatal("first claim should run")
	}

	claimed, err = claimInitialSyncRun(path, "source-a:hash-a", time.Hour, now.Add(5*time.Minute))
	if err != nil {
		t.Fatalf("second claim returned error: %v", err)
	}
	if claimed {
		t.Fatal("second claim should be throttled")
	}

	claimed, err = claimInitialSyncRun(path, "source-a:hash-a", time.Hour, now.Add(time.Hour))
	if err != nil {
		t.Fatalf("third claim returned error: %v", err)
	}
	if !claimed {
		t.Fatal("claim after interval should run")
	}
}

func TestClaimInitialSyncRunAllowsChangedConfigHash(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sync-runtime-runs.json")
	now := time.Date(2026, 5, 13, 3, 0, 0, 0, time.UTC)

	claimed, err := claimInitialSyncRun(path, "source-a:hash-a", time.Hour, now)
	if err != nil {
		t.Fatalf("first claim returned error: %v", err)
	}
	if !claimed {
		t.Fatal("first claim should run")
	}

	claimed, err = claimInitialSyncRun(path, "source-a:hash-b", time.Hour, now.Add(5*time.Minute))
	if err != nil {
		t.Fatalf("changed hash claim returned error: %v", err)
	}
	if !claimed {
		t.Fatal("changed config hash should run immediately")
	}
}
