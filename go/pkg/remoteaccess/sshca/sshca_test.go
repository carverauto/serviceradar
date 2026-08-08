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

package sshca_test

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/carverauto/serviceradar/go/pkg/remoteaccess/sshca"
)

func TestSignUserCertificate(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 5, 9, 12, 0, 0, 0, time.UTC)
	caSigner, caPrivateKey := newTestSigner(t)
	userSigner, _ := newTestSigner(t)

	ca, err := sshca.New(privateKeyPEM(t, caPrivateKey), nil,
		sshca.WithClock(func() time.Time { return now }),
		sshca.WithMaxTTL(2*time.Hour),
	)
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}

	userPublicKey := ssh.MarshalAuthorizedKey(userSigner.PublicKey())
	signed, err := ca.SignUserCertificate(sshca.UserCertificateRequest{
		PublicKey:  userPublicKey,
		KeyID:      "session-1:actor-1:target-1",
		Principals: []string{" root ", "ubuntu", "root", ""},
		TTL:        time.Hour,
		Serial:     42,
	})
	if err != nil {
		t.Fatalf("SignUserCertificate returned error: %v", err)
	}

	publicKey, _, _, _, err := ssh.ParseAuthorizedKey(signed.AuthorizedKey)
	if err != nil {
		t.Fatalf("parse signed cert: %v", err)
	}
	cert, ok := publicKey.(*ssh.Certificate)
	if !ok {
		t.Fatalf("signed key type = %T, want *ssh.Certificate", publicKey)
	}

	if cert.CertType != ssh.UserCert {
		t.Fatalf("cert type = %d", cert.CertType)
	}
	if cert.Serial != 42 {
		t.Fatalf("serial = %d", cert.Serial)
	}
	if cert.KeyId != "session-1:actor-1:target-1" {
		t.Fatalf("key id = %q", cert.KeyId)
	}
	if got, want := cert.ValidPrincipals, []string{"root", "ubuntu"}; !equalStrings(got, want) {
		t.Fatalf("principals = %#v, want %#v", got, want)
	}
	if got, want := int64(cert.ValidAfter), now.Add(-sshca.DefaultBackdate).Unix(); got != want {
		t.Fatalf("valid after = %d, want %d", got, want)
	}
	if got, want := int64(cert.ValidBefore), now.Add(time.Hour).Unix(); got != want {
		t.Fatalf("valid before = %d, want %d", got, want)
	}
	if cert.Extensions["permit-pty"] != "" {
		t.Fatalf("extensions = %#v", cert.Extensions)
	}
	if !bytes.Equal(cert.SignatureKey.Marshal(), caSigner.PublicKey().Marshal()) {
		t.Fatal("certificate was not signed by CA public key")
	}
	if signed.ExpiresAt != now.Add(time.Hour) {
		t.Fatalf("expires at = %s", signed.ExpiresAt)
	}
	if signed.PublicKeyFingerprint != ssh.FingerprintSHA256(userSigner.PublicKey()) {
		t.Fatalf("fingerprint = %q", signed.PublicKeyFingerprint)
	}
}

