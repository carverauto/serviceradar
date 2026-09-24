/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package agent

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type oauth2CountingTokenServer struct {
	*httptest.Server
	mu        sync.Mutex
	exchanges int
}

// newOAuth2CountingTokenServer issues a distinct token per exchange so a test
// can tell a reused token from a fresh one. expiresIn "" omits the field.
func newOAuth2CountingTokenServer(t *testing.T, expiresIn string) *oauth2CountingTokenServer {
	t.Helper()
	server := &oauth2CountingTokenServer{}
	server.Server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		server.mu.Lock()
		server.exchanges++
		n := server.exchanges
		server.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		if expiresIn == "" {
			_, _ = fmt.Fprintf(w, `{"access_token":"token-%d"}`, n)
			return
		}
		_, _ = fmt.Fprintf(w, `{"access_token":"token-%d","expires_in":%s}`, n, expiresIn)
	}))
	t.Cleanup(server.Close)
	return server
}

func (s *oauth2CountingTokenServer) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.exchanges
}

type oauth2CacheHarness struct {
	t      *testing.T
	exec   *pluginExecution
	grant  credentialBrokerGrant
	server *oauth2CountingTokenServer
	now    time.Time
}

func newOAuth2CacheHarness(t *testing.T, expiresIn string) *oauth2CacheHarness {
	t.Helper()
	server := newOAuth2CountingTokenServer(t, expiresIn)
	manager := NewPluginManager(t.Context(), PluginManagerConfig{})
	t.Cleanup(manager.Stop)
	h := &oauth2CacheHarness{
		t:      t,
		exec:   newPluginExecution(manager, &pluginAssignment{}),
		grant:  credentialBrokerGrant{Inject: oauth2PasswordBearerTestInject(mustParseURL(t, server.URL+"/oauth/token"))},
		server: server,
		now:    time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC),
	}
	manager.credentialNow = func() time.Time { return h.now }
	return h
}

func (h *oauth2CacheHarness) authorize(password string) (*http.Request, string) {
	h.t.Helper()
	req, err := http.NewRequestWithContext(
		h.t.Context(), http.MethodPost, "https://inventory.example.test/api/devices", strings.NewReader(`{}`),
	)
	if err != nil {
		h.t.Fatal(err)
	}
	material := CredentialBrokerMaterial{Fields: map[string]string{
		"username": "inventory-user",
		"password": password,
	}}
	if err := h.exec.applyCredentialBrokerOAuth2Bearer(
		h.t.Context(), req, h.grant, material, oauth2GrantShapes[injectTypeOAuth2PasswordBearer], true,
	); err != nil {
		h.t.Fatalf("token exchange failed: %v", err)
	}
	return req, req.Header.Get("Authorization")
}

func TestCredentialBrokerOAuth2ReusesTokenWithinItsLifetime(t *testing.T) {
	h := newOAuth2CacheHarness(t, "1200")

	_, first := h.authorize("long-lived-password")
	h.now = h.now.Add(5 * time.Minute)
	_, second := h.authorize("long-lived-password")

	if first != "Bearer token-1" || second != first {
		t.Fatalf("Authorization first=%q second=%q, want the same cached token", first, second)
	}
	if got := h.server.count(); got != 1 {
		t.Fatalf("token exchanges = %d, want 1", got)
	}
}

func TestCredentialBrokerOAuth2RefreshesBeforeExpiry(t *testing.T) {
	// expires_in 600s is under the cap: reused until 600s - 60s margin.
	h := newOAuth2CacheHarness(t, "600")

	_, first := h.authorize("long-lived-password")
	h.now = h.now.Add(540*time.Second - time.Second)
	_, stillCached := h.authorize("long-lived-password")
	h.now = h.now.Add(time.Second)
	_, refreshed := h.authorize("long-lived-password")

	if stillCached != first {
		t.Fatalf("token replaced before the margin: %q -> %q", first, stillCached)
	}
	if refreshed == first || h.server.count() != 2 {
		t.Fatalf("token not refreshed at the margin: %q, exchanges = %d", refreshed, h.server.count())
	}
}

func TestCredentialBrokerOAuth2CapsAdvertisedLifetime(t *testing.T) {
	// OpenText NA advertises 3600s but documents a 20-minute token.
	h := newOAuth2CacheHarness(t, "3600")

	_, first := h.authorize("long-lived-password")
	h.now = h.now.Add(oauth2TokenCacheMaxTTL - oauth2TokenCacheExpiryMargin)
	_, refreshed := h.authorize("long-lived-password")

	if refreshed == first || h.server.count() != 2 {
		t.Fatalf("advertised lifetime not capped: %q, exchanges = %d", refreshed, h.server.count())
	}
}

func TestCredentialBrokerOAuth2DoesNotCacheWithoutExpiry(t *testing.T) {
	h := newOAuth2CacheHarness(t, "")

	h.authorize("long-lived-password")
	h.authorize("long-lived-password")

	if got := h.server.count(); got != 2 {
		t.Fatalf("token exchanges = %d, want 2 when expires_in is absent", got)
	}
}

func TestCredentialBrokerOAuth2DoesNotReuseTokenAcrossCredentials(t *testing.T) {
	h := newOAuth2CacheHarness(t, "1200")

	_, original := h.authorize("long-lived-password")
	_, rotated := h.authorize("rotated-password")

	if rotated == original || h.server.count() != 2 {
		t.Fatalf("rotated credential reused a token: %q, exchanges = %d", rotated, h.server.count())
	}
}

func TestCredentialBrokerOAuth2DropsTokenUpstreamRejects(t *testing.T) {
	h := newOAuth2CacheHarness(t, "1200")

	req, first := h.authorize("long-lived-password")
	grant := h.grant
	h.exec.invalidateRejectedOAuth2Token(req, &grant, http.StatusForbidden)
	_, afterForbidden := h.authorize("long-lived-password")
	if afterForbidden != first {
		t.Fatalf("a 403 evicted the token: %q -> %q", first, afterForbidden)
	}

	h.exec.invalidateRejectedOAuth2Token(req, &grant, http.StatusUnauthorized)
	_, afterUnauthorized := h.authorize("long-lived-password")
	if afterUnauthorized == first || h.server.count() != 2 {
		t.Fatalf("a 401 did not evict the token: %q, exchanges = %d", afterUnauthorized, h.server.count())
	}
}

func TestOAuth2TokenExchangeTimeoutFollowsRequestDeadline(t *testing.T) {
	if got := oauth2TokenExchangeTimeout(t.Context()); got != pluginDefaultHTTPTimeout {
		t.Fatalf("no deadline: timeout = %v, want the default", got)
	}

	short, cancelShort := context.WithTimeout(t.Context(), time.Second)
	defer cancelShort()
	if got := oauth2TokenExchangeTimeout(short); got != pluginDefaultHTTPTimeout {
		t.Fatalf("short deadline: timeout = %v, want the default floor", got)
	}

	long, cancelLong := context.WithTimeout(t.Context(), 2*time.Minute)
	defer cancelLong()
	if got := oauth2TokenExchangeTimeout(long); got <= pluginDefaultHTTPTimeout || got > 2*time.Minute {
		t.Fatalf("long deadline: timeout = %v, want the remaining request budget", got)
	}
}
