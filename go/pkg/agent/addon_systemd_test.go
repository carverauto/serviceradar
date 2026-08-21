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
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
)

func TestValidateAddonUnitName(t *testing.T) {
	ok := []string{"serviceradar-netprobe.service", "serviceradar-bumblebee-scan.timer"}
	for _, name := range ok {
		if err := validateAddonUnitName(name); err != nil {
			t.Fatalf("validateAddonUnitName(%q) = %v, want nil", name, err)
		}
	}

	bad := []string{
		"../escape.service",     // traversal
		"sub/dir.service",       // separator
		"serviceradar-netprobe", // no unit suffix
		"serviceradar.conf",     // wrong suffix
		"",                      // empty
	}
	for _, name := range bad {
		if err := validateAddonUnitName(name); !errors.Is(err, ErrAddonUnitNameUnsafe) {
			t.Fatalf("validateAddonUnitName(%q) = %v, want ErrAddonUnitNameUnsafe", name, err)
		}
	}
}

// stageTestAddonUnit writes a staged unit file under <addonsRoot>/np/versions/1.0.0 and
// points the add-on's `current` symlink at it (mirroring a staged bundle's layout).
func stageTestAddonUnit(t *testing.T, addonsRoot, unitName, content string) {
	t.Helper()
	versionDir := filepath.Join(addonsRoot, "np", addonVersionsDir, "1.0.0")
	if err := os.MkdirAll(versionDir, 0o755); err != nil {
		t.Fatalf("mkdir version dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(versionDir, unitName), []byte(content), 0o644); err != nil {
		t.Fatalf("write unit: %v", err)
	}
	current := filepath.Join(addonsRoot, "np", addonCurrentLink)
	_ = os.Remove(current)
	if err := os.Symlink(filepath.Join(addonVersionsDir, "1.0.0"), current); err != nil {
		t.Fatalf("symlink current: %v", err)
	}
}

func TestResolveStagedAddonUnit(t *testing.T) {
	tmp := t.TempDir()
	addonsRoot := filepath.Join(tmp, addonsDirName)
	stageTestAddonUnit(t, addonsRoot, "serviceradar-np.service", "[Service]\nExecStart=/bin/true\n")

	got, err := resolveStagedAddonUnit(tmp, "np", "serviceradar-np.service")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if filepath.Base(got) != "serviceradar-np.service" {
		t.Fatalf("resolved base = %q", filepath.Base(got))
	}
	if data, err := os.ReadFile(got); err != nil || len(data) == 0 {
		t.Fatalf("resolved unit unreadable: %v", err)
	}

	// Unsafe names and ids are rejected.
	if _, err := resolveStagedAddonUnit(tmp, "np", "../evil.service"); !errors.Is(err, ErrAddonUnitNameUnsafe) {
		t.Fatalf("want ErrAddonUnitNameUnsafe, got %v", err)
	}
	if _, err := resolveStagedAddonUnit(tmp, "../etc", "serviceradar-np.service"); !errors.Is(err, ErrAddonUnsafePath) {
		t.Fatalf("want ErrAddonUnsafePath, got %v", err)
	}
}

func TestResolveStagedAddonUnitEscapeGuard(t *testing.T) {
	tmp := t.TempDir()
	addonsRoot := filepath.Join(tmp, addonsDirName)
	addonDir := filepath.Join(addonsRoot, "np")
	if err := os.MkdirAll(addonDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	outside := filepath.Join(tmp, "outside")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatalf("mkdir outside: %v", err)
	}
	if err := os.WriteFile(filepath.Join(outside, "serviceradar-np.service"), []byte("x"), 0o644); err != nil {
		t.Fatalf("write outside unit: %v", err)
	}
	if err := os.Symlink(outside, filepath.Join(addonDir, addonCurrentLink)); err != nil {
		t.Fatalf("symlink current->outside: %v", err)
	}

	if _, err := resolveStagedAddonUnit(tmp, "np", "serviceradar-np.service"); !errors.Is(err, ErrAddonUnitEscape) {
		t.Fatalf("want ErrAddonUnitEscape, got %v", err)
	}
}

func TestScalibrSystemdUnitRelabelsStagedBinary(t *testing.T) {
	assertSystemdUnitRelabelsStagedBinary(t,
		filepath.Join("..", "..", "..", "addons", "scalibr-endpoint-inventory",
			"serviceradar-scalibr-endpoint-inventory.service"),
		"/var/lib/serviceradar/agent/addons/scalibr-endpoint-inventory/current/serviceradar-scalibr-endpoint-inventory",
	)
}

func TestBumblebeeSystemdUnitRelabelsStagedBinary(t *testing.T) {
	assertSystemdUnitRelabelsStagedBinary(t,
		filepath.Join("..", "..", "..", "addons", "bumblebee-scan",
			"serviceradar-bumblebee-scan.service"),
		"/var/lib/serviceradar/agent/addons/bumblebee/current/serviceradar-bumblebee-scan",
	)
}

func TestNetprobeSystemdUnitRelabelsStagedBinary(t *testing.T) {
	assertSystemdUnitRelabelsStagedBinary(t,
		filepath.Join("..", "..", "..", "addons", "netprobe",
			"serviceradar-netprobe.service"),
		"/var/lib/serviceradar/agent/addons/netprobe/current/serviceradar-netprobe",
	)
}

func TestWorkloadIdentitySystemdUnitRelabelsStagedBinary(t *testing.T) {
	assertSystemdUnitRelabelsStagedBinary(t,
		filepath.Join("..", "..", "..", "addons", "workload-identity",
			"serviceradar-workload-identity.service"),
		"/var/lib/serviceradar/agent/addons/workload-identity/current/serviceradar-workload-identity",
	)
}

func assertSystemdUnitRelabelsStagedBinary(t *testing.T, unitPath, stagedBinary string) {
	t.Helper()
	unitBytes, err := os.ReadFile(unitPath)
	if err != nil {
		t.Fatalf("read unit %s: %v", unitPath, err)
	}
	unit := string(unitBytes)
	if !strings.Contains(unit, "ExecStartPre=+/bin/sh -c '/usr/bin/chcon -t bin_t ") {
		t.Fatal("unit must relabel the staged binary before exec (SELinux var_lib_t -> 203/EXEC)")
	}
	if !strings.Contains(unit, stagedBinary) {
		t.Fatalf("unit ExecStartPre must target the staged current/ binary %s", stagedBinary)
	}
	if !unitAllowsChconOnStagedBinary(unit, stagedBinary) {
		t.Fatalf("ProtectSystem=strict units must ReadWritePaths a prefix of %s so chcon can set bin_t", stagedBinary)
	}
}

func unitAllowsChconOnStagedBinary(unit, stagedBinary string) bool {
	for _, line := range strings.Split(unit, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "ReadWritePaths=") {
			continue
		}
		for _, path := range strings.Fields(strings.TrimPrefix(line, "ReadWritePaths=")) {
			if path == stagedBinary || strings.HasPrefix(stagedBinary, strings.TrimRight(path, "/")+"/") {
				return true
			}
		}
	}
	return false
}

