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
	"sync/atomic"
	"testing"
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
	if got := normalizeAuthInstance(""); got != defaultCoreURL {
		t.Fatalf("empty instance = %q, want default %q", got, defaultCoreURL)
	}

	if got := normalizeAuthInstance("https://sr.example.com///"); got != testAuthInstance {
		t.Fatalf("trailing slashes not stripped: %q", got)
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

func TestDeviceCodeFlowSuccess(t *testing.T) {
	srv := newDeviceTestServer(t, []tokenAnswer{
		{status: http.StatusBadRequest, body: map[string]string{"error": "authorization_pending"}},
		successTokenAnswer(),
	})

	entry, err := runDeviceCodeFlow(srv.server.Client(), srv.server.URL, authDefaultScope, false, io.Discard)
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

	if srv.clientIDSeen != authClientID {
		t.Fatalf("client_id = %q, want %q", srv.clientIDSeen, authClientID)
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

	entry, err := runDeviceCodeFlow(srv.server.Client(), srv.server.URL, authDefaultScope, false, io.Discard)
	if err != nil {
		t.Fatalf("device flow with slow_down: %v", err)
	}

	if entry.Token != "test-jwt-token" {
		t.Fatalf("token = %q", entry.Token)
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

			_, err := runDeviceCodeFlow(srv.server.Client(), srv.server.URL, authDefaultScope, false, io.Discard)
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

	_, err := runDeviceCodeFlow(srv.Client(), srv.URL, authDefaultScope, false, io.Discard)
	if !errors.Is(err, errAuthFlowFailed) {
		t.Fatalf("err = %v, want %v", err, errAuthFlowFailed)
	}
}

func TestDeviceCodeFlowPrintsVerificationURL(t *testing.T) {
	srv := newDeviceTestServer(t, []tokenAnswer{successTokenAnswer()})

	var out bytes.Buffer
	_, err := runDeviceCodeFlow(srv.server.Client(), srv.server.URL, authDefaultScope, false, &out)
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
