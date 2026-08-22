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
	defaultRuntimeDir             = "/run/serviceradar/addons"
	defaultHealthInterval         = 5 * time.Second
	defaultUnhealthyThreshold     = 3
	defaultConfigureTimeout       = 10 * time.Second
	defaultCommandTimeout         = 300 * time.Second
	defaultHealthTimeout          = 5 * time.Second
	defaultRestartBackoffInitial  = time.Second
	defaultRestartBackoffMax      = time.Minute
	defaultRestartLimitPerMinute  = 5
	defaultCircuitBreakerCooldown = time.Minute
	restartLimitWindow            = time.Minute
)

// Config controls add-on manager paths and supervision timing.
type Config struct {
	// RuntimeDir is the base directory under which go-plugin creates per-add-on
	// Unix-domain sockets (UnixSocketConfig.TempDir).
	RuntimeDir             string
	HealthInterval         time.Duration
	HealthTimeout          time.Duration
	UnhealthyThreshold     int
	ConfigureTimeout       time.Duration
	RestartBackoffInitial  time.Duration
	RestartBackoffMax      time.Duration
	RestartLimitPerMinute  int
	CircuitBreakerCooldown time.Duration
	ArtifactMaxBytes       int64
	CredentialResolver     coreaddon.CredentialResolver
	TelemetryHandler       func(addonID string, batch *coreaddon.TelemetryBatch)
	ArtifactHandler        ArtifactHandler
	// OtlpRelayRunner, when set, is invoked on its own goroutine for every
	// running add-on that advertises CapabilityOtlpRelayV1 and supports the
	// client-side relay stream. It owns the acked OTLP relay pump for one
	// add-on instance and must return promptly when ctx is cancelled: the
	// manager cancels ctx when the add-on stops, restarts, or turns
	// unhealthy, and on agent shutdown, then re-invokes the runner when the
	// add-on is healthy again (the add-on resumes from its durable ack
	// watermark, so stop/start is lossless).
	OtlpRelayRunner func(ctx context.Context, addonID string, client coreaddon.OtlpRelayClient)
	// LocalOtlpEndpoint is a static fallback OTLP endpoint for add-on
	// self-telemetry (agent config knob), used only when the desired add-on
	// set does not include a sidecar-supervised otel-collector to derive the
	// endpoint from (for example, a collector running as a systemd add-on or
	// host service). The endpoint derived from the otel-collector add-on's
	// delivered config always wins.
	LocalOtlpEndpoint string
	// AddonCgroupRoot is a cgroup v2 directory the agent may write to (a delegated
	// sub-tree) under which add-on subprocesses are placed with their manifest
	// resource limits. Empty disables cgroup enforcement.
	AddonCgroupRoot string
	Logger          zerolog.Logger
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
	if cfg.CircuitBreakerCooldown <= 0 {
		cfg.CircuitBreakerCooldown = defaultCircuitBreakerCooldown
	}
	if cfg.ArtifactMaxBytes <= 0 {
		cfg.ArtifactMaxBytes = defaultArtifactMaxBytes
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
	// localOtlpEndpoint is the self-telemetry OTLP endpoint injected into
	// spawned add-on environments, derived from the otel-collector add-on's
	// delivered config on every Apply (falling back to cfg.LocalOtlpEndpoint,
	// then ""). Read at spawn time so restarts pick up the current value.
	localOtlpEndpoint string
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

	// Self-telemetry: derive the local OTLP endpoint from the otel-collector
	// add-on's delivered config (cross-add-on config access happens here, at
	// reconcile time, where every desired spec is in hand). Add-ons spawned
	// or restarted from now on export to it; already-running add-ons keep
	// their spawn-time environment until their next restart.
	m.localOtlpEndpoint = localOtlpEndpointFromSpecs(specs)
	if m.localOtlpEndpoint == "" {
		m.localOtlpEndpoint = m.cfg.LocalOtlpEndpoint
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
		case r.needsRestart(spec):
			// A restart-boundary field changed: replace the runner immediately
			// so operator remediation is not held behind a circuit cooldown.
			toStop = append(toStop, r)
			delete(m.runners, id)
			m.startRunnerLocked(spec)
		case r.finished():
			// Circuit-open runners stay visible until their cooldown expires,
			// but still absorb config-only updates for the eventual restart.
			r.update(spec)
			if r.circuitBreakerCoolingDown(time.Now().UTC()) || r.circuitOpenCoolingDown(time.Now().UTC()) {
				continue
			}
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

// SetCredentialResolver installs the trusted gateway-backed credential resolver
// used for configure-time native add-on credential injection.
func (m *Manager) SetCredentialResolver(resolver coreaddon.CredentialResolver) {
	if m == nil {
		return
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.cfg.CredentialResolver = resolver
	for _, r := range m.runners {
		r.setCredentialResolver(resolver)
	}
}

// startRunnerLocked creates and starts a supervisor for spec. The caller holds m.mu.
func (m *Manager) startRunnerLocked(spec Spec) {
	r := newRunner(spec, m.cfg)
	r.localOtlpEndpoint = m.currentLocalOtlpEndpoint
	m.runners[spec.ID] = r
	ctx, cancel := context.WithCancel(context.Background())
	r.cancel = cancel
	go r.run(ctx)
}

// currentLocalOtlpEndpoint returns the self-telemetry OTLP endpoint derived
// by the most recent Apply ("" when no collector is configured).
func (m *Manager) currentLocalOtlpEndpoint() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.localOtlpEndpoint
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

// RunCommand executes a generic command against a supervised native add-on.
func (m *Manager) RunCommand(ctx context.Context, invocation CommandInvocation) (coreaddon.CommandResult, error) {
	if m == nil {
		return coreaddon.CommandResult{}, ErrAddonCommandUnavailable
	}

	r, err := m.commandRunner(invocation)
	if err != nil {
		return coreaddon.CommandResult{}, err
	}

	return r.runCommand(ctx, invocation)
}

func (m *Manager) commandRunner(invocation CommandInvocation) (*runner, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.closed {
		return nil, ErrManagerClosed
	}

	if invocation.AssignmentID != "" {
		for _, r := range m.runners {
			if r.currentSpec().AssignmentID == invocation.AssignmentID {
				return r, nil
			}
		}
		return nil, ErrAddonAssignmentNotFound
	}

	if invocation.AddonID != "" {
		if r, ok := m.runners[invocation.AddonID]; ok {
			return r, nil
		}
	}

	return nil, ErrAddonAssignmentNotFound
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

	// localOtlpEndpoint, when non-nil, supplies the current self-telemetry
	// OTLP endpoint at spawn time (nil in tests that build runners directly).
	localOtlpEndpoint func() string

	reconfigure chan struct{}

	mu            sync.Mutex
	spec          Spec
	status        Status
	restartWindow []time.Time
	circuitUntil  time.Time
	healthySince  time.Time
	commandClient coreaddon.CommandClient
	// metricFeed is the source-aware local metric feed opened by a metric-feed:v1
	// add-on, or nil when no subscribed feed is active. Guarded by mu.
	metricFeed *metricFeedLifecycle
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

func (r *runner) setCredentialResolver(resolver coreaddon.CredentialResolver) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.cfg.CredentialResolver = resolver
}

func (r *runner) credentialResolver() coreaddon.CredentialResolver {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.cfg.CredentialResolver
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

// needsRestart reports whether a restart-boundary field changed (the assigned
// version, binary path, or args), which requires relaunching the subprocess
// rather than reconfiguring. Version is a restart boundary because add-ons are
// launched through stable "current" symlinks whose string path does not change
// when the symlink is retargeted to a new package directory.
func (r *runner) needsRestart(spec Spec) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.spec.Version != spec.Version ||
		r.spec.BinaryPath != spec.BinaryPath ||
		!equalStrings(r.spec.Args, spec.Args) ||
		!equalStrings(metricFeedSourcesFromConfig(r.spec.ConfigJSON), metricFeedSourcesFromConfig(spec.ConfigJSON))
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
			r.setCircuitOpen(errString(err))
			return
		}

		r.setState(StateRestarting, errString(err))
		if r.runWasStable(runStart, time.Now().UTC()) {
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

	cmd := exec.CommandContext(ctx, spec.BinaryPath, spec.Args...) //nolint:gosec // path comes from a verified, signed add-on artifact

	// Self-telemetry env convention (10.5): point the add-on at the local
	// otel-collector when one is configured. addonProcessEnv handles the
	// loop guard (never the collector itself), the operator opt-out, and
	// explicit-endpoint precedence.
	localEndpoint := ""
	if r.localOtlpEndpoint != nil {
		localEndpoint = r.localOtlpEndpoint()
	}
	cmd.Env = addonProcessEnv(os.Environ(), r.id, localEndpoint)

	// Enforce the manifest resource limits on the add-on subprocess (cgroup v2 on
	// Linux). Best-effort: a failure to enforce logs, is surfaced through status,
	// and launches without limits rather than blocking the add-on.
	if cleanup, cgroupPath, err := applyResourceLimits(cmd, r.id, spec.Resources, r.cfg.AddonCgroupRoot, r.cfg.Logger); err != nil {
		r.cfg.Logger.Warn().Err(err).Str("addon", r.id).
			Msg("addon resource limits not enforced; launching without limits")
		r.setResourceLimits("", fmt.Sprintf("resource limits not enforced: %v", err))
	} else {
		r.setResourceLimits(cgroupPath, "")
		defer cleanup()
	}

	client := goplugin.NewClient(&goplugin.ClientConfig{
		HandshakeConfig:  coreaddon.Handshake,
		Plugins:          coreaddon.ClientPluginSet(),
		Cmd:              cmd,
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

	// The DELIVERED version is authoritative, never the plugin's self-report.
	//
	// The artifact is sha256- plus signature-verified at staging, so the bytes running
	// here are by construction the packaged version; `info.Version` is just a string the
	// add-on author compiled in, and it goes stale the moment they forget to bump it.
	//
	// Letting it win silently stalls the fleet. The rollout health gate asks
	// `version_at_least?(observed, candidate)`, so an add-on that reports a frozen
	// version can never satisfy a rollout to a newer one: it ages out at
	// `candidate_health_timeout`, fails the rollout, and the source's package is never
	// advanced -- `track_latest_approved` looks dead while the add-on is running fine.
	// This is exactly how the anomaly add-on (shipped 0.3.4, self-reporting 0.3.0)
	// blocked its own upgrades.
	//
	// Capabilities are different and still come from the running add-on: they describe
	// what this process can actually do right now, which the manifest cannot know.
	version := spec.Version
	capabilities := append([]string(nil), spec.Capabilities...)
	if info, err := ac.Info(ctx); err == nil {
		if len(info.Capabilities) > 0 {
			capabilities = append([]string(nil), info.Capabilities...)
		}
	}

	r.setRunning(pid, version, capabilities)
	r.setCommandClient(ac)
	defer r.clearCommandClient(ac)

	telemetryCtx, telemetryCancel := context.WithCancel(ctx)
	defer telemetryCancel()
	if diagnostics, ok := ac.(coreaddon.StreamLossDiagnostics); ok {
		go r.drainStreamLossDiagnostics(telemetryCtx, diagnostics.StreamLossEvents())
	}
	if hasCapability(capabilities, coreaddon.CapabilityNativeTelemetryV1) {
		if telemetryClient, ok := ac.(coreaddon.TelemetryClient); ok {
			go r.drainTelemetry(telemetryCtx, telemetryClient)
		}
	}
	if r.cfg.ArtifactHandler != nil && hasCapability(capabilities, coreaddon.CapabilityArtifactStagingV1) {
		if artifactClient, ok := ac.(coreaddon.ArtifactClient); ok {
			go r.drainArtifacts(telemetryCtx, artifactClient)
		}
	}

	var relay *relayLifecycle
	if hasCapability(capabilities, coreaddon.CapabilityOtlpRelayV1) && r.cfg.OtlpRelayRunner != nil {
		if relayClient, ok := ac.(coreaddon.OtlpRelayClient); ok {
			relay = newRelayLifecycle(ctx, r.id, relayClient, r.cfg.OtlpRelayRunner)
			relay.start()
			defer relay.stop()
		}
	}

	if hasCapability(capabilities, coreaddon.CapabilityMetricFeedV1) {
		if feedClient, ok := ac.(coreaddon.MetricFeedClient); ok {
			if lifecycle := r.startMetricFeed(telemetryCtx, feedClient); lifecycle != nil {
				defer func() {
					lifecycle.stop()
					r.clearMetricFeed(lifecycle)
				}()
			}
		}
	}

	return r.supervise(ctx, client, ac, pid, relay)
}

// relayLifecycle ties the OTLP relay runner goroutine to the add-on's health
// transitions: the pump runs while the add-on is running and healthy, stops
// when it degrades or turns unhealthy, and restarts when it recovers. The
// add-on resumes from its durable ack watermark on every restart, so the
// stop/start cycle is lossless. A nil *relayLifecycle is a no-op.
type relayLifecycle struct {
	parent  context.Context
	addonID string
	client  coreaddon.OtlpRelayClient
	runner  func(ctx context.Context, addonID string, client coreaddon.OtlpRelayClient)

	mu     sync.Mutex
	cancel context.CancelFunc
	done   chan struct{}
}

func newRelayLifecycle(
	parent context.Context,
	addonID string,
	client coreaddon.OtlpRelayClient,
	runner func(ctx context.Context, addonID string, client coreaddon.OtlpRelayClient),
) *relayLifecycle {
	return &relayLifecycle{parent: parent, addonID: addonID, client: client, runner: runner}
}

// start launches the relay runner goroutine if it is not already running.
func (l *relayLifecycle) start() {
	if l == nil {
		return
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	if l.cancel != nil || l.parent.Err() != nil {
		return
	}

	ctx, cancel := context.WithCancel(l.parent)
	done := make(chan struct{})
	l.cancel = cancel
	l.done = done

	go func() {
		defer close(done)
		l.runner(ctx, l.addonID, l.client)
	}()
}

// stop cancels the relay runner and waits for it to return.
func (l *relayLifecycle) stop() {
	if l == nil {
		return
	}

	l.mu.Lock()
	cancel, done := l.cancel, l.done
	l.cancel, l.done = nil, nil
	l.mu.Unlock()

	if cancel == nil {
		return
	}
	cancel()
	<-done
}

func (r *runner) runCommand(parent context.Context, invocation CommandInvocation) (coreaddon.CommandResult, error) {
	client, err := r.commandClientSnapshot()
	if err != nil {
		return coreaddon.CommandResult{}, err
	}

	timeout := invocation.Timeout
	if timeout <= 0 {
		timeout = defaultCommandTimeout
	}

	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	return client.RunCommand(ctx, coreaddon.CommandRequest{
		CommandID:    invocation.CommandID,
		CommandType:  invocation.CommandType,
		ActionID:     invocation.ActionID,
		Schema:       invocation.Schema,
		PayloadJSON:  invocation.PayloadJSON,
		DeadlineUnix: invocation.DeadlineUnix,
		Metadata:     invocation.Metadata,
	})
}

func (r *runner) commandClientSnapshot() (coreaddon.CommandClient, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.status.State != StateRunning {
		return nil, ErrAddonCommandUnavailable
	}
	if r.commandClient == nil {
		return nil, ErrAddonCommandUnavailable
	}
	return r.commandClient, nil
}

func (r *runner) setCommandClient(ac coreaddon.Addon) {
	commandClient, ok := ac.(coreaddon.CommandClient)
	if !ok {
		return
	}

	r.mu.Lock()
	r.commandClient = commandClient
	r.mu.Unlock()
}

func (r *runner) clearCommandClient(ac coreaddon.Addon) {
	commandClient, ok := ac.(coreaddon.CommandClient)
	if !ok {
		return
	}

	r.mu.Lock()
	if r.commandClient == commandClient {
		r.commandClient = nil
	}
	r.mu.Unlock()
}

func hasCapability(capabilities []string, capability string) bool {
	for _, candidate := range capabilities {
		if candidate == capability {
			return true
		}
	}
	return false
}

// startMetricFeed opens the local metric feed against a metric-feed:v1 add-on
// when its delivered config explicitly subscribes to at least one source.
func (r *runner) startMetricFeed(ctx context.Context, client coreaddon.MetricFeedClient) *metricFeedLifecycle {
	spec := r.currentSpec()
	sources := metricFeedSourcesFromConfig(spec.ConfigJSON)
	if len(sources) == 0 {
		r.cfg.Logger.Debug().Str("addon", r.id).Msg("metric-feed add-on has no subscribed sources")
		return nil
	}

	lifecycle := newMetricFeedLifecycle(
		ctx,
		r.id,
		client,
		sources,
		r.cfg.Logger,
		r.cfg.RestartBackoffInitial,
		r.cfg.RestartBackoffMax,
	)
	lifecycle.start()

	r.mu.Lock()
	r.metricFeed = lifecycle
	r.mu.Unlock()

	return lifecycle
}

func (r *runner) clearMetricFeed(lifecycle *metricFeedLifecycle) {
	r.mu.Lock()
	if r.metricFeed == lifecycle {
		r.metricFeed = nil
	}
	r.mu.Unlock()
}

func (r *runner) publishMetricFeed(source string, payload []byte) bool {
	r.mu.Lock()
	lifecycle := r.metricFeed
	r.mu.Unlock()
	if lifecycle == nil {
		return false
	}

	return lifecycle.publish(source, payload)
}

// PublishMetricFeed fans a locally collected MetricBatch out only to running
// add-ons that explicitly subscribed to source. The call is non-blocking and
// lossy by contract.
func (m *Manager) PublishMetricFeed(source string, payload []byte) int {
	if m == nil || len(payload) == 0 || canonicalMetricFeedSource(source) == "" {
		return 0
	}

	m.mu.Lock()
	runners := make([]*runner, 0, len(m.runners))
	for _, r := range m.runners {
		runners = append(runners, r)
	}
	m.mu.Unlock()

	accepted := 0
	for _, r := range runners {
		if r.publishMetricFeed(source, payload) {
			accepted++
		}
	}
	return accepted
}

func (r *runner) drainStreamLossDiagnostics(ctx context.Context, events <-chan coreaddon.StreamLossEvent) {
	for {
		select {
		case <-ctx.Done():
			return
		case event, ok := <-events:
			if !ok {
				return
			}
			log := r.cfg.Logger.Warn().
				Str("addon", r.id).
				Str("stream", event.Stream).
				Str("operation", event.Operation)
			if event.EOF {
				log.Str("reason", "eof").Msg("addon stream ended")
				continue
			}
			log.Err(event.Err).Str("reason", "error").Msg("addon stream ended")
		}
	}
}

func (r *runner) drainTelemetry(ctx context.Context, telemetryClient coreaddon.TelemetryClient) {
	diagnostics := streamDiagnostics(telemetryClient)

	reconnectStreamLoop(
		ctx,
		r.cfg.RestartBackoffInitial,
		r.cfg.RestartBackoffMax,
		func(ctx context.Context) (<-chan *coreaddon.TelemetryBatch, error) {
			return telemetryClient.StreamTelemetry(ctx)
		},
		r.drainTelemetryStream,
		func(err error, delay time.Duration) {
			r.cfg.Logger.Warn().
				Err(err).
				Str("addon", r.id).
				Dur("retry_after", delay).
				Msg("addon telemetry stream failed to open")
		},
		func(delay time.Duration) {
			diagnostic := readStreamDiagnostic(diagnostics)
			stream := diagnostic.Stream
			if stream == "" {
				stream = coreaddon.StreamNameTelemetry
			}

			log := r.cfg.Logger.Warn().
				Str("addon", r.id).
				Str("stream", stream).
				Str("stream_end", string(diagnostic.Kind)).
				Dur("retry_after", delay)
			if diagnostic.Err != nil {
				log.Err(diagnostic.Err)
			}
			log.Msg("addon telemetry stream closed; reconnecting")
		},
	)
}

func (r *runner) drainTelemetryStream(ctx context.Context, batches <-chan *coreaddon.TelemetryBatch) bool {
	madeProgress := false
	for {
		select {
		case <-ctx.Done():
			return madeProgress
		case batch, ok := <-batches:
			if !ok {
				return madeProgress
			}
			if batch == nil {
				continue
			}
			madeProgress = true
			if r.cfg.TelemetryHandler != nil {
				r.cfg.TelemetryHandler(r.id, batch)
			}
		}
	}
}

func streamDiagnostics(client interface{}) <-chan coreaddon.StreamDiagnostic {
	diagnostics, ok := client.(coreaddon.StreamDiagnosticsClient)
	if !ok {
		return nil
	}
	return diagnostics.StreamDiagnostics()
}

func readStreamDiagnostic(diagnostics <-chan coreaddon.StreamDiagnostic) coreaddon.StreamDiagnostic {
	if diagnostics == nil {
		return coreaddon.StreamDiagnostic{Kind: "unknown"}
	}

	select {
	case diagnostic := <-diagnostics:
		if diagnostic.Kind == "" {
			diagnostic.Kind = "unknown"
		}
		return diagnostic
	default:
		return coreaddon.StreamDiagnostic{Kind: "unknown"}
	}
}

// supervise polls health and applies reconfiguration until the add-on exits or
// the context is cancelled. relay (which may be nil) is stopped while the
// add-on is degraded/unhealthy and restarted when it recovers.
func (r *runner) supervise(ctx context.Context, client *goplugin.Client, ac coreaddon.Addon, pid int, relay *relayLifecycle) error {
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
					relay.stop()
				}
				if client.Exited() {
					r.setExited(errString(err))
					return fmt.Errorf("%w: %s: %w", ErrAddonExited, r.id, err)
				}
				continue
			}

			failures = 0
			r.setHealthy(pid, h)
			if h.Status == coreaddon.HealthDegraded || h.Status == coreaddon.HealthUnhealthy {
				relay.stop()
			} else {
				relay.start()
			}
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

	configJSON, err := injectCredentialMaterials(ctx, spec.ConfigJSON, r.credentialResolver())
	if err != nil {
		return err
	}

	res, err := ac.Configure(ctx, configJSON)
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
	if len(status.Capabilities) == 0 {
		status.Capabilities = append([]string(nil), r.spec.Capabilities...)
	} else {
		status.Capabilities = append([]string(nil), status.Capabilities...)
	}
	return status
}

func (r *runner) circuitOpenCoolingDown(now time.Time) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	return r.status.State == StateCircuitOpen && !r.circuitUntil.IsZero() && now.Before(r.circuitUntil)
}

func (r *runner) setState(state State, lastErr string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.status.State = state
	r.status.PID = 0
	r.status.LastError = lastErr
	if state != StateCircuitOpen {
		r.circuitUntil = time.Time{}
	}
}

func (r *runner) setRunning(pid int, version string, capabilities []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.status.State = StateRunning
	r.status.PID = pid
	r.status.Version = version
	r.status.Capabilities = append([]string(nil), capabilities...)
	r.status.DegradationReason = ""
	r.status.LastStartedAt = time.Now().UTC()
	r.status.LastExitedAt = time.Time{}
	r.status.LastError = ""
	r.circuitUntil = time.Time{}
	r.healthySince = time.Time{}
}

func (r *runner) setResourceLimits(cgroupPath, limitErr string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.status.ResourceCgroup = cgroupPath
	r.status.ResourceLimitErr = limitErr
}

func (r *runner) setHealthy(pid int, h coreaddon.Health) {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now().UTC()

	// The add-on protocol distinguishes three health levels; collapsing Degraded
	// into StateUnhealthy threw that distinction away at the last hop. The
	// control plane then could not tell "this build is broken" from "this host
	// is missing something", and gated rollouts on both -- so powerdns reporting
	// that no Recursor is attached, and anomaly reporting an undelegated cpu
	// cgroup controller, each wedged their rollouts indefinitely while the
	// add-ons ran perfectly well.
	//
	// Degraded keeps its own state. The reason is still reported either way, and
	// the fleet row still flags it, so nothing becomes less visible.
	switch h.Status {
	case coreaddon.HealthDegraded:
		r.status.State = StateDegraded
		r.status.DegradationReason = h.DegradationReason
		r.healthySince = time.Time{}
	case coreaddon.HealthUnhealthy:
		r.status.State = StateUnhealthy
		r.status.DegradationReason = h.DegradationReason
		r.healthySince = time.Time{}
	case coreaddon.HealthHealthy, coreaddon.HealthUnspecified:
		r.status.State = StateRunning
		r.status.DegradationReason = ""
		if r.healthySince.IsZero() {
			r.healthySince = now
		}
	}
	r.status.PID = pid
	// Deliberately NOT taking h.Version: the delivered version set at start is
	// authoritative (see startOnce), and a health report must not be able to walk it
	// back to a stale self-reported string and stall the rollout gate.
	r.status.LastHealthAt = now
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

func (r *runner) circuitBreakerCoolingDown(now time.Time) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.status.State != StateCircuitOpen {
		return false
	}
	if r.status.LastExitedAt.IsZero() {
		return false
	}

	return now.Sub(r.status.LastExitedAt) < r.cfg.CircuitBreakerCooldown
}

func (r *runner) setCircuitOpen(lastErr string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.circuitUntil.IsZero() {
		r.circuitUntil = r.nextCircuitCooldownUntilLocked(time.Now().UTC())
	}
	if lastErr == "" {
		lastErr = "restart circuit open"
	}

	r.status.State = StateCircuitOpen
	r.status.PID = 0
	r.status.LastExitedAt = time.Now().UTC()
	r.status.LastError = lastErr
	r.status.DegradationReason = lastErr
}

func (r *runner) recordRestart(err error) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now().UTC()
	cutoff := now.Add(-restartLimitWindow)
	kept := r.restartWindow[:0]
	for _, ts := range r.restartWindow {
		if ts.After(cutoff) {
			kept = append(kept, ts)
		}
	}
	r.restartWindow = kept

	if len(r.restartWindow) >= r.cfg.RestartLimitPerMinute {
		r.status.LastError = errString(err)
		r.circuitUntil = r.nextCircuitCooldownUntilLocked(now)
		return false
	}

	r.restartWindow = append(r.restartWindow, now)
	r.status.RestartCount++
	return true
}

func (r *runner) nextCircuitCooldownUntilLocked(now time.Time) time.Time {
	cooldown := r.cfg.CircuitBreakerCooldown
	if cooldown <= 0 {
		cooldown = defaultCircuitBreakerCooldown
	}

	return now.Add(cooldown)
}

func (r *runner) runWasStable(runStart, now time.Time) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	return !r.healthySince.IsZero() &&
		r.healthySince.After(runStart) &&
		now.Sub(r.healthySince) >= r.cfg.RestartBackoffMax
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
