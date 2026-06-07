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
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/go/pkg/agent/sidecar"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

func newNetprobeStatusPushLoop(t *testing.T, installed bool) *PushLoop {
	t.Helper()

	pl := NewPushLoop(
		&Server{config: &ServerConfig{AgentID: "agent-netprobe-status"}},
		nil,
		30*time.Second,
		logger.NewTestLogger(),
	)
	if installed {
		pl.installedSystemdAddons = map[string][]string{
			"netprobe": {"serviceradar-netprobe.service"},
		}
	}

	return pl
}

func stubSystemdUnitStatus(t *testing.T, pl *PushLoop, fn func(string) systemdUnitStatus) {
	t.Helper()

	original := pl.readSystemdUnitStatus
	pl.readSystemdUnitStatus = fn
	t.Cleanup(func() {
		pl.readSystemdUnitStatus = original
	})
}

// stageAddonCurrent builds <root>/<addonID>/versions/<version> with a `current`
// symlink pointing at it, mirroring the activation runtime's staging layout.
func stageAddonCurrent(t *testing.T, addonID string, version string) string {
	t.Helper()

	root := t.TempDir()
	addonDir := filepath.Join(root, addonID)
	if err := os.MkdirAll(filepath.Join(addonDir, "versions", version), 0o755); err != nil {
		t.Fatalf("mkdir version dir: %v", err)
	}
	if err := os.Symlink(filepath.Join("versions", version), filepath.Join(addonDir, "current")); err != nil {
		t.Fatalf("symlink current: %v", err)
	}

	return root
}

func stageAddonCurrentWithFiles(t *testing.T, addonID string, version string, files map[string]string) string {
	t.Helper()

	root := stageAddonCurrent(t, addonID, version)
	current := filepath.Join(root, addonID, "current")
	for name, contents := range files {
		if err := os.WriteFile(filepath.Join(current, name), []byte(contents), 0o644); err != nil {
			t.Fatalf("write staged addon file %s: %v", name, err)
		}
	}

	return root
}

func stageNetprobeCurrent(t *testing.T, version string) string {
	t.Helper()

	return stageAddonCurrent(t, "netprobe", version)
}

// When netprobe is not installed as a systemd add-on, no addon:netprobe status is
// synthesized (nothing for Edge Ops to track).
func TestNetprobeAddonStatusNotInstalled(t *testing.T) {
	pl := newNetprobeStatusPushLoop(t, false)

	if got := pl.netprobeAddonStatus(t.TempDir(), nil); got != nil {
		t.Fatalf("expected nil when netprobe not installed, got %#v", got)
	}
}

// Installed + a healthy netprobe sidecar entry => addon:netprobe is active with the
// installed version, host arch, and the sidecar's live pid/health folded in.
func TestNetprobeAddonStatusRunning(t *testing.T) {
	pl := newNetprobeStatusPushLoop(t, true)
	root := stageNetprobeCurrent(t, "1.2.3")
	sidecars := []*proto.SidecarStatus{
		{
			Name:         "netprobe",
			State:        string(sidecar.StateRunning),
			Pid:          4321,
			LastHealthAt: time.Unix(1_700_000_000, 0).UTC().UnixNano(),
		},
	}

	got := pl.netprobeAddonStatus(root, sidecars)
	if got == nil {
		t.Fatal("expected addon:netprobe status")
	}
	if got.GetName() != "addon:netprobe" {
		t.Fatalf("name = %q, want addon:netprobe", got.GetName())
	}
	if got.GetState() != string(sidecar.StateRunning) {
		t.Fatalf("state = %q, want %q", got.GetState(), sidecar.StateRunning)
	}
	if got.GetVersion() != "1.2.3" {
		t.Fatalf("version = %q, want 1.2.3", got.GetVersion())
	}
	if got.GetArch() != runtime.GOARCH {
		t.Fatalf("arch = %q, want %q", got.GetArch(), runtime.GOARCH)
	}
	if got.GetPid() != 4321 {
		t.Fatalf("pid = %d, want 4321", got.GetPid())
	}
	if got.GetLastHealthAt() == 0 {
		t.Fatalf("expected last_health_at to be carried from the sidecar")
	}
}

