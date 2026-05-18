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

package agent

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
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

const fakeProxmoxConsolePrompt = "login: "

func TestRunProxmoxConsoleSSHRoutesBridgeFrames(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()

	bridge := newPluginProxmoxConsoleBridge(nil)
	if _, err := bridge.Open(ctx, pluginProxmoxConsoleOpenRequest{TerminalType: "xterm-256color"}); err != nil {
		t.Fatalf("open bridge: %v", err)
	}

	session := &fakeProxmoxConsoleSSHSession{
		waitCh: make(chan struct{}),
		stdout: strings.NewReader(fakeProxmoxConsolePrompt),
		stderr: strings.NewReader(""),
	}
	done := make(chan error, 1)
	go func() {
		done <- runProxmoxConsoleSSH(ctx, proxmoxConsoleSSHConfig{
			Console: proxmoxConsoleSessionSpec{Cols: 120, Rows: 40},
			Target:  proxmoxConsoleSSHTarget{Hostname: "pve.example"},
			SSH:     proxmoxConsoleSSHAuth{Username: "root", Password: "secret"},
		}, bridge, func(context.Context, proxmoxConsoleSSHConfig) (proxmoxConsoleSSHSession, error) {
			return session, nil
		})
	}()

	output, err := bridge.Read(ctx)
	if err != nil {
		t.Fatalf("read bridge output: %v", err)
	}
	if string(output) != fakeProxmoxConsolePrompt {
		t.Fatalf("unexpected bridge output %q", string(output))
	}

	if err := bridge.Write([]byte(fakeProxmoxConsoleCommand)); err != nil {
		t.Fatalf("write bridge input: %v", err)
	}
	if err := bridge.Resize(132, 43); err != nil {
		t.Fatalf("resize bridge: %v", err)
	}

	waitFor(t, time.Second, func() bool {
		stdin, windowChanges := session.ioState()
		return stdin == fakeProxmoxConsoleCommand &&
			len(windowChanges) == 1 &&
			windowChanges[0] == [2]int{43, 132}
	})

	ptyRows, ptyCols, shellStarted := session.ptyState()
	if ptyRows != 40 || ptyCols != 120 || !shellStarted {
		t.Fatalf("unexpected session state rows=%d cols=%d shell=%t", ptyRows, ptyCols, shellStarted)
	}

	_ = bridge.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("runProxmoxConsoleSSH returned error: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for SSH connector shutdown")
	}
	if !session.isClosed() {
		t.Fatal("expected SSH session to close")
	}
}

func TestRunProxmoxConsoleSSHRejectsInvalidConfigBeforeDial(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		cfg  proxmoxConsoleSSHConfig
		want error
	}{
		{
			name: "invalid target port",
			cfg: proxmoxConsoleSSHConfig{
				Target: proxmoxConsoleSSHTarget{Hostname: "pve.example", SSHPort: 70_000},
				SSH:    proxmoxConsoleSSHAuth{Username: "root", Password: "secret"},
			},
			want: errInvalidProxmoxSSHTargetPort,
		},
		{
			name: "oversized host",
			cfg: proxmoxConsoleSSHConfig{
				Target: proxmoxConsoleSSHTarget{Hostname: strings.Repeat("a", maxProxmoxSSHTargetHostBytes+1)},
				SSH:    proxmoxConsoleSSHAuth{Username: "root", Password: "secret"},
			},
			want: errInvalidProxmoxSSHFieldSize,
		},
		{
			name: "oversized private key",
			cfg: proxmoxConsoleSSHConfig{
				Target: proxmoxConsoleSSHTarget{Hostname: "pve.example"},
				SSH: proxmoxConsoleSSHAuth{
					Username:   "root",
					PrivateKey: strings.Repeat("k", maxProxmoxSSHPrivateKeyBytes+1),
				},
			},
			want: errInvalidProxmoxSSHFieldSize,
		},
		{
			name: "missing credential",
			cfg: proxmoxConsoleSSHConfig{
				Target: proxmoxConsoleSSHTarget{Hostname: "pve.example"},
				SSH:    proxmoxConsoleSSHAuth{Username: "root"},
			},
			want: errProxmoxSSHCredentialRequired,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			bridge := newPluginProxmoxConsoleBridge(nil)
			if _, err := bridge.Open(t.Context(), pluginProxmoxConsoleOpenRequest{}); err != nil {
				t.Fatalf("open bridge: %v", err)
			}

			dialCalled := false
			err := runProxmoxConsoleSSH(t.Context(), tt.cfg, bridge, func(context.Context, proxmoxConsoleSSHConfig) (proxmoxConsoleSSHSession, error) {
				dialCalled = true
				return nil, nil
			})
			if !errors.Is(err, tt.want) {
				t.Fatalf("runProxmoxConsoleSSH error = %v, want %v", err, tt.want)
			}
			if dialCalled {
				t.Fatal("dialer was called for invalid config")
			}
		})
	}
}

