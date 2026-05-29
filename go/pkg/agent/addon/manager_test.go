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

package addon

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// sampleAddonBin is the compiled reference add-on used across the e2e tests. It
// is empty when no binary could be produced (e.g. a sandbox without the Go
// toolchain), in which case the dependent tests skip rather than fail.
var sampleAddonBin string

func TestMain(m *testing.M) {
	sampleAddonBin = resolveSampleAddonBin()
	os.Exit(m.Run())
}

// resolveSampleAddonBin prefers a prebuilt binary supplied via
// SERVICERADAR_SAMPLE_ADDON_BIN (e.g. a Bazel data dependency) and otherwise
// compiles the reference add-on with the Go toolchain.
func resolveSampleAddonBin() string {
	if bin := os.Getenv("SERVICERADAR_SAMPLE_ADDON_BIN"); bin != "" {
		if abs, err := filepath.Abs(bin); err == nil {
			if _, statErr := os.Stat(abs); statErr == nil {
				return abs
			}
		}
		// Fall through to building when the supplied path cannot be resolved.
	}

	if _, err := exec.LookPath("go"); err != nil {
		return ""
	}

	dir, err := os.MkdirTemp("", "sr-addon-test")
	if err != nil {
		return ""
	}

	bin := filepath.Join(dir, "serviceradar-sample-addon")
	cmd := exec.Command("go", "build", "-o", bin, "github.com/carverauto/serviceradar/go/cmd/serviceradar-sample-addon")
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		_ = os.RemoveAll(dir)
		return ""
	}
	return bin
}

func requireSampleAddon(t *testing.T) {
	t.Helper()
	if sampleAddonBin == "" {
		t.Skip("reference add-on binary unavailable (no SERVICERADAR_SAMPLE_ADDON_BIN and no Go toolchain)")
	}
}

func testConfig(t *testing.T) Config {
	t.Helper()
	return Config{
		RuntimeDir:            t.TempDir(),
		HealthInterval:        100 * time.Millisecond,
		HealthTimeout:         2 * time.Second,
		UnhealthyThreshold:    3,
		ConfigureTimeout:      2 * time.Second,
		RestartBackoffInitial: 50 * time.Millisecond,
		RestartBackoffMax:     500 * time.Millisecond,
		RestartLimitPerMinute: 5,
	}
}

func statusByID(m *Manager, id string) (Status, bool) {
	for _, s := range m.Status() {
		if s.ID == id {
			return s, true
		}
	}
	return Status{}, false
}

func waitForState(t *testing.T, m *Manager, id string, want State, timeout time.Duration) Status {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if s, ok := statusByID(m, id); ok && s.State == want {
			return s
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("addon %s did not reach state %s within %s; status=%+v", id, want, timeout, m.Status())
	return Status{}
}

func stopManager(t *testing.T, m *Manager) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := m.Stop(ctx); err != nil {
		t.Errorf("stop manager: %v", err)
	}
}

func TestManagerLaunchesConfiguresAndSupervises(t *testing.T) {
	requireSampleAddon(t)

	mgr := NewManager(testConfig(t))
	t.Cleanup(func() { stopManager(t, mgr) })

	err := mgr.Apply(context.Background(), []Spec{{
		ID:           "sample",
		Version:      "0.1.0",
		BinaryPath:   sampleAddonBin,
		ConfigJSON:   []byte(`{"message":"hi"}`),
		Capabilities: []string{"sample"},
	}})
	if err != nil {
		t.Fatalf("apply: %v", err)
	}

	s := waitForState(t, mgr, "sample", StateRunning, 15*time.Second)
	if s.Version != "0.1.0" {
		t.Fatalf("expected version 0.1.0 reported via Info, got %q", s.Version)
	}
	if s.ConfigHash == "" {
		t.Fatalf("expected a config hash after Configure, got empty")
	}

	// Confirm the add-on stays running across several health cycles.
	time.Sleep(400 * time.Millisecond)
	s, ok := statusByID(mgr, "sample")
	if !ok {
		t.Fatalf("sample addon missing from status")
	}
	if s.State != StateRunning {
		t.Fatalf("expected running after health cycles, got %s (last_error=%q)", s.State, s.LastError)
	}
	if s.LastHealthAt.IsZero() {
		t.Fatalf("expected a health timestamp to be recorded")
	}
}

func TestManagerStopsRemovedAddon(t *testing.T) {
	requireSampleAddon(t)

	mgr := NewManager(testConfig(t))
	t.Cleanup(func() { stopManager(t, mgr) })

	if err := mgr.Apply(context.Background(), []Spec{{
		ID:         "sample",
		BinaryPath: sampleAddonBin,
		ConfigJSON: []byte("{}"),
	}}); err != nil {
		t.Fatalf("apply: %v", err)
	}
	waitForState(t, mgr, "sample", StateRunning, 15*time.Second)

	if err := mgr.Apply(context.Background(), nil); err != nil {
		t.Fatalf("apply empty: %v", err)
	}
	if s, ok := statusByID(mgr, "sample"); ok {
		t.Fatalf("expected sample addon to be removed, still present: %+v", s)
	}
}

func TestManagerApplyAfterStopFails(t *testing.T) {
	mgr := NewManager(testConfig(t))
	stopManager(t, mgr)
	if err := mgr.Apply(context.Background(), nil); err == nil {
		t.Fatalf("expected ErrManagerClosed after Stop")
	}
}

func TestManagerRestartsOnBinaryChange(t *testing.T) {
	requireSampleAddon(t)

	// A second copy of the reference binary at a different path.
	dir := t.TempDir()
	bin2 := filepath.Join(dir, "serviceradar-sample-addon-v2")
	data, err := os.ReadFile(sampleAddonBin)
	if err != nil {
		t.Fatalf("read sample addon: %v", err)
	}
	if err := os.WriteFile(bin2, data, 0o755); err != nil {
		t.Fatalf("write sample addon copy: %v", err)
	}

	mgr := NewManager(testConfig(t))
	t.Cleanup(func() { stopManager(t, mgr) })

	if err := mgr.Apply(context.Background(), []Spec{{
		ID:         "sample",
		BinaryPath: sampleAddonBin,
		ConfigJSON: []byte("{}"),
	}}); err != nil {
		t.Fatalf("apply: %v", err)
	}
	s1 := waitForState(t, mgr, "sample", StateRunning, 15*time.Second)
	if s1.PID == 0 {
		t.Skip("go-plugin did not report a PID; cannot assert relaunch")
	}

	// Changing the binary path must relaunch the subprocess, not reconfigure the
	// old one (the regression: a binary upgrade silently kept the old process).
	if err := mgr.Apply(context.Background(), []Spec{{
		ID:         "sample",
		BinaryPath: bin2,
		ConfigJSON: []byte("{}"),
	}}); err != nil {
		t.Fatalf("apply v2: %v", err)
	}

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if s, ok := statusByID(mgr, "sample"); ok && s.State == StateRunning && s.PID != 0 && s.PID != s1.PID {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("expected relaunch with a new PID after binary change; old pid=%d, status=%+v", s1.PID, mgr.Status())
}
