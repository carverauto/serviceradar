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
	"io"
	"strings"
	"sync"
	"testing"
	"time"
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
		stdout: strings.NewReader("login: "),
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
	if string(output) != "login: " {
		t.Fatalf("unexpected bridge output %q", string(output))
	}

	if err := bridge.Write([]byte("whoami\r")); err != nil {
		t.Fatalf("write bridge input: %v", err)
	}
	if err := bridge.Resize(132, 43); err != nil {
		t.Fatalf("resize bridge: %v", err)
	}

	waitFor(t, time.Second, func() bool {
		stdin, windowChanges := session.ioState()
		return stdin == "whoami\r" &&
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
