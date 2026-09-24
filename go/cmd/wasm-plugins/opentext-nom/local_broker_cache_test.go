//go:build !tinygo

package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar-sdk-go/v2/sdk"
)

func TestLocalOAuthBrokerReusesTokenUntilRejected(t *testing.T) {
	var (
		mu          sync.Mutex
		exchanges   int
		rejectToken string
	)
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch request.URL.Path {
		case "/oauth/token":
			exchanges++
			response.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprintf(response, `{"access_token":"token-%d","expires_in":1200}`, exchanges)
		case "/api/v1/commands":
			if request.Header.Get("Authorization") == "Bearer "+rejectToken {
				response.WriteHeader(http.StatusUnauthorized)
				return
			}
			_, _ = fmt.Fprint(response, `[]`)
		default:
			response.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	cfg := validTestConfig()
	cfg.TokenURL = server.URL + "/oauth/token"
	cfg.APIURL = server.URL + "/api/v1/commands"
	broker, err := newLocalOAuthBroker(cfg, map[string]string{"username": "u", "password": "p"}, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	broker.now = func() time.Time { return now }

	call := func() int {
		t.Helper()
		response, err := broker.Handle(t.Context(), sdk.HTTPRequest{Method: http.MethodPost, URL: cfg.APIURL})
		if err != nil {
			t.Fatalf("Handle() error = %v", err)
		}
		return response.Status
	}
	exchangeCount := func() int {
		mu.Lock()
		defer mu.Unlock()
		return exchanges
	}

	for range 3 {
		if status := call(); status != http.StatusOK {
			t.Fatalf("status = %d", status)
		}
	}
	if got := exchangeCount(); got != 1 {
		t.Fatalf("token exchanges after 3 requests = %d, want 1", got)
	}

	mu.Lock()
	rejectToken = "token-1"
	mu.Unlock()
	if status := call(); status != http.StatusUnauthorized {
		t.Fatalf("status = %d, want the upstream 401", status)
	}
	if status := call(); status != http.StatusOK || exchangeCount() != 2 {
		t.Fatalf("after a 401: status = %d, exchanges = %d, want a fresh token", status, exchangeCount())
	}

	// expires_in 1200s is capped to 15 minutes, refreshed 60s early.
	now = now.Add(localTokenMaxTTL - localTokenExpiryMargin)
	call()
	if got := exchangeCount(); got != 3 {
		t.Fatalf("token exchanges after the capped lifetime = %d, want 3", got)
	}
}

func TestLocalOAuthBrokerToleratesMalformedExpiresIn(t *testing.T) {
	var (
		mu        sync.Mutex
		exchanges int
	)
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if request.URL.Path == "/oauth/token" {
			exchanges++
			_, _ = fmt.Fprintf(response, `{"access_token":"token-%d","expires_in":"n/a"}`, exchanges)
			return
		}
		_, _ = fmt.Fprint(response, `[]`)
	}))
	defer server.Close()

	cfg := validTestConfig()
	cfg.TokenURL = server.URL + "/oauth/token"
	cfg.APIURL = server.URL + "/api/v1/commands"
	broker, err := newLocalOAuthBroker(cfg, map[string]string{"username": "u", "password": "p"}, server.Client())
	if err != nil {
		t.Fatal(err)
	}

	for range 2 {
		response, err := broker.Handle(t.Context(), sdk.HTTPRequest{Method: http.MethodPost, URL: cfg.APIURL})
		if err != nil || response.Status != http.StatusOK {
			t.Fatalf("Handle() = %v, %v; want a successful login despite a malformed expires_in", response, err)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if exchanges != 2 {
		t.Fatalf("token exchanges = %d, want 2 (uncached)", exchanges)
	}
}

func TestLocalOAuthBrokerLateRejectionKeepsRefreshedToken(t *testing.T) {
	cfg := validTestConfig()
	broker, err := newLocalOAuthBroker(cfg, map[string]string{"username": "u", "password": "p"}, &http.Client{})
	if err != nil {
		t.Fatal(err)
	}
	broker.cacheToken([]byte("fresh-token"), 1200)

	broker.dropCachedToken([]byte("stale-token"))
	got, err := broker.bearerToken(t.Context())
	if err != nil || string(got) != "fresh-token" {
		t.Fatalf("after a late 401 for a stale token: token = %q, err = %v, want the fresh token kept", got, err)
	}

	broker.dropCachedToken([]byte("fresh-token"))
	broker.tokenMu.Lock()
	remaining := len(broker.token)
	broker.tokenMu.Unlock()
	if remaining != 0 {
		t.Fatal("rejecting the cached token did not evict it")
	}
}
