/*
 * Copyright 2025 Carver Automation Corporation.
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

package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const testAuthInstance = "https://sr.example.com"

func TestAuthParseLogin(t *testing.T) {
	cfg := &CmdConfig{}
	err := (AuthHandler{}).Parse([]string{"login", "--instance", testAuthInstance, "--scope", "custom.scope", "--no-browser"}, cfg)
	if err != nil {
		t.Fatalf("parse auth login: %v", err)
	}

	if cfg.AuthCommand != authCommandLogin {
		t.Fatalf("AuthCommand = %q, want %q", cfg.AuthCommand, authCommandLogin)
	}

	if cfg.AuthInstance != testAuthInstance {
		t.Fatalf("AuthInstance = %q", cfg.AuthInstance)
	}

	if cfg.AuthScope != "custom.scope" {
		t.Fatalf("AuthScope = %q", cfg.AuthScope)
	}

	if !cfg.AuthNoBrowser {
		t.Fatal("AuthNoBrowser = false, want true")
	}
}

func TestAuthParseStatusAndLogout(t *testing.T) {
	for _, action := range []string{"status", "logout"} {
		cfg := &CmdConfig{}
		if err := (AuthHandler{}).Parse([]string{action, "--instance", testAuthInstance + "/"}, cfg); err != nil {
			t.Fatalf("parse auth %s: %v", action, err)
		}

		if cfg.AuthCommand != action {
			t.Fatalf("AuthCommand = %q, want %q", cfg.AuthCommand, action)
		}

		if cfg.AuthInstance != testAuthInstance+"/" {
			t.Fatalf("AuthInstance = %q", cfg.AuthInstance)
		}
	}
}

func TestAuthParseErrors(t *testing.T) {
	if err := (AuthHandler{}).Parse(nil, &CmdConfig{}); !errors.Is(err, errAuthActionRequired) {
		t.Fatalf("missing action err = %v, want %v", err, errAuthActionRequired)
	}

	if err := (AuthHandler{}).Parse([]string{"capture"}, &CmdConfig{}); !errors.Is(err, errAuthUnknownAction) {
		t.Fatalf("unknown action err = %v, want %v", err, errAuthUnknownAction)
	}
}

func TestNormalizeAuthInstance(t *testing.T) {
	if got := normalizeAuthInstance("  "); got != "" {
		t.Fatalf("blank instance = %q, want empty", got)
	}

	if got := normalizeAuthInstance("https://sr.example.com///"); got != testAuthInstance {
		t.Fatalf("trailing slashes not stripped: %q", got)
	}

	// The store is shared with the JS CLI, whose normalizeInstanceUrl only
	// trims and strips trailing slashes; inventing a scheme here would write a
	// key the JS CLI could never look up.
	if got := normalizeAuthInstance("sr.example.com"); got != "sr.example.com" {
		t.Fatalf("scheme-less instance = %q, want it left alone", got)
	}
}

func TestAuthLoginRejectsInstanceWithoutScheme(t *testing.T) {
	isolateCredentialStore(t)

	err := RunAuthLogin(&CmdConfig{AuthInstance: "sr.example.com"})
	if !errors.Is(err, errAuthInstanceURL) {
		t.Fatalf("scheme-less login err = %v, want %v", err, errAuthInstanceURL)
	}

	if err := RunAuthLogin(&CmdConfig{AuthInstance: "   "}); !errors.Is(err, errAuthInstanceRequired) {
		t.Fatalf("blank login err = %v, want %v", err, errAuthInstanceRequired)
	}
}

// TestAuthBcryptGenMatchesHelmHookInvocation reproduces the argv the Helm
// secret-generator hook runs: `... auth bcrypt-gen --password <pw>`. It must
// succeed and print a hash of the password itself.
func TestAuthBcryptGenMatchesHelmHookInvocation(t *testing.T) {
	if testing.Short() {
		t.Skip("production-cost bcrypt generation and verification are exercised in the non-short suite")
	}

	password := t.Name()

	cfg := &CmdConfig{}
	if err := (AuthHandler{}).Parse([]string{"bcrypt-gen", "--password", password}, cfg); err != nil {
		t.Fatalf("parse auth bcrypt-gen: %v", err)
	}

	out := captureStdout(t, func() {
		if err := RunAuthCommand(cfg); err != nil {
			t.Fatalf("run auth bcrypt-gen: %v", err)
		}
	})

	hash := strings.TrimSpace(out)
	if err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)); err != nil {
		t.Fatalf("printed hash %q does not verify against the password: %v", hash, err)
	}
}

func TestAuthBcryptGenRequiresPassword(t *testing.T) {
	cfg := &CmdConfig{}
	if err := (AuthHandler{}).Parse([]string{"bcrypt-gen"}, cfg); err != nil {
		t.Fatalf("parse auth bcrypt-gen: %v", err)
	}

	if err := RunAuthCommand(cfg); !errors.Is(err, errAuthPasswordRequired) {
		t.Fatalf("err = %v, want %v", err, errAuthPasswordRequired)
	}
}

func TestAuthFilterEmptyStaysEmpty(t *testing.T) {
	if got := authFilter(&CmdConfig{}); got != "" {
		t.Fatalf("empty filter = %q, want empty (list all)", got)
	}

	if got := authFilter(&CmdConfig{AuthInstance: testAuthInstance + "/"}); got != testAuthInstance {
		t.Fatalf("explicit filter = %q", got)
	}
}

// deviceTestServer serves the RFC 8628 pair with scripted token-poll answers.
type deviceTestServer struct {
	mu            sync.Mutex
	t             *testing.T
	server        *httptest.Server
	deviceSeen    atomic.Int32
	tokenCalls    atomic.Int32
	tokenAnswers  []tokenAnswer
	devicePayload map[string]any
	clientIDSeen  string
}

type tokenAnswer struct {
	status int
	body   any
}

func newDeviceTestServer(t *testing.T, tokenAnswers []tokenAnswer) *deviceTestServer {
	t.Helper()

	s := &deviceTestServer{t: t, tokenAnswers: tokenAnswers}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/cli/auth/device", s.handleDevice)
	mux.HandleFunc("/api/v1/cli/auth/token", s.handleToken)
	s.server = httptest.NewServer(mux)
	t.Cleanup(s.server.Close)

	return s
}

func (s *deviceTestServer) handleDevice(w http.ResponseWriter, r *http.Request) {
	s.deviceSeen.Add(1)

	var req map[string]string
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.clientIDSeen = req["client_id"]

	payload := map[string]any{
		"device_code":               "test-device-code",
		"user_code":                 "TEST-CODE1",
		"verification_uri":          s.server.URL + "/cli/auth/device",
		"verification_uri_complete": s.server.URL + "/cli/auth/device?user_code=TEST-CODE1",
		"expires_in":                60,
		"interval":                  1,
	}
	for key, value := range s.devicePayload {
		payload[key] = value
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(payload)
}

func (s *deviceTestServer) handleToken(w http.ResponseWriter, r *http.Request) {
	call := int(s.tokenCalls.Add(1)) - 1

	answer := tokenAnswer{status: http.StatusBadRequest, body: map[string]string{"error": "authorization_pending"}}
	if call < len(s.tokenAnswers) {
		answer = s.tokenAnswers[call]
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(answer.status)
	_ = json.NewEncoder(w).Encode(answer.body)
}

func successTokenAnswer() tokenAnswer {
	return tokenAnswer{status: http.StatusOK, body: map[string]any{
		"access_token": "test-jwt-token",
		"token_type":   "Bearer",
		"expires_in":   2592000,
		"scope":        "dashboard.publish",
		"user":         map[string]string{"id": "user-1", "email": "tester@example.com"},
	}}
}

type deviceTestClock struct {
	current time.Time
	waits   []time.Duration
}

func (c *deviceTestClock) now() time.Time { return c.current }

func (c *deviceTestClock) sleep(d time.Duration) {
	c.waits = append(c.waits, d)
	c.current = c.current.Add(d)
}

func runTestDeviceCodeFlow(client *http.Client, instance string, openBrowser bool, writer io.Writer) (authCredentialEntry, error) {
	clock := &deviceTestClock{}
	return runDeviceCodeFlowWithClock(client, instance, authDefaultScope, openBrowser, writer, clock.now, clock.sleep)
}

func TestDeviceCodeFlowSuccess(t *testing.T) {
	srv := newDeviceTestServer(t, []tokenAnswer{
		{status: http.StatusBadRequest, body: map[string]string{"error": "authorization_pending"}},
		successTokenAnswer(),
	})

	entry, err := runTestDeviceCodeFlow(srv.server.Client(), srv.server.URL, false, io.Discard)
	if err != nil {
		t.Fatalf("device flow: %v", err)
	}

	if entry.Token != "test-jwt-token" {
		t.Fatalf("token = %q", entry.Token)
	}

	if entry.User != "tester@example.com" {
		t.Fatalf("user = %q", entry.User)
	}

	if entry.ObtainedAt == "" || entry.ExpiresAt == "" {
		t.Fatalf("timestamps missing: %+v", entry)
	}

	srv.mu.Lock()
	clientIDSeen := srv.clientIDSeen
	srv.mu.Unlock()
	if clientIDSeen != authClientID {
		t.Fatalf("client_id = %q, want %q", clientIDSeen, authClientID)
	}

	if got := int(srv.tokenCalls.Load()); got != 2 {
		t.Fatalf("token polls = %d, want 2 (pending then success)", got)
	}
}

func TestDeviceCodeFlowSlowDownBacksOff(t *testing.T) {
	srv := newDeviceTestServer(t, []tokenAnswer{
		{status: http.StatusBadRequest, body: map[string]string{"error": "slow_down"}},
		successTokenAnswer(),
	})

	clock := &deviceTestClock{}
	entry, err := runDeviceCodeFlowWithClock(srv.server.Client(), srv.server.URL, authDefaultScope, false, io.Discard, clock.now, clock.sleep)
	if err != nil {
		t.Fatalf("device flow with slow_down: %v", err)
	}

	if len(clock.waits) != 2 || clock.waits[0] != time.Second || clock.waits[1] != 6*time.Second {
		t.Fatalf("poll waits = %v, want [1s 6s]", clock.waits)
	}

	if entry.Token != "test-jwt-token" {
		t.Fatalf("token = %q", entry.Token)
	}
}

func TestDeviceCodeFlowTimesOut(t *testing.T) {
	srv := newDeviceTestServer(t, nil)
	srv.mu.Lock()
	srv.devicePayload = map[string]any{"expires_in": 2}
	srv.mu.Unlock()

	clock := &deviceTestClock{}
	_, err := runDeviceCodeFlowWithClock(srv.server.Client(), srv.server.URL, authDefaultScope, false, io.Discard, clock.now, clock.sleep)
	if !errors.Is(err, errAuthExpired) {
		t.Fatalf("err = %v, want %v", err, errAuthExpired)
	}
	if got := srv.tokenCalls.Load(); got != 2 {
		t.Fatalf("token polls = %d, want 2", got)
	}
	if elapsed := clock.current.Sub(time.Time{}); elapsed != 2*time.Second {
		t.Fatalf("elapsed = %s, want 2s", elapsed)
	}
}

func TestDeviceCodeFlowTerminalStates(t *testing.T) {
	cases := []struct {
		name    string
		code    string
		wantErr error
	}{
		{"denied", "access_denied", errAuthDenied},
		{"expired", "expired_token", errAuthExpired},
		{"invalid", "invalid_grant", nil},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := newDeviceTestServer(t, []tokenAnswer{
				{status: http.StatusBadRequest, body: map[string]string{"error": tc.code}},
			})

			_, err := runTestDeviceCodeFlow(srv.server.Client(), srv.server.URL, false, io.Discard)
			if err == nil {
				t.Fatal("expected error, got nil")
			}

			if tc.wantErr != nil && !errors.Is(err, tc.wantErr) {
				t.Fatalf("err = %v, want %v", err, tc.wantErr)
			}
		})
	}
}

func TestDeviceCodeFlowDeviceNotFound(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.NotFound(w, nil)
	}))
	t.Cleanup(srv.Close)

	_, err := runTestDeviceCodeFlow(srv.Client(), srv.URL, false, io.Discard)
	if !errors.Is(err, errAuthFlowFailed) {
		t.Fatalf("err = %v, want %v", err, errAuthFlowFailed)
	}
}

func TestDeviceCodeFlowRejectsNonHTTPVerificationURI(t *testing.T) {
	srv := newDeviceTestServer(t, []tokenAnswer{successTokenAnswer()})
	srv.mu.Lock()
	srv.devicePayload = map[string]any{
		"verification_uri":          "file:///etc/passwd",
		"verification_uri_complete": "file:///etc/passwd",
	}
	srv.mu.Unlock()

	var out bytes.Buffer
	_, err := runTestDeviceCodeFlow(srv.server.Client(), srv.server.URL, true, &out)
	if !errors.Is(err, errAuthFlowFailed) {
		t.Fatalf("err = %v, want %v", err, errAuthFlowFailed)
	}

	if strings.Contains(out.String(), "file:///etc/passwd") {
		t.Fatalf("rejected URI was printed anyway:\n%s", out.String())
	}
}

func TestDeviceCodeFlowPrintsVerificationURL(t *testing.T) {
	srv := newDeviceTestServer(t, []tokenAnswer{successTokenAnswer()})

	var out bytes.Buffer
	_, err := runTestDeviceCodeFlow(srv.server.Client(), srv.server.URL, false, &out)
	if err != nil {
		t.Fatalf("device flow: %v", err)
	}

	if !strings.Contains(out.String(), "/cli/auth/device?user_code=TEST-CODE1") {
		t.Fatalf("verification URL missing from output:\n%s", out.String())
	}

	if !strings.Contains(out.String(), "TEST-CODE1") {
		t.Fatalf("user code missing from output:\n%s", out.String())
	}
}

func isolateCredentialStore(t *testing.T) {
	t.Helper()
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv("HOME", t.TempDir())
}

func TestCredentialStoreRoundTrip(t *testing.T) {
	isolateCredentialStore(t)

	entry := authCredentialEntry{Token: "secret-jwt", User: "tester@example.com", ObtainedAt: "2026-01-01T00:00:00Z"}
	if err := upsertStoredCredential(testAuthInstance+"/", entry); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	store, err := readCredentialStore()
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	got, ok := store.Instances[testAuthInstance]
	if !ok {
		t.Fatalf("stored instances = %v", store.Instances)
	}

	if got.Token != "secret-jwt" || got.User != "tester@example.com" {
		t.Fatalf("stored entry = %+v", got)
	}

	info, err := os.Stat(credentialsPath())
	if err != nil {
		t.Fatalf("stat credential file: %v", err)
	}

	if info.Mode().Perm() != 0600 {
		t.Fatalf("credential file mode = %o, want 600", info.Mode().Perm())
	}

	dirInfo, err := os.Stat(credentialsDir())
	if err != nil {
		t.Fatalf("stat credential dir: %v", err)
	}

	if dirInfo.Mode().Perm() != 0700 {
		t.Fatalf("credential dir mode = %o, want 700", dirInfo.Mode().Perm())
	}

	removed, err := deleteStoredCredential(testAuthInstance)
	if err != nil || !removed {
		t.Fatalf("delete = %v, %v", removed, err)
	}

	removed, err = deleteStoredCredential(testAuthInstance)
	if err != nil || removed {
		t.Fatalf("second delete = %v, %v", removed, err)
	}
}

func TestAuthStatusNeverPrintsToken(t *testing.T) {
	isolateCredentialStore(t)

	if err := upsertStoredCredential(testAuthInstance, authCredentialEntry{Token: "secret-jwt", User: "tester"}); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	var out bytes.Buffer
	if err := writeAuthStatus(&out, ""); err != nil {
		t.Fatalf("status: %v", err)
	}

	if strings.Contains(out.String(), "secret-jwt") {
		t.Fatalf("status leaked the token:\n%s", out.String())
	}

	if !strings.Contains(out.String(), "tester") || !strings.Contains(out.String(), testAuthInstance) {
		t.Fatalf("status missing user/instance:\n%s", out.String())
	}
}

func TestAuthStatusReportsUnmatchedFilter(t *testing.T) {
	isolateCredentialStore(t)

	if err := upsertStoredCredential(testAuthInstance, authCredentialEntry{Token: "secret-jwt"}); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	var out bytes.Buffer
	if err := writeAuthStatus(&out, "https://typo.example.com"); err != nil {
		t.Fatalf("status: %v", err)
	}

	if !strings.Contains(out.String(), "No credential stored for https://typo.example.com") {
		t.Fatalf("unmatched filter produced no message:\n%q", out.String())
	}
}

func TestCredentialStoreWritesAtomically(t *testing.T) {
	isolateCredentialStore(t)

	if err := upsertStoredCredential(testAuthInstance, authCredentialEntry{Token: "first"}); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	info, err := os.Lstat(credentialsPath())
	if err != nil {
		t.Fatalf("stat credential file: %v", err)
	}

	if info.Mode()&os.ModeSymlink != 0 {
		t.Fatal("credential file must be a regular file, not a symlink")
	}

	entries, err := os.ReadDir(credentialsDir())
	if err != nil {
		t.Fatalf("read credential dir: %v", err)
	}

	if len(entries) != 1 {
		t.Fatalf("credential dir left temp files behind: %v", entries)
	}

	if err := upsertStoredCredential("https://two.example.com", authCredentialEntry{Token: "second"}); err != nil {
		t.Fatalf("second upsert: %v", err)
	}

	store, err := readCredentialStore()
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	if len(store.Instances) != 2 {
		t.Fatalf("instances = %v, want both preserved", store.Instances)
	}
}

func TestAuthLogoutDisambiguation(t *testing.T) {
	isolateCredentialStore(t)

	if err := upsertStoredCredential("https://one.example.com", authCredentialEntry{Token: "one"}); err != nil {
		t.Fatalf("upsert one: %v", err)
	}

	if err := upsertStoredCredential("https://two.example.com", authCredentialEntry{Token: "two"}); err != nil {
		t.Fatalf("upsert two: %v", err)
	}

	if err := writeAuthLogout(io.Discard, ""); err == nil {
		t.Fatal("expected disambiguation error, got nil")
	}

	var out bytes.Buffer
	if err := writeAuthLogout(&out, "https://one.example.com"); err != nil {
		t.Fatalf("logout one: %v", err)
	}

	if _, err := os.Stat(filepath.Join(credentialsDir(), authCredentialsFileName)); err != nil {
		t.Fatalf("store file should survive partial logout: %v", err)
	}

	store, err := readCredentialStore()
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	if len(store.Instances) != 1 || store.Instances["https://two.example.com"].Token != "two" {
		t.Fatalf("instances after logout = %v", store.Instances)
	}
}
