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

package remoteaccess

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

const (
	fakeSSHPrompt     = "login: "
	fakeSSHCommand    = "whoami\r"
	fakeSSHTargetHost = "router.example"
	fakeSSHUsername   = "admin"
)

func TestOpenSSHPTYRoutesBytesResizeAndClose(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	session := &fakeSSHSession{
		stdout: strings.NewReader(fakeSSHPrompt),
		stderr: strings.NewReader(""),
		waitCh: make(chan struct{}),
	}

	pty, err := OpenSSHPTY(ctx, SSHConfig{
		Target: SSHTarget{Host: fakeSSHTargetHost, Port: 2222},
		Auth:   SSHAuth{Username: fakeSSHUsername, Password: "secret"},
		Cols:   132,
		Rows:   43,
	}, func(_ context.Context, cfg SSHConfig) (SSHSession, error) {
		if cfg.Target.Host != fakeSSHTargetHost || cfg.Target.Port != 2222 {
			t.Fatalf("target = %#v", cfg.Target)
		}
		if cfg.Auth.Username != fakeSSHUsername || cfg.Auth.Password != "secret" {
			t.Fatalf("auth = %#v", cfg.Auth)
		}
		return session, nil
	})
	if err != nil {
		t.Fatalf("OpenSSHPTY returned error: %v", err)
	}

	output, err := pty.Read(ctx)
	if err != nil {
		t.Fatalf("Read returned error: %v", err)
	}
	if string(output) != fakeSSHPrompt {
		t.Fatalf("output = %q", string(output))
	}

	if err := pty.Write([]byte(fakeSSHCommand)); err != nil {
		t.Fatalf("Write returned error: %v", err)
	}
	if err := pty.Resize(100, 30); err != nil {
		t.Fatalf("Resize returned error: %v", err)
	}

	waitForSSHTest(t, time.Second, func() bool {
		stdin, windowChanges := session.ioState()
		return stdin == fakeSSHCommand && len(windowChanges) == 1 && windowChanges[0] == [2]int{30, 100}
	})

	rows, cols, shellStarted := session.ptyState()
	if rows != 43 || cols != 132 || !shellStarted {
		t.Fatalf("pty rows=%d cols=%d shell=%t", rows, cols, shellStarted)
	}

	if err := pty.Close(); err != nil {
		t.Fatalf("Close returned error: %v", err)
	}
	if !session.isClosed() {
		t.Fatal("expected SSH session to close")
	}
}