func TestStagedAddonExecutablesSelectsBinariesOnly(t *testing.T) {
	tmp := t.TempDir()
	addonsRoot := filepath.Join(tmp, addonsDirName)
	stageTestAddonUnit(t, addonsRoot, "serviceradar-np.service", "[Service]\nExecStart=/bin/true\n")
	versionDir := filepath.Join(addonsRoot, "np", addonVersionsDir, "1.0.0")
	if err := os.WriteFile(filepath.Join(versionDir, "serviceradar-np"), []byte("bin"), 0o755); err != nil {
		t.Fatalf("write binary: %v", err)
	}
	if err := os.WriteFile(filepath.Join(versionDir, "config.json"), []byte(`{}`), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}
	if err := os.WriteFile(filepath.Join(versionDir, "probe.o"), []byte("obj"), 0o755); err != nil {
		t.Fatalf("write object: %v", err)
	}

	got := stagedAddonExecutables(tmp, "np")
	if len(got) != 1 || filepath.Base(got[0]) != "serviceradar-np" {
		t.Fatalf("stagedAddonExecutables = %v, want [serviceradar-np]", got)
	}
}

func TestInstallAddonSystemdUnitsValidation(t *testing.T) {
	// No units -> ErrAddonSystemdNoUnits (before any systemctl/exec).
	if err := InstallAddonSystemdUnits(context.Background(), AddonSystemdInstallRequest{AddonID: "np"}); !errors.Is(err, ErrAddonSystemdNoUnits) {
		t.Fatalf("want ErrAddonSystemdNoUnits, got %v", err)
	}

	// Enable unit not in the unit set -> ErrAddonSystemdEnableNotListed.
	req := AddonSystemdInstallRequest{
		AddonID: "np",
		Units:   []string{"a.service"},
		Enable:  "b.timer",
	}
	if err := InstallAddonSystemdUnits(context.Background(), req); !errors.Is(err, ErrAddonSystemdEnableNotListed) {
		t.Fatalf("want ErrAddonSystemdEnableNotListed, got %v", err)
	}
}

