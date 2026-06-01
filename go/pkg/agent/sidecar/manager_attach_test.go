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
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// TestManagerStartAttachConnectsWithoutLaunching proves attach mode never execs the binary:
// the sidecar's BinaryPath points at a path that does not exist, so the launch path would
// fail to start and never reach Running. Reaching Running (with PID 0) and firing OnHealthy
// therefore proves the manager connected to the (externally-managed) socket without launching.
func TestManagerStartAttachConnectsWithoutLaunching(t *testing.T) {
	dir := t.TempDir()

	var healthy atomic.Int32
	var gotClient atomic.Bool
	sc := &fakeSidecar{
		name:   "netprobe",
		binary: filepath.Join(dir, "does-not-exist-must-not-be-exec'd"),
		onHealthy: func(c Client) {
			if c != nil {
				gotClient.Store(true)
			}
			healthy.Add(1)
		},
	}
	mgr := newTestManager(t, dir, ClientFactory(func(context.Context, string) (Client, error) {
		return fakeClient{}, nil
	}), sc)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := mgr.StartAttach(ctx); err != nil {
		t.Fatalf("StartAttach() error = %v", err)
	}

	waitForStatus(t, mgr, "netprobe", func(status Status) bool {
		return status.State == StateRunning
	})

	status := statusByName(t, mgr, "netprobe")
	if status.PID != 0 {
		t.Fatalf("attach-mode PID = %d, want 0 (agent does not own the process)", status.PID)
	}

	waitForCondition(t, "OnHealthy callback", func() bool { return healthy.Load() > 0 })
	if !gotClient.Load() {
		t.Fatal("OnHealthy was not called with a non-nil client")
	}

	stopCtx, stopCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer stopCancel()
	if err := mgr.Stop(stopCtx); err != nil {
		t.Fatalf("Stop() error = %v", err)
	}
	if status := statusByName(t, mgr, "netprobe"); status.State != StateStopped {
		t.Fatalf("state after Stop() = %q, want %q", status.State, StateStopped)
	}
}

// flakyClient is a connected client whose Ping can be flipped to fail (simulating a dropped
// connection to an externally-managed process) and that records Close() calls.
type flakyClient struct {
	pingFails *atomic.Bool
	closes    *atomic.Int32
}

func (c *flakyClient) Ping(context.Context) error {
	if c.pingFails.Load() {
		return errTestProbeFailed
	}
	return nil
}

func (c *flakyClient) Close() error {
	c.closes.Add(1)
	return nil
}

// TestManagerStartAttachReconnects proves attach mode treats a dropped connection as a
// reconnect, not a process restart: it connects (Running), the connection drops (Ping starts
// failing) driving Unhealthy and closing the stale client, then recovers — the health loop
// re-dials the factory and returns to Running — all with RestartCount and PID staying 0
// (the agent never owns/restarts the process).
func TestManagerStartAttachReconnects(t *testing.T) {
	dir := t.TempDir()
	sc := &fakeSidecar{name: "netprobe", binary: filepath.Join(dir, "unused")}

	var dials atomic.Int32
	var pingFails atomic.Bool
	var closes atomic.Int32
	mgr := newTestManager(t, dir, ClientFactory(func(context.Context, string) (Client, error) {
		dials.Add(1)
		return &flakyClient{pingFails: &pingFails, closes: &closes}, nil
	}), sc)
	mgr.cfg.UnhealthyThreshold = 2

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := mgr.StartAttach(ctx); err != nil {
		t.Fatalf("StartAttach() error = %v", err)
	}

	// 1. First connect succeeds -> Running.
	waitForStatus(t, mgr, "netprobe", func(status Status) bool { return status.State == StateRunning })
	dialsBeforeDrop := dials.Load()

	// 2. Connection drops: the attached client's Ping fails -> stale client closed -> Unhealthy.
	pingFails.Store(true)
	waitForStatus(t, mgr, "netprobe", func(status Status) bool { return status.State == StateUnhealthy })
	if closes.Load() < 1 {
		t.Fatal("dropped client was not Close()'d on connection loss")
	}

	// 3. Recovery: Ping succeeds again -> health loop re-dials -> Running.
	pingFails.Store(false)
	waitForStatus(t, mgr, "netprobe", func(status Status) bool { return status.State == StateRunning })
	if dials.Load() <= dialsBeforeDrop {
		t.Fatalf("expected a re-dial after the drop (reconnect); dials %d <= %d", dials.Load(), dialsBeforeDrop)
	}

	// Attach mode must never restart a process or claim a PID.
	status := statusByName(t, mgr, "netprobe")
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

// TestManagerModeReportsStartedAndAttach checks Mode() across the start/stop transitions the
// push loop relies on to decide whether a launch<->attach switch is needed.
func TestManagerModeReportsStartedAndAttach(t *testing.T) {
	dir := t.TempDir()
	sc := &fakeSidecar{name: "netprobe", binary: filepath.Join(dir, "unused")}
	mgr := newTestManager(t, dir, ClientFactory(func(context.Context, string) (Client, error) {
		return fakeClient{}, nil
	}), sc)

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
	if started, _ := mgr.Mode(); started {
		t.Fatal("Mode() after Stop reports started=true, want false")
	}

	if err := mgr.Start(ctx); err != nil {
		t.Fatalf("Start() error = %v", err)
	}
	if started, attach := mgr.Mode(); !started || attach {
		t.Fatalf("Mode() after Start = (%v,%v), want (true,false)", started, attach)
	}
	_ = mgr.Stop(stopCtx)
}
