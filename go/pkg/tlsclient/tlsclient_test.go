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

package tlsclient

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// get performs one request through cfg against server and reports the
// handshake/request error, so each case asserts on a real TLS handshake rather
// than on the fields of the returned config.
func get(t *testing.T, server *httptest.Server, cfg *tls.Config) error {
	t.Helper()

	client := &http.Client{Transport: &http.Transport{TLSClientConfig: cfg}}
	defer client.CloseIdleConnections()

	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, server.URL, http.NoBody)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()

	return nil
}

func newServer(t *testing.T) *httptest.Server {
	t.Helper()

	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(server.Close)

	return server
}

// otherCA returns a pool holding a freshly generated, unrelated CA, so
// pinning it must reject the server under test.
func otherCA(t *testing.T) *x509.CertPool {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "unrelated-ca.example.com"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse certificate: %v", err)
	}

	pool := x509.NewCertPool()
	pool.AddCert(cert)

	return pool
}

func captureLogger() (*zerolog.Logger, *bytes.Buffer) {
	var buf bytes.Buffer
	logger := zerolog.New(&buf)

	return &logger, &buf
}

func TestConfigVerifiesByDefault(t *testing.T) {
	t.Parallel()

	server := newServer(t)
	logger, logs := captureLogger()

	err := get(t, server, Config(Policy{Target: "host01.example.com", Logger: logger}))

	var unknownAuthority x509.UnknownAuthorityError
	if !errors.As(err, &unknownAuthority) {
		t.Fatalf("default policy must verify the chain, got err=%v", err)
	}
	if logs.Len() != 0 {
		t.Fatalf("a verified config must not log a skip, got %q", logs.String())
	}
}

func TestConfigIgnoresInsecureBase(t *testing.T) {
	t.Parallel()

	server := newServer(t)
	base := &tls.Config{MinVersion: tls.VersionTLS12}
	base.InsecureSkipVerify = true

	err := get(t, server, Config(Policy{Base: base}))

	var unknownAuthority x509.UnknownAuthorityError
	if !errors.As(err, &unknownAuthority) {
		t.Fatalf("only Policy.InsecureSkipVerify may opt in, got err=%v", err)
	}
}

func TestConfigOptInSkipsVerificationAndLogs(t *testing.T) {
	t.Parallel()

	server := newServer(t)
	logger, logs := captureLogger()

	err := get(t, server, Config(Policy{
		InsecureSkipVerify: true,
		OptIn:              "test.insecure_skip_verify",
		Target:             "host01.example.com",
		Logger:             logger,
	}))
	if err != nil {
		t.Fatalf("explicit opt-in must reach a self-signed server: %v", err)
	}

	line := logs.String()
	for _, want := range []string{
		`"level":"warn"`,
		"verification disabled",
		`"tls_target":"host01.example.com"`,
		`"tls_opt_in":"test.insecure_skip_verify"`,
	} {
		if !strings.Contains(line, want) {
			t.Fatalf("skip log %q missing %q", line, want)
		}
	}
}

func TestConfigPinnedCAWinsOverOptIn(t *testing.T) {
	t.Parallel()

	server := newServer(t)

	trusted := x509.NewCertPool()
	trusted.AddCert(server.Certificate())

	cases := map[string]struct {
		roots   *x509.CertPool
		wantErr bool
	}{
		"matching pinned CA verifies": {roots: trusted},
		"wrong pinned CA rejects":     {roots: otherCA(t), wantErr: true},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			logger, logs := captureLogger()
			err := get(t, server, Config(Policy{
				PinnedRoots:        tc.roots,
				InsecureSkipVerify: true,
				Logger:             logger,
			}))
			if tc.wantErr && err == nil {
				t.Fatal("opt-in must not skip verification while a CA is pinned")
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("pinned CA should verify the server: %v", err)
			}
			if !strings.Contains(logs.String(), "opt-in ignored") {
				t.Fatalf("an overridden opt-in must be logged, got %q", logs.String())
			}
		})
	}
}

func TestConfigPinnedFingerprintWinsOverOptIn(t *testing.T) {
	t.Parallel()

	server := newServer(t)
	match := Fingerprint(server.Certificate().Raw)
	mismatch := FingerprintPrefix + strings.Repeat("0", 64)

	trusted := x509.NewCertPool()
	trusted.AddCert(server.Certificate())

	cases := map[string]struct {
		fingerprint string
		roots       *x509.CertPool
		wantErr     error
	}{
		"matching fingerprint verifies":          {fingerprint: match},
		"wrong fingerprint rejects":              {fingerprint: mismatch, wantErr: ErrFingerprintMismatch},
		"fingerprint is checked beside a CA pin": {fingerprint: mismatch, roots: trusted, wantErr: ErrFingerprintMismatch},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()

			err := get(t, server, Config(Policy{
				PinnedFingerprint:  tc.fingerprint,
				PinnedRoots:        tc.roots,
				InsecureSkipVerify: true,
			}))
			if tc.wantErr == nil && err != nil {
				t.Fatalf("pinned fingerprint should verify the server: %v", err)
			}
			if tc.wantErr != nil && !errors.Is(err, tc.wantErr) {
				t.Fatalf("err = %v, want %v", err, tc.wantErr)
			}
		})
	}
}
