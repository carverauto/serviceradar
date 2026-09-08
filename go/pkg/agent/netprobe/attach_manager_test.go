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

package netprobe

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	"github.com/rs/zerolog"
)

var errAttachProbeFailed = errors.New("probe failed")

func TestAttachManagerConnectsWithoutLaunching(t *testing.T) {
	dir := t.TempDir()
	sc := NewSidecar(SidecarConfig{
		BinaryPath: filepath.Join(dir, "does-not-exist-must-not-be-execed"),
		Logger:     zerolog.Nop(),
	})
	mgr := newTestAttachManager(t, dir, sc, sidecar.ClientFactory(func(context.Context, string) (sidecar.Client, error) {
		return attachFakeClient{}, nil
	}))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := mgr.StartAttach(ctx); err != nil {
		t.Fatalf("StartAttach() error = %v", err)
	}

	waitForAttachStatus(t, mgr, func(status sidecar.Status) bool {
		return status.State == sidecar.StateRunning
	})

	status := attachStatus(t, mgr)
	if status.PID != 0 {
		t.Fatalf("attach-mode PID = %d, want 0 (agent does not own the process)", status.PID)
	}
	if !sc.Healthy() {
		t.Fatal("netprobe sidecar was not marked healthy")
	}

	stopCtx, stopCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer stopCancel()
	if err := mgr.Stop(stopCtx); err != nil {
		t.Fatalf("Stop() error = %v", err)
	}
	if status := attachStatus(t, mgr); status.State != sidecar.StateStopped {
		t.Fatalf("state after Stop() = %q, want %q", status.State, sidecar.StateStopped)
	}
}

func TestAttachManagerReconnectsDroppedClient(t *testing.T) {
	dir := t.TempDir()
	sc := NewSidecar(SidecarConfig{Logger: zerolog.Nop()})

	var dials atomic.Int32
	var pingFails atomic.Bool
	var closes atomic.Int32
	mgr := newTestAttachManager(t, dir, sc, sidecar.ClientFactory(func(context.Context, string) (sidecar.Client, error) {
		dials.Add(1)
		return &flakyAttachClient{pingFails: &pingFails, closes: &closes}, nil
	}))
	mgr.cfg.UnhealthyThreshold = 2

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := mgr.StartAttach(ctx); err != nil {
		t.Fatalf("StartAttach() error = %v", err)
	}

	waitForAttachStatus(t, mgr, func(status sidecar.Status) bool { return status.State == sidecar.StateRunning })
	dialsBeforeDrop := dials.Load()

	pingFails.Store(true)
	waitForAttachStatus(t, mgr, func(status sidecar.Status) bool { return status.State == sidecar.StateUnhealthy })
	if closes.Load() < 1 {
		t.Fatal("dropped client was not Close()'d on connection loss")
	}

	pingFails.Store(false)
	waitForAttachStatus(t, mgr, func(status sidecar.Status) bool { return status.State == sidecar.StateRunning })
	if dials.Load() <= dialsBeforeDrop {
		t.Fatalf("expected a re-dial after the drop; dials %d <= %d", dials.Load(), dialsBeforeDrop)
	}

	status := attachStatus(t, mgr)
	if status.RestartCount != 0 {
		t.Fatalf("RestartCount = %d, want 0 (attach mode must not restart a process)", status.RestartCount)
	}
	if status.PID != 0 {
		t.Fatalf("PID = %d, want 0 (agent does not own the attached process)", status.PID)
	}

	stopCtx, stopCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer stopCancel()
	if err := mgr.Stop(stopCtx); err != nil {
		t.Fatalf("Stop() error = %v", err)
	}
}

