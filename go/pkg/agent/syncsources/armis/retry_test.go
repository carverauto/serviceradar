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
	"net/url"
	"sort"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

// sleepRecorder stands in for the retry wait: it records each requested wait
// and returns at once, so retry tests never sleep.
type sleepRecorder struct {
	mu    sync.Mutex
	waits []time.Duration
}

func (s *sleepRecorder) sleep(ctx context.Context, d time.Duration) error {
	s.mu.Lock()
	s.waits = append(s.waits, d)
	s.mu.Unlock()

	return ctx.Err()
}

func (s *sleepRecorder) recorded() []time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()

	return append([]time.Duration(nil), s.waits...)
}

// testRetryPolicy keeps the production shape with a small attempt count.
func testRetryPolicy() retryPolicy {
	return retryPolicy{maxAttempts: 3, baseDelay: time.Second, maxDelay: 15 * time.Second, budget: 2 * time.Minute}
}

const (
	firstPageBody = `{"data":{"count":2,"next":2,"results":[
		{"id":101,"ipAddress":"192.0.2.101","name":"host101.example.com"},
		{"id":102,"ipAddress":"192.0.2.102","name":"host102.example.com"}
	],"total":4},"success":true}`
	secondPageBody = `{"data":{"count":2,"next":null,"results":[
		{"id":103,"ipAddress":"192.0.2.103","name":"host103.example.com"},
		{"id":104,"ipAddress":"192.0.2.104","name":"host104.example.com"}
	],"total":4},"success":true}`
)

