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
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"sync"
	"time"

	coreaddon "github.com/carverauto/serviceradar/go/pkg/addon"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	hclog "github.com/hashicorp/go-hclog"
	goplugin "github.com/hashicorp/go-plugin"
	"github.com/rs/zerolog"
)

const (
	defaultRuntimeDir            = "/run/serviceradar/addons"
	defaultHealthInterval        = 5 * time.Second
	defaultUnhealthyThreshold    = 3
	defaultConfigureTimeout      = 10 * time.Second
	defaultHealthTimeout         = 5 * time.Second
	defaultRestartBackoffInitial = time.Second
	defaultRestartBackoffMax     = time.Minute
	defaultRestartLimitPerMinute = 5
)

// Config controls add-on manager paths and supervision timing.
type Config struct {
	// RuntimeDir is the base directory under which go-plugin creates per-add-on
	// Unix-domain sockets (UnixSocketConfig.TempDir).
	RuntimeDir            string
	HealthInterval        time.Duration
	HealthTimeout         time.Duration
	UnhealthyThreshold    int
	ConfigureTimeout      time.Duration
	RestartBackoffInitial time.Duration
	RestartBackoffMax     time.Duration
	RestartLimitPerMinute int
	Logger                zerolog.Logger
}

func applyDefaults(cfg Config) Config {
	if cfg.RuntimeDir == "" {
		cfg.RuntimeDir = defaultRuntimeDir
	}
	if cfg.HealthInterval <= 0 {
		cfg.HealthInterval = defaultHealthInterval
	}
	if cfg.HealthTimeout <= 0 {
		cfg.HealthTimeout = defaultHealthTimeout
	}
	if cfg.UnhealthyThreshold <= 0 {
		cfg.UnhealthyThreshold = defaultUnhealthyThreshold
	}
	if cfg.ConfigureTimeout <= 0 {
		cfg.ConfigureTimeout = defaultConfigureTimeout
	}
	if cfg.RestartBackoffInitial <= 0 {
		cfg.RestartBackoffInitial = defaultRestartBackoffInitial
	}
	if cfg.RestartBackoffMax <= 0 {
		cfg.RestartBackoffMax = defaultRestartBackoffMax
	}
	if cfg.RestartLimitPerMinute <= 0 {
		cfg.RestartLimitPerMinute = defaultRestartLimitPerMinute
	}
	if cfg.Logger.GetLevel() == zerolog.Disabled {
		cfg.Logger = logger.GetLogger().With().Str("component", "agent.addon").Logger()
	}
	return cfg
}

// Manager supervises native add-on subprocesses over go-plugin.
type Manager struct {
	cfg Config

	mu      sync.Mutex
	runners map[string]*runner
	closed  bool
}

var _ AddonManager = (*Manager)(nil)

// NewManager creates an add-on manager with the provided configuration.
func NewManager(cfg Config) *Manager {
	return &Manager{
		cfg:     applyDefaults(cfg),
		runners: make(map[string]*runner),
	}
}

// Apply reconciles the supervised add-ons to the desired set: it launches new
// add-ons, restarts ones whose binary/args changed or whose supervisor has exited
// (e.g. after the restart circuit breaker tripped), reconfigures config-only
// changes, and stops removed ones.
func (m *Manager) Apply(_ context.Context, specs []Spec) error {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return ErrManagerClosed
	}

	desired := make(map[string]Spec, len(specs))
	for _, s := range specs {
		desired[s.ID] = s
	}

	// Collect runners to tear down and shut them down AFTER releasing the lock:
	// shutdown blocks on the go-plugin client Kill (seconds), and Status()/Stop()
	// take the same mutex.
	var toStop []*runner

	for id, r := range m.runners {
		if _, ok := desired[id]; !ok {
			toStop = append(toStop, r)
			delete(m.runners, id)
		}
	}

	for id, spec := range desired {
		r, ok := m.runners[id]
		switch {
		case !ok:
			m.startRunnerLocked(spec)
		case r.finished() || r.needsRestart(spec):
			// Supervisor exited (circuit breaker) or a restart-boundary field
			// (binary/args) changed: replace the runner so the new binary/args
			// actually launch instead of reconfiguring the old process.
			toStop = append(toStop, r)
			delete(m.runners, id)
			m.startRunnerLocked(spec)
		default:
			r.update(spec)
		}
	}

	m.mu.Unlock()

	for _, r := range toStop {
		r.shutdown()
	}

	return nil
}

// startRunnerLocked creates and starts a supervisor for spec. The caller holds m.mu.
func (m *Manager) startRunnerLocked(spec Spec) {
	r := newRunner(spec, m.cfg)
	m.runners[spec.ID] = r
	ctx, cancel := context.WithCancel(context.Background())
	r.cancel = cancel
	go r.run(ctx)
}