func TestUninstallAddonSystemdUnitsValidation(t *testing.T) {
	if err := UninstallAddonSystemdUnits(context.Background(), nil); !errors.Is(err, ErrAddonSystemdNoUnits) {
		t.Fatalf("want ErrAddonSystemdNoUnits, got %v", err)
	}
	if err := UninstallAddonSystemdUnits(context.Background(), []string{"../evil.service"}); !errors.Is(err, ErrAddonUnitNameUnsafe) {
		t.Fatalf("want ErrAddonUnitNameUnsafe, got %v", err)
	}
}

func TestDiscoverStagedAddonUnits(t *testing.T) {
	tmp := t.TempDir()
	addonsRoot := filepath.Join(tmp, addonsDirName)
	stageTestAddonUnit(t, addonsRoot, "serviceradar-np.timer", "[Timer]\n")
	stageTestAddonUnit(t, addonsRoot, "serviceradar-np.service", "[Service]\nExecStart=/bin/true\n")
	// A non-unit file in the staged dir (e.g. the binary) must be ignored.
	versionDir := filepath.Join(addonsRoot, "np", addonVersionsDir, "1.0.0")
	if err := os.WriteFile(filepath.Join(versionDir, "serviceradar-np-addon"), []byte("bin"), 0o755); err != nil {
		t.Fatalf("write binary: %v", err)
	}

	got, err := discoverStagedAddonUnits(tmp, "np")
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	want := []string{"serviceradar-np.service", "serviceradar-np.timer"} // sorted, units only
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("discover = %v, want %v", got, want)
	}

	if _, err := discoverStagedAddonUnits(tmp, "../etc"); !errors.Is(err, ErrAddonUnsafePath) {
		t.Fatalf("want ErrAddonUnsafePath for unsafe id, got %v", err)
	}
}

func TestPickPrimarySystemdUnit(t *testing.T) {
	units := []string{"x.service", "x.timer"}

	if got, err := pickPrimarySystemdUnit(units, addonSupervisionSystemdTimer); err != nil || got != "x.timer" {
		t.Fatalf("timer mode = %q,%v; want x.timer", got, err)
	}
	if got, err := pickPrimarySystemdUnit(units, addonSupervisionSystemdService); err != nil || got != "x.service" {
		t.Fatalf("service mode = %q,%v; want x.service", got, err)
	}

	// Two timers -> ambiguous.
	if _, err := pickPrimarySystemdUnit([]string{"a.timer", "b.timer"}, addonSupervisionSystemdTimer); !errors.Is(err, ErrAddonSystemdPrimaryAmbiguous) {
		t.Fatalf("want ErrAddonSystemdPrimaryAmbiguous, got %v", err)
	}
	// No service for service mode -> ambiguous (zero matches).
	if _, err := pickPrimarySystemdUnit([]string{"a.timer"}, addonSupervisionSystemdService); !errors.Is(err, ErrAddonSystemdPrimaryAmbiguous) {
		t.Fatalf("want ErrAddonSystemdPrimaryAmbiguous for no service, got %v", err)
	}
	// Unknown supervision model.
	if _, err := pickPrimarySystemdUnit(units, "agent_sidecar"); !errors.Is(err, ErrAddonSystemdSupervisionUnknown) {
		t.Fatalf("want ErrAddonSystemdSupervisionUnknown, got %v", err)
	}
}