func TestSignUserCertificateRejectsInvalidRequests(t *testing.T) {
	t.Parallel()

	caSigner, _ := newTestSigner(t)
	userSigner, _ := newTestSigner(t)
	ca := sshca.NewFromSigner(caSigner, sshca.WithClock(func() time.Time {
		return time.Date(2026, 5, 9, 12, 0, 0, 0, time.UTC)
	}), sshca.WithMaxTTL(time.Hour))

	validPublicKey := ssh.MarshalAuthorizedKey(userSigner.PublicKey())
	certPublicKey := signedPublicKey(t, caSigner, userSigner)

	tests := []struct {
		name string
		req  sshca.UserCertificateRequest
		want error
	}{
		{
			name: "public key",
			req:  sshca.UserCertificateRequest{KeyID: "session-1", Principals: []string{"root"}, TTL: time.Minute},
			want: sshca.ErrPublicKeyRequired,
		},
		{
			name: "public key is certificate",
			req: sshca.UserCertificateRequest{
				PublicKey:  certPublicKey,
				KeyID:      "session-1",
				Principals: []string{"root"},
				TTL:        time.Minute,
			},
			want: sshca.ErrPublicKeyIsCert,
		},
		{
			name: "key id",
			req:  sshca.UserCertificateRequest{PublicKey: validPublicKey, Principals: []string{"root"}, TTL: time.Minute},
			want: sshca.ErrKeyIDRequired,
		},
		{
			name: "principals",
			req:  sshca.UserCertificateRequest{PublicKey: validPublicKey, KeyID: "session-1", TTL: time.Minute},
			want: sshca.ErrPrincipalRequired,
		},
		{
			name: "ttl",
			req:  sshca.UserCertificateRequest{PublicKey: validPublicKey, KeyID: "session-1", Principals: []string{"root"}},
			want: sshca.ErrTTLRequired,
		},
		{
			name: "ttl maximum",
			req: sshca.UserCertificateRequest{
				PublicKey:  validPublicKey,
				KeyID:      "session-1",
				Principals: []string{"root"},
				TTL:        2 * time.Hour,
			},
			want: sshca.ErrTTLExceedsMaximum,
		},
		{
			name: "validity",
			req: sshca.UserCertificateRequest{
				PublicKey:  validPublicKey,
				KeyID:      "session-1",
				Principals: []string{"root"},
				TTL:        time.Minute,
				ValidAfter: time.Date(2026, 5, 10, 12, 0, 0, 0, time.UTC),
			},
			want: sshca.ErrInvalidValidity,
		},
		{
			name: "critical option",
			req: sshca.UserCertificateRequest{
				PublicKey:       validPublicKey,
				KeyID:           "session-1",
				Principals:      []string{"root"},
				TTL:             time.Minute,
				CriticalOptions: map[string]string{"force-command": "/bin/sh"},
			},
			want: sshca.ErrUnsupportedCritical,
		},
		{
			name: "extension",
			req: sshca.UserCertificateRequest{
				PublicKey:  validPublicKey,
				KeyID:      "session-1",
				Principals: []string{"root"},
				TTL:        time.Minute,
				Extensions: map[string]string{"permit-port-forwarding": ""},
			},
			want: sshca.ErrUnsupportedExtension,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			_, err := ca.SignUserCertificate(tt.req)
			if !errors.Is(err, tt.want) {
				t.Fatalf("error = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestSignUserCertificateRejectsWeakCASignerKey(t *testing.T) {
	t.Parallel()

	weakRSA, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate RSA key: %v", err)
	}
	caSigner, err := ssh.NewSignerFromKey(weakRSA)
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}
	userSigner, _ := newTestSigner(t)

	ca := sshca.NewFromSigner(caSigner, sshca.WithMaxTTL(time.Hour))
	_, err = ca.SignUserCertificate(sshca.UserCertificateRequest{
		PublicKey:  ssh.MarshalAuthorizedKey(userSigner.PublicKey()),
		KeyID:      "session-1",
		Principals: []string{"root"},
		TTL:        time.Minute,
	})
	if !errors.Is(err, sshca.ErrUnsupportedSignerKey) {
		t.Fatalf("error = %v, want %v", err, sshca.ErrUnsupportedSignerKey)
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

func signedPublicKey(t *testing.T, caSigner, userSigner ssh.Signer) []byte {
	t.Helper()

	cert := &ssh.Certificate{
		Key:             userSigner.PublicKey(),
		Serial:          7,
		CertType:        ssh.UserCert,
		KeyId:           "existing-cert",
		ValidPrincipals: []string{"root"},
		ValidAfter:      uint64(time.Now().Add(-time.Minute).Unix()),
		ValidBefore:     uint64(time.Now().Add(time.Minute).Unix()),
	}
	if err := cert.SignCert(rand.Reader, caSigner); err != nil {
		t.Fatalf("sign cert: %v", err)
	}
	return ssh.MarshalAuthorizedKey(cert)
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
