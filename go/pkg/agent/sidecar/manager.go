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
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/rs/zerolog"
)

const (
	defaultRuntimeDir              = "/run/serviceradar"
	defaultConfigDir               = "/etc/serviceradar/sidecars"
	defaultHealthInterval          = 5 * time.Second
	defaultUnhealthyThreshold      = 3
	defaultShutdownGrace           = 5 * time.Second
	defaultRestartBackoffInitial   = time.Second
	defaultRestartBackoffMax       = time.Minute
	defaultRestartLimitPerMinute   = 5
	sidecarLogScannerMaxBufferSize = 4 * 1024 * 1024
)

var (
	ErrManagerStarted  = errors.New("sidecar manager already started")
	ErrDuplicateName   = errors.New("duplicate sidecar name")
	ErrInvalidName     = errors.New("sidecar name is required")
	ErrNoClientFactory = errors.New("sidecar client factory is required")
	ErrNilClient       = errors.New("sidecar client factory returned nil client")
	ErrSidecarExited   = errors.New("sidecar exited")
)

// Config controls manager paths and supervision timing.
type Config struct {
	RuntimeDir            string
	ConfigDir             string
	HealthInterval        time.Duration
	UnhealthyThreshold    int
	ShutdownGrace         time.Duration
	RestartBackoffInitial time.Duration
	RestartBackoffMax     time.Duration
	RestartLimitPerMinute int
	ClientFactory         ClientFactory
	Logger                zerolog.Logger
}

// Manager supervises long-lived agent sidecar processes.
type Manager struct {
	cfg      Config
	sidecars []Sidecar

	mu      sync.RWMutex
	started bool
	attach  bool
	ctx     context.Context
	cancel  context.CancelFunc
	wg      sync.WaitGroup
	records map[string]*record
}

type record struct {
	sidecar       Sidecar
	status        Status
	restartWindow []time.Time
}

// NewManager creates a manager for the provided sidecars.
func NewManager(cfg Config, sidecars ...Sidecar) (*Manager, error) {
	cfg = applyDefaults(cfg)
	if cfg.ClientFactory == nil {
		return nil, ErrNoClientFactory
	}

	records := make(map[string]*record, len(sidecars))
	for _, sc := range sidecars {
		if sc == nil {
			return nil, ErrInvalidName
		}
		name := strings.TrimSpace(sc.Name())
		if name == "" {
			return nil, ErrInvalidName
		}
		if _, ok := records[name]; ok {
			return nil, fmt.Errorf("%w: %s", ErrDuplicateName, name)
		}

		records[name] = &record{
			sidecar: sc,
			status: Status{
				Name:       name,
				State:      StateStopped,
				SocketPath: socketPath(cfg.RuntimeDir, name),
				ConfigPath: configPath(cfg.ConfigDir, name),
			},
		}
	}

	return &Manager{
		cfg:      cfg,
		sidecars: append([]Sidecar(nil), sidecars...),
		records:  records,
	}, nil
}

// Start begins supervising every configured sidecar: the manager launches each process
// and restarts it (with backoff + a circuit breaker) when it exits.
func (m *Manager) Start(ctx context.Context) error {
	return m.start(ctx, false)
}

// StartAttach begins supervising every configured sidecar in ATTACH mode: the manager does
// NOT launch the process — an external supervisor (systemd) owns the process lifecycle — and
// instead connects to the well-known socket, health-checks it, wires the client into the
// sidecar (enabling config push + event ingest), and reconnects on connection loss. It never
// execs a binary and never restarts a process. Used when an add-on is delivered as a
// systemd-service (migrate-netprobe §2.2).
func (m *Manager) StartAttach(ctx context.Context) error {
	return m.start(ctx, true)
}

func (m *Manager) start(ctx context.Context, attach bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.started {
		return ErrManagerStarted
	}
	if err := ensureDirectoryMode(m.cfg.RuntimeDir, 0o700); err != nil {
		return fmt.Errorf("create sidecar runtime dir: %w", err)
	}
	if err := ensureDirectoryMode(m.cfg.ConfigDir, 0o750); err != nil {
		return fmt.Errorf("create sidecar config dir: %w", err)
	}
	for _, sc := range m.sidecars {
		if err := ensureDirectoryMode(sidecarRuntimeDir(m.cfg.RuntimeDir, sc.Name()), 0o700); err != nil {
			return fmt.Errorf("create sidecar runtime dir for %s: %w", sc.Name(), err)
		}
	}

	m.ctx, m.cancel = context.WithCancel(ctx)
	m.started = true
	m.attach = attach

	for _, sc := range m.sidecars {
		m.wg.Add(1)
		go m.supervise(m.ctx, sc, attach)
	}

	return nil
}

// Mode reports whether the manager is currently started and, if so, whether it is running
// in attach mode (vs. launch mode). Callers use it to decide whether a mode switch (Stop +
// Start/StartAttach) is needed; `attach` is meaningful only when `started` is true.
func (m *Manager) Mode() (started, attach bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	return m.started, m.attach
}

