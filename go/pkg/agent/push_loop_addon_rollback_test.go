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
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

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

func TestPreInstallFailureRestoresPreviousStateConfig(t *testing.T) {
	runtimeRoot := t.TempDir()
	root := resolveAddonArtifactRoot(runtimeRoot)
	tgz := makeAddonTarGz(t, map[string][]byte{
		"serviceradar-bumblebee-scan":       []byte("#!/bin/sh\nexit 0\n"),
		"bumblebee-scan.json":               []byte("{\n  \"mode\": \"v1\"\n}\n"),
		"serviceradar-bumblebee-scan.timer": []byte("[Timer]\nOnUnitActiveSec=6h\n"),
	})
	key := "addons/bumblebee/0.1.0"
	store := &fakeObjectStore{data: map[string][]byte{key: tgz}}
	if _, err := stageAddonArtifact(context.Background(), store, root, &proto.AddonAssignmentConfig{
		AddonId:           "bumblebee",
		Version:           "0.1.0",
		BinaryPath:        "/usr/local/lib/serviceradar/bin/serviceradar-bumblebee-scan",
		ArtifactObjectKey: key,
		ArtifactSha256:    sha256Hex(tgz),
	}, ""); err != nil {
		t.Fatal(err)
	}
	if err := applyStagedAddonRuntimeConfig(runtimeRoot, &proto.AddonAssignmentConfig{
		AddonId: "bumblebee",
		Version: "0.1.0",
	}); err != nil {
		t.Fatal(err)
	}

	v2 := makeAddonTarGz(t, map[string][]byte{
		"serviceradar-bumblebee-scan":       []byte("#!/bin/sh\nexit 0\n"),
		"bumblebee-scan.json":               []byte("{\n  \"mode\": \"v2\"\n}\n"),
		"serviceradar-bumblebee-scan.timer": []byte("[Timer]\nOnUnitActiveSec=6h\n"),
	})
	v2key := "addons/bumblebee/0.2.0"
	v2store := &fakeObjectStore{data: map[string][]byte{v2key: v2}}
	pl := newSystemdAddonPushLoop(t)
	installed := false
	disposition := pl.applySystemdAddonAtRoot(
		context.Background(),
		&proto.AddonAssignmentConfig{
			AddonId:           "bumblebee",
			Version:           "0.2.0",
			ArtifactSignature: "sig",
			ArtifactObjectKey: v2key,
			ArtifactSha256:    sha256Hex(v2),
			BinaryPath:        "/usr/local/lib/serviceradar/bin/serviceradar-bumblebee-scan",
		},
		addonDeliveryPushedArtifact,
		addonSupervisionSystemdService,
		time.Now(),
		runtimeRoot,
		func(context.Context, *proto.AddonAssignmentConfig, string) bool { return false },
		func(context.Context, *proto.AddonAssignmentConfig, string, time.Time) (string, addonDeliveryDisposition, error) {
			if _, err := stageAddonArtifact(context.Background(), v2store, root, &proto.AddonAssignmentConfig{
				AddonId:           "bumblebee",
				Version:           "0.2.0",
				BinaryPath:        "/usr/local/lib/serviceradar/bin/serviceradar-bumblebee-scan",
				ArtifactObjectKey: v2key,
				ArtifactSha256:    sha256Hex(v2),
			}, ""); err != nil {
				return "", addonDeliveryPermanentFailure, err
			}
			return "", addonDeliverySucceeded, nil
		},
		func(context.Context, AddonSystemdInstallRequest) error {
			installed = true
			return nil
		},
	)
	if disposition != addonDeliveryPermanentFailure {
		t.Fatalf("disposition = %v, want permanent failure for supervision unit contract mismatch", disposition)
	}
	if installed {
		t.Fatal("supervision mismatch reached install")
	}
	state := readJSONMap(t, filepath.Join(addonStateDir(runtimeRoot, "bumblebee"), "bumblebee-scan.json"))
	if state["mode"] != "v1" {
		t.Fatalf("pre-install failure left candidate state in place: %#v", state)
	}
}