func TestOpenSSHPTYValidatesConfig(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		cfg  SSHConfig
		want error
	}{
		{
			name: "target",
			cfg:  SSHConfig{Auth: SSHAuth{Username: fakeSSHUsername, Password: "secret"}},
			want: ErrMissingSSHTargetHost,
		},
		{
			name: "username",
			cfg:  SSHConfig{Target: SSHTarget{Host: fakeSSHTargetHost}, Auth: SSHAuth{Password: "secret"}},
			want: ErrSSHUsernameRequired,
		},
		{
			name: "credential",
			cfg:  SSHConfig{Target: SSHTarget{Host: fakeSSHTargetHost}, Auth: SSHAuth{Username: fakeSSHUsername}},
			want: ErrSSHCredentialRequired,
		},
		{
			name: "certificate requires private key",
			cfg: SSHConfig{
				Target: SSHTarget{Host: fakeSSHTargetHost},
				Auth:   SSHAuth{Username: fakeSSHUsername, Certificate: "ssh-ed25519-cert-v01@openssh.com AAAA"},
			},
			want: ErrSSHCertificateRequiresKey,
		},
		{
			name: "invalid target port",
			cfg: SSHConfig{
				Target: SSHTarget{Host: fakeSSHTargetHost, Port: 70_000},
				Auth:   SSHAuth{Username: fakeSSHUsername, Password: "secret"},
			},
			want: ErrInvalidSSHTargetPort,
		},
		{
			name: "oversized host",
			cfg: SSHConfig{
				Target: SSHTarget{Host: strings.Repeat("a", maxSSHTargetHostBytes+1)},
				Auth:   SSHAuth{Username: fakeSSHUsername, Password: "secret"},
			},
			want: ErrInvalidSSHFieldSize,
		},
		{
			name: "oversized terminal type",
			cfg: SSHConfig{
				Target:       SSHTarget{Host: fakeSSHTargetHost},
				Auth:         SSHAuth{Username: fakeSSHUsername, Password: "secret"},
				TerminalType: strings.Repeat("x", maxSSHTerminalTypeBytes+1),
			},
			want: ErrInvalidSSHFieldSize,
		},
		{
			name: "oversized private key",
			cfg: SSHConfig{
				Target: SSHTarget{Host: fakeSSHTargetHost},
				Auth: SSHAuth{
					Username:   fakeSSHUsername,
					PrivateKey: strings.Repeat("k", maxSSHPrivateKeyBytes+1),
				},
			},
			want: ErrInvalidSSHFieldSize,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			_, err := OpenSSHPTY(context.Background(), tt.cfg, func(context.Context, SSHConfig) (SSHSession, error) {
				t.Fatal("dialer should not be called for invalid config")
				return nil, nil
			})
			if !errors.Is(err, tt.want) {
				t.Fatalf("error = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestSSHSignerWrapsOpenSSHCertificate(t *testing.T) {
	t.Parallel()

	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}

	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}

	cert := &ssh.Certificate{
		Key:             signer.PublicKey(),
		Serial:          1234,
		CertType:        ssh.UserCert,
		KeyId:           "session-1",
		ValidPrincipals: []string{fakeSSHUsername},
		ValidAfter:      uint64(time.Now().Add(-time.Minute).Unix()),
		ValidBefore:     uint64(time.Now().Add(time.Hour).Unix()),
		Permissions: ssh.Permissions{
			Extensions: map[string]string{"permit-pty": ""},
		},
	}
	if err := cert.SignCert(rand.Reader, signer); err != nil {
		t.Fatalf("sign cert: %v", err)
	}

	certSigner, err := sshSigner(privateKeyPEM(t, privateKey), "", string(ssh.MarshalAuthorizedKey(cert)))
	if err != nil {
		t.Fatalf("sshSigner returned error: %v", err)
	}

	if got := certSigner.PublicKey().Type(); got != ssh.CertAlgoED25519v01 {
		t.Fatalf("public key type = %q, want %q", got, ssh.CertAlgoED25519v01)
	}
}

func TestSSHSignerRejectsCertificateForDifferentKey(t *testing.T) {
	t.Parallel()

	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate private key: %v", err)
	}
	_, otherPrivateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate other key: %v", err)
	}

	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}
	otherSigner, err := ssh.NewSignerFromKey(otherPrivateKey)
	if err != nil {
		t.Fatalf("new other signer: %v", err)
	}

	cert := &ssh.Certificate{
		Key:             otherSigner.PublicKey(),
		Serial:          1234,
		CertType:        ssh.UserCert,
		KeyId:           "session-1",
		ValidPrincipals: []string{fakeSSHUsername},
		ValidAfter:      uint64(time.Now().Add(-time.Minute).Unix()),
		ValidBefore:     uint64(time.Now().Add(time.Hour).Unix()),
	}
	if err := cert.SignCert(rand.Reader, signer); err != nil {
		t.Fatalf("sign cert: %v", err)
	}

	_, err = sshSigner(privateKeyPEM(t, privateKey), "", string(ssh.MarshalAuthorizedKey(cert)))
	if !errors.Is(err, ErrSSHCertificateKeyMismatch) {
		t.Fatalf("sshSigner error = %v, want %v", err, ErrSSHCertificateKeyMismatch)
	}
}

func TestSSHSignerRejectsHostCertificate(t *testing.T) {
	t.Parallel()

	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}

	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}

	cert := &ssh.Certificate{
		Key:             signer.PublicKey(),
		Serial:          1234,
		CertType:        ssh.HostCert,
		KeyId:           "session-1",
		ValidPrincipals: []string{fakeSSHTargetHost},
		ValidAfter:      uint64(time.Now().Add(-time.Minute).Unix()),
		ValidBefore:     uint64(time.Now().Add(time.Hour).Unix()),
	}
	if err := cert.SignCert(rand.Reader, signer); err != nil {
		t.Fatalf("sign cert: %v", err)
	}

	_, err = sshSigner(privateKeyPEM(t, privateKey), "", string(ssh.MarshalAuthorizedKey(cert)))
	if !errors.Is(err, ErrInvalidSSHCertificate) {
		t.Fatalf("sshSigner error = %v, want %v", err, ErrInvalidSSHCertificate)
	}
}

func TestSSHHostKeyPolicyUsesKnownHostsFile(t *testing.T) {
	t.Parallel()

	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}
	knownHostsPath := filepath.Join(t.TempDir(), "known_hosts")
	hostAddress := knownhosts.Normalize("router.example:2222")
	line := knownhosts.Line([]string{hostAddress}, signer.PublicKey())
	if err := os.WriteFile(knownHostsPath, []byte(line+"\n"), 0o600); err != nil {
		t.Fatalf("write known_hosts: %v", err)
	}

	callback, err := sshHostKeyCallback("known_hosts", knownHostsPath)
	if err != nil {
		t.Fatalf("known_hosts callback: %v", err)
	}
	if err := callback("router.example:2222", &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 2222}, signer.PublicKey()); err != nil {
		t.Fatalf("known_hosts callback returned error: %v", err)
	}

	if callback, err = sshHostKeyCallback("skip_verify", ""); err != nil {
		t.Fatalf("skip_verify returned error: %v", err)
	} else if callback == nil {
		t.Fatal("skip_verify returned nil callback")
	}
}