// Stop terminates all sidecars and waits for their supervisor loops to exit.
func (m *Manager) Stop(ctx context.Context) error {
	m.mu.RLock()
	cancel := m.cancel
	started := m.started
	m.mu.RUnlock()

	if !started {
		return nil
	}
	if cancel != nil {
		cancel()
	}

	done := make(chan struct{})
	go func() {
		m.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		m.mu.Lock()
		m.started = false
		m.mu.Unlock()
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Status returns a stable snapshot of every managed sidecar.
func (m *Manager) Status() []Status {
	m.mu.RLock()
	defer m.mu.RUnlock()

	statuses := make([]Status, 0, len(m.records))
	for _, sc := range m.sidecars {
		if rec, ok := m.records[sc.Name()]; ok {
			statuses = append(statuses, rec.status)
		}
	}

	return statuses
}

func (m *Manager) supervise(ctx context.Context, sc Sidecar, attach bool) {
	defer m.wg.Done()

	if attach {
		m.superviseAttached(ctx, sc)
		return
	}

	backoff := m.cfg.RestartBackoffInitial
	name := sc.Name()

	for {
		if ctx.Err() != nil {
			m.setState(name, StateStopped, "")
			return
		}

		runStart := time.Now()
		err := m.runOnce(ctx, sc)
		if ctx.Err() != nil {
			m.setState(name, StateStopped, "")
			return
		}

		if !m.recordRestart(name, err) {
			lastErr := "restart circuit breaker opened"
			if err != nil {
				lastErr = err.Error()
			}
			m.setState(name, StateCircuitOpen, lastErr)
			sc.OnUnhealthy(fmt.Errorf("sidecar %s restart circuit breaker opened: %w", name, err))
			return
		}

		m.setState(name, StateRestarting, errorString(err))
		if time.Since(runStart) >= m.cfg.RestartBackoffMax {
			backoff = m.cfg.RestartBackoffInitial
		}
		timer := time.NewTimer(backoff)
		select {
		case <-ctx.Done():
			timer.Stop()
			m.setState(name, StateStopped, "")
			return
		case <-timer.C:
		}

		backoff *= 2
		if backoff > m.cfg.RestartBackoffMax {
			backoff = m.cfg.RestartBackoffMax
		}
	}
}

// superviseAttached keeps a health/client connection alive to an externally-managed
// sidecar socket until the context is cancelled. There is no child process to launch, wait
// on, or restart — systemd owns the process — so the manager only owns the connection: the
// health loop dials the socket, wires the client into the sidecar via OnHealthy (enabling
// config push + event ingest), and reconnects on loss. PID stays 0 because the agent does
// not own the process; the health loop drives the status to Running once connected, or
// Unhealthy if the external process is unreachable.
func (m *Manager) superviseAttached(ctx context.Context, sc Sidecar) {
	name := sc.Name()
	socket := socketPath(m.cfg.RuntimeDir, name)

	m.setState(name, StateStarting, "")
	m.healthLoop(ctx, sc, socket, 0)
	m.setState(name, StateStopped, "")
}

func (m *Manager) runOnce(ctx context.Context, sc Sidecar) error {
	name := sc.Name()
	socket := socketPath(m.cfg.RuntimeDir, name)
	config := configPath(m.cfg.ConfigDir, name)

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	cmd := exec.CommandContext(runCtx, sc.BinaryPath(), sc.Args(socket, config)...)
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return signalTerminate(cmd.Process)
	}
	cmd.WaitDelay = m.cfg.ShutdownGrace

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("create sidecar stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("create sidecar stderr pipe: %w", err)
	}

	m.setState(name, StateStarting, "")
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start sidecar %s: %w", name, err)
	}

	pid := cmd.Process.Pid
	sidecarLogger := m.cfg.Logger.With().Str("sidecar", name).Int("pid", pid).Logger()
	m.setStarted(name, pid, socket, config)

	var logWG sync.WaitGroup
	logWG.Add(2)
	go scanSidecarLogs(&logWG, stdout, sidecarLogger, false)
	go scanSidecarLogs(&logWG, stderr, sidecarLogger, true)

	healthDone := make(chan struct{})
	go func() {
		defer close(healthDone)
		m.healthLoop(runCtx, sc, socket, pid)
	}()

	err = cmd.Wait()
	cancel()
	<-healthDone
	logWG.Wait()

	m.setExited(name, errorString(err))
	if err == nil {
		return fmt.Errorf("%w: %s", ErrSidecarExited, name)
	}

	return fmt.Errorf("%w: %s: %w", ErrSidecarExited, name, err)
}

func (m *Manager) healthLoop(ctx context.Context, sc Sidecar, socketPath string, pid int) {
	ticker := time.NewTicker(m.cfg.HealthInterval)
	defer ticker.Stop()

	failures := 0
	var client Client
	defer func() {
		if client != nil {
			_ = client.Close()
		}
	}()

	if ctx.Err() == nil {
		client = m.probeHealth(ctx, sc, socketPath, pid, client, &failures)
	}

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			client = m.probeHealth(ctx, sc, socketPath, pid, client, &failures)
		}
	}
}