// Status returns a stable snapshot of every supervised add-on.
func (m *Manager) Status() []Status {
	m.mu.Lock()
	defer m.mu.Unlock()

	statuses := make([]Status, 0, len(m.runners))
	for _, r := range m.runners {
		statuses = append(statuses, r.snapshot())
	}
	return statuses
}

// Stop terminates all add-ons and waits for their supervisors to exit.
func (m *Manager) Stop(ctx context.Context) error {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return nil
	}
	m.closed = true
	runners := make([]*runner, 0, len(m.runners))
	for _, r := range m.runners {
		runners = append(runners, r)
	}
	m.runners = make(map[string]*runner)
	m.mu.Unlock()

	for _, r := range runners {
		r.cancel()
	}
	for _, r := range runners {
		select {
		case <-r.done:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}

// runner supervises a single add-on subprocess.
type runner struct {
	id       string
	cfg      Config
	hclogger hclog.Logger

	cancel context.CancelFunc
	done   chan struct{}

	reconfigure chan struct{}

	mu            sync.Mutex
	spec          Spec
	status        Status
	restartWindow []time.Time
}

func newRunner(spec Spec, cfg Config) *runner {
	return &runner{
		id:          spec.ID,
		cfg:         cfg,
		hclogger:    hclog.New(&hclog.LoggerOptions{Name: "addon." + spec.ID, Level: hclog.Warn, Output: os.Stderr}),
		done:        make(chan struct{}),
		reconfigure: make(chan struct{}, 1),
		spec:        spec,
		status:      Status{ID: spec.ID, State: StateStopped, Version: spec.Version, Arch: runtime.GOARCH},
	}
}

// update applies a config-only spec change to a running add-on, signalling
// reconfiguration when the delivered configuration changed. Binary/args changes
// are restart boundaries handled by Apply (relaunch), not here.
func (r *runner) update(spec Spec) {
	r.mu.Lock()
	changed := !bytes.Equal(r.spec.ConfigJSON, spec.ConfigJSON)
	r.spec = spec
	r.mu.Unlock()

	if changed {
		select {
		case r.reconfigure <- struct{}{}:
		default:
		}
	}
}

// finished reports whether the runner's supervisor goroutine has exited (stopped
// or circuit-broken), so Apply can replace it instead of issuing a dead reconfigure.
func (r *runner) finished() bool {
	select {
	case <-r.done:
		return true
	default:
		return false
	}
}

// needsRestart reports whether a restart-boundary field changed (the binary path
// or its args), which requires relaunching the subprocess rather than reconfiguring.
func (r *runner) needsRestart(spec Spec) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.spec.BinaryPath != spec.BinaryPath || !equalStrings(r.spec.Args, spec.Args)
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// shutdown cancels the runner and waits for its supervisor loop to exit.
func (r *runner) shutdown() {
	if r.cancel != nil {
		r.cancel()
	}
	<-r.done
}

func (r *runner) currentSpec() Spec {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.spec
}

func (r *runner) run(ctx context.Context) {
	defer close(r.done)

	backoff := r.cfg.RestartBackoffInitial
	for {
		if ctx.Err() != nil {
			r.setState(StateStopped, "")
			return
		}

		runStart := time.Now()
		err := r.runOnce(ctx)
		if ctx.Err() != nil {
			r.setState(StateStopped, "")
			return
		}

		if !r.recordRestart(err) {
			r.setState(StateCircuitOpen, errString(err))
			return
		}

		r.setState(StateRestarting, errString(err))
		if time.Since(runStart) >= r.cfg.RestartBackoffMax {
			backoff = r.cfg.RestartBackoffInitial
		}

		timer := time.NewTimer(backoff)
		select {
		case <-ctx.Done():
			timer.Stop()
			r.setState(StateStopped, "")
			return
		case <-timer.C:
		}

		backoff *= 2
		if backoff > r.cfg.RestartBackoffMax {
			backoff = r.cfg.RestartBackoffMax
		}
	}
}

func (r *runner) runOnce(ctx context.Context) error {
	spec := r.currentSpec()
	r.setState(StateStarting, "")

	client := goplugin.NewClient(&goplugin.ClientConfig{
		HandshakeConfig:  coreaddon.Handshake,
		Plugins:          coreaddon.ClientPluginSet(),
		Cmd:              exec.CommandContext(ctx, spec.BinaryPath, spec.Args...), //nolint:gosec // path comes from a verified, signed add-on artifact
		AllowedProtocols: []goplugin.Protocol{goplugin.ProtocolGRPC},
		AutoMTLS:         true,
		Logger:           r.hclogger,
		UnixSocketConfig: &goplugin.UnixSocketConfig{TempDir: r.cfg.RuntimeDir},
	})
	defer client.Kill()

	rpcClient, err := client.Client()
	if err != nil {
		r.setExited(errString(err))
		return fmt.Errorf("start addon %s: %w", r.id, err)
	}

	raw, err := rpcClient.Dispense(coreaddon.PluginName)
	if err != nil {
		r.setExited(errString(err))
		return fmt.Errorf("dispense addon %s: %w", r.id, err)
	}

	ac, ok := raw.(coreaddon.Addon)
	if !ok {
		return fmt.Errorf("addon %s: %w (got %T)", r.id, ErrUnexpectedClientType, raw)
	}

	pid := 0
	if rc := client.ReattachConfig(); rc != nil {
		pid = rc.Pid
	}

	if err := r.configure(ctx, ac); err != nil {
		r.setExited(errString(err))
		return fmt.Errorf("configure addon %s: %w", r.id, err)
	}

	version := spec.Version
	if info, err := ac.Info(ctx); err == nil && info.Version != "" {
		version = info.Version
	}
	r.setRunning(pid, version)

	return r.supervise(ctx, client, ac, pid)
}

// supervise polls health and applies reconfiguration until the add-on exits or
// the context is cancelled.
func (r *runner) supervise(ctx context.Context, client *goplugin.Client, ac coreaddon.Addon, pid int) error {
	ticker := time.NewTicker(r.cfg.HealthInterval)
	defer ticker.Stop()

	failures := 0
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-r.reconfigure:
			if err := r.configure(ctx, ac); err != nil {
				r.cfg.Logger.Warn().Err(err).Str("addon", r.id).Msg("addon reconfigure failed")
			}
		case <-ticker.C:
			if client.Exited() {
				r.setExited("plugin process exited")
				return fmt.Errorf("%w: %s", ErrAddonExited, r.id)
			}

			h, err := r.probeHealth(ctx, ac)
			if err != nil {
				failures++
				if failures >= r.cfg.UnhealthyThreshold {
					r.setUnhealthy(pid, errString(err))
				}
				if client.Exited() {
					r.setExited(errString(err))
					return fmt.Errorf("%w: %s: %w", ErrAddonExited, r.id, err)
				}
				continue
			}

			failures = 0
			r.setHealthy(pid, h)
		}
	}
}

