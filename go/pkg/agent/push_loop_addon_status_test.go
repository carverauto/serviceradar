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

// stageNetprobeCurrent builds <root>/netprobe/versions/<version> with a `current`
// symlink pointing at it, mirroring the activation runtime's staging layout.
func stageNetprobeCurrent(t *testing.T, version string) string {
	t.Helper()

	root := t.TempDir()
	addonDir := filepath.Join(root, "netprobe")
	if err := os.MkdirAll(filepath.Join(addonDir, "versions", version), 0o755); err != nil {
		t.Fatalf("mkdir version dir: %v", err)
	}
	if err := os.Symlink(filepath.Join("versions", version), filepath.Join(addonDir, "current")); err != nil {
		t.Fatalf("symlink current: %v", err)
	}

	return root
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
