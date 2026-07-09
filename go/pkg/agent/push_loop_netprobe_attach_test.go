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

package agent

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	agentnetprobe "github.com/carverauto/serviceradar/go/pkg/agent/netprobe"
	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/rs/zerolog"
)

var (
	errNoExternalNetprobe = errors.New("no external netprobe in test")
	errStartAttachTest    = errors.New("start attach failed in test")
)

type recordingSidecarLifecycleManager struct {
	statuses         []sidecar.Status
	started          bool
	attach           bool
	stopped          bool
	startAttachErr   error
	startAttachCalls int
}

func (m *recordingSidecarLifecycleManager) Status() []sidecar.Status {
	return m.statuses
}

func (m *recordingSidecarLifecycleManager) StartAttach(context.Context) error {
	m.startAttachCalls++
	if m.startAttachErr != nil {
		return m.startAttachErr
	}

	m.started = true
	m.attach = true
	return nil
}

func (m *recordingSidecarLifecycleManager) Stop(context.Context) error {
	m.started = false
	m.attach = false
	m.stopped = true
	return nil
}

func (m *recordingSidecarLifecycleManager) Mode() (started, attach bool) {
	return m.started, m.attach
}

func TestNetprobeSystemdAssignmentPresent(t *testing.T) {
	tests := []struct {
		name   string
		addons []*proto.AddonAssignmentConfig
		want   bool
	}{
		{"nil", nil, false},
		{"enabled systemd-service netprobe", []*proto.AddonAssignmentConfig{
			{AddonId: "netprobe", Enabled: true, Supervision: "systemd_service"},
		}, true},
		{"disabled netprobe", []*proto.AddonAssignmentConfig{
			{AddonId: "netprobe", Enabled: false, Supervision: "systemd_service"},
		}, false},
		{"agent_sidecar supervision is not systemd", []*proto.AddonAssignmentConfig{
			{AddonId: "netprobe", Enabled: true, Supervision: "agent_sidecar"},
		}, false},
		{"different addon id", []*proto.AddonAssignmentConfig{
			{AddonId: "bumblebee", Enabled: true, Supervision: "systemd_service"},
		}, false},
		{"systemd_timer also dispatches as systemd", []*proto.AddonAssignmentConfig{
			{AddonId: "netprobe", Enabled: true, Supervision: "systemd_timer"},
		}, true},
		{"nil entry skipped, real one found", []*proto.AddonAssignmentConfig{
			nil,
			{AddonId: "netprobe", Enabled: true, Supervision: "systemd_service"},
		}, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := netprobeSystemdAssignmentPresent(tt.addons); got != tt.want {
				t.Fatalf("netprobeSystemdAssignmentPresent = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestApplyVisibilityConfigClearsNetprobeOnUnsupportedHost(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "sidecars", "netprobe.json")
	manager := &recordingSidecarLifecycleManager{
		started: true,
		attach:  true,
		statuses: []sidecar.Status{{
			Name:       agentnetprobe.DefaultSidecarName,
			ConfigPath: configPath,
		}},
	}
	netprobeSidecar := agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{Logger: zerolog.Nop()})
	pl := NewPushLoop(&Server{
		netprobeSidecar: netprobeSidecar,
		sidecarManager:  manager,
		sidecarStatus:   manager,
	}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, false)

	if disposition, err := pl.applyVisibilityConfig(context.Background(), &proto.VisibilityConfig{Enabled: true}, []*proto.AddonAssignmentConfig{
		{AddonId: "netprobe", Enabled: true, Supervision: "systemd_service"},
	}); disposition != addonDeliverySucceeded || err != nil {
		t.Fatalf("applyVisibilityConfig() = %v (%v), want succeeded for unsupported host", disposition, err)
	}
	if _, err := os.Stat(configPath); !os.IsNotExist(err) {
		t.Fatalf("expected no netprobe bootstrap config to be written, stat err=%v", err)
	}
	if !manager.stopped {
		t.Fatal("expected unsupported visibility apply to stop existing netprobe manager state")
	}
}

func TestApplyVisibilityConfigStartAttachFailureIsTransient(t *testing.T) {
	dir := t.TempDir()
	manager := &recordingSidecarLifecycleManager{
		statuses: []sidecar.Status{{
			Name:       agentnetprobe.DefaultSidecarName,
			ConfigPath: filepath.Join(dir, "netprobe.json"),
		}},
		startAttachErr: errStartAttachTest,
	}
	netprobeSidecar := agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{Logger: zerolog.Nop()})
	pl := NewPushLoop(&Server{
		netprobeSidecar: netprobeSidecar,
		sidecarManager:  manager,
		sidecarStatus:   manager,
	}, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)

	disposition, err := pl.applyVisibilityConfig(
		context.Background(),
		&proto.VisibilityConfig{Enabled: true},
		[]*proto.AddonAssignmentConfig{{
			AddonId:     agentnetprobe.DefaultSidecarName,
			Enabled:     true,
			Supervision: addonSupervisionSystemdService,
		}},
	)

	if disposition != addonDeliveryTransientFailure || !errors.Is(err, errStartAttachTest) {
		t.Fatalf("applyVisibilityConfig() = %v (%v), want transient attach failure", disposition, err)
	}
	if manager.startAttachCalls != 1 {
		t.Fatalf("StartAttach calls = %d, want 1", manager.startAttachCalls)
	}
	if started, attach := manager.Mode(); started || attach {
		t.Fatalf("Mode after failed StartAttach = (%v,%v), want (false,false)", started, attach)
	}
	if _, err := os.Stat(filepath.Join(dir, "netprobe.json")); err != nil {
		t.Fatalf("bootstrap config should be ready before attach starts: %v", err)
	}

	manager.startAttachErr = nil
	disposition, err = pl.applyVisibilityConfig(
		context.Background(),
		&proto.VisibilityConfig{Enabled: true},
		[]*proto.AddonAssignmentConfig{{
			AddonId:     agentnetprobe.DefaultSidecarName,
			Enabled:     true,
			Supervision: addonSupervisionSystemdService,
		}},
	)
	if disposition != addonDeliverySucceeded || err != nil {
		t.Fatalf("applyVisibilityConfig() retry = %v (%v), want success", disposition, err)
	}
	if manager.startAttachCalls != 2 {
		t.Fatalf("StartAttach calls after retry = %d, want 2", manager.startAttachCalls)
	}
	if started, attach := manager.Mode(); !started || !attach {
		t.Fatalf("Mode after successful retry = (%v,%v), want (true,true)", started, attach)
	}
}

// TestApplyVisibilityConfigRoutesNetprobeBySupervision proves the §2.2 cutover routing: a
// netprobe systemd-service assignment puts the supervisor in ATTACH mode (systemd owns the
// process), and removing the assignment stops the attach loop rather than launching an
// optional netprobe binary from the base agent.
func TestApplyVisibilityConfigRoutesNetprobeBySupervision(t *testing.T) {
	dir := t.TempDir()
	netprobeSidecar := agentnetprobe.NewSidecar(agentnetprobe.SidecarConfig{Logger: zerolog.Nop()})
	manager, err := agentnetprobe.NewAttachManager(agentnetprobe.AttachManagerConfig{
		RuntimeDir:     filepath.Join(dir, "run"),
		ConfigDir:      filepath.Join(dir, "cfg"),
		HealthInterval: 10 * time.Millisecond,
		ClientFactory: sidecar.ClientFactory(func(context.Context, string) (sidecar.Client, error) {
			return nil, errNoExternalNetprobe
		}),
		Logger: zerolog.Nop(),
	}, netprobeSidecar)
	if err != nil {
		t.Fatalf("NewAttachManager: %v", err)
	}

	srv := &Server{
		netprobeSidecar: netprobeSidecar,
		sidecarManager:  manager,
		sidecarStatus:   manager,
	}
	pl := NewPushLoop(srv, nil, 30*time.Second, logger.NewTestLogger())
	setHostNetworkVisibilitySupportForTest(pl, true)

	// A cancellable context bounds the sidecar's async apply-on-connect push; cancelling it
	// on teardown stops the in-flight push goroutine rather than leaving it polling.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// systemd-managed -> attach mode (connect, don't launch).
	if disposition, err := pl.applyVisibilityConfig(ctx, &proto.VisibilityConfig{Enabled: true}, []*proto.AddonAssignmentConfig{
		{AddonId: "netprobe", Enabled: true, Supervision: "systemd_service"},
	}); disposition != addonDeliverySucceeded || err != nil {
		t.Fatalf("applyVisibilityConfig(systemdManaged=true) = %v (%v), want succeeded", disposition, err)
	}
	if started, attach := manager.Mode(); !started || !attach {
		t.Fatalf("Mode after systemd-managed apply = (%v,%v), want (true,true)", started, attach)
	}
	bootstrapBytes, err := os.ReadFile(filepath.Join(dir, "cfg", "netprobe.json"))
	if err != nil {
		t.Fatalf("read netprobe bootstrap: %v", err)
	}
	var bootstrap map[string]any
	if err := json.Unmarshal(bootstrapBytes, &bootstrap); err != nil {
		t.Fatalf("decode netprobe bootstrap: %v", err)
	}
	if enabled, ok := bootstrap["enabled"].(bool); !ok || !enabled {
		t.Fatalf("bootstrap enabled = %#v, want true", bootstrap["enabled"])
	}

	// Assignment removed -> stop the attach loop; the agent no longer falls back to
	// launching netprobe from the base runtime.
	if disposition, err := pl.applyVisibilityConfig(ctx, &proto.VisibilityConfig{}, nil); disposition != addonDeliverySucceeded || err != nil {
		t.Fatalf("applyVisibilityConfig(systemdManaged=false, no work) = %v (%v), want succeeded", disposition, err)
	}
	if started, _ := manager.Mode(); started {
		t.Fatalf("Mode after launched no-work apply = started %v, want false (stopped)", started)
	}

	stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = manager.Stop(stopCtx)
}
