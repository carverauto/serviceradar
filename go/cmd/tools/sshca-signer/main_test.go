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

package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
)

const testCAKeyEnv = "SR_TEST_CA_KEY"

func TestRunSignsCertificateFromJSONRequest(t *testing.T) {
	t.Parallel()

	caSigner, caPrivateKey := newTestSigner(t)
	userSigner, _ := newTestSigner(t)

	request := signRequest{
		PublicKey:  strings.TrimSpace(string(ssh.MarshalAuthorizedKey(userSigner.PublicKey()))),
		KeyID:      "sr:remote-access:session-1:user-1:agent-1:ssh:device-1",
		Principals: []string{"ubuntu"},
		TTLSeconds: 900,
		Serial:     42,
	}
	stdin := new(bytes.Buffer)
	if err := json.NewEncoder(stdin).Encode(request); err != nil {
		t.Fatalf("encode request: %v", err)
	}

	var stdout, stderr bytes.Buffer
	exitCode := run(
		[]string{"--ca-key-env=" + testCAKeyEnv, "--max-ttl=1h"},
		stdin,
		&stdout,
		&stderr,
		func(key string) string {
			if key == testCAKeyEnv {
				return string(privateKeyPEM(t, caPrivateKey))
			}
			return ""
		},
	)
	if exitCode != 0 {
		t.Fatalf("run exit code = %d, stderr = %s", exitCode, stderr.String())
	}

	var response signResponse
	if err := json.Unmarshal(stdout.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if response.Serial != 42 {
		t.Fatalf("serial = %d, want 42", response.Serial)
	}
	if response.Fingerprint != ssh.FingerprintSHA256(userSigner.PublicKey()) {
		t.Fatalf("fingerprint = %q", response.Fingerprint)
	}
	if response.ExpiresAt == "" {
		t.Fatal("expires_at is empty")
	}
	if response.CAKeySource != caKeySourceEnv {
		t.Fatalf("ca_key_source = %q, want %q", response.CAKeySource, caKeySourceEnv)
	}
	if response.CAKeyFingerprint != ssh.FingerprintSHA256(caSigner.PublicKey()) {
		t.Fatalf("ca_key_fingerprint = %q", response.CAKeyFingerprint)
	}

	publicKey, _, _, _, err := ssh.ParseAuthorizedKey([]byte(response.Certificate))
	if err != nil {
		t.Fatalf("parse certificate: %v", err)
	}
	cert, ok := publicKey.(*ssh.Certificate)
	if !ok {
		t.Fatalf("certificate key type = %T, want *ssh.Certificate", publicKey)
	}
	if cert.KeyId != request.KeyID {
		t.Fatalf("key id = %q, want %q", cert.KeyId, request.KeyID)
	}
	if got, want := cert.ValidPrincipals, []string{"ubuntu"}; !equalStrings(got, want) {
		t.Fatalf("principals = %#v, want %#v", got, want)
	}
}

func TestRunRejectsMissingCAKey(t *testing.T) {
	t.Parallel()

	var stdout, stderr bytes.Buffer
	exitCode := run(
		[]string{"--ca-key-env=" + testCAKeyEnv},
		strings.NewReader(`{}`),
		&stdout,
		&stderr,
		func(string) string { return "" },
	)
	if exitCode != 2 {
		t.Fatalf("run exit code = %d, want 2", exitCode)
	}
	if !strings.Contains(stderr.String(), "CA key is required") {
		t.Fatalf("stderr = %q", stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("stdout = %q, want empty", stdout.String())
	}
}

func TestRunWritesCAKeyLoadAuditEvent(t *testing.T) {
	t.Parallel()

	caSigner, caPrivateKey := newTestSigner(t)
	userSigner, _ := newTestSigner(t)
	auditFile := filepath.Join(t.TempDir(), "sshca-audit.jsonl")

	request := signRequest{
		PublicKey:  strings.TrimSpace(string(ssh.MarshalAuthorizedKey(userSigner.PublicKey()))),
		KeyID:      "sr:remote-access:session-2:user-1:agent-1:ssh:device-1",
		Principals: []string{"ubuntu"},
		TTLSeconds: 300,
	}
	stdin := new(bytes.Buffer)
	if err := json.NewEncoder(stdin).Encode(request); err != nil {
		t.Fatalf("encode request: %v", err)
	}

	var stdout, stderr bytes.Buffer
	exitCode := run(
		[]string{"--ca-key-env=" + testCAKeyEnv, "--audit-file=" + auditFile},
		stdin,
		&stdout,
		&stderr,
		func(key string) string {
			if key == testCAKeyEnv {
				return string(privateKeyPEM(t, caPrivateKey))
			}
			return ""
		},
	)
	if exitCode != 0 {
		t.Fatalf("run exit code = %d, stderr = %s", exitCode, stderr.String())
	}

	auditBytes, err := os.ReadFile(auditFile)
	if err != nil {
		t.Fatalf("read audit file: %v", err)
	}

	var event map[string]any
	if err := json.Unmarshal(auditBytes, &event); err != nil {
		t.Fatalf("decode audit event: %v", err)
	}
	if event["event"] != auditEventCAKeyLoaded {
		t.Fatalf("event = %v, want %q", event["event"], auditEventCAKeyLoaded)
	}
	if event["ca_key_source"] != caKeySourceEnv {
		t.Fatalf("ca_key_source = %v, want %q", event["ca_key_source"], caKeySourceEnv)
	}
	if event["ca_key_fingerprint"] != ssh.FingerprintSHA256(caSigner.PublicKey()) {
		t.Fatalf("ca_key_fingerprint = %v", event["ca_key_fingerprint"])
	}
	if _, exists := event["ca_key_path"]; exists {
		t.Fatal("audit event leaked ca_key_path")
	}
}

func newTestSigner(t *testing.T) (ssh.Signer, ed25519.PrivateKey) {
	t.Helper()

	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}
	return signer, privateKey
}

func privateKeyPEM(t *testing.T, key ed25519.PrivateKey) []byte {
	t.Helper()

	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal private key: %v", err)
	}

	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