func (r *runner) probeHealth(parent context.Context, ac coreaddon.Addon) (coreaddon.Health, error) {
	ctx, cancel := context.WithTimeout(parent, r.cfg.HealthTimeout)
	defer cancel()
	return ac.Health(ctx)
}

func (r *runner) configure(parent context.Context, ac coreaddon.Addon) error {
	spec := r.currentSpec()
	ctx, cancel := context.WithTimeout(parent, r.cfg.ConfigureTimeout)
	defer cancel()

	res, err := ac.Configure(ctx, spec.ConfigJSON)
	if err != nil {
		return err
	}
	if !res.Accepted {
		return fmt.Errorf("addon %s: %w: %s", r.id, ErrConfigurationRejected, res.Error)
	}

	r.mu.Lock()
	r.status.ConfigHash = res.ConfigHash
	r.mu.Unlock()
	return nil
}

func (r *runner) snapshot() Status {
	r.mu.Lock()
	defer r.mu.Unlock()
	status := r.status
	status.Capabilities = append([]string(nil), r.spec.Capabilities...)
	return status
}

func (r *runner) setState(state State, lastErr string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.status.State = state
	r.status.PID = 0
	r.status.LastError = lastErr
}

func (r *runner) setRunning(pid int, version string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.status.State = StateRunning
	r.status.PID = pid
	r.status.Version = version
	r.status.DegradationReason = ""
	r.status.LastStartedAt = time.Now().UTC()
	r.status.LastExitedAt = time.Time{}
	r.status.LastError = ""
}

func (r *runner) setHealthy(pid int, h coreaddon.Health) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if h.Status == coreaddon.HealthDegraded || h.Status == coreaddon.HealthUnhealthy {
		r.status.State = StateUnhealthy
		r.status.DegradationReason = h.DegradationReason
	} else {
		r.status.State = StateRunning
		r.status.DegradationReason = ""
	}
	r.status.PID = pid
	if h.Version != "" {
		r.status.Version = h.Version
	}
	r.status.LastHealthAt = time.Now().UTC()
	r.status.LastError = ""
}

func (r *runner) setUnhealthy(pid int, lastErr string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.status.State = StateUnhealthy
	r.status.PID = pid
	r.status.LastError = lastErr
}

func (r *runner) setExited(lastErr string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.status.PID = 0
	r.status.LastExitedAt = time.Now().UTC()
	r.status.LastError = lastErr
}

func (r *runner) recordRestart(err error) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now().UTC()
	cutoff := now.Add(-time.Minute)
	kept := r.restartWindow[:0]
	for _, ts := range r.restartWindow {
		if ts.After(cutoff) {
			kept = append(kept, ts)
		}
	}
	r.restartWindow = kept

	if len(r.restartWindow) >= r.cfg.RestartLimitPerMinute {
		r.status.LastError = errString(err)
		return false
	}

	r.restartWindow = append(r.restartWindow, now)
	r.status.RestartCount++
	return true
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
