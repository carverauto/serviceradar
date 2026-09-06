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

var (
	errTestProxmoxConsoleSSHDialAuthFailed         = errors.New("auth failed for root using secret token")
	errTestProxmoxConsoleSSHUnexpectedPassword     = errors.New("unexpected password")
	errTestProxmoxConsoleSSHExpectedSessionChannel = errors.New("expected SSH session channel")
	errTestProxmoxConsoleSSHInputNotReceived       = errors.New("terminal input did not reach SSH peer")
	errTestProxmoxConsoleSSHShellNotRequested      = errors.New("shell was not requested")
)

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
			Console:          proxmoxConsoleSessionSpec{Cols: 120, Rows: 40},
			Target:           proxmoxConsoleSSHTarget{Hostname: "pve.example"},
			SSH:              proxmoxConsoleSSHAuth{Username: "root", Password: "secret"},
			SSHHostKeyPolicy: proxmoxSSHHostKeyPolicyKnownHosts,
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

func TestRunProxmoxConsoleSSHRedactsDialErrorFromTerminal(t *testing.T) {
	t.Parallel()

	bridge := newPluginProxmoxConsoleBridge(nil)
	if _, err := bridge.Open(t.Context(), pluginProxmoxConsoleOpenRequest{}); err != nil {
		t.Fatalf("open bridge: %v", err)
	}

	err := runProxmoxConsoleSSH(t.Context(), proxmoxConsoleSSHConfig{
		Console:          proxmoxConsoleSessionSpec{Cols: 120, Rows: 40},
		Target:           proxmoxConsoleSSHTarget{Hostname: "pve.example"},
		SSH:              proxmoxConsoleSSHAuth{Username: "root", Password: "secret"},
		SSHHostKeyPolicy: proxmoxSSHHostKeyPolicyKnownHosts,
	}, bridge, func(context.Context, proxmoxConsoleSSHConfig) (proxmoxConsoleSSHSession, error) {
		return nil, errTestProxmoxConsoleSSHDialAuthFailed
	})
	if !errors.Is(err, errTestProxmoxConsoleSSHDialAuthFailed) {
		t.Fatalf("runProxmoxConsoleSSH error = %v, want %v", err, errTestProxmoxConsoleSSHDialAuthFailed)
	}

	output, readErr := bridge.Read(t.Context())
	if readErr != nil {
		t.Fatalf("read bridge output: %v", readErr)
	}
	if got := string(output); got != "SSH console unavailable\r\n" {
		t.Fatalf("terminal output = %q", got)
	}
	if strings.Contains(string(output), "secret") || strings.Contains(string(output), "root") {
		t.Fatalf("terminal output leaked raw dial error: %q", string(output))
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
		{
			name: "missing host key policy",
			cfg: proxmoxConsoleSSHConfig{
				Target: proxmoxConsoleSSHTarget{Hostname: "pve.example"},
				SSH:    proxmoxConsoleSSHAuth{Username: "root", Password: "secret"},
			},
			want: errUnsupportedProxmoxSSHHostKeyPolicy,
		},
		{
			name: "skip verify host key policy",
			cfg: proxmoxConsoleSSHConfig{
				Target:           proxmoxConsoleSSHTarget{Hostname: "pve.example"},
				SSH:              proxmoxConsoleSSHAuth{Username: "root", Password: "secret"},
				SSHHostKeyPolicy: "skip_verify",
			},
			want: errUnsupportedProxmoxSSHHostKeyPolicy,
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

	err := runProxmoxConsoleSSH(ctx, proxmoxConsoleSSHConfig{
		Console:          proxmoxConsoleSessionSpec{Cols: 120, Rows: 40},
		Target:           proxmoxConsoleSSHTarget{Hostname: "pve.example"},
		SSH:              proxmoxConsoleSSHAuth{Username: "root", Password: "secret"},
		SSHHostKeyPolicy: proxmoxSSHHostKeyPolicyKnownHosts,
	}, bridge, func(context.Context, proxmoxConsoleSSHConfig) (proxmoxConsoleSSHSession, error) {
		return nil, errTestProxmoxConsoleSSHDialAuthFailed
	})
	if !errors.Is(err, errTestProxmoxConsoleSSHDialAuthFailed) {
		t.Fatalf("runProxmoxConsoleSSH error = %v, want %v", err, errTestProxmoxConsoleSSHDialAuthFailed)
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

func TestProxmoxConsoleSSHHostKeyCallbackRejectsSkipVerifyAtLeaf(t *testing.T) {
	t.Parallel()

	for _, policy := range []string{"", "skip_verify", "accept_any"} {
		if callback, err := proxmoxConsoleSSHHostKeyCallback(policy, ""); !errors.Is(err, errUnsupportedProxmoxSSHHostKeyPolicy) || callback != nil {
			t.Fatalf("policy %q callback=%v err=%v, want leaf denial", policy, callback, err)
		}
	}
}

func TestDialProxmoxConsoleSSHRevocationCancelsStalledHandshake(t *testing.T) {
	t.Parallel()

	var listenConfig net.ListenConfig
	listener, err := listenConfig.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer func() { _ = listener.Close() }()

	accepted := make(chan net.Conn, 1)
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			accepted <- conn
		}
	}()

	address := listener.Addr().(*net.TCPAddr)
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() {
		_, dialErr := dialProxmoxConsoleSSH(ctx, proxmoxConsoleSSHConfig{
			Target: proxmoxConsoleSSHTarget{
				IP:      address.IP.String(),
				SSHPort: address.Port,
			},
			SSH:              proxmoxConsoleSSHAuth{Username: "root", Password: "secret"},
			SSHHostKeyPolicy: proxmoxSSHHostKeyPolicyTrustFirstUse,
			KnownHostsPath:   filepath.Join(t.TempDir(), "known_hosts"),
			TimeoutMS:        30_000,
		})
		done <- dialErr
	}()

	var serverConn net.Conn
	select {
	case serverConn = <-accepted:
		defer func() { _ = serverConn.Close() }()
	case <-time.After(time.Second):
		t.Fatal("SSH test peer did not accept the connection")
	}

	// The peer intentionally sends no SSH banner. Revoking the execution must
	// close the raw socket instead of waiting for the 30-second dial timeout.
	cancel()
	select {
	case dialErr := <-done:
		if !errors.Is(dialErr, context.Canceled) {
			t.Fatalf("dial error = %v, want context cancellation", dialErr)
		}
	case <-time.After(time.Second):
		t.Fatal("revoked SSH execution remained blocked in the handshake")
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

func TestProxmoxConsoleSSHTargetAddressPrefersAddressOverHostname(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		target   proxmoxConsoleSSHTarget
		wantHost string
		wantPort int
	}{
		{
			name:     "address wins over a hostname the agent cannot resolve",
			target:   proxmoxConsoleSSHTarget{Hostname: "pve-node", IP: "192.0.2.10"},
			wantHost: "192.0.2.10",
			wantPort: 22,
		},
		{
			name:     "hostname is used when no address is known",
			target:   proxmoxConsoleSSHTarget{Hostname: "pve-node.example.com", SSHPort: 2222},
			wantHost: "pve-node.example.com",
			wantPort: 2222,
		},
		{
			name:     "base URL host remains the last resort",
			target:   proxmoxConsoleSSHTarget{BaseURL: "https://192.0.2.11:8006"},
			wantHost: "192.0.2.11",
			wantPort: 22,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			host, port, err := proxmoxConsoleSSHTargetAddress(tt.target)
			if err != nil {
				t.Fatalf("proxmoxConsoleSSHTargetAddress returned error: %v", err)
			}
			if host != tt.wantHost {
				t.Fatalf("host = %q, want %q", host, tt.wantHost)
			}
			if port != tt.wantPort {
				t.Fatalf("port = %d, want %d", port, tt.wantPort)
			}
		})
	}
}

// This exercises the real TCP/SSH transport and terminal bridge with an
// intentionally unresolvable inventory label and a reachable loopback address.
func TestRunProxmoxConsoleSSHAddressPreferenceOpensTerminal(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()

	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(key)
	if err != nil {
		t.Fatal(err)
	}
	serverConfig := &ssh.ServerConfig{
		PasswordCallback: func(_ ssh.ConnMetadata, password []byte) (*ssh.Permissions, error) {
			if string(password) != "synthetic-password" {
				return nil, errTestProxmoxConsoleSSHUnexpectedPassword
			}
			return nil, nil
		},
	}
	serverConfig.AddHostKey(signer)
	var lc net.ListenConfig
	listener, err := lc.Listen(ctx, "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = listener.Close() }()
	address := listener.Addr().(*net.TCPAddr)
	serverDone := make(chan error, 1)
	const command = "echo synthetic-shell-ready\n"
	const response = "synthetic-shell-ready\r\n"
	go func() {
		serverDone <- func() error {
			conn, acceptErr := listener.Accept()
			if acceptErr != nil {
				return acceptErr
			}
			defer func() { _ = conn.Close() }()
			_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
			sshConn, channels, requests, handshakeErr := ssh.NewServerConn(conn, serverConfig)
			if handshakeErr != nil {
				return handshakeErr
			}
			defer func() { _ = sshConn.Close() }()
			go ssh.DiscardRequests(requests)
			newChannel := <-channels
			if newChannel == nil || newChannel.ChannelType() != "session" {
				return errTestProxmoxConsoleSSHExpectedSessionChannel
			}
			channel, channelRequests, channelErr := newChannel.Accept()
			if channelErr != nil {
				return channelErr
			}
			defer func() { _ = channel.Close() }()
			for request := range channelRequests {
				_ = request.Reply(request.Type == "pty-req" || request.Type == "shell", nil)
				if request.Type == "shell" {
					input := make([]byte, len(command))
					if _, readErr := io.ReadFull(channel, input); readErr != nil {
						return readErr
					}
					if string(input) != command {
						return errTestProxmoxConsoleSSHInputNotReceived
					}
					if _, writeErr := io.WriteString(channel, response); writeErr != nil {
						return writeErr
					}
					<-ctx.Done()
					return nil
				}
			}
			return errTestProxmoxConsoleSSHShellNotRequested
		}()
	}()

	bridge := newPluginProxmoxConsoleBridge(nil)
	if _, err := bridge.Open(ctx, pluginProxmoxConsoleOpenRequest{}); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = bridge.Close() }()
	done := make(chan error, 1)
	go func() {
		done <- runProxmoxConsoleSSH(ctx, proxmoxConsoleSSHConfig{
			Target: proxmoxConsoleSSHTarget{
				Hostname: "host01.invalid",
				IP:       address.IP.String(),
				SSHPort:  address.Port,
			},
			SSH:              proxmoxConsoleSSHAuth{Username: "synthetic-user", Password: "synthetic-password"},
			SSHHostKeyPolicy: proxmoxSSHHostKeyPolicyTrustFirstUse,
			KnownHostsPath:   filepath.Join(t.TempDir(), "known_hosts"),
			TimeoutMS:        2000,
		}, bridge, nil)
	}()
	if err := bridge.Write([]byte(command)); err != nil {
		t.Fatal(err)
	}
	var output strings.Builder
	for !strings.Contains(output.String(), response) {
		chunk, readErr := bridge.Read(ctx)
		if readErr != nil {
			t.Fatalf("terminal read: %v; output: %q", readErr, output.String())
		}
		output.Write(chunk)
		if strings.Contains(output.String(), proxmoxSSHConsoleUnavailableMessage) {
			t.Fatalf("SSH terminal unavailable: %q", output.String())
		}
	}
	t.Logf("Inventory hostname=host01.invalid; address=127.0.0.1; real SSH terminal input=%q output=%q", command, output.String())
	cancel()
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("terminal connector did not shut down")
	}
}
