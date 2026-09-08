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
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
)

var (
	errFirstExit  = errors.New("first exit")
	errSecondExit = errors.New("second exit")
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

// resolveBinPath resolves a reference add-on path supplied by the build system or
// the environment, returning "" when it does not point at an existing file.
//
// Bazel supplies these as $(rootpath ...), which is relative to the RUNFILES ROOT --
// but a go_test's working directory is its own package directory, so filepath.Abs
// resolves them against go/pkg/agent/addon/ and misses. TEST_SRCDIR/TEST_WORKSPACE is
// the runfiles root, so try that first; "_main" covers bzlmod's default workspace name
// when TEST_WORKSPACE is unset. The CWD-relative attempt remains last so a plain
// `go test` run with an absolute or relative override keeps working.
func resolveBinPath(bin string) string {
	if bin == "" {
		return ""
	}

	if filepath.IsAbs(bin) {
		if _, err := os.Stat(bin); err == nil {
			return bin
		}

		return ""
	}

	if srcDir := strings.TrimSpace(os.Getenv("TEST_SRCDIR")); srcDir != "" {
		for _, workspace := range []string{strings.TrimSpace(os.Getenv("TEST_WORKSPACE")), "_main"} {
			if workspace == "" {
				continue
			}

			if candidate := filepath.Join(srcDir, workspace, bin); fileExists(candidate) {
				return candidate
			}
		}
	}

	if abs, err := filepath.Abs(bin); err == nil && fileExists(abs) {
		return abs
	}

	return ""
}

func fileExists(path string) bool {
	info, err := os.Stat(path)

	return err == nil && !info.IsDir()
}

// resolveSampleAddonBin prefers a prebuilt binary supplied via
// SERVICERADAR_SAMPLE_ADDON_BIN (e.g. a Bazel data dependency) and otherwise
// compiles the reference add-on with the Go toolchain.
func resolveSampleAddonBin() string {
	if bin := resolveBinPath(os.Getenv("SERVICERADAR_SAMPLE_ADDON_BIN")); bin != "" {
		return bin
	}
	// Fall through to building when the supplied path cannot be resolved.

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

func waitForLifecycleState(t *testing.T, m *Manager, id string, state State, timeout time.Duration) Status {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if s, ok := statusByID(m, id); ok && s.State == state {
			return s
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("addon %s did not reach state %s within %s; status=%+v", id, state, timeout, m.Status())
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

	s := waitForState(t, mgr, "sample", 15*time.Second)
	if s.Version != "0.1.0" {
		t.Fatalf("expected the delivered version 0.1.0, got %q", s.Version)
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

func TestManagerSurfacesResourceLimitEnforcementFailure(t *testing.T) {
	requireSampleAddon(t)

	mgr := NewManager(testConfig(t))
	t.Cleanup(func() { stopManager(t, mgr) })

	err := mgr.Apply(context.Background(), []Spec{{
		ID:         "sample",
		Version:    "0.1.0",
		BinaryPath: sampleAddonBin,
		ConfigJSON: []byte(`{"message":"hi"}`),
		Resources: Resources{
			MemoryMaxBytes: 64 << 20,
			TasksMax:       16,
		},
	}})
	if err != nil {
		t.Fatalf("apply: %v", err)
	}

	s := waitForState(t, mgr, "sample", 15*time.Second)
	if s.ResourceLimitErr == "" {
		t.Fatalf("expected resource limit enforcement error in status, got %+v", s)
	}

	protoStatuses := ToProtoStatuses([]Status{s})
	if len(protoStatuses) != 1 {
		t.Fatalf("expected one proto status, got %d", len(protoStatuses))
	}
	if got := protoStatuses[0].GetLastError(); !strings.Contains(got, "resource limits not enforced") {
		t.Fatalf("expected resource warning in proto last_error, got %q", got)
	}
}

func TestRunnerRunOnceUsesSingleSpecSnapshot(t *testing.T) {
	initial := Spec{
		ID:         "sample",
		BinaryPath: filepath.Join(t.TempDir(), "missing-addon"),
		ConfigJSON: []byte("{}"),
	}
	r := newRunner(initial, applyDefaults(Config{RuntimeDir: t.TempDir()}))

	snapshotCaptured := make(chan struct{})
	continueStartup := make(chan struct{})
	r.localOtlpEndpoint = func() string {
		close(snapshotCaptured)
		<-continueStartup
		return ""
	}

	runDone := make(chan error, 1)
	go func() {
		runDone <- r.runOnce(t.Context())
	}()

	<-snapshotCaptured
	updated := initial
	updated.Resources = Resources{MemoryMaxBytes: 64 << 20}
	r.update(updated)
	close(continueStartup)

	if err := <-runDone; err == nil {
		t.Fatal("runOnce() with a missing binary returned nil")
	}
	if got := r.snapshot().ResourceLimitErr; got != "" {
		t.Fatalf("runOnce() mixed updated resources into the captured spec: %q", got)
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

func TestManagerCircuitBreakerCooldownPreventsImmediateRelaunch(t *testing.T) {
	cfg := testConfig(t)
	cfg.RestartBackoffInitial = 5 * time.Millisecond
	cfg.RestartBackoffMax = 10 * time.Millisecond
	cfg.RestartLimitPerMinute = 1
	cfg.CircuitBreakerCooldown = 150 * time.Millisecond

	mgr := NewManager(cfg)
	t.Cleanup(func() { stopManager(t, mgr) })

	spec := Spec{
		ID:         "broken",
		BinaryPath: filepath.Join(t.TempDir(), "missing-addon"),
		ConfigJSON: []byte(`{"generation":1}`),
	}
	if err := mgr.Apply(context.Background(), []Spec{spec}); err != nil {
		t.Fatalf("apply broken addon: %v", err)
	}

	circuitOpen := waitForLifecycleState(t, mgr, "broken", StateCircuitOpen, 2*time.Second)
	if circuitOpen.LastError == "" {
		t.Fatalf("expected circuit-open status to include last error: %+v", circuitOpen)
	}
	if circuitOpen.LastExitedAt.IsZero() {
		t.Fatalf("expected circuit-open status to record LastExitedAt: %+v", circuitOpen)
	}

	protoStatuses := ToProtoStatuses([]Status{circuitOpen})
	if len(protoStatuses) != 1 {
		t.Fatalf("expected one proto status, got %d", len(protoStatuses))
	}
	if got := protoStatuses[0].GetState(); got != string(StateCircuitOpen) {
		t.Fatalf("proto state = %q, want %q", got, StateCircuitOpen)
	}
	if protoStatuses[0].GetLastError() == "" {
		t.Fatal("expected circuit-open proto status to surface last_error")
	}

	mgr.mu.Lock()
	firstRunner := mgr.runners["broken"]
	mgr.mu.Unlock()
	if firstRunner == nil {
		t.Fatal("expected circuit-open runner to remain tracked")
	}

	spec.ConfigJSON = []byte(`{"generation":2}`)
	if err := mgr.Apply(context.Background(), []Spec{spec}); err != nil {
		t.Fatalf("apply during cooldown: %v", err)
	}

	mgr.mu.Lock()
	duringCooldown := mgr.runners["broken"]
	updatedConfig := append([]byte(nil), duringCooldown.spec.ConfigJSON...)
	mgr.mu.Unlock()
	if duringCooldown != firstRunner {
		t.Fatal("runner relaunched before circuit-breaker cooldown elapsed")
	}
	if string(updatedConfig) != string(spec.ConfigJSON) {
		t.Fatalf("config during cooldown = %s, want %s", updatedConfig, spec.ConfigJSON)
	}
	stillOpen := waitForLifecycleState(t, mgr, "broken", StateCircuitOpen, 200*time.Millisecond)
	if stillOpen.RestartCount != circuitOpen.RestartCount {
		t.Fatalf("restart count changed during cooldown: got %d, want %d", stillOpen.RestartCount, circuitOpen.RestartCount)
	}

	time.Sleep(cfg.CircuitBreakerCooldown + 50*time.Millisecond)
	if err := mgr.Apply(context.Background(), []Spec{spec}); err != nil {
		t.Fatalf("apply after cooldown: %v", err)
	}

	mgr.mu.Lock()
	afterCooldown := mgr.runners["broken"]
	mgr.mu.Unlock()
	if afterCooldown == nil {
		t.Fatal("expected runner after cooldown")
	}
	if afterCooldown == firstRunner {
		t.Fatal("runner was not relaunched after circuit-breaker cooldown elapsed")
	}
}

func TestManagerKeepsCircuitOpenRunnerUntilCooldownExpires(t *testing.T) {
	cfg := testConfig(t)
	cfg.RestartLimitPerMinute = 1
	mgr := NewManager(cfg)
	t.Cleanup(func() { stopManager(t, mgr) })

	spec := Spec{ID: "sample", BinaryPath: "/bin/false", ConfigJSON: []byte("{}")}
	circuit := newRunner(spec, mgr.cfg)
	circuit.status.State = StateCircuitOpen
	circuit.status.LastError = "addon exited"
	circuit.status.DegradationReason = "addon exited"
	circuit.circuitUntil = time.Now().UTC().Add(time.Minute)
	close(circuit.done)
	mgr.runners[spec.ID] = circuit

	if err := mgr.Apply(context.Background(), []Spec{spec}); err != nil {
		t.Fatalf("apply during cooldown: %v", err)
	}
	if got := mgr.runners[spec.ID]; got != circuit {
		t.Fatalf("expected circuit-open runner to remain during cooldown")
	}
	if s, ok := statusByID(mgr, spec.ID); !ok || s.State != StateCircuitOpen || s.LastError == "" {
		t.Fatalf("expected circuit_open status with last_error, got status=%+v ok=%v", s, ok)
	}

	circuit.circuitUntil = time.Now().UTC().Add(-time.Millisecond)
	if err := mgr.Apply(context.Background(), []Spec{spec}); err != nil {
		t.Fatalf("apply after cooldown: %v", err)
	}
	if got := mgr.runners[spec.ID]; got == circuit {
		t.Fatalf("expected manager to re-arm by replacing runner after cooldown")
	}
}

func TestRestartBackoffResetRequiresHealthyRuntime(t *testing.T) {
	cfg := testConfig(t)
	cfg.RestartBackoffMax = 100 * time.Millisecond
	r := newRunner(Spec{ID: "sample"}, cfg)

	now := time.Now().UTC()
	runStart := now.Add(-time.Second)
	if r.runWasStable(runStart, now) {
		t.Fatal("run with no healthy probe must not reset restart backoff")
	}

	r.healthySince = now.Add(-50 * time.Millisecond)
	if r.runWasStable(runStart, now) {
		t.Fatal("recent healthy probe below stability window must not reset restart backoff")
	}

	r.healthySince = now.Add(-150 * time.Millisecond)
	if !r.runWasStable(runStart, now) {
		t.Fatal("healthy runtime beyond stability window should reset restart backoff")
	}

	r.healthySince = runStart.Add(-time.Millisecond)
	if r.runWasStable(runStart, now) {
		t.Fatal("healthy probe from a previous run must not reset current restart backoff")
	}
}

func TestHealthySinceResetsWhenAddonDegrades(t *testing.T) {
	r := newRunner(Spec{ID: "sample"}, testConfig(t))

	r.setHealthy(123, coreaddon.Health{Status: coreaddon.HealthHealthy})
	if r.healthySince.IsZero() {
		t.Fatal("healthy probe should start the stability window")
	}

	firstHealthy := r.healthySince
	r.setHealthy(123, coreaddon.Health{Status: coreaddon.HealthHealthy})
	if !r.healthySince.Equal(firstHealthy) {
		t.Fatal("subsequent healthy probes must not restart the stability window")
	}

	r.setHealthy(123, coreaddon.Health{
		Status:            coreaddon.HealthDegraded,
		DegradationReason: "waiting for feed",
	})
	if !r.healthySince.IsZero() {
		t.Fatal("degraded health should clear the stability window")
	}
}

// The add-on protocol has three health levels and the control plane gates
// rollouts on the reported state, so Degraded must not arrive as "unhealthy".
// Collapsing them wedged powerdns and anomaly rollouts indefinitely while both
// add-ons were running correctly.
func TestSetHealthyReportsDegradedDistinctlyFromUnhealthy(t *testing.T) {
	cfg := testConfig(t)
	r := newRunner(Spec{ID: "sample"}, cfg)

	r.setHealthy(1, coreaddon.Health{
		Status:            coreaddon.HealthDegraded,
		DegradationReason: "no PowerDNS Recursor protobuf producer connected",
	})

	if got := r.status.State; got != StateDegraded {
		t.Fatalf("degraded health must report StateDegraded, got %q", got)
	}
	if r.status.DegradationReason == "" {
		t.Fatal("the reason must still be reported; suppressing the gate must not suppress the signal")
	}

	r.setHealthy(1, coreaddon.Health{
		Status:            coreaddon.HealthUnhealthy,
		DegradationReason: "systemd unit failed",
	})

	if got := r.status.State; got != StateUnhealthy {
		t.Fatalf("unhealthy health must still report StateUnhealthy, got %q", got)
	}

	r.setHealthy(1, coreaddon.Health{Status: coreaddon.HealthHealthy})
	if got := r.status.State; got != StateRunning {
		t.Fatalf("healthy must report StateRunning, got %q", got)
	}
	if r.status.DegradationReason != "" {
		t.Fatal("recovering must clear the degradation reason")
	}
}

func TestRecordRestartOpensCircuitUntilRestartWindowExpires(t *testing.T) {
	cfg := testConfig(t)
	cfg.RestartLimitPerMinute = 1
	r := newRunner(Spec{ID: "sample"}, cfg)

	if !r.recordRestart(errFirstExit) {
		t.Fatal("first restart should be allowed")
	}
	if r.recordRestart(errSecondExit) {
		t.Fatal("second restart inside limit window should open circuit")
	}
	r.setCircuitOpen("second exit")

	if !r.circuitOpenCoolingDown(time.Now().UTC()) {
		t.Fatal("expected circuit cooldown after restart limit is exceeded")
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

// The version an add-on reports must be the one the control plane DELIVERED, not the
// string the add-on author compiled in.
//
// The rollout health gate asks version_at_least?(observed, candidate). An add-on whose
// self-reported version has gone stale can therefore never satisfy a rollout to a newer
// one: it ages out at candidate_health_timeout, fails the rollout for the whole fleet,
// and the source's package is never advanced -- track_latest_approved looks dead while
// the add-on is running perfectly well. The anomaly add-on shipped 0.3.4 while reporting
// 0.3.0 and blocked every one of its own upgrades this way.
func TestManagerReportsDeliveredVersionNotSelfReported(t *testing.T) {
	requireSampleAddon(t)

	mgr := NewManager(testConfig(t))
	t.Cleanup(func() { stopManager(t, mgr) })

	// The reference add-on compiles in "0.1.0"; deliver a different version.
	const delivered = "0.9.9"

	err := mgr.Apply(context.Background(), []Spec{{
		ID:           "sample",
		Version:      delivered,
		BinaryPath:   sampleAddonBin,
		ConfigJSON:   []byte(`{"message":"hi"}`),
		Capabilities: []string{"sample"},
	}})
	if err != nil {
		t.Fatalf("apply: %v", err)
	}

	s := waitForState(t, mgr, "sample", 15*time.Second)
	if s.Version != delivered {
		t.Fatalf("status version = %q, want the delivered %q; the add-on's own %q must not win",
			s.Version, delivered, "0.1.0")
	}

	// Health reports must not walk it back either.
	time.Sleep(600 * time.Millisecond)

	after, ok := statusByID(mgr, "sample")
	if !ok {
		t.Fatal("sample add-on status disappeared")
	}
	if after.Version != delivered {
		t.Fatalf("status version after health cycles = %q, want %q", after.Version, delivered)
	}
}