func TestSystemdPermanentRefusalViaUpdaterExitCodeSuppressesRetriesUntilInputOrUpdaterChanges(t *testing.T) {
	runtimeRoot := t.TempDir()
	root := resolveAddonArtifactRoot(runtimeRoot)
	hitsFile := filepath.Join(t.TempDir(), "updater-hits")
	updaterPath := filepath.Join(t.TempDir(), "fake-agent-updater")
	// Opaque stderr proves classification uses subprocess exit code 78, never error-text matching.
	scriptV1 := "#!/bin/sh\nprintf 'x\\n' >> '" + hitsFile + "'\nprintf 'opaque refusal\\n' >&2\nexit 78\n"
	if err := os.WriteFile(updaterPath, []byte(scriptV1), 0o755); err != nil {
		t.Fatalf("write fake updater: %v", err)
	}

	stageVersion := func(version string) (string, string) {
		t.Helper()
		tgz := makeAddonTarGz(t, map[string][]byte{
			"serviceradar-bumblebee-scan": []byte("#!/bin/sh\nexit 0\n"),
			"bumblebee-scan.json":         []byte("{\n  \"mode\": \"v1\"\n}\n"),
			"serviceradar-bumblebee-scan.service": []byte(
				"[Service]\nExecStart=/var/lib/serviceradar/agent/addons/bumblebee/current/serviceradar-bumblebee-scan\n",
			),
		})
		key := "addons/bumblebee/" + version
		store := &fakeObjectStore{data: map[string][]byte{key: tgz}}
		sha := sha256Hex(tgz)
		if _, err := stageAddonArtifact(context.Background(), store, root, &proto.AddonAssignmentConfig{
			AddonId:           "bumblebee",
			Version:           version,
			BinaryPath:        "/var/lib/serviceradar/agent/addons/bumblebee/current/serviceradar-bumblebee-scan",
			ArtifactObjectKey: key,
			ArtifactSha256:    sha,
		}, ""); err != nil {
			t.Fatalf("stage %s: %v", version, err)
		}
		return key, sha
	}

	keyV1, shaV1 := stageVersion("0.1.6")
	pl := newSystemdAddonPushLoop(t)
	pl.systemdUpdaterPathOverride = updaterPath
	now := time.Now()
	assignment := &proto.AddonAssignmentConfig{
		AddonId:           "bumblebee",
		Enabled:           true,
		Version:           "0.1.6",
		Delivery:          addonDeliveryPushedArtifact,
		Supervision:       addonSupervisionSystemdService,
		ArtifactObjectKey: keyV1,
		ArtifactSha256:    shaV1,
		ArtifactSignature: "sig-v1",
		BinaryPath:        "/var/lib/serviceradar/agent/addons/bumblebee/current/serviceradar-bumblebee-scan",
		DownloadToken:     "ephemeral-token-1",
	}

	deliver := func(_ context.Context, a *proto.AddonAssignmentConfig, _ string, at time.Time) (string, addonDeliveryDisposition, error) {
		if pl.addonDeliveryInBackoff(a, at) {
			return "", addonDeliveryPermanentFailure, errAddonDeliveryBackoff
		}
		return filepath.Join(root, a.GetAddonId(), addonVersionsDir, a.GetVersion(), "serviceradar-bumblebee-scan"), addonDeliverySucceeded, nil
	}
	installViaSubprocess := func(ctx context.Context, req AddonSystemdInstallRequest) error {
		cmd, err := systemdInstallUpdaterArgs(req)
		if err != nil {
			return err
		}
		if err := runAgentUpdaterCommand(ctx, updaterPath, cmd.args...); err != nil {
			return fmt.Errorf("agent-updater systemd install failed: %w", err)
		}
		return nil
	}
	hitCount := func() int {
		data, err := os.ReadFile(hitsFile)
		if os.IsNotExist(err) {
			return 0
		}
		if err != nil {
			t.Fatalf("read hits: %v", err)
		}
		return len(data) / 2
	}

	// First attempt: exits 78 -> permanent failure, recorded for per-addon status.
	disp := pl.applySystemdAddonAtRoot(
		context.Background(),
		assignment,
		addonDeliveryPushedArtifact,
		addonSupervisionSystemdService,
		now,
		runtimeRoot,
		func(context.Context, *proto.AddonAssignmentConfig, string) bool { return false },
		deliver,
		installViaSubprocess,
	)
	if disp != addonDeliveryPermanentFailure {
		t.Fatalf("first disposition = %v, want permanent failure", disp)
	}
	if got := hitCount(); got != 1 {
		t.Fatalf("updater hits after first attempt = %d, want 1", got)
	}
	statuses := pl.addonDeliveryFailureStatuses(nil)
	if len(statuses) != 1 || statuses[0].GetName() != "addon:bumblebee" || statuses[0].GetApplyDisposition() != configSectionDispositionPermanent {
		t.Fatalf("per-addon failure status = %+v, want addon:bumblebee with permanent_failure", statuses)
	}

	// Second attempt 10 minutes later (past the 5-minute artifact backoff) with a rotated
	// DownloadToken: must STILL be suppressed without spawning the setuid updater again.
	assignmentRotatedToken := &proto.AddonAssignmentConfig{
		AddonId:           assignment.GetAddonId(),
		Enabled:           true,
		Version:           assignment.GetVersion(),
		Delivery:          assignment.GetDelivery(),
		Supervision:       assignment.GetSupervision(),
		ArtifactObjectKey: assignment.GetArtifactObjectKey(),
		ArtifactSha256:    assignment.GetArtifactSha256(),
		ArtifactSignature: assignment.GetArtifactSignature(),
		BinaryPath:        assignment.GetBinaryPath(),
		DownloadToken:     "ephemeral-token-2",
	}
	disp2 := pl.applySystemdAddonAtRoot(
		context.Background(),
		assignmentRotatedToken,
		addonDeliveryPushedArtifact,
		addonSupervisionSystemdService,
		now.Add(10*time.Minute),
		runtimeRoot,
		func(context.Context, *proto.AddonAssignmentConfig, string) bool { return false },
		deliver,
		installViaSubprocess,
	)
	if disp2 != addonDeliveryPermanentFailure {
		t.Fatalf("suppressed disposition = %v, want permanent failure", disp2)
	}
	if got := hitCount(); got != 1 {
		t.Fatalf("updater hits past 5m with unchanged assignment and updater = %d, want 1 (suppressed)", got)
	}

	// Replacing the package-owned updater binary on disk changes its stat identity and
	// must immediately retry even with the same assignment.
	scriptV2 := "#!/bin/sh\n# upgraded updater build\nprintf 'x\\n' >> '" + hitsFile + "'\nprintf 'still refused\\n' >&2\nexit 78\n"
	if err := os.WriteFile(updaterPath, []byte(scriptV2), 0o755); err != nil {
		t.Fatalf("rewrite fake updater: %v", err)
	}
	dispUpdaterChanged := pl.applySystemdAddonAtRoot(
		context.Background(),
		assignmentRotatedToken,
		addonDeliveryPushedArtifact,
		addonSupervisionSystemdService,
		now.Add(10*time.Minute+time.Second),
		runtimeRoot,
		func(context.Context, *proto.AddonAssignmentConfig, string) bool { return false },
		deliver,
		installViaSubprocess,
	)
	if dispUpdaterChanged != addonDeliveryPermanentFailure {
		t.Fatalf("disposition after updater replacement = %v, want permanent failure", dispUpdaterChanged)
	}
	if got := hitCount(); got != 2 {
		t.Fatalf("updater hits after updater binary changed on disk = %d, want 2", got)
	}

	// A replacement with identical bytes, size, and mtime is still a different executable
	// (new inode), and it must retry on the very next poll, inside the artifact backoff
	// window opened by the refusal one second earlier.
	priorInfo, err := os.Stat(updaterPath)
	if err != nil {
		t.Fatalf("stat fake updater: %v", err)
	}
	replacement := updaterPath + ".new"
	if err := os.WriteFile(replacement, []byte(scriptV2), 0o755); err != nil {
		t.Fatalf("write replacement updater: %v", err)
	}
	if err := os.Chtimes(replacement, priorInfo.ModTime(), priorInfo.ModTime()); err != nil {
		t.Fatalf("preserve replacement mtime: %v", err)
	}
	if err := os.Rename(replacement, updaterPath); err != nil {
		t.Fatalf("install replacement updater: %v", err)
	}
	_ = pl.applySystemdAddonAtRoot(
		context.Background(),
		assignmentRotatedToken,
		addonDeliveryPushedArtifact,
		addonSupervisionSystemdService,
		now.Add(10*time.Minute+2*time.Second),
		runtimeRoot,
		func(context.Context, *proto.AddonAssignmentConfig, string) bool { return false },
		deliver,
		installViaSubprocess,
	)
	if got := hitCount(); got != 3 {
		t.Fatalf("updater hits after same-size, same-mtime updater replacement = %d, want 3", got)
	}

	// Changing the assigned package version must immediately retry the updater.
	keyV2, shaV2 := stageVersion("0.1.8")
	assignmentUpgraded := &proto.AddonAssignmentConfig{
		AddonId:           "bumblebee",
		Enabled:           true,
		Version:           "0.1.8",
		Delivery:          addonDeliveryPushedArtifact,
		Supervision:       addonSupervisionSystemdService,
		ArtifactObjectKey: keyV2,
		ArtifactSha256:    shaV2,
		ArtifactSignature: "sig-v2",
		BinaryPath:        "/usr/lib/serviceradar/addons/bumblebee/current/serviceradar-bumblebee-scan",
	}
	_ = pl.applySystemdAddonAtRoot(
		context.Background(),
		assignmentUpgraded,
		addonDeliveryPushedArtifact,
		addonSupervisionSystemdService,
		now.Add(11*time.Minute),
		runtimeRoot,
		func(context.Context, *proto.AddonAssignmentConfig, string) bool { return false },
		deliver,
		installViaSubprocess,
	)
	if got := hitCount(); got != 4 {
		t.Fatalf("updater hits after version change = %d, want 4", got)
	}
}

