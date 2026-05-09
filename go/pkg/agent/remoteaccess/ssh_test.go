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
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestOpenSSHPTYRoutesBytesResizeAndClose(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	session := &fakeSSHSession{
		stdout: strings.NewReader("login: "),
		stderr: strings.NewReader(""),
		waitCh: make(chan struct{}),
	}

	pty, err := OpenSSHPTY(ctx, SSHConfig{
		Target: SSHTarget{Host: "router.example", Port: 2222},
		Auth:   SSHAuth{Username: "admin", Password: "secret"},
		Cols:   132,
		Rows:   43,
	}, func(_ context.Context, cfg SSHConfig) (SSHSession, error) {
		if cfg.Target.Host != "router.example" || cfg.Target.Port != 2222 {
			t.Fatalf("target = %#v", cfg.Target)
		}
		if cfg.Auth.Username != "admin" || cfg.Auth.Password != "secret" {
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
	if string(output) != "login: " {
		t.Fatalf("output = %q", string(output))
	}

	if err := pty.Write([]byte("whoami\r")); err != nil {
		t.Fatalf("Write returned error: %v", err)
	}
	if err := pty.Resize(100, 30); err != nil {
		t.Fatalf("Resize returned error: %v", err)
	}

	waitForSSHTest(t, time.Second, func() bool {
		stdin, windowChanges := session.ioState()
		return stdin == "whoami\r" && len(windowChanges) == 1 && windowChanges[0] == [2]int{30, 100}
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
			cfg:  SSHConfig{Auth: SSHAuth{Username: "admin", Password: "secret"}},
			want: ErrMissingSSHTargetHost,
		},
		{
			name: "username",
			cfg:  SSHConfig{Target: SSHTarget{Host: "router.example"}, Auth: SSHAuth{Password: "secret"}},
			want: ErrSSHUsernameRequired,
		},
		{
			name: "credential",
			cfg:  SSHConfig{Target: SSHTarget{Host: "router.example"}, Auth: SSHAuth{Username: "admin"}},
			want: ErrSSHCredentialRequired,
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

func TestSSHHostKeyPolicyRequiresExplicitSkipVerifyUntilStoreExists(t *testing.T) {
	t.Parallel()

	if _, err := sshHostKeyCallback("known_hosts"); !errors.Is(err, ErrSSHHostKeyStoreUnavailable) {
		t.Fatalf("known_hosts error = %v, want %v", err, ErrSSHHostKeyStoreUnavailable)
	}
	if _, err := sshHostKeyCallback("trust_on_first_use"); !errors.Is(err, ErrSSHHostKeyStoreUnavailable) {
		t.Fatalf("trust_on_first_use error = %v, want %v", err, ErrSSHHostKeyStoreUnavailable)
	}
	if _, err := sshHostKeyCallback("skip_verify"); err != nil {
		t.Fatalf("skip_verify returned error: %v", err)
	}
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
