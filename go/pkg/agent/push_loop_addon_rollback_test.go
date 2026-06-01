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
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const netprobeTestUnit = "serviceradar-netprobe.service"

var errAgentUpdaterUnavailable = errors.New("agent-updater unavailable")

// stageSystemdAddonFixture builds a temp runtime root with
// <root>/addons/<id>/versions/<v>/ dirs (each holding the named unit files) and points
// `current` -> versions/<current>, mirroring the post-stageAndCapability staging layout.
// Returns the runtime root to pass to reconcileStagedSystemdUnits.
func stageSystemdAddonFixture(t *testing.T, addonID, current string, versions map[string][]string) string {
	t.Helper()

	runtimeRoot := t.TempDir()
	addonDir := filepath.Join(resolveAddonArtifactRoot(runtimeRoot), addonID)
	for version, units := range versions {
		versionDir := filepath.Join(addonDir, addonVersionsDir, version)
		if err := os.MkdirAll(versionDir, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", versionDir, err)
		}
		for _, unit := range units {
			if err := os.WriteFile(filepath.Join(versionDir, unit), []byte("[Unit]\n"), 0o644); err != nil {
				t.Fatalf("write unit %s: %v", unit, err)
			}
		}
	}
	if err := switchAddonCurrentSymlink(addonDir, filepath.Join(addonVersionsDir, current)); err != nil {
		t.Fatalf("switch current symlink: %v", err)
	}

	return runtimeRoot
}

func newSystemdAddonPushLoop(t *testing.T) *PushLoop {
	t.Helper()

	return NewPushLoop(&Server{config: &ServerConfig{}}, nil, 30*time.Second, logger.NewTestLogger())
}

func currentAddonTarget(t *testing.T, runtimeRoot, addonID string) string {
	t.Helper()

	addonDir := filepath.Join(resolveAddonArtifactRoot(runtimeRoot), addonID)
	target, ok := readAddonCurrentTarget(addonDir)
	if !ok {
		t.Fatalf("current symlink missing for %s", addonID)
	}

	return target
}

// §2.4: a failed unit install rolls `current` back to the prior version (no
// half-installed/running-but-incapable add-on left behind).
func TestReconcileStagedSystemdUnitsRollsBackOnInstallFailure(t *testing.T) {
	const id = "netprobe"

	prior := filepath.Join(addonVersionsDir, "1.0.0")
	runtimeRoot := stageSystemdAddonFixture(t, id, "1.1.0", map[string][]string{
		"1.0.0": {netprobeTestUnit},
		"1.1.0": {netprobeTestUnit},
	})

	pl := newSystemdAddonPushLoop(t)
	installAttempted := false
	failingInstall := func(_ context.Context, _ string, _ []string, _ string) error {
		installAttempted = true
		return errAgentUpdaterUnavailable
	}

	pl.reconcileStagedSystemdUnits(
		context.Background(),
		&proto.AddonAssignmentConfig{AddonId: id},
		addonSupervisionSystemdService,
		runtimeRoot,
		prior,
		failingInstall,
	)

	if !installAttempted {
		t.Fatal("expected an install attempt before the failure")
	}
	if got := currentAddonTarget(t, runtimeRoot, id); got != prior {
		t.Fatalf("current = %q, want rollback to %q", got, prior)
	}
	if units := pl.systemdAddonUnits(id); len(units) != 0 {
		t.Fatalf("expected no remembered units after a rolled-back install, got %v", units)
	}
}

// §2.4: a freshly-staged bundle with no systemd units rolls back without attempting an
// install.
func TestReconcileStagedSystemdUnitsRollsBackWhenNoUnits(t *testing.T) {
	const id = "netprobe"

	prior := filepath.Join(addonVersionsDir, "1.0.0")
	runtimeRoot := stageSystemdAddonFixture(t, id, "1.1.0", map[string][]string{
		"1.0.0": {netprobeTestUnit},
		"1.1.0": {}, // staged version ships no units
	})

	pl := newSystemdAddonPushLoop(t)
	install := func(_ context.Context, _ string, _ []string, _ string) error {
		t.Error("install must not run when the staged bundle has no units")
		return nil
	}

	pl.reconcileStagedSystemdUnits(
		context.Background(),
		&proto.AddonAssignmentConfig{AddonId: id},
		addonSupervisionSystemdService,
		runtimeRoot,
		prior,
		install,
	)

	if got := currentAddonTarget(t, runtimeRoot, id); got != prior {
		t.Fatalf("current = %q, want rollback to %q", got, prior)
	}
}

// A successful install keeps `current` on the new version and records the installed
// units (no rollback).
func TestReconcileStagedSystemdUnitsSuccess(t *testing.T) {
	const id = "netprobe"

	newTarget := filepath.Join(addonVersionsDir, "1.1.0")
	runtimeRoot := stageSystemdAddonFixture(t, id, "1.1.0", map[string][]string{
		"1.0.0": {netprobeTestUnit},
		"1.1.0": {netprobeTestUnit},
	})

	pl := newSystemdAddonPushLoop(t)
	var gotUnits []string
	var gotEnable string
	okInstall := func(_ context.Context, _ string, units []string, enable string) error {
		gotUnits = units
		gotEnable = enable
		return nil
	}

	pl.reconcileStagedSystemdUnits(
		context.Background(),
		&proto.AddonAssignmentConfig{AddonId: id},
		addonSupervisionSystemdService,
		runtimeRoot,
		filepath.Join(addonVersionsDir, "1.0.0"),
		okInstall,
	)

	if len(gotUnits) != 1 || gotUnits[0] != netprobeTestUnit {
		t.Fatalf("install units = %v, want [%s]", gotUnits, netprobeTestUnit)
	}
	if gotEnable != netprobeTestUnit {
		t.Fatalf("enable = %q, want %s", gotEnable, netprobeTestUnit)
	}
	if cur := currentAddonTarget(t, runtimeRoot, id); cur != newTarget {
		t.Fatalf("current = %q, want it to stay on %q (no rollback)", cur, newTarget)
	}
	if units := pl.systemdAddonUnits(id); len(units) != 1 || units[0] != netprobeTestUnit {
		t.Fatalf("remembered units = %v, want [%s]", units, netprobeTestUnit)
	}
}