func TestFailedSystemdActivationRestoresPreviousStateConfig(t *testing.T) {
	for _, tc := range []struct {
		name            string
		installErr      error
		wantDisposition addonDeliveryDisposition
		wantReported    string
	}{
		{
			name:            "updater unavailable is retried",
			installErr:      errAgentUpdaterUnavailable,
			wantDisposition: addonDeliveryTransientFailure,
		},
		{
			// The package-owned updater only changes with a host package upgrade, so
			// retrying cannot succeed. Deferring would hold every config version back.
			name: "updater missing a required flag is reported, not retried",
			installErr: fmt.Errorf("locate agent updater for systemd install: %w",
				fmt.Errorf("%w: --addon-version", errReleaseUpdaterFlagUnsupported)),
			wantDisposition: addonDeliveryPermanentFailure,
			wantReported:    "bumblebee: locate agent updater for systemd install: release updater does not support required flag: --addon-version",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pl, disposition, runtimeRoot := applyBumblebeeUpgradeWithInstallError(t, tc.installErr)

			if disposition != tc.wantDisposition {
				t.Fatalf("disposition = %v, want %v", disposition, tc.wantDisposition)
			}
			got := ""
			var addonPermErr *addonAssignmentsPermanentError
			if permErr := pl.assignedAddonPermanentFailureError(); errors.As(permErr, &addonPermErr) {
				got = addonPermErr.summary
			}
			if got != tc.wantReported {
				t.Fatalf("reported failure = %q, want %q", got, tc.wantReported)
			}
			state := readJSONMap(t, filepath.Join(addonStateDir(runtimeRoot, "bumblebee"), "bumblebee-scan.json"))
			if state["mode"] != "v1" {
				t.Fatalf("failed activation left the new state config in place: %#v", state)
			}
		})
	}
}