func (m *Manager) probeHealth(
	ctx context.Context,
	sc Sidecar,
	socketPath string,
	pid int,
	client Client,
	failures *int,
) Client {
	var err error
	if client == nil {
		client, err = m.cfg.ClientFactory(ctx, socketPath)
		if err == nil && client == nil {
			err = ErrNilClient
		}
	}
	if err == nil {
		err = client.Ping(ctx)
	}
	if err == nil {
		*failures = 0
		m.setHealthy(sc.Name(), pid)
		sc.OnHealthy(client)
		return client
	}

	if client != nil {
		_ = client.Close()
		client = nil
	}

	*failures++
	if *failures == m.cfg.UnhealthyThreshold {
		m.setUnhealthy(sc.Name(), pid, err)
		sc.OnUnhealthy(err)
	}

	return nil
}

func (m *Manager) setState(name string, state State, lastError string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	rec, ok := m.records[name]
	if !ok {
		return
	}
	rec.status.State = state
	rec.status.PID = 0
	rec.status.LastError = lastError
}

func (m *Manager) setStarted(name string, pid int, socketPath, configPath string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	rec, ok := m.records[name]
	if !ok {
		return
	}
	rec.status.State = StateRunning
	rec.status.PID = pid
	rec.status.SocketPath = socketPath
	rec.status.ConfigPath = configPath
	rec.status.LastStartedAt = time.Now().UTC()
	rec.status.LastExitedAt = time.Time{}
	rec.status.LastError = ""
}

func (m *Manager) setExited(name, lastError string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	rec, ok := m.records[name]
	if !ok {
		return
	}
	rec.status.PID = 0
	rec.status.LastExitedAt = time.Now().UTC()
	rec.status.LastError = lastError
}

func (m *Manager) setHealthy(name string, pid int) {
	m.mu.Lock()
	defer m.mu.Unlock()

	rec, ok := m.records[name]
	if !ok {
		return
	}
	rec.status.State = StateRunning
	rec.status.PID = pid
	rec.status.LastHealthAt = time.Now().UTC()
	rec.status.LastError = ""
}

func (m *Manager) setUnhealthy(name string, pid int, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	rec, ok := m.records[name]
	if !ok {
		return
	}
	rec.status.State = StateUnhealthy
	rec.status.PID = pid
	rec.status.LastError = errorString(err)
}

func (m *Manager) recordRestart(name string, err error) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	rec, ok := m.records[name]
	if !ok {
		return false
	}

	now := time.Now().UTC()
	cutoff := now.Add(-time.Minute)
	oldWindow := rec.restartWindow
	rec.restartWindow = rec.restartWindow[:0]
	for _, ts := range oldWindow {
		if ts.After(cutoff) {
			rec.restartWindow = append(rec.restartWindow, ts)
		}
	}

	if len(rec.restartWindow) >= m.cfg.RestartLimitPerMinute {
		rec.status.LastError = errorString(err)
		return false
	}

	rec.restartWindow = append(rec.restartWindow, now)
	rec.status.RestartCount++
	return true
}

func scanSidecarLogs(wg *sync.WaitGroup, r io.Reader, log zerolog.Logger, isErr bool) {
	defer wg.Done()

	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), sidecarLogScannerMaxBufferSize)

	for scanner.Scan() {
		line := scanner.Text()
		if isErr {
			log.Warn().Str("stream", "stderr").Msg(line)
		} else {
			log.Info().Str("stream", "stdout").Msg(line)
		}
	}
	if err := scanner.Err(); err != nil {
		if isExpectedLogPipeClose(err) {
			return
		}
		log.Warn().Err(err).Msg("sidecar log scanner failed")
	}
}

func isExpectedLogPipeClose(err error) bool {
	return errors.Is(err, os.ErrClosed) ||
		errors.Is(err, io.ErrClosedPipe) ||
		strings.Contains(err.Error(), "file already closed")
}

func applyDefaults(cfg Config) Config {
	if cfg.RuntimeDir == "" {
		cfg.RuntimeDir = defaultRuntimeDir
	}
	if cfg.ConfigDir == "" {
		cfg.ConfigDir = defaultConfigDir
	}
	if cfg.HealthInterval <= 0 {
		cfg.HealthInterval = defaultHealthInterval
	}
	if cfg.UnhealthyThreshold <= 0 {
		cfg.UnhealthyThreshold = defaultUnhealthyThreshold
	}
	if cfg.ShutdownGrace <= 0 {
		cfg.ShutdownGrace = defaultShutdownGrace
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
		cfg.Logger = logger.GetLogger().With().Str("component", "agent.sidecar").Logger()
	}

	return cfg
}

func socketPath(runtimeDir, name string) string {
	return filepath.Join(sidecarRuntimeDir(runtimeDir, name), "ipc.sock")
}

func configPath(configDir, name string) string {
	return filepath.Join(configDir, name+".json")
}

func sidecarRuntimeDir(runtimeDir, name string) string {
	return filepath.Join(runtimeDir, name)
}

func errorString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func ensureDirectoryMode(path string, mode os.FileMode) error {
	if err := os.MkdirAll(path, mode); err != nil {
		return err
	}
	return os.Chmod(path, mode)
}
