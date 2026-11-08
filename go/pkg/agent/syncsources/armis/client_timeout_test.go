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

// returnsWithinLimit bounds how long a request under test may block before the
// test fails instead of hanging.
const returnsWithinLimit = 5 * time.Second

// returnsWithin fails the test, instead of hanging it, when call outlives
// returnsWithinLimit.
func returnsWithin(t *testing.T, call func() error) error {
	t.Helper()

	done := make(chan error, 1)
	go func() { done <- call() }()

	select {
	case err := <-done:
		return err
	case <-time.After(returnsWithinLimit):
		t.Fatalf("Armis request still blocked after %s", returnsWithinLimit)
		return nil
	}
}

func TestStalledArmisRequestFailsAtTheClientTimeout(t *testing.T) {
	server := stalledServer(t)
	apiClient := newClientWithTimeout(models.SourceConfig{Endpoint: server.URL}, 200*time.Millisecond)
	defer apiClient.close()

	err := returnsWithin(t, func() error {
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

	err := returnsWithin(t, func() error {
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

	if got := apiClient.httpClient().Timeout; got != 30*time.Second {
		t.Fatalf("request timeout = %s, want 30s", got)
	}

	transport, ok := apiClient.httpClient().Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport type = %T, want *http.Transport", apiClient.httpClient().Transport)
	}
	if transport.DialContext == nil {
		t.Fatal("expected bounded DialContext on Armis transport")
	}
	if transport.TLSHandshakeTimeout != 10*time.Second {
		t.Fatalf("TLSHandshakeTimeout = %s, want 10s", transport.TLSHandshakeTimeout)
	}
	if transport.ResponseHeaderTimeout != 30*time.Second {
		t.Fatalf("ResponseHeaderTimeout = %s, want 30s", transport.ResponseHeaderTimeout)
	}
}

func TestStalledTLSHandshakeFailsAtHandshakeTimeout(t *testing.T) {
	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	release := make(chan struct{})
	t.Cleanup(func() {
		close(release)
		_ = listener.Close()
	})

	go func() {
		for {
			conn, acceptErr := listener.Accept()
			if acceptErr != nil {
				return
			}
			go func(c net.Conn) {
				defer func() { _ = c.Close() }()
				<-release
			}(conn)
		}
	}()

	apiClient := newClientWithTimeout(
		models.SourceConfig{
			Endpoint:           "https://" + listener.Addr().String(),
			InsecureSkipVerify: true,
		},
		200*time.Millisecond,
	)
	defer apiClient.close()

	err = returnsWithin(t, func() error {
		_, reqErr := apiClient.accessToken(context.Background(), map[string]string{"secret_key": "synthetic"})
		return reqErr
	})

	var netErr net.Error
	if !errors.As(err, &netErr) || !netErr.Timeout() {
		t.Fatalf("expected TLS handshake timeout error, got %v", err)
	}
}

func TestStreamingBodyStallFailsAtRequestTimeoutAfterHeadersArrive(t *testing.T) {
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"data":{`))
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(func() {
		close(release)
		server.Close()
	})

	apiClient := newClientWithTimeout(models.SourceConfig{Endpoint: server.URL}, 200*time.Millisecond)
	defer apiClient.close()

	err := returnsWithin(t, func() error {
		_, reqErr := apiClient.accessToken(context.Background(), map[string]string{"secret_key": "synthetic"})
		return reqErr
	})

	var netErr net.Error
	if !errors.As(err, &netErr) || !netErr.Timeout() {
		t.Fatalf("expected body read timeout error, got %v", err)
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

func TestErrorStatusBodyStallStaysATimeout(t *testing.T) {
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"message":`))
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(func() {
		close(release)
		server.Close()
	})

	apiClient := newClientWithTimeout(models.SourceConfig{Endpoint: server.URL}, 200*time.Millisecond)
	defer apiClient.close()

	tokenErr := returnsWithin(t, func() error {
		_, reqErr := apiClient.accessToken(context.Background(), map[string]string{"secret_key": "synthetic"})
		return reqErr
	})
	searchErr := returnsWithin(t, func() error {
		_, reqErr := apiClient.search(context.Background(), "synthetic-token", "in:devices", 0, 10)
		return reqErr
	})
	v3TokenErr := returnsWithin(t, func() error {
		_, reqErr := apiClient.v3AccessToken(
			context.Background(),
			models.SourceConfig{Credentials: map[string]string{
				"v3_client_id":     "synthetic-client",
				"v3_client_secret": "synthetic-secret",
				"v3_vendor_id":     "synthetic-vendor",
			}},
			assetEnrichmentConfig{endpoint: server.URL},
		)
		return reqErr
	})

	for name, err := range map[string]error{"token": tokenErr, "search": searchErr, "v3 token": v3TokenErr} {
		var netErr net.Error
		if !errors.As(err, &netErr) || !netErr.Timeout() {
			t.Fatalf("%s: expected body read timeout error, got %v", name, err)
		}
	}
	if !isUnauthorized(searchErr) {
		t.Fatalf("search: expected the 401 status to stay visible, got %v", searchErr)
	}
}