func TestSystemdAddonsToRemove(t *testing.T) {
	installed := map[string][]string{
		"netprobe":  {"serviceradar-netprobe.service"},
		"bumblebee": {"serviceradar-bumblebee.service", "serviceradar-bumblebee.timer"},
		"gone":      {"gone.service"},
	}

	// netprobe + bumblebee still desired; "gone" is no longer assigned.
	toRemove := systemdAddonsToRemove(installed, map[string]bool{"netprobe": true, "bumblebee": true})
	if !reflect.DeepEqual(toRemove, map[string][]string{"gone": {"gone.service"}}) {
		t.Fatalf("toRemove = %v, want only 'gone'", toRemove)
	}

	// All desired -> nothing to remove.
	if got := systemdAddonsToRemove(installed, map[string]bool{"netprobe": true, "bumblebee": true, "gone": true}); got != nil {
		t.Fatalf("expected nil when all desired, got %v", got)
	}

	// None desired -> all removed.
	if got := systemdAddonsToRemove(installed, map[string]bool{}); len(got) != 3 {
		t.Fatalf("expected all 3 removed when none desired, got %v", got)
	}
}

func TestStringsNotIn(t *testing.T) {
	if got := stringsNotIn([]string{"a", "b", "c"}, []string{"b", "c"}); !reflect.DeepEqual(got, []string{"a"}) {
		t.Fatalf("stringsNotIn = %v, want [a]", got)
	}
	if got := stringsNotIn([]string{"x"}, []string{"x", "y"}); got != nil {
		t.Fatalf("expected nil when all present, got %v", got)
	}
	if got := stringsNotIn(nil, []string{"a"}); got != nil {
		t.Fatalf("expected nil for empty input, got %v", got)
	}
}

// stageTestAddonFiles stages arbitrary files under <addonsRoot>/<id>/versions/1.0.0 and
// points the add-on's current symlink at them.
func stageTestAddonFiles(t *testing.T, addonsRoot, id string, files map[string]string) {
	t.Helper()
	vdir := filepath.Join(addonsRoot, id, addonVersionsDir, "1.0.0")
	if err := os.MkdirAll(vdir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(vdir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	current := filepath.Join(addonsRoot, id, addonCurrentLink)
	_ = os.Remove(current)
	if err := os.Symlink(filepath.Join(addonVersionsDir, "1.0.0"), current); err != nil {
		t.Fatalf("symlink current: %v", err)
	}
}

func TestDiscoverInstalledSystemdAddons(t *testing.T) {
	root := filepath.Join(t.TempDir(), addonsDirName)
	stageTestAddonFiles(t, root, "np", map[string]string{
		"serviceradar-np.service": "[Service]\n",
		"serviceradar-np.timer":   "[Timer]\n",
	})
	// A sidecar-style add-on with no unit files must be excluded.
	stageTestAddonFiles(t, root, "sidecaronly", map[string]string{
		"serviceradar-sidecaronly-addon": "bin",
	})

	got := discoverInstalledSystemdAddons(root)
	want := map[string][]string{"np": {"serviceradar-np.service", "serviceradar-np.timer"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("discoverInstalledSystemdAddons = %v, want %v", got, want)
	}

	if got := discoverInstalledSystemdAddons(filepath.Join(t.TempDir(), "absent")); got != nil {
		t.Fatalf("expected nil for missing root, got %v", got)
	}
}

func TestRenderSystemdResourceDropIn(t *testing.T) {
	got := renderSystemdResourceDropIn(agentaddon.Resources{
		CPUMaxPercent:   50,
		MemoryMaxBytes:  268435456,
		MemoryHighBytes: 201326592,
		TasksMax:        32,
		Slice:           "serviceradar-addons.slice",
	})

	for _, want := range []string{
		"[Service]",
		"CPUQuota=50%",
		"MemoryHigh=201326592",
		"MemoryMax=268435456",
		"TasksMax=32",
		"Slice=serviceradar-addons.slice",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("drop-in missing %q in:\n%s", want, got)
		}
	}

	// Only declared (non-zero) limits are emitted.
	partial := renderSystemdResourceDropIn(agentaddon.Resources{MemoryMaxBytes: 1024})
	if strings.Contains(partial, "CPUQuota") || strings.Contains(partial, "TasksMax") ||
		strings.Contains(partial, "Slice=") {
		t.Errorf("unset limits must not appear:\n%s", partial)
	}
	if !strings.Contains(partial, "MemoryMax=1024") {
		t.Errorf("MemoryMax should appear:\n%s", partial)
	}
}
