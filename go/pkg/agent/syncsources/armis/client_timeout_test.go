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

package armis

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

// stalledServer accepts requests and never answers until the test ends: the
// shape of a stalled upstream API.
func stalledServer(t *testing.T) *httptest.Server {
	t.Helper()

	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(func() {
		close(release)
		server.Close()
	})

	return server
}

// returnsWithin fails the test, instead of hanging it, when call outlives limit.
func returnsWithin(t *testing.T, limit time.Duration, call func() error) error {
	t.Helper()

	done := make(chan error, 1)
	go func() { done <- call() }()

	select {
	case err := <-done:
		return err
	case <-time.After(limit):
		t.Fatalf("Armis request still blocked after %s", limit)
		return nil
	}
}

func TestStalledArmisRequestFailsAtTheClientTimeout(t *testing.T) {
	server := stalledServer(t)
	apiClient := newClientWithTimeout(models.SourceConfig{Endpoint: server.URL}, 200*time.Millisecond)
	defer apiClient.close()

	err := returnsWithin(t, 5*time.Second, func() error {
		_, err := apiClient.accessToken(context.Background(), map[string]string{"secret_key": "synthetic"})
		return err
	})

	var netErr net.Error
	if !errors.As(err, &netErr) || !netErr.Timeout() {
		t.Fatalf("expected a client timeout, got %v", err)
	}
}

func TestStalledArmisRequestHonorsAShorterContextDeadline(t *testing.T) {
	server := stalledServer(t)
	apiClient := newClientWithTimeout(models.SourceConfig{Endpoint: server.URL}, time.Hour)
	defer apiClient.close()

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	err := returnsWithin(t, 5*time.Second, func() error {
		_, err := apiClient.search(ctx, "synthetic-token", testDeviceQuery, 0, 10)
		return err
	})

	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected the context deadline, got %v", err)
	}
}

func TestDefaultArmisClientHasARequestTimeout(t *testing.T) {
	apiClient := newClient(models.SourceConfig{Endpoint: "https://armis.example.com"})
	defer apiClient.close()

	if got := apiClient.httpClient().Timeout; got != requestTimeout {
		t.Fatalf("request timeout = %s, want %s", got, requestTimeout)
	}
}

func TestInsecureArmisClientReusesOneConnectionAcrossRequests(t *testing.T) {
	var connections atomic.Int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"access_token":"token-123"},"success":true}`))
	}))
	server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			connections.Add(1)
		}
	}
	server.StartTLS()
	defer server.Close()

	apiClient := newClient(models.SourceConfig{Endpoint: server.URL, InsecureSkipVerify: true})
	defer apiClient.close()

	for i := 0; i < 3; i++ {
		if _, err := apiClient.accessToken(context.Background(), map[string]string{"secret_key": "synthetic"}); err != nil {
			t.Fatalf("request %d: %v", i, err)
		}
	}

	if got := connections.Load(); got != 1 {
		t.Fatalf("opened %d connections for 3 sequential requests, want 1 pooled connection", got)
	}
}