func TestAttachManagerModeReportsAttachOnly(t *testing.T) {
	dir := t.TempDir()
	mgr := newTestAttachManager(t, dir, NewSidecar(SidecarConfig{Logger: zerolog.Nop()}),
		sidecar.ClientFactory(func(context.Context, string) (sidecar.Client, error) {
			return attachFakeClient{}, nil
		}))

	if started, attach := mgr.Mode(); started || attach {
		t.Fatalf("Mode() before start = (%v,%v), want (false,false)", started, attach)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := mgr.StartAttach(ctx); err != nil {
		t.Fatalf("StartAttach() error = %v", err)
	}
	if started, attach := mgr.Mode(); !started || !attach {
		t.Fatalf("Mode() after StartAttach = (%v,%v), want (true,true)", started, attach)
	}

	stopCtx, stopCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer stopCancel()
	if err := mgr.Stop(stopCtx); err != nil {
		t.Fatalf("Stop() error = %v", err)
	}
	if started, attach := mgr.Mode(); started || attach {
		t.Fatalf("Mode() after Stop = (%v,%v), want (false,false)", started, attach)
	}
}

func newTestAttachManager(
	t *testing.T,
	dir string,
	sc *Sidecar,
	factory sidecar.ClientFactory,
) *AttachManager {
	t.Helper()

	mgr, err := NewAttachManager(AttachManagerConfig{
		RuntimeDir:         filepath.Join(dir, "run"),
		ConfigDir:          filepath.Join(dir, "config"),
		HealthInterval:     10 * time.Millisecond,
		UnhealthyThreshold: 1,
		ClientFactory:      factory,
		Logger:             zerolog.Nop(),
	}, sc)
	if err != nil {
		t.Fatalf("NewAttachManager() error = %v", err)
	}

	return mgr
}

func waitForAttachStatus(t *testing.T, mgr *AttachManager, accept func(sidecar.Status) bool) {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		status := attachStatus(t, mgr)
		if accept(status) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}

	t.Fatalf("timed out waiting for attach status; last value: %+v", attachStatus(t, mgr))
}

func attachStatus(t *testing.T, mgr *AttachManager) sidecar.Status {
	t.Helper()

	statuses := mgr.Status()
	if len(statuses) != 1 {
		t.Fatalf("Status() returned %d entries, want 1", len(statuses))
	}

	return statuses[0]
}

type attachFakeClient struct{}

func (attachFakeClient) Ping(context.Context) error { return nil }

func (attachFakeClient) Close() error { return nil }

type flakyAttachClient struct {
	pingFails *atomic.Bool
	closes    *atomic.Int32
}

func (c *flakyAttachClient) Ping(context.Context) error {
	if c.pingFails.Load() {
		return errAttachProbeFailed
	}

	return nil
}

func (c *flakyAttachClient) Close() error {
	c.closes.Add(1)
	return nil
}

func TestAttachManagerRejectsNilClient(t *testing.T) {
	dir := t.TempDir()
	mgr := newTestAttachManager(t, dir, NewSidecar(SidecarConfig{Logger: zerolog.Nop()}),
		sidecar.ClientFactory(func(context.Context, string) (sidecar.Client, error) {
			return nil, nil
		}))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := mgr.StartAttach(ctx); err != nil {
		t.Fatalf("StartAttach() error = %v", err)
	}

	waitForAttachStatus(t, mgr, func(status sidecar.Status) bool {
		return status.State == sidecar.StateUnhealthy
	})

	status := attachStatus(t, mgr)
	if got := status.LastError; got != ErrAttachNilClient.Error() {
		t.Fatalf("LastError = %q, want %q", got, ErrAttachNilClient.Error())
	}
}

func ExampleAttachManager_Mode() {
	mgr := &AttachManager{}
	started, attach := mgr.Mode()
	fmt.Println(started, attach)
	// Output: false false
}

// The agent derives the AddonService socket independently of netprobe, which
// derives it from --socket (default_addon_socket_path in rust/netprobe/src/main.rs).
// Nothing at runtime reconciles the two: if they disagree, the pump quietly
// never connects and discovery silently stays on the legacy channel forever.
// Pinning them as siblings is what makes that drift a test failure instead.
func TestAddonSocketIsASiblingOfTheIPCSocket(t *testing.T) {
	const runtimeDir = "/run/serviceradar"

	ipc := attachSocketPath(runtimeDir, DefaultSidecarName)
	addon := AttachAddonSocketPath(runtimeDir, DefaultSidecarName)

	if got, want := ipc, "/run/serviceradar/netprobe/ipc.sock"; got != want {
		t.Fatalf("IPC socket path drifted from the shipped unit: got %q, want %q", got, want)
	}
	if got, want := addon, "/run/serviceradar/netprobe/addon.sock"; got != want {
		t.Fatalf("addon socket path drifted from netprobe's default: got %q, want %q", got, want)
	}
	if filepath.Dir(addon) != filepath.Dir(ipc) {
		t.Fatalf("addon socket %q is not a sibling of IPC socket %q", addon, ipc)
	}
}
