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

package sidecar

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

func TestManagerStartsHealthChecksAndStopsChild(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script child process test is unix-only")
	}

	dir := t.TempDir()
	script := writeScript(t, dir, "long-running.sh", `
trap 'exit 0' TERM
while true; do sleep 1; done
`)

	var healthy atomic.Int32
	sc := &fakeSidecar{
		name:   "netprobe",
		binary: script,
		onHealthy: func(Client) {
			healthy.Add(1)
		},
	}
	mgr := newTestManager(t, dir, ClientFactory(func(context.Context, string) (Client, error) {
		return fakeClient{}, nil
	}), sc)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := mgr.Start(ctx); err != nil {
		t.Fatalf("Start() error = %v", err)
	}

	waitForStatus(t, mgr, "netprobe", func(status Status) bool {
		return status.State == StateHealthy && status.PID > 0
	})
	status := statusByName(t, mgr, "netprobe")
	if got, want := status.SocketPath, filepath.Join(dir, "run", "netprobe", "ipc.sock"); got != want {
		t.Fatalf("SocketPath = %q, want %q", got, want)
	}
	assertDirMode(t, filepath.Join(dir, "run"), 0o700)
	assertDirMode(t, filepath.Join(dir, "run", "netprobe"), 0o700)

	if healthy.Load() == 0 {
		t.Fatal("expected OnHealthy to be called")
	}

	stopCtx, stopCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer stopCancel()
	if err := mgr.Stop(stopCtx); err != nil {
		t.Fatalf("Stop() error = %v", err)
	}

	status = statusByName(t, mgr, "netprobe")
	if status.State != StateStopped {
		t.Fatalf("state after Stop() = %q, want %q", status.State, StateStopped)
	}
}

func TestManagerMarksUnhealthyAfterConsecutiveProbeFailures(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script child process test is unix-only")
	}

	dir := t.TempDir()
	script := writeScript(t, dir, "unhealthy.sh", `
trap 'exit 0' TERM
while true; do sleep 1; done
`)

	var unhealthy atomic.Int32
	sc := &fakeSidecar{
		name:   "netprobe",
		binary: script,
		onUnhealthy: func(error) {
			unhealthy.Add(1)
		},
	}
	mgr := newTestManager(t, dir, ClientFactory(func(context.Context, string) (Client, error) {
		return nil, errors.New("probe failed")
	}), sc)
	mgr.cfg.UnhealthyThreshold = 2

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := mgr.Start(ctx); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	defer func() {
		stopCtx, stopCancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer stopCancel()
		_ = mgr.Stop(stopCtx)
	}()

	waitForStatus(t, mgr, "netprobe", func(status Status) bool {
		return status.State == StateUnhealthy
	})
	if unhealthy.Load() == 0 {
		t.Fatal("expected OnUnhealthy to be called")
	}
}

func TestManagerOpensCircuitBreakerAfterRestartLimit(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script child process test is unix-only")
	}

	dir := t.TempDir()
	script := writeScript(t, dir, "exits.sh", `exit 2`)

	var unhealthy atomic.Int32
	sc := &fakeSidecar{
		name:   "netprobe",
		binary: script,
		onUnhealthy: func(error) {
			unhealthy.Add(1)
		},
	}
	mgr := newTestManager(t, dir, ClientFactory(func(context.Context, string) (Client, error) {
		return fakeClient{}, nil
	}), sc)
	mgr.cfg.RestartLimitPerMinute = 2

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := mgr.Start(ctx); err != nil {
		t.Fatalf("Start() error = %v", err)
	}

	waitForStatus(t, mgr, "netprobe", func(status Status) bool {
		return status.State == StateCircuitOpen
	})
	status := statusByName(t, mgr, "netprobe")
	if status.RestartCount != 2 {
		t.Fatalf("RestartCount = %d, want 2", status.RestartCount)
	}
	if unhealthy.Load() == 0 {
		t.Fatal("expected circuit breaker to call OnUnhealthy")
	}
}

func newTestManager(t *testing.T, dir string, factory ClientFactory, sidecars ...Sidecar) *Manager {
	t.Helper()

	mgr, err := NewManager(Config{
		RuntimeDir:            filepath.Join(dir, "run"),
		ConfigDir:             filepath.Join(dir, "config"),
		HealthInterval:        10 * time.Millisecond,
		ShutdownGrace:         250 * time.Millisecond,
		RestartBackoffInitial: time.Millisecond,
		RestartBackoffMax:     5 * time.Millisecond,
		RestartLimitPerMinute: 5,
		ClientFactory:         factory,
		Logger:                zerolog.Nop(),
	}, sidecars...)
	if err != nil {
		t.Fatalf("NewManager() error = %v", err)
	}

	return mgr
}

func writeScript(t *testing.T, dir, name, body string) string {
	t.Helper()

	path := filepath.Join(dir, name)
	data := []byte("#!/bin/sh\n" + body + "\n")
	if err := os.WriteFile(path, data, 0o755); err != nil {
		t.Fatalf("write test script: %v", err)
	}

	return path
}

func assertDirMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat %s: %v", path, err)
	}
	if !info.IsDir() {
		t.Fatalf("%s is not a directory", path)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("%s mode = %#o, want %#o", path, got, want)
	}
}

func waitForStatus(t *testing.T, mgr *Manager, name string, accept func(Status) bool) {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		status := statusByName(t, mgr, name)
		if accept(status) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}

	t.Fatalf("timed out waiting for status; last status: %+v", statusByName(t, mgr, name))
}

func statusByName(t *testing.T, mgr *Manager, name string) Status {
	t.Helper()

	for _, status := range mgr.Status() {
		if status.Name == name {
			return status
		}
	}
	t.Fatalf("missing status for sidecar %q", name)
	return Status{}
}

type fakeSidecar struct {
	name        string
	binary      string
	onHealthy   func(Client)
	onUnhealthy func(error)
}

func (f *fakeSidecar) Name() string { return f.name }

func (f *fakeSidecar) BinaryPath() string { return f.binary }

func (f *fakeSidecar) Args(_, _ string) []string { return nil }

func (f *fakeSidecar) OnHealthy(client Client) {
	if f.onHealthy != nil {
		f.onHealthy(client)
	}
}

func (f *fakeSidecar) OnUnhealthy(err error) {
	if f.onUnhealthy != nil {
		f.onUnhealthy(err)
	}
}

type fakeClient struct{}

func (fakeClient) Ping(context.Context) error { return nil }

func (fakeClient) Close() error { return nil }