// Installed but with no running sidecar entry => addon:netprobe reports the installed
// version but a stopped state (installed, not active).
func TestNetprobeAddonStatusInstalledNotRunning(t *testing.T) {
	pl := newNetprobeStatusPushLoop(t, true)
	root := stageNetprobeCurrent(t, "0.9.0")
	stubSystemdUnitStatus(t, pl, func(string) systemdUnitStatus {
		return systemdUnitStatus{state: agentaddon.StateStopped}
	})

	got := pl.netprobeAddonStatus(root, nil)
	if got == nil {
		t.Fatal("expected addon:netprobe status when installed")
	}
	if got.GetState() != string(agentaddon.StateStopped) {
		t.Fatalf("state = %q, want %q", got.GetState(), agentaddon.StateStopped)
	}
	if got.GetVersion() != "0.9.0" {
		t.Fatalf("version = %q, want 0.9.0", got.GetVersion())
	}
}

func TestSystemdAddonStatusesIncludesWorkloadIdentity(t *testing.T) {
	pl := NewPushLoop(
		&Server{config: &ServerConfig{AgentID: "agent-workload-identity-status"}},
		nil,
		30*time.Second,
		logger.NewTestLogger(),
	)
	pl.installedSystemdAddons = map[string][]string{
		"workload-identity": {"serviceradar-workload-identity.service"},
	}
	root := stageAddonCurrent(t, "workload-identity", "0.1.0")
	stubSystemdUnitStatus(t, pl, func(unit string) systemdUnitStatus {
		if unit != "serviceradar-workload-identity.service" {
			t.Fatalf("unexpected systemd unit %q", unit)
		}

		return systemdUnitStatus{state: agentaddon.StateRunning, pid: 2468}
	})

	statuses := pl.systemdAddonStatuses(root, nil)
	if len(statuses) != 1 {
		t.Fatalf("systemd addon statuses = %#v, want one workload-identity status", statuses)
	}

	got := statuses[0]
	if got.GetName() != "addon:workload-identity" {
		t.Fatalf("name = %q, want addon:workload-identity", got.GetName())
	}
	if got.GetState() != string(agentaddon.StateRunning) {
		t.Fatalf("state = %q, want %q", got.GetState(), agentaddon.StateRunning)
	}
	if got.GetVersion() != "0.1.0" {
		t.Fatalf("version = %q, want 0.1.0", got.GetVersion())
	}
	if got.GetPid() != 2468 {
		t.Fatalf("pid = %d, want 2468", got.GetPid())
	}
	if got.GetLastHealthAt() == 0 {
		t.Fatalf("expected running systemd add-on to carry last_health_at")
	}
}

func TestSystemdAddonStatusesRehydratesWorkloadIdentityFromDisk(t *testing.T) {
	pl := NewPushLoop(
		&Server{config: &ServerConfig{AgentID: "agent-workload-identity-rehydrate"}},
		nil,
		30*time.Second,
		logger.NewTestLogger(),
	)
	root := stageAddonCurrentWithFiles(t, "workload-identity", "0.1.1", map[string]string{
		"serviceradar-workload-identity.service": "[Service]\n",
	})
	stubSystemdUnitStatus(t, pl, func(unit string) systemdUnitStatus {
		if unit != "serviceradar-workload-identity.service" {
			t.Fatalf("unexpected systemd unit %q", unit)
		}

		return systemdUnitStatus{state: agentaddon.StateRunning, pid: 1357}
	})

	statuses := pl.systemdAddonStatuses(root, nil)
	if len(statuses) != 1 {
		t.Fatalf("systemd addon statuses = %#v, want rehydrated workload-identity status", statuses)
	}

	got := statuses[0]
	if got.GetName() != "addon:workload-identity" {
		t.Fatalf("name = %q, want addon:workload-identity", got.GetName())
	}
	if got.GetState() != string(agentaddon.StateRunning) {
		t.Fatalf("state = %q, want %q", got.GetState(), agentaddon.StateRunning)
	}
	if got.GetVersion() != "0.1.1" {
		t.Fatalf("version = %q, want 0.1.1", got.GetVersion())
	}
	if got.GetPid() != 1357 {
		t.Fatalf("pid = %d, want 1357", got.GetPid())
	}
}

func TestParseSystemdUnitStatusOutputIgnoresPropertyOrder(t *testing.T) {
	got := parseSystemdUnitStatusOutput("MainPID=673112\nActiveState=active\n")
	if got.state != agentaddon.StateRunning {
		t.Fatalf("state = %q, want %q", got.state, agentaddon.StateRunning)
	}
	if got.pid != 673112 {
		t.Fatalf("pid = %d, want 673112", got.pid)
	}
}