func TestSSHHostKeyPolicyTrustOnFirstUsePinsUnknownHost(t *testing.T) {
	t.Parallel()

	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}
	knownHostsPath := filepath.Join(t.TempDir(), "known_hosts")

	callback, err := sshHostKeyCallback("trust_on_first_use", knownHostsPath)
	if err != nil {
		t.Fatalf("trust_on_first_use callback: %v", err)
	}
	if err := callback("router.example:2222", &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 2222}, signer.PublicKey()); err != nil {
		t.Fatalf("first use returned error: %v", err)
	}
	if data, err := os.ReadFile(knownHostsPath); err != nil {
		t.Fatalf("read known_hosts: %v", err)
	} else if !strings.Contains(string(data), signer.PublicKey().Type()) {
		t.Fatalf("known_hosts did not contain pinned key: %q", string(data))
	}

	callback, err = sshHostKeyCallback("known_hosts", knownHostsPath)
	if err != nil {
		t.Fatalf("known_hosts callback: %v", err)
	}
	if err := callback("router.example:2222", &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 2222}, signer.PublicKey()); err != nil {
		t.Fatalf("known_hosts did not accept TOFU-pinned key: %v", err)
	}
}

func TestSSHHostKeyPolicyRejectsChangedTrustOnFirstUseKey(t *testing.T) {
	t.Parallel()

	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	_, changedPrivateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate changed key: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatalf("new signer: %v", err)
	}
	changedSigner, err := ssh.NewSignerFromKey(changedPrivateKey)
	if err != nil {
		t.Fatalf("new changed signer: %v", err)
	}
	knownHostsPath := filepath.Join(t.TempDir(), "known_hosts")
	line := knownhosts.Line([]string{knownhosts.Normalize("router.example:2222")}, signer.PublicKey())
	if err := os.WriteFile(knownHostsPath, []byte(line+"\n"), 0o600); err != nil {
		t.Fatalf("write known_hosts: %v", err)
	}

	callback, err := sshHostKeyCallback("trust_on_first_use", knownHostsPath)
	if err != nil {
		t.Fatalf("trust_on_first_use callback: %v", err)
	}
	if err := callback("router.example:2222", &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 2222}, changedSigner.PublicKey()); err == nil {
		t.Fatal("expected changed TOFU key to be rejected")
	}
}

func TestSSHHostKeyPolicyRejectsUnsupportedPolicy(t *testing.T) {
	t.Parallel()

	if _, err := sshHostKeyCallback("accept_anything", ""); !errors.Is(err, ErrUnsupportedSSHHostKeyPolicy) {
		t.Fatalf("unsupported policy error = %v, want %v", err, ErrUnsupportedSSHHostKeyPolicy)
	}
}

func privateKeyPEM(t *testing.T, key ed25519.PrivateKey) string {
	t.Helper()

	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal private key: %v", err)
	}

	return string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
}

func waitForSSHTest(t *testing.T, timeout time.Duration, predicate func() bool) {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if predicate() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("condition was not met before timeout")
}

type fakeSSHSession struct {
	mu            sync.Mutex
	stdin         bytes.Buffer
	stdout        io.Reader
	stderr        io.Reader
	ptyRows       int
	ptyCols       int
	windowChanges [][2]int
	shellStarted  bool
	closed        bool
	waitCh        chan struct{}
	waitOnce      sync.Once
}

func (f *fakeSSHSession) StdinPipe() (io.WriteCloser, error) {
	return fakeSSHStdin{session: f}, nil
}

func (f *fakeSSHSession) StdoutPipe() (io.Reader, error) { return f.stdout, nil }
func (f *fakeSSHSession) StderrPipe() (io.Reader, error) { return f.stderr, nil }

func (f *fakeSSHSession) RequestPty(_ string, h, w int) error {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.ptyRows = h
	f.ptyCols = w

	return nil
}

func (f *fakeSSHSession) WindowChange(h, w int) error {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.windowChanges = append(f.windowChanges, [2]int{h, w})

	return nil
}

func (f *fakeSSHSession) Shell() error {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.shellStarted = true

	return nil
}

func (f *fakeSSHSession) Wait() error {
	<-f.waitCh
	return nil
}

func (f *fakeSSHSession) Close() error {
	f.mu.Lock()
	f.closed = true
	f.mu.Unlock()

	f.waitOnce.Do(func() { close(f.waitCh) })

	return nil
}

func (f *fakeSSHSession) ioState() (string, [][2]int) {
	f.mu.Lock()
	defer f.mu.Unlock()

	windowChanges := append([][2]int(nil), f.windowChanges...)

	return f.stdin.String(), windowChanges
}

func (f *fakeSSHSession) ptyState() (int, int, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()

	return f.ptyRows, f.ptyCols, f.shellStarted
}

func (f *fakeSSHSession) isClosed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()

	return f.closed
}

type fakeSSHStdin struct {
	session *fakeSSHSession
}

func (s fakeSSHStdin) Write(p []byte) (int, error) {
	s.session.mu.Lock()
	defer s.session.mu.Unlock()

	return s.session.stdin.Write(p)
}

func (s fakeSSHStdin) Close() error { return nil }
