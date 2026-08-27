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
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	addonpb "github.com/carverauto/serviceradar/proto/agent/addon/v1"
	"github.com/rs/zerolog"
)

const (
	defaultAttachRuntimeDir     = "/run/serviceradar"
	defaultAttachConfigDir      = "/etc/serviceradar/sidecars"
	defaultAttachHealthInterval = 5 * time.Second
	defaultAttachUnhealthyAfter = 3
	defaultAttachShutdownGrace  = 5 * time.Second
	defaultAttachRuntimeDirMode = 0o700
	defaultAttachConfigDirMode  = 0o750
	defaultAttachSidecarDirMode = 0o700
)

var (
	ErrAttachManagerStarted = errors.New("netprobe attach manager already started")
	ErrAttachInvalidName    = errors.New("netprobe sidecar name is required")
	ErrAttachNoClient       = errors.New("netprobe attach client factory is required")
	ErrAttachNilClient      = errors.New("netprobe attach client factory returned nil client")
)

// AttachManagerConfig controls the netprobe attach path. The agent never launches
// netprobe here; systemd owns the add-on process and this manager only keeps the
// health/config/event IPC client connected to the well-known socket.
type AttachManagerConfig struct {
	RuntimeDir         string
	ConfigDir          string
	HealthInterval     time.Duration
	UnhealthyThreshold int
	ShutdownGrace      time.Duration
	ClientFactory      sidecar.ClientFactory
	Logger             zerolog.Logger
	// AddonTelemetrySink, when set, starts the AddonService telemetry pump
	// alongside the health loop. Socket discovery already lives here, so the
	// pump derives its path from the same RuntimeDir the IPC client uses rather
	// than being configured separately and drifting from it.
	AddonTelemetrySink func(*addonpb.TelemetryBatch)
}

// AttachManager tracks the externally supervised netprobe process and exposes its
// status through the shared SidecarStatus shape.
type AttachManager struct {
	cfg     AttachManagerConfig
	sidecar *Sidecar

	mu      sync.RWMutex
	started bool
	ctx     context.Context
	cancel  context.CancelFunc
	wg      sync.WaitGroup
	status  sidecar.Status
}

// NewAttachManager creates an attach-only manager for netprobe.
func NewAttachManager(cfg AttachManagerConfig, sc *Sidecar) (*AttachManager, error) {
	cfg = applyAttachDefaults(cfg)
	if cfg.ClientFactory == nil {
		return nil, ErrAttachNoClient
	}
	if sc == nil {
		sc = NewSidecar(SidecarConfig{})
	}
	name := strings.TrimSpace(sc.Name())
	if name == "" {
		return nil, ErrAttachInvalidName
	}

	return &AttachManager{
		cfg:     cfg,
		sidecar: sc,
		status: sidecar.Status{
			Name:       name,
			State:      sidecar.StateStopped,
			SocketPath: attachSocketPath(cfg.RuntimeDir, name),
			ConfigPath: attachConfigPath(cfg.ConfigDir, name),
		},
	}, nil
}

// StartAttach connects to the externally managed netprobe socket and keeps the
// client healthy until Stop or context cancellation. It never execs a binary.
func (m *AttachManager) StartAttach(ctx context.Context) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.started {
		return ErrAttachManagerStarted
	}

	name := m.sidecar.Name()
	if err := ensureAttachDirectoryMode(m.cfg.RuntimeDir, defaultAttachRuntimeDirMode); err != nil {
		return fmt.Errorf("create netprobe runtime dir: %w", err)
	}
	if err := ensureAttachDirectoryMode(m.cfg.ConfigDir, defaultAttachConfigDirMode); err != nil {
		return fmt.Errorf("create netprobe config dir: %w", err)
	}
	if err := ensureAttachDirectoryMode(attachSidecarRuntimeDir(m.cfg.RuntimeDir, name), defaultAttachSidecarDirMode); err != nil {
		return fmt.Errorf("create netprobe runtime dir for %s: %w", name, err)
	}

	m.ctx, m.cancel = context.WithCancel(ctx)
	m.started = true
	m.status.State = sidecar.StateStarting
	m.status.PID = 0
	m.status.LastError = ""
	m.wg.Add(1)
	go m.healthLoop(m.ctx)

	// The command client rides the same socket the telemetry pump uses. Wired
	// here rather than at construction because this is where the runtime dir and
	// sidecar name are both known, so the two cannot drift apart.
	m.sidecar.SetAddonCommandClient(NewAddonCommandClient(AttachAddonSocketPath(m.cfg.RuntimeDir, name)))

	if m.cfg.AddonTelemetrySink != nil {
		pump, err := NewAddonPump(AddonPumpConfig{
			SocketPath: AttachAddonSocketPath(m.cfg.RuntimeDir, name),
			Sink:       m.cfg.AddonTelemetrySink,
			Logger:     m.cfg.Logger,
		})
		if err != nil {
			// Not fatal: the legacy channel still carries discovery, so a pump
			// that cannot be constructed degrades to the pre-cutover behaviour.
			m.cfg.Logger.Error().Err(err).Msg("Failed to start netprobe AddonService pump")
		} else {
			m.wg.Add(1)
			go func() {
				defer m.wg.Done()
				pump.Run(m.ctx)
			}()
		}
	}

	return nil
}