func TestRunProxmoxConsoleSSHDialFailureDoesNotLeakErrorToTerminal(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()

	bridge := newPluginProxmoxConsoleBridge(nil)
	if _, err := bridge.Open(ctx, pluginProxmoxConsoleOpenRequest{}); err != nil {
		t.Fatalf("open bridge: %v", err)
	}

	dialErr := errors.New("auth failed for root using secret token")
	err := runProxmoxConsoleSSH(ctx, proxmoxConsoleSSHConfig{
		Console: proxmoxConsoleSessionSpec{Cols: 120, Rows: 40},
		Target:  proxmoxConsoleSSHTarget{Hostname: "pve.example"},
		SSH:     proxmoxConsoleSSHAuth{Username: "root", Password: "secret"},
	}, bridge, func(context.Context, proxmoxConsoleSSHConfig) (proxmoxConsoleSSHSession, error) {
		return nil, dialErr
	})
	if !errors.Is(err, dialErr) {
		t.Fatalf("runProxmoxConsoleSSH error = %v, want %v", err, dialErr)
	}

	output, readErr := bridge.Read(ctx)
	if readErr != nil {
		t.Fatalf("read bridge output: %v", readErr)
	}
	if string(output) != proxmoxSSHConsoleUnavailableMessage {
		t.Fatalf("terminal output = %q, want %q", string(output), proxmoxSSHConsoleUnavailableMessage)
	}
	if strings.Contains(string(output), "secret") || strings.Contains(string(output), "root") {
		t.Fatalf("terminal output leaked sensitive detail: %q", string(output))
	}
}

func TestProxmoxConsoleSSHHostKeyPolicyUsesSharedKnownHostsStore(t *testing.T) {
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
	line := knownhosts.Line([]string{knownhosts.Normalize("pve.example:2222")}, signer.PublicKey())
	if err := os.WriteFile(knownHostsPath, []byte(line+"\n"), 0o600); err != nil {
		t.Fatalf("write known_hosts: %v", err)
	}

	callback, err := proxmoxConsoleSSHHostKeyCallback("known_hosts", knownHostsPath)
	if err != nil {
		t.Fatalf("known_hosts callback: %v", err)
	}
	if err := callback("pve.example:2222", &net.TCPAddr{IP: net.ParseIP("192.0.2.20"), Port: 2222}, signer.PublicKey()); err != nil {
		t.Fatalf("known_hosts callback rejected pinned key: %v", err)
	}
}

func TestProxmoxConsoleSSHHostKeyPolicyTrustOnFirstUsePinsUnknownHost(t *testing.T) {
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
	callback, err := proxmoxConsoleSSHHostKeyCallback("trust_on_first_use", knownHostsPath)
	if err != nil {
		t.Fatalf("trust_on_first_use callback: %v", err)
	}
	if err := callback("pve.example:2222", &net.TCPAddr{IP: net.ParseIP("192.0.2.20"), Port: 2222}, signer.PublicKey()); err != nil {
		t.Fatalf("first use rejected key: %v", err)
	}

	data, err := os.ReadFile(knownHostsPath)
	if err != nil {
		t.Fatalf("read known_hosts: %v", err)
	}
	if !strings.Contains(string(data), signer.PublicKey().Type()) {
		t.Fatalf("known_hosts did not contain pinned key: %q", string(data))
	}
}

func waitFor(t *testing.T, timeout time.Duration, predicate func() bool) {
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

type fakeProxmoxConsoleSSHSession struct {
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

func (f *fakeProxmoxConsoleSSHSession) StdinPipe() (io.WriteCloser, error) {
	return fakeProxmoxConsoleSSHStdin{session: f}, nil
}

func (f *fakeProxmoxConsoleSSHSession) StdoutPipe() (io.Reader, error) { return f.stdout, nil }
func (f *fakeProxmoxConsoleSSHSession) StderrPipe() (io.Reader, error) { return f.stderr, nil }

func (f *fakeProxmoxConsoleSSHSession) RequestPty(_ string, h, w int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ptyRows = h
	f.ptyCols = w
	return nil
}

func (f *fakeProxmoxConsoleSSHSession) WindowChange(h, w int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.windowChanges = append(f.windowChanges, [2]int{h, w})
	return nil
}

func (f *fakeProxmoxConsoleSSHSession) Shell() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.shellStarted = true
	return nil
}

func (f *fakeProxmoxConsoleSSHSession) Wait() error {
	<-f.waitCh
	return nil
}

func (f *fakeProxmoxConsoleSSHSession) Close() error {
	f.mu.Lock()
	f.closed = true
	f.mu.Unlock()
	f.waitOnce.Do(func() { close(f.waitCh) })
	return nil
}

func (f *fakeProxmoxConsoleSSHSession) ioState() (string, [][2]int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	windowChanges := append([][2]int(nil), f.windowChanges...)
	return f.stdin.String(), windowChanges
}

func (f *fakeProxmoxConsoleSSHSession) ptyState() (int, int, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.ptyRows, f.ptyCols, f.shellStarted
}

func (f *fakeProxmoxConsoleSSHSession) isClosed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closed
}

type fakeProxmoxConsoleSSHStdin struct {
	session *fakeProxmoxConsoleSSHSession
}

func (s fakeProxmoxConsoleSSHStdin) Write(p []byte) (int, error) {
	s.session.mu.Lock()
	defer s.session.mu.Unlock()
	return s.session.stdin.Write(p)
}

func (s fakeProxmoxConsoleSSHStdin) Close() error { return nil }