// applyBumblebeeUpgradeWithInstallError stages bumblebee 0.1.0 as the applied version,
// then applies 0.2.0 through a privileged install that fails with installErr.
func applyBumblebeeUpgradeWithInstallError(t *testing.T, installErr error) (*PushLoop, addonDeliveryDisposition, string) {
	t.Helper()

	runtimeRoot := t.TempDir()
	root := resolveAddonArtifactRoot(runtimeRoot)
	stage := func(version string, config []byte) {
		t.Helper()
		tgz := makeAddonTarGz(t, map[string][]byte{
			"serviceradar-bumblebee-scan":         []byte("#!/bin/sh\nexit 0\n"),
			"bumblebee-scan.json":                 config,
			"serviceradar-bumblebee-scan.service": []byte("[Service]\nExecStart=/bin/true\n"),
		})
		key := "addons/bumblebee/" + version
		store := &fakeObjectStore{data: map[string][]byte{key: tgz}}
		a := &proto.AddonAssignmentConfig{
			AddonId:           "bumblebee",
			Version:           version,
			BinaryPath:        "/usr/local/lib/serviceradar/bin/serviceradar-bumblebee-scan",
			ArtifactObjectKey: key,
			ArtifactSha256:    sha256Hex(tgz),
		}
		if _, err := stageAddonArtifact(context.Background(), store, root, a, ""); err != nil {
			t.Fatalf("stage %s: %v", version, err)
		}
	}
	stage("0.1.0", []byte("{\n  \"mode\": \"v1\"\n}\n"))
	if err := applyStagedAddonRuntimeConfig(runtimeRoot, &proto.AddonAssignmentConfig{
		AddonId: "bumblebee",
		Version: "0.1.0",
	}); err != nil {
		t.Fatal(err)
	}

	pl := newSystemdAddonPushLoop(t)
	a := &proto.AddonAssignmentConfig{
		AddonId:           "bumblebee",
		Version:           "0.2.0",
		ArtifactSignature: "sig",
		ConfigJson:        []byte(`{"mode":"v2"}`),
	}
	disposition := pl.applySystemdAddonAtRoot(
		context.Background(),
		a,
		addonDeliveryPushedArtifact,
		addonSupervisionSystemdService,
		time.Now(),
		runtimeRoot,
		func(context.Context, *proto.AddonAssignmentConfig, string) bool { return false },
		func(context.Context, *proto.AddonAssignmentConfig, string, time.Time) (string, addonDeliveryDisposition, error) {
			stage("0.2.0", []byte("{\n  \"mode\": \"v2\"\n}\n"))
			return "", addonDeliverySucceeded, nil
		},
		func(context.Context, AddonSystemdInstallRequest) error {
			return installErr
		},
	)

	return pl, disposition, runtimeRoot
}

