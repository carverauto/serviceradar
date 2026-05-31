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
	"testing"
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
