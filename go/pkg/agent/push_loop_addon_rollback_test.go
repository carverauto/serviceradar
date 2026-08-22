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
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const (
	netprobeTestAddonID = "netprobe"
	netprobeTestUnit    = "serviceradar-netprobe.service"
)

var errAgentUpdaterUnavailable = errors.New("agent-updater unavailable")

// stageSystemdAddonFixture builds a temp runtime root with
// <root>/addons/netprobe/versions/<v>/ dirs (each holding the named unit files) and points
// `current` -> versions/1.1.0, mirroring the post-stageAndCapability staging layout.
// Returns the runtime root to pass to reconcileStagedSystemdUnits.
func stageSystemdAddonFixture(t *testing.T, versions map[string][]string) string {
	t.Helper()

	runtimeRoot := t.TempDir()
	addonDir := filepath.Join(resolveAddonArtifactRoot(runtimeRoot), netprobeTestAddonID)
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
	if err := switchAddonCurrentSymlink(addonDir, filepath.Join(addonVersionsDir, "1.1.0")); err != nil {
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
	runtimeRoot := stageSystemdAddonFixture(t, map[string][]string{
		"1.0.0": {netprobeTestUnit},
		"1.1.0": {netprobeTestUnit},
	})

	pl := newSystemdAddonPushLoop(t)
	installAttempted := false
	failingInstall := func(_ context.Context, _ string, _ []string, _ string, _ agentaddon.Resources) error {
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
	runtimeRoot := stageSystemdAddonFixture(t, map[string][]string{
		"1.0.0": {netprobeTestUnit},
		"1.1.0": {}, // staged version ships no units
	})

	pl := newSystemdAddonPushLoop(t)
	install := func(_ context.Context, _ string, _ []string, _ string, _ agentaddon.Resources) error {
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
	runtimeRoot := stageSystemdAddonFixture(t, map[string][]string{
		"1.0.0": {netprobeTestUnit},
		"1.1.0": {netprobeTestUnit},
	})

	pl := newSystemdAddonPushLoop(t)
	var gotUnits []string
	var gotEnable string
	okInstall := func(_ context.Context, _ string, units []string, enable string, _ agentaddon.Resources) error {
		gotUnits = units
		gotEnable = enable
		return nil
	}

	pl.reconcileStagedSystemdUnits(
		context.Background(),
		&proto.AddonAssignmentConfig{
			AddonId:        id,
			Version:        "1.1.0",
			BinaryPath:     "/var/lib/serviceradar/agent/addons/netprobe/current/serviceradar-netprobe",
			ArtifactSha256: sha256Hex([]byte("netprobe-1.1.0")),
		},
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
	if !systemdAddonActivationCurrent(
		filepath.Join(resolveAddonArtifactRoot(runtimeRoot), id, addonVersionsDir, "1.1.0"),
		"1.1.0",
		"serviceradar-netprobe",
		sha256Hex([]byte("netprobe-1.1.0")),
		"",
		"",
		[]string{netprobeTestUnit},
	) {
		t.Fatal("expected successful systemd install to record durable activation metadata")
	}
}

func TestSystemdAddonAssignmentCurrentRequiresMatchingStageMetadataAndTrackedUnits(t *testing.T) {
	const id = "netprobe"

	payload := []byte("netprobe-binary")
	sha := sha256Hex(payload)
	runtimeRoot := stageSystemdAddonFixture(t, map[string][]string{
		"1.1.0": {netprobeTestUnit},
	})
	versionDir := filepath.Join(resolveAddonArtifactRoot(runtimeRoot), id, addonVersionsDir, "1.1.0")
	if err := os.WriteFile(filepath.Join(versionDir, "serviceradar-netprobe"), payload, addonBinaryMode); err != nil {
		t.Fatalf("write binary: %v", err)
	}
	if err := writeAddonStageMetadata(versionDir, addonStageMetadata{
		AddonID:        id,
		Version:        "1.1.0",
		BinaryName:     "serviceradar-netprobe",
		ArtifactObject: "native-addons/netprobe/1.1.0/linux/amd64/netprobe.tar.gz",
		ArtifactSHA256: sha,
	}); err != nil {
		t.Fatalf("write stage metadata: %v", err)
	}

	assignment := &proto.AddonAssignmentConfig{
		AddonId:           id,
		Version:           "1.1.0",
		BinaryPath:        "/var/lib/serviceradar/agent/addons/netprobe/current/serviceradar-netprobe",
		ArtifactObjectKey: "native-addons/netprobe/1.1.0/linux/amd64/netprobe.tar.gz",
		ArtifactSha256:    sha,
	}

	pl := newSystemdAddonPushLoop(t)
	if pl.systemdAddonAssignmentCurrent(assignment, runtimeRoot) {
		t.Fatal("assignment should not be current until systemd units are tracked")
	}

	pl.rememberSystemdAddon(id, []string{netprobeTestUnit})
	if pl.systemdAddonAssignmentCurrent(assignment, runtimeRoot) {
		t.Fatal("assignment should not be current until systemd activation metadata is recorded")
	}
	if err := writeAddonSystemdActivationMetadata(versionDir, addonSystemdActivationMetadata{
		AddonID:        id,
		Version:        "1.1.0",
		BinaryName:     "serviceradar-netprobe",
		ArtifactSHA256: sha,
		Units:          []string{netprobeTestUnit},
		Enable:         netprobeTestUnit,
	}); err != nil {
		t.Fatalf("write systemd activation metadata: %v", err)
	}
	if !pl.systemdAddonAssignmentCurrent(assignment, runtimeRoot) {
		t.Fatal("assignment should be current with matching stage metadata, activation metadata, and tracked units")
	}

	assignment.ConfigJson = []byte(`{"context_name":"default-cp3"}`)
	if pl.systemdAddonAssignmentCurrent(assignment, runtimeRoot) {
		t.Fatal("assignment with changed config must not be treated as current")
	}
	if err := writeAddonSystemdActivationMetadata(versionDir, addonSystemdActivationMetadata{
		AddonID:        id,
		Version:        "1.1.0",
		BinaryName:     "serviceradar-netprobe",
		ArtifactSHA256: sha,
		ConfigSHA256:   addonAssignmentConfigSHA256(assignment.GetConfigJson()),
		Units:          []string{netprobeTestUnit},
		Enable:         netprobeTestUnit,
	}); err != nil {
		t.Fatalf("write systemd activation metadata with config hash: %v", err)
	}
	if !pl.systemdAddonAssignmentCurrent(assignment, runtimeRoot) {
		t.Fatal("assignment should be current after matching config hash is recorded")
	}

	assignment.ArtifactSha256 = sha256Hex([]byte("different"))
	if pl.systemdAddonAssignmentCurrent(assignment, runtimeRoot) {
		t.Fatal("assignment with a different artifact sha must not be treated as current")
	}
}

func TestSystemdAddonRuntimeEndpointReadyRequiresNetprobeSocket(t *testing.T) {
	socketDir, err := os.MkdirTemp("/tmp", "sr-netprobe-")
	if err != nil {
		t.Fatalf("create short test socket directory: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(socketDir) })
	socketPath := filepath.Join(socketDir, "ipc.sock")
	if systemdAddonRuntimeEndpointReady(
		true,
		netprobeTestAddonID,
		addonSupervisionSystemdService,
		socketPath,
	) {
		t.Fatal("active netprobe with a missing IPC socket must be reconciled")
	}

	var listenConfig net.ListenConfig
	listener, err := listenConfig.Listen(context.Background(), "unix", socketPath)
	if err != nil {
		t.Fatalf("listen on test Unix socket: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	if !systemdAddonRuntimeEndpointReady(
		true,
		netprobeTestAddonID,
		addonSupervisionSystemdService,
		socketPath,
	) {
		t.Fatal("active netprobe with its IPC socket should skip unchanged activation")
	}
}

func TestApplySystemdAddonReconcilesCurrentNetprobeWhenIPCSocketMissing(t *testing.T) {
	payload := []byte("netprobe-binary")
	sha := sha256Hex(payload)
	runtimeRoot := stageSystemdAddonFixture(t, map[string][]string{
		"1.1.0": {netprobeTestUnit},
	})
	versionDir := filepath.Join(resolveAddonArtifactRoot(runtimeRoot), netprobeTestAddonID, addonVersionsDir, "1.1.0")
	if err := os.WriteFile(filepath.Join(versionDir, "serviceradar-netprobe"), payload, addonBinaryMode); err != nil {
		t.Fatalf("write binary: %v", err)
	}
	if err := writeAddonStageMetadata(versionDir, addonStageMetadata{
		AddonID:        netprobeTestAddonID,
		Version:        "1.1.0",
		BinaryName:     "serviceradar-netprobe",
		ArtifactObject: "native-addons/netprobe/1.1.0/linux/amd64/netprobe.tar.gz",
		ArtifactSHA256: sha,
	}); err != nil {
		t.Fatalf("write stage metadata: %v", err)
	}
	if err := writeAddonSystemdActivationMetadata(versionDir, addonSystemdActivationMetadata{
		AddonID:        netprobeTestAddonID,
		Version:        "1.1.0",
		BinaryName:     "serviceradar-netprobe",
		ArtifactSHA256: sha,
		Units:          []string{netprobeTestUnit},
		Enable:         netprobeTestUnit,
	}); err != nil {
		t.Fatalf("write activation metadata: %v", err)
	}

	assignment := &proto.AddonAssignmentConfig{
		AddonId:           netprobeTestAddonID,
		Version:           "1.1.0",
		BinaryPath:        "/var/lib/serviceradar/agent/addons/netprobe/current/serviceradar-netprobe",
		ArtifactObjectKey: "native-addons/netprobe/1.1.0/linux/amd64/netprobe.tar.gz",
		ArtifactSha256:    sha,
	}
	pl := newSystemdAddonPushLoop(t)
	pl.rememberSystemdAddon(netprobeTestAddonID, []string{netprobeTestUnit})
	if !pl.systemdAddonAssignmentCurrent(assignment, runtimeRoot) {
		t.Fatal("test fixture must be a current systemd assignment")
	}

	missingSocket := filepath.Join(t.TempDir(), "ipc.sock")
	deliveries := 0
	installs := 0
	disposition := pl.applySystemdAddonAtRoot(
		context.Background(),
		assignment,
		addonDeliveryPushedArtifact,
		addonSupervisionSystemdService,
		time.Now(),
		runtimeRoot,
		func(context.Context, *proto.AddonAssignmentConfig, string) bool {
			return systemdAddonRuntimeEndpointReady(
				true,
				netprobeTestAddonID,
				addonSupervisionSystemdService,
				missingSocket,
			)
		},
		func(context.Context, *proto.AddonAssignmentConfig, string, time.Time) (string, addonDeliveryDisposition, error) {
			deliveries++
			return filepath.Join(versionDir, "serviceradar-netprobe"), addonDeliverySucceeded, nil
		},
		func(context.Context, string, []string, string, agentaddon.Resources) error {
			installs++
			return nil
		},
	)

	if disposition != addonDeliverySucceeded {
		t.Fatalf("apply disposition = %v, want success", disposition)
	}
	if deliveries != 1 || installs != 1 {
		t.Fatalf("deliveries = %d, installs = %d; missing IPC socket must reach reinstall", deliveries, installs)
	}
}

// The SELinux relabel must run from the AGENT, before the units are installed.
//
// serviceradar-agent-updater is setuid-root and owned by the RPM: a release
// activation replaces the agent but never the updater, so hosts that have
// self-updated for months still run their original updater. When the relabel lived
// only inside the updater, every such host left its staged add-on binaries labelled
// var_lib_t and systemd failed each start with 203/EXEC. Relabelling here keeps the
// fix with the component that actually updates.
func TestReconcileStagedSystemdUnitsRelabelsBeforeInstall(t *testing.T) {
	const id = "netprobe"

	runtimeRoot := stageSystemdAddonFixture(t, map[string][]string{
		"1.1.0": {netprobeTestUnit},
	})

	pl := newSystemdAddonPushLoop(t)

	var order []string
	var relabelledRoot, relabelledAddon string

	pl.relabelStagedAddonExecutables = func(root, addonID string) {
		order = append(order, "relabel")
		relabelledRoot, relabelledAddon = root, addonID
	}

	install := func(_ context.Context, _ string, _ []string, _ string, _ agentaddon.Resources) error {
		order = append(order, "install")
		return nil
	}

	pl.reconcileStagedSystemdUnits(
		context.Background(),
		&proto.AddonAssignmentConfig{
			AddonId:        id,
			Version:        "1.1.0",
			ArtifactSha256: sha256Hex([]byte("netprobe-1.1.0")),
		},
		addonSupervisionSystemdService,
		runtimeRoot,
		"",
		install,
	)

	if len(order) != 2 || order[0] != "relabel" || order[1] != "install" {
		t.Fatalf("call order = %v, want [relabel install]; a relabel after enable --now "+
			"still leaves the first start at 203/EXEC", order)
	}
	if relabelledAddon != id {
		t.Fatalf("relabelled addon = %q, want %q", relabelledAddon, id)
	}
	if relabelledRoot != runtimeRoot {
		t.Fatalf("relabelled runtime root = %q, want %q", relabelledRoot, runtimeRoot)
	}
}