// twoPageServer serves a token and a two-page device search. failSecondPage is
// called for every request of the second page with its 1-based attempt number
// and answers that attempt itself by returning true.
func twoPageServer(
	t *testing.T,
	failSecondPage func(w http.ResponseWriter, attempt int) bool,
) (*httptest.Server, func() int) {
	t.Helper()

	var (
		mu       sync.Mutex
		attempts int
	)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case accessTokenPath:
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"access_token":"token-123"},"success":true}`))
		case searchPath:
			body := firstPageBody
			if r.URL.Query().Get("from") == "2" {
				mu.Lock()
				attempts++
				attempt := attempts
				mu.Unlock()
				if failSecondPage(w, attempt) {
					return
				}
				body = secondPageBody
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(body))
		default:
			t.Errorf("unexpected path %q", r.URL.Path)
		}
	}))
	t.Cleanup(server.Close)

	return server, func() int {
		mu.Lock()
		defer mu.Unlock()
		return attempts
	}
}

func twoPageSource(endpoint string) models.SourceConfig {
	return models.SourceConfig{
		Type:        SourceType,
		Endpoint:    endpoint,
		Credentials: map[string]string{"secret_key": "secret", "page_size": "2"},
		Queries:     []models.QueryConfig{{Label: "test", Query: testDeviceQuery}},
	}
}

// closeConnection drops the connection without answering: the shape of an
// API pod or load balancer going away mid-request.
func closeConnection(t *testing.T, w http.ResponseWriter) {
	t.Helper()

	conn, _, err := http.NewResponseController(w).Hijack()
	if err != nil {
		t.Errorf("hijack: %v", err)
		return
	}
	_ = conn.Close()
}

func TestSyncRetriesTransientPageFailuresWithoutDuplicatingDevices(t *testing.T) {
	failures := map[string]func(t *testing.T, w http.ResponseWriter){
		"429":               func(_ *testing.T, w http.ResponseWriter) { http.Error(w, "slow down", http.StatusTooManyRequests) },
		"502":               func(_ *testing.T, w http.ResponseWriter) { http.Error(w, "bad gateway", http.StatusBadGateway) },
		"503":               func(_ *testing.T, w http.ResponseWriter) { http.Error(w, "unavailable", http.StatusServiceUnavailable) },
		"504":               func(_ *testing.T, w http.ResponseWriter) { http.Error(w, "gateway timeout", http.StatusGatewayTimeout) },
		"connection closed": closeConnection,
	}

	for name, fail := range failures {
		t.Run(name, func(t *testing.T) {
			// Two consecutive failures: the HTTP transport may itself resend
			// once on a dropped reused connection, never twice.
			server, secondPageAttempts := twoPageServer(t, func(w http.ResponseWriter, attempt int) bool {
				if attempt > 2 {
					return false
				}
				fail(t, w)
				return true
			})

			recorder := &emitRecorder{}
			sleeps := &sleepRecorder{}
			driver := &Driver{retryPolicy: testRetryPolicy(), sleep: sleeps.sleep}

			count, err := driver.Sync(context.Background(), testRunContext(twoPageSource(server.URL), recorder.emit))
			if err != nil {
				t.Fatalf("Sync error = %v, want a complete run", err)
			}
			if count != 4 {
				t.Fatalf("count = %d, want 4", count)
			}

			got := recorder.deviceIDs()
			sort.Strings(got)
			want := []string{
				"partition-a:192.0.2.101", "partition-a:192.0.2.102",
				"partition-a:192.0.2.103", "partition-a:192.0.2.104",
			}
			if strings.Join(got, ",") != strings.Join(want, ",") {
				t.Fatalf("emitted devices = %v, want each of %v exactly once", got, want)
			}
			if attempts := secondPageAttempts(); attempts < 3 {
				t.Fatalf("second page attempts = %d, want the failed page retried", attempts)
			}
		})
	}
}

func TestSyncReportsPartialRunWhenPageRetriesAreExhausted(t *testing.T) {
	server, secondPageAttempts := twoPageServer(t, func(w http.ResponseWriter, _ int) bool {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return true
	})

	recorder := &emitRecorder{}
	sleeps := &sleepRecorder{}
	driver := &Driver{retryPolicy: testRetryPolicy(), sleep: sleeps.sleep}

	count, err := driver.Sync(context.Background(), testRunContext(twoPageSource(server.URL), recorder.emit))
	if err == nil {
		t.Fatal("Sync succeeded, want a partial-run error")
	}
	for _, want := range []string{"partial armis sync after streaming 2 devices", "gave up after 3 attempts", "503"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error = %q, want it to contain %q", err, want)
		}
	}
	if count != 2 {
		t.Fatalf("count = %d, want the first page's 2 devices", count)
	}
	if attempts := secondPageAttempts(); attempts != 3 {
		t.Fatalf("second page attempts = %d, want 3", attempts)
	}
	if waits := sleeps.recorded(); len(waits) != 2 {
		t.Fatalf("retry waits = %v, want 2", waits)
	}
}

func TestSyncDoesNotRetryNonTransientPageFailures(t *testing.T) {
	failures := map[string]func(w http.ResponseWriter){
		"403 forbidden": func(w http.ResponseWriter) { http.Error(w, "forbidden", http.StatusForbidden) },
		"malformed body": func(w http.ResponseWriter) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"data":{"results":[`))
		},
	}

	for name, fail := range failures {
		t.Run(name, func(t *testing.T) {
			server, secondPageAttempts := twoPageServer(t, func(w http.ResponseWriter, _ int) bool {
				fail(w)
				return true
			})

			recorder := &emitRecorder{}
			sleeps := &sleepRecorder{}
			driver := &Driver{retryPolicy: testRetryPolicy(), sleep: sleeps.sleep}

			count, err := driver.Sync(context.Background(), testRunContext(twoPageSource(server.URL), recorder.emit))
			if err == nil || !strings.Contains(err.Error(), "partial armis sync after streaming 2 devices") {
				t.Fatalf("error = %v, want a partial-run error", err)
			}
			if count != 2 {
				t.Fatalf("count = %d, want 2", count)
			}
			if attempts := secondPageAttempts(); attempts != 1 {
				t.Fatalf("second page attempts = %d, want 1", attempts)
			}
			if waits := sleeps.recorded(); len(waits) != 0 {
				t.Fatalf("retry waits = %v, want none", waits)
			}
		})
	}
}

func TestSyncStopsRetryingPromptlyWhenTheRunIsCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	server, secondPageAttempts := twoPageServer(t, func(w http.ResponseWriter, _ int) bool {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return true
	})

	// The run is cancelled once the retry starts waiting; the real
	// context-aware wait, with a backoff far longer than the test, must end.
	driver := &Driver{
		retryPolicy: retryPolicy{maxAttempts: 5, baseDelay: time.Hour, maxDelay: time.Hour, budget: 24 * time.Hour},
		sleep: func(ctx context.Context, d time.Duration) error {
			cancel()
			return sleepContext(ctx, d)
		},
	}
	recorder := &emitRecorder{}

	var count int
	err := returnsWithin(t, func() error {
		var syncErr error
		count, syncErr = driver.Sync(ctx, testRunContext(twoPageSource(server.URL), recorder.emit))
		return syncErr
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("error = %v, want context.Canceled", err)
	}
	if !strings.Contains(err.Error(), "partial armis sync after streaming 2 devices") {
		t.Fatalf("error = %q, want the partial-run context", err)
	}
	if count != 2 {
		t.Fatalf("count = %d, want 2", count)
	}
	if attempts := secondPageAttempts(); attempts != 1 {
		t.Fatalf("second page attempts = %d, want 1", attempts)
	}
}