func TestTimerActivationIsRequestedOnlyForANewVersion(t *testing.T) {
	timer := "serviceradar-netprobe.timer"
	for _, tc := range []struct {
		name, prior, supervision string
		wantFresh                bool
	}{
		{"upgrade", "versions/1.0.0", addonSupervisionSystemdTimer, true},
		{"first install", "", addonSupervisionSystemdTimer, true},
		{"same version failure", "versions/1.1.0", addonSupervisionSystemdTimer, false},
		{"service upgrade", "versions/1.0.0", addonSupervisionSystemdService, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			units := []string{netprobeTestUnit}
			if tc.supervision == addonSupervisionSystemdTimer {
				units = append(units, timer)
			}
			root := stageSystemdAddonFixture(t, map[string][]string{
				"1.0.0": units, "1.1.0": units,
			})
			assignment := &proto.AddonAssignmentConfig{
				AddonId: netprobeTestAddonID, Version: "1.1.0",
			}
			pl := newSystemdAddonPushLoop(t)
			called := false
			install := func(_ context.Context, req AddonSystemdInstallRequest) error {
				called = true
				if req.RunTimerNow != tc.wantFresh {
					t.Fatalf("fresh timer execution = %v, want %v", req.RunTimerNow, tc.wantFresh)
				}
				return nil
			}
			if err := pl.reconcileStagedSystemdUnits(context.Background(), assignment,
				tc.supervision, root, tc.prior, install); err != nil {
				t.Fatalf("candidate systemd activation failed: %v", err)
			}
			if !called {
				t.Fatal("candidate never reached the privileged install boundary")
			}
		})
	}
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
	failingInstall := func(_ context.Context, _ AddonSystemdInstallRequest) error {
		installAttempted = true
		return errAgentUpdaterUnavailable
	}

	err := pl.reconcileStagedSystemdUnits(
		context.Background(),
		&proto.AddonAssignmentConfig{AddonId: id},
		addonSupervisionSystemdService,
		runtimeRoot,
		prior,
		failingInstall,
	)
	if !errors.Is(err, errAgentUpdaterUnavailable) {
		t.Fatalf("reconcile error = %v, want errAgentUpdaterUnavailable", err)
	}

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
	install := func(_ context.Context, _ AddonSystemdInstallRequest) error {
		t.Error("install must not run when the staged bundle has no units")
		return nil
	}

	err := pl.reconcileStagedSystemdUnits(
		context.Background(),
		&proto.AddonAssignmentConfig{AddonId: id},
		addonSupervisionSystemdService,
		runtimeRoot,
		prior,
		install,
	)
	if !errors.Is(err, ErrAddonSystemdNoUnitsDiscovered) {
		t.Fatalf("reconcile error = %v, want ErrAddonSystemdNoUnitsDiscovered", err)
	}

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
	okInstall := func(_ context.Context, req AddonSystemdInstallRequest) error {
		gotUnits = req.Units
		gotEnable = req.Enable
		return nil
	}

	err := pl.reconcileStagedSystemdUnits(
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
	if err != nil {
		t.Fatalf("reconcile failed: %v", err)
	}

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
	if err := os.WriteFile(StagedAddonArtifactPath(versionDir), payload, 0o644); err != nil {
		t.Fatalf("retain artifact: %v", err)
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
	if err := os.WriteFile(StagedAddonArtifactPath(versionDir), payload, 0o644); err != nil {
		t.Fatalf("retain artifact: %v", err)
	}
	if err := writeAddonStageMetadata(versionDir, addonStageMetadata{
		AddonID:        netprobeTestAddonID,
		Version:        "1.1.0",
		BinaryName:     "serviceradar-netprobe",
		ArtifactObject: "native-addons/netprobe/1.1.0/linux/amd64/netprobe.tar.gz",
		ArtifactSHA256: sha,
		Signature:      "test-signature",
	}); err != nil {
		t.Fatalf("write stage metadata: %v", err)
	}
	if err := writeAddonSystemdActivationMetadata(versionDir, addonSystemdActivationMetadata{
		AddonID:        netprobeTestAddonID,
		Version:        "1.1.0",
		BinaryName:     "serviceradar-netprobe",
		ArtifactSHA256: sha,
		Signature:      "test-signature",
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
		ArtifactSignature: "test-signature",
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
		func(context.Context, AddonSystemdInstallRequest) error {
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

// Privileged artifact metadata (version, binary, digest, signature, artifact path)
// is passed to the root-owned updater so it can verify and materialize the runtime.
func TestReconcileStagedSystemdUnitsPassesArtifactMetadataToUpdater(t *testing.T) {
	const id = "netprobe"

	runtimeRoot := stageSystemdAddonFixture(t, map[string][]string{
		"1.1.0": {netprobeTestUnit},
	})

	pl := newSystemdAddonPushLoop(t)
	var gotReq AddonSystemdInstallRequest
	install := func(_ context.Context, req AddonSystemdInstallRequest) error {
		gotReq = req
		return nil
	}

	wantSHA := sha256Hex([]byte("netprobe-1.1.0"))
	wantSig := "test-sig"
	err := pl.reconcileStagedSystemdUnits(
		context.Background(),
		&proto.AddonAssignmentConfig{
			AddonId:           id,
			Version:           "1.1.0",
			ArtifactSha256:    wantSHA,
			ArtifactSignature: wantSig,
		},
		addonSupervisionSystemdService,
		runtimeRoot,
		"",
		install,
	)
	if err != nil {
		t.Fatalf("reconcile failed: %v", err)
	}

	if gotReq.AddonID != id {
		t.Fatalf("got AddonID = %q, want %q", gotReq.AddonID, id)
	}
	if gotReq.Version != "1.1.0" {
		t.Fatalf("got Version = %q, want 1.1.0", gotReq.Version)
	}
	if gotReq.ArtifactSHA256 != wantSHA {
		t.Fatalf("got ArtifactSHA256 = %q, want %q", gotReq.ArtifactSHA256, wantSHA)
	}
	if gotReq.Signature != wantSig {
		t.Fatalf("got Signature = %q, want %q", gotReq.Signature, wantSig)
	}
}
