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
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
)

// sampleAddonBin is the compiled reference add-on used across the e2e tests. It
// is empty when no binary could be produced (e.g. a sandbox without the Go
// toolchain), in which case the dependent tests skip rather than fail.
//
//nolint:gochecknoglobals // resolved once in TestMain and shared read-only by the e2e add-on tests.
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
	cmd := exec.CommandContext(context.Background(), "go", "build", "-o", bin, "github.com/carverauto/serviceradar/go/cmd/serviceradar-sample-addon")
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
		RuntimeDir:             t.TempDir(),
		HealthInterval:         100 * time.Millisecond,
		HealthTimeout:          2 * time.Second,
		UnhealthyThreshold:     3,
		ConfigureTimeout:       2 * time.Second,
		RestartBackoffInitial:  50 * time.Millisecond,
		RestartBackoffMax:      500 * time.Millisecond,
		RestartCircuitCooldown: 100 * time.Millisecond,
		RestartLimitPerMinute:  5,
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

func statusHasCapability(status Status, capability string) bool {
	for _, candidate := range status.Capabilities {
		if candidate == capability {
			return true
		}
	}
	return false
}

func waitForState(t *testing.T, m *Manager, id string, timeout time.Duration) Status {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if s, ok := statusByID(m, id); ok && s.State == StateRunning {
			return s
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("addon %s did not reach state %s within %s; status=%+v", id, StateRunning, timeout, m.Status())
	return Status{}
}

func TestRunnerSetHealthyPreservesRunningDiagnostics(t *testing.T) {
	r := &runner{
		id:     "anomaly",
		status: Status{ID: "anomaly", State: StateStopped},
	}
	diagnostics := `{"kind":"anomaly_scoring_liveness","samples_scored_total":42}`

	r.setHealthy(1234, coreaddon.Health{
		Status:            coreaddon.HealthHealthy,
		Version:           "0.1.1",
		DegradationReason: diagnostics,
	})

	status := r.snapshot()
	if status.State != StateRunning {
		t.Fatalf("expected running state, got %s", status.State)
	}
	if status.DegradationReason != diagnostics {
		t.Fatalf("expected diagnostics to be preserved, got %q", status.DegradationReason)
	}
	if status.LastError != "" {
		t.Fatalf("expected no last_error for healthy probe, got %q", status.LastError)
	}
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

	s := waitForState(t, mgr, "sample", 15*time.Second)
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

func TestManagerKeepsLegacyAddonNonTelemetry(t *testing.T) {
	requireSampleAddon(t)

	var telemetryBatches atomic.Int64
	cfg := testConfig(t)
	cfg.TelemetryHandler = func(_ string, _ *coreaddon.TelemetryBatch) {
		telemetryBatches.Add(1)
	}

	mgr := NewManager(cfg)
	t.Cleanup(func() { stopManager(t, mgr) })

	err := mgr.Apply(context.Background(), []Spec{{
		ID:         "sample",
		Version:    "0.1.0",
		BinaryPath: sampleAddonBin,
		ConfigJSON: []byte(`{"message":"legacy"}`),
	}})
	if err != nil {
		t.Fatalf("apply: %v", err)
	}

	s := waitForState(t, mgr, "sample", 15*time.Second)
	if statusHasCapability(s, coreaddon.CapabilityNativeTelemetryV1) {
		t.Fatalf("legacy addon unexpectedly reported telemetry capability: %+v", s.Capabilities)
	}

	time.Sleep(250 * time.Millisecond)
	if got := telemetryBatches.Load(); got != 0 {
		t.Fatalf("legacy addon emitted telemetry batches = %d, want 0", got)
	}
}

func TestRunnerDrainTelemetryReconnectsAfterStreamClose(t *testing.T) {
	handled := make(chan *coreaddon.TelemetryBatch, 1)
	cfg := testConfig(t)
	cfg.TelemetryHandler = func(_ string, batch *coreaddon.TelemetryBatch) {
		handled <- batch
	}
	r := newRunner(Spec{ID: "anomaly"}, cfg)
	client := &reconnectingTelemetryClient{
		opened: make(chan int, 2),
		batch:  &coreaddon.TelemetryBatch{},
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go r.drainTelemetry(ctx, client)

	waitForTelemetryStream(t, client.opened, 1)
	waitForTelemetryStream(t, client.opened, 2)

	select {
	case <-handled:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for telemetry batch after reconnect")
	}
}

func TestRunnerRearmsCircuitBreakerAfterCooldown(t *testing.T) {
	cfg := testConfig(t)
	cfg.RestartLimitPerMinute = 1
	cfg.RestartBackoffInitial = 10 * time.Millisecond
	cfg.RestartBackoffMax = 20 * time.Millisecond
	cfg.RestartCircuitCooldown = 50 * time.Millisecond

	r := newRunner(Spec{
		ID:         "bad-addon",
		BinaryPath: filepath.Join(t.TempDir(), "missing-addon"),
	}, cfg)
	ctx, cancel := context.WithCancel(context.Background())
	defer func() {
		cancel()
		<-r.done
	}()

	go r.run(ctx)

	waitForRunnerState(t, r, StateCircuitOpen, 2*time.Second)
	firstCircuit := runnerStatusSnapshot(r).RestartCount

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if runnerStatusSnapshot(r).RestartCount > firstCircuit {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}

	t.Fatalf("restart count did not advance after circuit cooldown; status=%+v", runnerStatusSnapshot(r))
}

func TestRunnerBackoffResetRequiresHealthyRuntime(t *testing.T) {
	r := newRunner(Spec{ID: "sample"}, testConfig(t))
	started := time.Now().Add(-time.Minute)

	r.mu.Lock()
	r.status.LastStartedAt = started
	r.status.LastHealthAt = time.Time{}
	r.mu.Unlock()

	if r.ranStablyFor(30 * time.Second) {
		t.Fatal("run without a successful health probe must not reset backoff")
	}

	r.mu.Lock()
	r.status.LastHealthAt = started.Add(10 * time.Second)
	r.mu.Unlock()

	if r.ranStablyFor(30 * time.Second) {
		t.Fatal("run with too little healthy time must not reset backoff")
	}

	r.mu.Lock()
	r.status.LastHealthAt = started.Add(45 * time.Second)
	r.mu.Unlock()

	if !r.ranStablyFor(30 * time.Second) {
		t.Fatal("run with enough healthy time should reset backoff")
	}
}

func TestRunnerNeedsRestartWhenResourceLimitsChange(t *testing.T) {
	r := newRunner(Spec{
		ID:        "anomaly",
		Resources: Resources{MemoryMaxBytes: 128 << 20},
	}, testConfig(t))

	if !r.needsRestart(Spec{
		ID:        "anomaly",
		Resources: Resources{MemoryMaxBytes: 256 << 20},
	}) {
		t.Fatal("resource-limit changes must restart the add-on so cgroup limits are re-applied")
	}
}

func TestRunnerStatusReportsResourceLimitWarning(t *testing.T) {
	r := newRunner(Spec{ID: "anomaly"}, testConfig(t))

	r.setResourceLimitStatus(resourceLimitStatus{
		Requested:  true,
		Enforced:   false,
		CgroupPath: "/sys/fs/cgroup/serviceradar-addons.slice/serviceradar-addon-anomaly",
		Warning:    "addon resource limits declared but addon_cgroup_root is not configured",
	})

	status := r.snapshot()
	if !status.ResourceLimitsRequested {
		t.Fatal("expected resource limits to be marked requested")
	}
	if status.ResourceLimitsEnforced {
		t.Fatal("expected resource limits to be marked unenforced")
	}
	if status.ResourceLimitCgroupPath == "" {
		t.Fatal("expected cgroup path to be retained in status")
	}
	if !strings.Contains(status.ResourceLimitError, "addon_cgroup_root") {
		t.Fatalf("resource limit error = %q, want addon_cgroup_root warning", status.ResourceLimitError)
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
	waitForState(t, mgr, "sample", 15*time.Second)

	if err := mgr.Apply(context.Background(), nil); err != nil {
		t.Fatalf("apply empty: %v", err)
	}
	if s, ok := statusByID(mgr, "sample"); ok {
		t.Fatalf("expected sample addon to be removed, still present: %+v", s)
	}
}

func TestManagerRunsCommandByAssignmentID(t *testing.T) {
	requireSampleAddon(t)

	mgr := NewManager(testConfig(t))
	t.Cleanup(func() { stopManager(t, mgr) })

	if err := mgr.Apply(context.Background(), []Spec{{
		AssignmentID: "assignment-1",
		ID:           "sample",
		Version:      "0.1.0",
		BinaryPath:   sampleAddonBin,
		ConfigJSON:   []byte(`{"message":"command"}`),
		Capabilities: []string{coreaddon.CapabilityProducerScheduleV1},
	}}); err != nil {
		t.Fatalf("apply: %v", err)
	}
	waitForState(t, mgr, "sample", 15*time.Second)

	result, err := mgr.RunCommand(context.Background(), CommandInvocation{
		AssignmentID: "assignment-1",
		CommandID:    "command-1",
		CommandType:  coreaddon.CommandTypeAddonRunCommand,
		ActionID:     "advisory.refresh",
		Schema:       coreaddon.ProducerScheduleRunSchemaV1,
		PayloadJSON:  []byte(`{"schema":"serviceradar.producer_schedule_run.v1","action_id":"advisory.refresh"}`),
		Timeout:      5 * time.Second,
	})
	if err != nil {
		t.Fatalf("run command: %v", err)
	}
	if !result.Success {
		t.Fatalf("command success = false, message=%q", result.Message)
	}
	if got := string(result.PayloadJSON); !strings.Contains(got, `"action_id":"advisory.refresh"`) {
		t.Fatalf("unexpected command payload: %s", got)
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
	s1 := waitForState(t, mgr, "sample", 15*time.Second)
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

func TestManagerRestartsOnVersionChangeWithStableBinaryPath(t *testing.T) {
	requireSampleAddon(t)

	mgr := NewManager(testConfig(t))
	t.Cleanup(func() { stopManager(t, mgr) })

	spec := Spec{
		ID:         "sample",
		Version:    "0.1.0",
		BinaryPath: sampleAddonBin,
		ConfigJSON: []byte("{}"),
	}
	if err := mgr.Apply(context.Background(), []Spec{spec}); err != nil {
		t.Fatalf("apply v1: %v", err)
	}
	s1 := waitForState(t, mgr, "sample", 15*time.Second)
	if s1.PID == 0 {
		t.Skip("go-plugin did not report a PID; cannot assert relaunch")
	}

	// Add-ons are launched through stable paths such as
	// /var/lib/serviceradar/agent/addons/netprobe/current/serviceradar-netprobe.
	// When current is retargeted to a new version directory, the path string stays
	// the same, so the assigned version must also be a restart boundary.
	spec.Version = "0.2.0"
	if err := mgr.Apply(context.Background(), []Spec{spec}); err != nil {
		t.Fatalf("apply v2: %v", err)
	}

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if s, ok := statusByID(mgr, "sample"); ok && s.State == StateRunning && s.PID != 0 && s.PID != s1.PID {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("expected relaunch with a new PID after version change; old pid=%d, status=%+v", s1.PID, mgr.Status())
}

type reconnectingTelemetryClient struct {
	mu      sync.Mutex
	streams int
	opened  chan int
	batch   *coreaddon.TelemetryBatch
}

func (c *reconnectingTelemetryClient) StreamTelemetry(ctx context.Context) (<-chan *coreaddon.TelemetryBatch, error) {
	c.mu.Lock()
	c.streams++
	streamID := c.streams
	c.mu.Unlock()

	batches := make(chan *coreaddon.TelemetryBatch, 1)
	c.opened <- streamID

	if streamID == 1 {
		close(batches)
		return batches, nil
	}

	go func() {
		defer close(batches)
		select {
		case batches <- c.batch:
		case <-ctx.Done():
			return
		}
		<-ctx.Done()
	}()

	return batches, nil
}

type diagnosticTelemetryClient struct {
	batches <-chan *coreaddon.TelemetryBatch
	errs    <-chan error
	err     error
}

func (c diagnosticTelemetryClient) StreamTelemetry(context.Context) (<-chan *coreaddon.TelemetryBatch, error) {
	return c.batches, c.err
}

func (c diagnosticTelemetryClient) StreamTelemetryWithDiagnostics(
	context.Context,
) (<-chan *coreaddon.TelemetryBatch, <-chan error, error) {
	return c.batches, c.errs, c.err
}

func TestRunnerDrainTelemetryReportsEOFAndTransportErrors(t *testing.T) {
	r := newRunner(Spec{ID: "anomaly"}, applyDefaults(Config{RuntimeDir: t.TempDir()}))

	batches := make(chan *coreaddon.TelemetryBatch)
	errs := make(chan error, 1)
	errs <- io.EOF
	close(errs)
	close(batches)

	err := r.drainTelemetryStream(context.Background(), diagnosticTelemetryClient{batches: batches, errs: errs})
	if !errors.Is(err, errAddonStreamClosed) {
		t.Fatalf("drainTelemetryStream error = %v, want addon stream closed", err)
	}
	if !errors.Is(err, io.EOF) {
		t.Fatalf("drainTelemetryStream error = %v, want wrapped io.EOF", err)
	}

	transportErr := errors.New("transport unavailable")
	batches = make(chan *coreaddon.TelemetryBatch)
	errs = make(chan error, 1)
	errs <- transportErr
	close(errs)
	close(batches)

	err = r.drainTelemetryStream(context.Background(), diagnosticTelemetryClient{batches: batches, errs: errs})
	if !errors.Is(err, errAddonStreamClosed) {
		t.Fatalf("drainTelemetryStream transport error = %v, want addon stream closed", err)
	}
	if !errors.Is(err, transportErr) {
		t.Fatalf("drainTelemetryStream transport error = %v, want wrapped transport error", err)
	}
}

func waitForTelemetryStream(t *testing.T, opened <-chan int, want int) {
	t.Helper()

	select {
	case got := <-opened:
		if got != want {
			t.Fatalf("opened telemetry stream = %d, want %d", got, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for telemetry stream %d", want)
	}
}

func waitForRunnerState(t *testing.T, r *runner, want State, timeout time.Duration) {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if runnerStatusSnapshot(r).State == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}

	t.Fatalf("runner state did not reach %s; status=%+v", want, runnerStatusSnapshot(r))
}

func runnerStatusSnapshot(r *runner) Status {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.status
}