// Stop tears down the health/client loop. It does not stop netprobe's process.
func (m *AttachManager) Stop(ctx context.Context) error {
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
		m.status.State = sidecar.StateStopped
		m.status.PID = 0
		m.status.LastError = ""
		m.mu.Unlock()
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Mode reports whether the attach loop is running. The second return is true
// whenever the manager is started because this manager has no launch mode.
func (m *AttachManager) Mode() (started, attach bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	return m.started, m.started
}

// Status returns the current netprobe status snapshot.
func (m *AttachManager) Status() []sidecar.Status {
	m.mu.RLock()
	defer m.mu.RUnlock()

	return []sidecar.Status{m.status}
}

func (m *AttachManager) healthLoop(ctx context.Context) {
	defer m.wg.Done()

	ticker := time.NewTicker(m.cfg.HealthInterval)
	defer ticker.Stop()

	failures := 0
	var client sidecar.Client
	defer func() {
		if client != nil {
			_ = client.Close()
		}
	}()

	if ctx.Err() == nil {
		client = m.probeHealth(ctx, client, &failures)
	}

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			client = m.probeHealth(ctx, client, &failures)
		}
	}
}

func (m *AttachManager) probeHealth(ctx context.Context, client sidecar.Client, failures *int) sidecar.Client {
	socket := attachSocketPath(m.cfg.RuntimeDir, m.sidecar.Name())

	var err error
	if client == nil {
		client, err = m.cfg.ClientFactory(ctx, socket)
		if err == nil && client == nil {
			err = ErrAttachNilClient
		}
	}
	if err == nil {
		err = client.Ping(ctx)
	}
	if err == nil {
		*failures = 0
		// Mark the sidecar healthy before flipping status to StateRunning so any
		// observer that sees StateRunning is guaranteed to also see Healthy().
		m.sidecar.OnHealthy(client)
		m.setHealthy()
		return client
	}

	if client != nil {
		_ = client.Close()
		client = nil
	}

	*failures++
	if *failures == m.cfg.UnhealthyThreshold {
		// Mirror the healthy path: mark the sidecar unhealthy before flipping
		// status to StateUnhealthy so observers see a consistent view.
		m.sidecar.OnUnhealthy(err)
		m.setUnhealthy(err)
	}

	return nil
}

func (m *AttachManager) setHealthy() {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.status.State = sidecar.StateRunning
	m.status.PID = 0
	m.status.LastHealthAt = time.Now().UTC()
	m.status.LastError = ""
}

func (m *AttachManager) setUnhealthy(err error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.status.State = sidecar.StateUnhealthy
	m.status.PID = 0
	m.status.LastError = attachErrorString(err)
}

func applyAttachDefaults(cfg AttachManagerConfig) AttachManagerConfig {
	if cfg.RuntimeDir == "" {
		cfg.RuntimeDir = defaultAttachRuntimeDir
	}
	if cfg.ConfigDir == "" {
		cfg.ConfigDir = defaultAttachConfigDir
	}
	if cfg.HealthInterval <= 0 {
		cfg.HealthInterval = defaultAttachHealthInterval
	}
	if cfg.UnhealthyThreshold <= 0 {
		cfg.UnhealthyThreshold = defaultAttachUnhealthyAfter
	}
	if cfg.ShutdownGrace <= 0 {
		cfg.ShutdownGrace = defaultAttachShutdownGrace
	}

	return cfg
}

func attachSocketPath(runtimeDir, name string) string {
	return filepath.Join(attachSidecarRuntimeDir(runtimeDir, name), "ipc.sock")
}

// AttachAddonSocketPath is netprobe's AddonService socket: a sibling of the
// legacy IPC socket. Kept in agreement with netprobe's own
// default_addon_socket_path, which derives the same name from --socket so the
// systemd unit does not have to carry the flag.
func AttachAddonSocketPath(runtimeDir, name string) string {
	return filepath.Join(attachSidecarRuntimeDir(runtimeDir, name), "addon.sock")
}

func attachConfigPath(configDir, name string) string {
	return filepath.Join(configDir, name+".json")
}

func attachSidecarRuntimeDir(runtimeDir, name string) string {
	return filepath.Join(runtimeDir, name)
}

func attachErrorString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func ensureAttachDirectoryMode(path string, mode os.FileMode) error {
	if err := os.MkdirAll(path, mode); err != nil {
		return err
	}
	return os.Chmod(path, mode)
}