func TestSyncHonorsRetryAfterWithinTheRetryBudget(t *testing.T) {
	cases := []struct {
		name       string
		retryAfter func() string
		wantWait   func(t *testing.T, waits []time.Duration)
		wantErr    string
	}{
		{
			name:       "delta seconds",
			retryAfter: func() string { return "7" },
			wantWait: func(t *testing.T, waits []time.Duration) {
				t.Helper()
				if len(waits) != 1 || waits[0] != 7*time.Second {
					t.Fatalf("retry waits = %v, want [7s]", waits)
				}
			},
		},
		{
			name:       "http date",
			retryAfter: func() string { return time.Now().Add(30 * time.Second).UTC().Format(http.TimeFormat) },
			wantWait: func(t *testing.T, waits []time.Duration) {
				t.Helper()
				if len(waits) != 1 || waits[0] < 25*time.Second || waits[0] > 30*time.Second {
					t.Fatalf("retry waits = %v, want one wait of about 30s", waits)
				}
			},
		},
		{
			name:       "beyond the budget",
			retryAfter: func() string { return "3600" },
			wantWait: func(t *testing.T, waits []time.Duration) {
				t.Helper()
				if len(waits) != 0 {
					t.Fatalf("retry waits = %v, want none", waits)
				}
			},
			wantErr: "exceeds the 2m0s retry budget",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			server, _ := twoPageServer(t, func(w http.ResponseWriter, attempt int) bool {
				if attempt > 1 {
					return false
				}
				w.Header().Set("Retry-After", tc.retryAfter())
				http.Error(w, "slow down", http.StatusTooManyRequests)
				return true
			})

			recorder := &emitRecorder{}
			sleeps := &sleepRecorder{}
			driver := &Driver{retryPolicy: testRetryPolicy(), sleep: sleeps.sleep}

			_, err := driver.Sync(context.Background(), testRunContext(twoPageSource(server.URL), recorder.emit))
			switch {
			case tc.wantErr == "" && err != nil:
				t.Fatalf("Sync error = %v, want a complete run", err)
			case tc.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tc.wantErr)):
				t.Fatalf("Sync error = %v, want it to contain %q", err, tc.wantErr)
			}
			tc.wantWait(t, sleeps.recorded())
		})
	}
}

func TestSyncRetriesARefusedConnectionThenFails(t *testing.T) {
	var listenConfig net.ListenConfig
	listener, err := listenConfig.Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	endpoint := "http://" + listener.Addr().String()
	_ = listener.Close()

	sleeps := &sleepRecorder{}
	driver := &Driver{retryPolicy: testRetryPolicy(), sleep: sleeps.sleep}

	count, err := driver.Sync(context.Background(), testRunContext(twoPageSource(endpoint), (&emitRecorder{}).emit))
	if !errors.Is(err, syscall.ECONNREFUSED) {
		t.Fatalf("error = %v, want connection refused", err)
	}
	if !strings.Contains(err.Error(), "gave up after 3 attempts") {
		t.Fatalf("error = %q, want the exhausted-retry context", err)
	}
	if count != 0 {
		t.Fatalf("count = %d, want 0", count)
	}
	if waits := sleeps.recorded(); len(waits) != 2 {
		t.Fatalf("retry waits = %v, want 2", waits)
	}
}

// A dial through an HTTP proxy reaches the caller as net/http's proxyconnect
// wrapper around the dial error. 10061 is Windows WSAECONNREFUSED, which no
// syscall constant matches, so only the nested dial Op marks it transient.
func TestProxiedDialFailureIsTransient(t *testing.T) {
	err := &url.Error{Op: "Post", URL: "https://198.51.100.10/api/v1/search/", Err: &net.OpError{
		Op:  "proxyconnect",
		Net: "tcp",
		Err: &net.OpError{Op: "dial", Net: "tcp", Err: syscall.Errno(10061)},
	}}

	reason, ok := transientReason(err)
	if !ok || reason != "connection_dial" {
		t.Fatalf("transientReason = (%q, %v), want (\"connection_dial\", true)", reason, ok)
	}
}
