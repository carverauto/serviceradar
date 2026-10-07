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

// systemd-service / systemd-timer supervision for native add-ons (delivery-models
// task 3.1). A non-root agent stages a signed add-on bundle (addon_activation.go) whose
// .service/.timer unit files ride inside the bundle, then asks the root-owned
// serviceradar-agent-updater to install + enable exactly the units the control plane
// names. The privileged systemctl operations run only inside the updater, against unit
// files re-resolved under the controlled add-on staging root. This is the supervision
// path for capability-granted long-running daemons (e.g. netprobe -> systemd-service)
// and periodic scanners (e.g. Bumblebee -> systemd-timer); the timer's spooled output
// is ingested by the consuming add-on's own spool service, not here.

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/go/pkg/hashutil"
)

// defaultPrivilegedAddonRoot is the root-owned runtime tree where the privileged
// updater materializes verified add-ons.
const defaultPrivilegedAddonRoot = "/usr/lib/serviceradar/addons"

// systemdUnitDir is where the root-owned updater installs add-on unit files.
// Can be overridden in unit tests.
var systemdUnitDir = "/etc/systemd/system"

// systemdUnitFileMode is the on-disk mode for an installed unit file (root:root 0644).
const systemdUnitFileMode = 0o644

var (
	// ErrSystemctlUnavailable is returned when systemctl is not on PATH (no systemd).
	ErrSystemctlUnavailable = errors.New("systemctl not available")
	// ErrAddonSystemdNoUnits is returned when an install/uninstall is requested with no
	// unit names.
	ErrAddonSystemdNoUnits = errors.New("no systemd units specified")
	// ErrAddonSystemdEnableNotListed is returned when the unit to enable is not part of
	// the installed unit set.
	ErrAddonSystemdEnableNotListed = errors.New("systemd enable unit is not in the installed unit set")
	// ErrAddonUnitNameUnsafe is returned when a unit file name is not a safe single path
	// segment ending in .service or .timer.
	ErrAddonUnitNameUnsafe = errors.New("addon systemd unit name is invalid")
	// ErrAddonUnitNotRegular is returned when a staged unit path is not a regular file.
	ErrAddonUnitNotRegular = errors.New("staged addon systemd unit is not a regular file")
	// ErrAddonUnitEscape is returned when a staged unit resolves outside its add-on dir.
	ErrAddonUnitEscape = errors.New("staged addon systemd unit resolves outside its staging directory")
	// ErrAddonSystemdNoUnitsDiscovered is returned when a systemd-supervised add-on's
	// staged bundle contains no .service/.timer unit files to install.
	ErrAddonSystemdNoUnitsDiscovered = errors.New("no systemd unit files in staged addon bundle")
	// ErrAddonSystemdPrimaryAmbiguous is returned when the unit to enable for a
	// supervision model cannot be chosen unambiguously (zero or multiple candidates).
	ErrAddonSystemdPrimaryAmbiguous = errors.New("cannot select a single systemd unit to enable")
	// ErrAddonSystemdSupervisionUnknown is returned when a primary unit is requested for
	// a supervision model that is not systemd-service or systemd-timer.
	ErrAddonSystemdSupervisionUnknown = errors.New("unsupported systemd supervision model")
	// ErrAddonSystemdTimerRequiresTimer is returned when timer activation is
	// requested without a timer primary unit.
	ErrAddonSystemdTimerRequiresTimer = errors.New("timer activation requires a timer primary unit")
	// ErrAddonSignatureRequired is returned when an unsigned artifact is requested
	// for privileged systemd supervision.
	ErrAddonSignatureRequired = errors.New("artifact signature is required for privileged systemd add-ons")
	// ErrAddonArtifactMissing is returned when the staged artifact archive cannot be found.
	ErrAddonArtifactMissing = errors.New("staged addon artifact is missing")
	// ErrAddonUnitExecPathUnsafe is returned when a unit would execute a command from
	// the agent-writable add-on tree.
	ErrAddonUnitExecPathUnsafe = errors.New("addon systemd unit executes from the agent-writable tree")
	// ErrAddonPrivilegedRootUnsafe is returned when the setuid updater would
	// materialize outside the root-owned privileged add-on tree.
	ErrAddonPrivilegedRootUnsafe = errors.New("privileged addon root is not root-owned")
	// ErrAddonSystemdSliceUnsafe is returned when a resource drop-in Slice is not
	// a single systemd unit-name token.
	ErrAddonSystemdSliceUnsafe = errors.New("addon systemd slice is not a unit name")
)

// AddonSystemdInstallRequest describes a privileged install + enable of an add-on's
// systemd units, materialized and verified by the root-owned updater.
type AddonSystemdInstallRequest struct {
	RuntimeRoot       string               // agent release runtime root ("" -> package default)
	PrivilegedRoot    string               // privileged add-on runtime root ("" -> /usr/lib/serviceradar/addons)
	AddonID           string               // add-on id (a single safe path segment)
	Version           string               // target version (a single safe path segment)
	BinaryName        string               // staged binary filename (a single safe path segment)
	ArtifactPath      string               // path to the staged artifact archive ("" -> default staging location)
	ArtifactSHA256    string               // expected artifact SHA256 digest
	Signature         string               // Ed25519 signature of the artifact
	Units             []string             // unit file names in the bundle (".service"/".timer")
	Enable            string               // the unit to `enable --now` (must be one of Units)
	Resources         agentaddon.Resources // manifest CPU/memory/task limits applied to Enable via a drop-in
	Capabilities      []string             // file capabilities applied to the verified privileged binary
	RunTimerNow       bool                 // clear prior scan failure and queue the newly installed timer service
	StateSnapshotPath string               // previous state config restored before re-enabling the prior unit
}

// validateAddonUnitName reports whether name is a safe single path segment naming a
// systemd unit file (a plain filename ending in .service or .timer). This blocks path
// traversal and restricts what the root-owned updater will copy into the unit dir.
func validateAddonUnitName(name string) error {
	if !safeAddonSegment(name) {
		return fmt.Errorf("%w: %q", ErrAddonUnitNameUnsafe, name)
	}
	if !strings.HasSuffix(name, ".service") && !strings.HasSuffix(name, ".timer") {
		return fmt.Errorf("%w: %q (must end in .service or .timer)", ErrAddonUnitNameUnsafe, name)
	}

	return nil
}

// resolveStagedAddonUnit resolves a unit file under the add-on's staged current/ dir,
// validating the name and confirming the resolved real path stays inside the add-on's
// own directory before the updater copies it into the system unit dir.
func resolveStagedAddonUnit(runtimeRoot, addonID, unitName string) (string, error) {
	if !safeAddonSegment(addonID) {
		return "", fmt.Errorf("%w: addon_id %q", ErrAddonUnsafePath, addonID)
	}
	if err := validateAddonUnitName(unitName); err != nil {
		return "", err
	}

	addonDir := filepath.Join(resolveAddonArtifactRoot(runtimeRoot), addonID)
	staged := filepath.Join(addonDir, addonCurrentLink, unitName)

	real, err := filepath.EvalSymlinks(staged)
	if err != nil {
		return "", fmt.Errorf("resolve staged addon unit: %w", err)
	}

	addonDirReal, err := filepath.EvalSymlinks(addonDir)
	if err != nil {
		return "", fmt.Errorf("resolve addon dir: %w", err)
	}
	if real != addonDirReal && !strings.HasPrefix(real, addonDirReal+string(os.PathSeparator)) {
		return "", fmt.Errorf("%w: %s", ErrAddonUnitEscape, real)
	}

	info, err := os.Stat(real)
	if err != nil {
		return "", fmt.Errorf("stat staged addon unit: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("%w: %s", ErrAddonUnitNotRegular, real)
	}

	return real, nil
}

// runSystemctl runs `systemctl <args...>`, returning a wrapped error (with output) on
// failure and ErrSystemctlUnavailable when systemctl is not installed.
func runSystemctl(ctx context.Context, args ...string) error {
	systemctlPath, err := exec.LookPath("systemctl")
	if err != nil {
		return fmt.Errorf("%w: %w", ErrSystemctlUnavailable, err)
	}

	cmd := exec.CommandContext(ctx, systemctlPath, args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("systemctl %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}

	return nil
}

// resolvePrivilegedAddonRoot returns the root-owned directory where the privileged
// updater materializes verified add-ons.
func resolvePrivilegedAddonRoot(privilegedRoot, runtimeRoot string) string {
	if clean := strings.TrimSpace(privilegedRoot); clean != "" {
		return clean
	}
	if clean := strings.TrimSpace(runtimeRoot); clean != "" && clean != defaultReleaseRuntimeRoot {
		return filepath.Join(clean, "privileged-addons")
	}
	return defaultPrivilegedAddonRoot
}

// resolvePrivilegedAddonUnit resolves a unit file under the add-on's privileged
// current/ dir, validating the name and confirming the resolved real path stays inside
// the add-on's own directory before the updater copies it into the system unit dir.
func resolvePrivilegedAddonUnit(privRoot, addonID, unitName string) (string, error) {
	if !safeAddonSegment(addonID) {
		return "", fmt.Errorf("%w: addon_id %q", ErrAddonUnsafePath, addonID)
	}
	if err := validateAddonUnitName(unitName); err != nil {
		return "", err
	}

	addonDir := filepath.Join(privRoot, addonID)
	staged := filepath.Join(addonDir, addonCurrentLink, unitName)

	real, err := filepath.EvalSymlinks(staged)
	if err != nil {
		return "", fmt.Errorf("resolve privileged addon unit: %w", err)
	}

	addonDirReal, err := filepath.EvalSymlinks(addonDir)
	if err != nil {
		return "", fmt.Errorf("resolve privileged addon dir: %w", err)
	}
	if real != addonDirReal && !strings.HasPrefix(real, addonDirReal+string(os.PathSeparator)) {
		return "", fmt.Errorf("%w: %s", ErrAddonUnitEscape, real)
	}

	info, err := os.Stat(real)
	if err != nil {
		return "", fmt.Errorf("stat privileged addon unit: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("%w: %s", ErrAddonUnitNotRegular, real)
	}

	return real, nil
}

// relabelPrivilegedAddonExecutables sets SELinux type bin_t on privileged add-on
// binaries so systemd (init_t) can exec them.
func relabelPrivilegedAddonExecutables(privRoot, addonID string) {
	if !safeAddonSegment(addonID) {
		return
	}
	currentDir := filepath.Join(privRoot, addonID, addonCurrentLink)
	entries, err := os.ReadDir(currentDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil || !isStagedAddonExecutable(entry.Name(), info.Mode()) {
			continue
		}
		relabelPathAsBinT(filepath.Join(currentDir, entry.Name()))
	}
}

// InstallAddonSystemdUnits is the privileged operation invoked inside the root-owned
// agent-updater: it verifies the signed artifact, materializes an immutable root-owned
// runtime tree below /usr/lib/serviceradar/addons/<id>, switches the privileged current
// symlink, copies units from that tree into the system unit dir, reloads systemd, and
// enables (--now) the primary unit. On any failure it removes newly installed units,
// drop-ins, and rolls the privileged current symlink back to its previous target.
func InstallAddonSystemdUnits(ctx context.Context, req AddonSystemdInstallRequest) error {
	if len(req.Units) == 0 {
		return ErrAddonSystemdNoUnits
	}
	if !safeAddonSegment(req.AddonID) {
		return fmt.Errorf("%w: addon_id %q", ErrAddonUnsafePath, req.AddonID)
	}
	enable := strings.TrimSpace(req.Enable)
	if enable != "" && !containsString(req.Units, enable) {
		return fmt.Errorf("%w: %q", ErrAddonSystemdEnableNotListed, enable)
	}
	for _, name := range req.Units {
		if err := validateAddonUnitName(name); err != nil {
			return err
		}
	}
	if !safeAddonSegment(req.Version) {
		return fmt.Errorf("%w: version %q", ErrAddonUnsafePath, req.Version)
	}
	if !safeAddonSegment(req.BinaryName) {
		return fmt.Errorf("%w: binary %q", ErrAddonUnsafePath, req.BinaryName)
	}
	if strings.TrimSpace(req.Signature) == "" {
		return ErrAddonSignatureRequired
	}

	// Read and verify the original artifact archive bytes directly.
	artifactPath := req.ArtifactPath
	if artifactPath == "" {
		stagingVersionDir := filepath.Join(resolveAddonArtifactRoot(req.RuntimeRoot), req.AddonID, addonVersionsDir, req.Version)
		artifactPath = StagedAddonArtifactPath(stagingVersionDir)
	}
	data, err := os.ReadFile(artifactPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return ErrAddonArtifactMissing
		}
		return fmt.Errorf("read addon artifact %s: %w", artifactPath, err)
	}

	wantSHA := strings.ToLower(strings.TrimSpace(req.ArtifactSHA256))
	if wantSHA == "" {
		return ErrAddonArtifactIncomplete
	}
	sum := sha256.Sum256(data)
	if !hashutil.EqualSHA256(wantSHA, sum) {
		return ErrAddonArtifactHashMismatch
	}

	if err := verifyAddonArtifactSignature(data, req.Signature); err != nil {
		return err
	}

	// Materialize into the root-owned privileged directory. A setuid caller cannot
	// choose that directory.
	privRoot, err := effectivePrivilegedAddonRoot(req.PrivilegedRoot, req.RuntimeRoot)
	if err != nil {
		return err
	}
	privAddonDir := filepath.Join(privRoot, req.AddonID)
	privVersionsDir := filepath.Join(privAddonDir, addonVersionsDir)
	if err := os.MkdirAll(privVersionsDir, 0o755); err != nil {
		return fmt.Errorf("create privileged addon versions dir: %w", err)
	}

	privVersionDir := filepath.Join(privVersionsDir, req.Version)
	tmpDir, err := os.MkdirTemp(privVersionsDir, ".tmp-extract-*")
	if err != nil {
		return fmt.Errorf("create temporary extract dir: %w", err)
	}
	defer func() { _ = os.RemoveAll(tmpDir) }()

	if isGzipArtifact(data) {
		if err := extractAddonTarball(tmpDir, data, req.BinaryName); err != nil {
			return err
		}
	} else {
		if err := writeAddonBinaryAtomic(filepath.Join(tmpDir, req.BinaryName), data); err != nil {
			return err
		}
	}

	if err := writeAddonStageMetadata(tmpDir, addonStageMetadata{
		AddonID:        req.AddonID,
		Version:        req.Version,
		BinaryName:     req.BinaryName,
		ArtifactSHA256: wantSHA,
		Signature:      strings.TrimSpace(req.Signature),
	}); err != nil {
		return err
	}

	_ = os.RemoveAll(privVersionDir)
	if err := os.Rename(tmpDir, privVersionDir); err != nil {
		return fmt.Errorf("publish privileged version dir: %w", err)
	}

	// Atomically manage the privileged current symlink and rollback target.
	prevPrivTarget, hasPrevPriv := readAddonCurrentTarget(privAddonDir)
	targetRel := filepath.Join(addonVersionsDir, req.Version)
	if err := switchAddonCurrentSymlink(privAddonDir, targetRel); err != nil {
		return err
	}

	rollbackPrivCurrent := func() {
		if hasPrevPriv {
			_ = switchAddonCurrentSymlink(privAddonDir, prevPrivTarget)
		} else {
			_ = os.Remove(filepath.Join(privAddonDir, addonCurrentLink))
		}
	}

	// Relabel executables in the root-owned runtime tree.
	relabelPrivilegedAddonExecutables(privRoot, req.AddonID)

	// Resolve + validate every unit ONLY from the privileged tree.
	type privUnit struct{ name, src string }
	resolved := make([]privUnit, 0, len(req.Units))
	for _, name := range req.Units {
		src, err := resolvePrivilegedAddonUnit(privRoot, req.AddonID, name)
		if err != nil {
			rollbackPrivCurrent()
			return err
		}
		resolved = append(resolved, privUnit{name: name, src: src})
	}

	timerService := ""
	if req.RunTimerNow {
		if !strings.HasSuffix(enable, ".timer") {
			rollbackPrivCurrent()
			return ErrAddonSystemdTimerRequiresTimer
		}
		src, err := resolvePrivilegedAddonUnit(privRoot, req.AddonID, enable)
		if err != nil {
			rollbackPrivCurrent()
			return err
		}
		timerService, err = stagedTimerService(src, enable, req.Units)
		if err != nil {
			rollbackPrivCurrent()
			return err
		}
	}

	type stagedUnit struct {
		name string
		data []byte
	}
	staged := make([]stagedUnit, 0, len(resolved))
	for _, u := range resolved {
		data, err := os.ReadFile(u.src)
		if err != nil {
			rollbackPrivCurrent()
			return fmt.Errorf("read privileged unit %s: %w", u.name, err)
		}
		if err := rejectAgentWritableUnitExecPaths(data, req.RuntimeRoot); err != nil {
			rollbackPrivCurrent()
			return err
		}
		staged = append(staged, stagedUnit{name: u.name, data: data})
	}

	if len(req.Capabilities) > 0 {
		if err := ApplyAddonCapabilities(ctx, AddonCapabilityRequest{
			RuntimeRoot:    req.RuntimeRoot,
			PrivilegedRoot: privRoot,
			AddonID:        req.AddonID,
			BinaryName:     req.BinaryName,
			Capabilities:   req.Capabilities,
		}); err != nil {
			rollbackPrivCurrent()
			return err
		}
	}

	// Snapshot every unit this install will replace. A failed activation must put the
	// previous unit bytes back; deleting only newly created files leaves a migration's
	// overwritten unit pointing at a privileged current that rollback just removed.
	type unitSnapshot struct {
		name    string
		existed bool
		data    []byte
	}
	snapshots := make([]unitSnapshot, 0, len(staged))
	for _, u := range staged {
		dest := filepath.Join(systemdUnitDir, u.name)
		snap := unitSnapshot{name: u.name}
		prev, err := os.ReadFile(dest)
		switch {
		case err == nil:
			snap.existed = true
			snap.data = prev
		case errors.Is(err, os.ErrNotExist):
		default:
			rollbackPrivCurrent()
			return fmt.Errorf("read existing unit %s: %w", u.name, err)
		}
		snapshots = append(snapshots, snap)
	}

	priorEnabled := false
	if enable != "" {
		for _, snap := range snapshots {
			if snap.name == enable && snap.existed {
				priorEnabled = runSystemctl(ctx, "is-enabled", "--quiet", enable) == nil
				break
			}
		}
	}

	var dropIn *dropInSnapshot
	cleanup := func() {
		if dropIn != nil {
			dropIn.restore()
		}
		for _, snap := range snapshots {
			dest := filepath.Join(systemdUnitDir, snap.name)
			if snap.existed {
				_ = os.WriteFile(dest, snap.data, systemdUnitFileMode)
			} else {
				_ = os.Remove(dest)
			}
		}
		_ = runSystemctl(ctx, "daemon-reload")
		rollbackPrivCurrent()
	}

	for _, u := range staged {
		dest := filepath.Join(systemdUnitDir, u.name)
		if err := os.WriteFile(dest, u.data, systemdUnitFileMode); err != nil {
			cleanup()
			return fmt.Errorf("install unit %s: %w", u.name, err)
		}
	}

	// Apply the manifest resource limits to the enabled unit via a systemd drop-in.
	if enable != "" && !req.Resources.IsZero() {
		snap, err := snapshotDropIn(filepath.Join(systemdUnitDir, enable+".d"))
		if err != nil {
			cleanup()
			return err
		}
		dropIn = &snap
		if _, err := writeSystemdResourceDropIn(enable, req.Resources); err != nil {
			cleanup()
			return err
		}
	}

	if err := runSystemctl(ctx, "daemon-reload"); err != nil {
		cleanup()
		return err
	}

	restoreState, err := loadAddonStateRestore(req.RuntimeRoot, req.AddonID, req.StateSnapshotPath)
	if err != nil {
		cleanup()
		return err
	}
	if enable != "" {
		if err := activateAddonSystemdUnits(ctx, enable, timerService); err != nil {
			_ = runSystemctl(ctx, "disable", "--now", enable)
			cleanup()
			restoreState()
			if priorEnabled {
				_ = runSystemctl(ctx, "enable", "--now", enable)
			}
			return err
		}
	}

	return nil
}

// stagedTimerService respects Timer.Unit while restricting activation to the
// validated service files in this signed bundle. Unrelated host units cannot be
// reset or restarted through an add-on timer reference.
func stagedTimerService(path, timer string, units []string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read staged timer: %w", err)
	}
	service := strings.TrimSuffix(timer, ".timer") + ".service"
	section := ""
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = line
			continue
		}
		if section != "[Timer]" {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if ok && strings.TrimSpace(key) == "Unit" {
			value = strings.TrimSpace(value)
			if value == "" {
				service = strings.TrimSuffix(timer, ".timer") + ".service"
			} else {
				service = value
			}
		}
	}
	if err := validateAddonUnitName(service); err != nil {
		return "", err
	}
	if !strings.HasSuffix(service, ".service") || !containsString(units, service) {
		return "", fmt.Errorf("%w: timer service %q", ErrAddonSystemdEnableNotListed, service)
	}
	return service, nil
}

func activateAddonSystemdUnits(ctx context.Context, enable, timerService string) error {
	if timerService != "" {
		if err := runSystemctl(ctx, "reset-failed", timerService); err != nil {
			return err
		}
	}
	if err := runSystemctl(ctx, "enable", "--now", enable); err != nil {
		return err
	}
	if err := runSystemctl(ctx, "restart", enable); err != nil {
		return err
	}
	if timerService != "" {
		// Queue a fresh execution of the staged candidate without blocking the
		// updater for an entire scan. Its own outcome remains visible to health.
		return runSystemctl(ctx, "restart", "--no-block", timerService)
	}
	return nil
}

// UninstallAddonSystemdUnits is the privileged teardown: it disables (--now) each unit,
// removes the installed unit files, and reloads systemd. Missing/already-disabled units
// are tolerated so teardown is idempotent. Used when an assignment is disabled/removed
// and as part of rollback.
func UninstallAddonSystemdUnits(ctx context.Context, units []string) error {
	if len(units) == 0 {
		return ErrAddonSystemdNoUnits
	}

	for _, name := range units {
		if err := validateAddonUnitName(name); err != nil {
			return err
		}
	}

	for _, name := range units {
		// Disable is best-effort: a unit that was never enabled (or already removed)
		// must not fail teardown.
		_ = runSystemctl(ctx, "disable", "--now", name)
		if err := os.Remove(filepath.Join(systemdUnitDir, name)); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove unit %s: %w", name, err)
		}
		// Remove the agent-owned resource drop-in dir alongside the unit it modifies
		// (best-effort; the unit is going away, so its drop-in must not linger).
		_ = os.RemoveAll(filepath.Join(systemdUnitDir, name+".d"))
	}

	return runSystemctl(ctx, "daemon-reload")
}

// systemdDropInFileName is the drop-in the agent owns for an add-on's resource
// limits. The 50- prefix orders it after distro defaults while leaving room for a
// higher-numbered operator override.
const systemdDropInFileName = "50-serviceradar-resources.conf"

// writeSystemdResourceDropIn writes a root:root 0644 systemd drop-in under
// <unit>.d applying the manifest resource limits to the enabled unit, creating
// the drop-in dir as needed. Returns the drop-in dir so a failed install can
// remove it. The unit name is already validated by the caller.
func writeSystemdResourceDropIn(unit string, res agentaddon.Resources) (string, error) {
	if err := validateAddonResourceSlice(res.Slice); err != nil {
		return "", err
	}
	dir := filepath.Join(systemdUnitDir, unit+".d")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("create systemd drop-in dir for %s: %w", unit, err)
	}

	path := filepath.Join(dir, systemdDropInFileName)
	if err := os.WriteFile(path, []byte(renderSystemdResourceDropIn(res)), systemdUnitFileMode); err != nil {
		return "", fmt.Errorf("write systemd resource drop-in for %s: %w", unit, err)
	}

	return dir, nil
}

// renderSystemdResourceDropIn renders a [Service] drop-in mapping the add-on
// resource limits to systemd directives. Only declared (non-zero) limits are
// emitted; CPUMaxPercent is a percent of ONE core, which is exactly systemd's
// CPUQuota semantics (100% = one core).
func renderSystemdResourceDropIn(res agentaddon.Resources) string {
	var b strings.Builder
	b.WriteString("# Generated by serviceradar-agent from the add-on manifest `resources`.\n")
	b.WriteString("[Service]\n")

	if res.CPUMaxPercent > 0 {
		fmt.Fprintf(&b, "CPUQuota=%g%%\n", res.CPUMaxPercent)
	}
	if res.MemoryHighBytes > 0 {
		fmt.Fprintf(&b, "MemoryHigh=%d\n", res.MemoryHighBytes)
	}
	if res.MemoryMaxBytes > 0 {
		fmt.Fprintf(&b, "MemoryMax=%d\n", res.MemoryMaxBytes)
	}
	if res.TasksMax > 0 {
		fmt.Fprintf(&b, "TasksMax=%d\n", res.TasksMax)
	}
	if res.Slice != "" {
		fmt.Fprintf(&b, "Slice=%s\n", res.Slice)
	}

	return b.String()
}

// relabelStagedAddonExecutables sets SELinux type bin_t on staged add-on
// binaries so systemd (init_t) can exec them. Files under /var/lib default to
// var_lib_t, which produces status=203/EXEC on Enforcing hosts. chcon is
// best-effort: absent SELinux tools or a disabled policy must not fail install.
func relabelStagedAddonExecutables(runtimeRoot, addonID string) {
	for _, path := range stagedAddonExecutables(runtimeRoot, addonID) {
		relabelPathAsBinT(path)
	}
}

func stagedAddonExecutables(runtimeRoot, addonID string) []string {
	if !safeAddonSegment(addonID) {
		return nil
	}

	currentDir := filepath.Join(resolveAddonArtifactRoot(runtimeRoot), addonID, addonCurrentLink)
	entries, err := os.ReadDir(currentDir)
	if err != nil {
		return nil
	}

	var out []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil || !isStagedAddonExecutable(entry.Name(), info.Mode()) {
			continue
		}
		out = append(out, filepath.Join(currentDir, entry.Name()))
	}
	sort.Strings(out)

	return out
}

func isStagedAddonExecutable(name string, mode os.FileMode) bool {
	if !mode.IsRegular() || mode&0o111 == 0 {
		return false
	}
	switch {
	case strings.HasSuffix(name, ".service"),
		strings.HasSuffix(name, ".timer"),
		strings.HasSuffix(name, ".json"),
		strings.HasSuffix(name, ".o"):
		return false
	default:
		return true
	}
}

func relabelPathAsBinT(path string) {
	chcon, err := exec.LookPath("chcon")
	if err != nil {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = exec.CommandContext(ctx, chcon, "-t", "bin_t", path).Run()
}

// containsString reports whether s is in list.
func containsString(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}

	return false
}

type dropInSnapshot struct {
	dir     string
	existed bool
	files   map[string][]byte
}

func snapshotDropIn(dir string) (dropInSnapshot, error) {
	snap := dropInSnapshot{dir: dir, files: map[string][]byte{}}
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return snap, nil
	}
	if err != nil {
		return snap, fmt.Errorf("read systemd drop-in dir: %w", err)
	}
	snap.existed = true
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			return snap, fmt.Errorf("read systemd drop-in %s: %w", entry.Name(), err)
		}
		snap.files[entry.Name()] = data
	}
	return snap, nil
}

func (s dropInSnapshot) restore() {
	if !s.existed {
		_ = os.RemoveAll(s.dir)
		return
	}
	entries, err := os.ReadDir(s.dir)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return
	}
	for _, entry := range entries {
		if _, ok := s.files[entry.Name()]; ok || entry.IsDir() {
			continue
		}
		_ = os.Remove(filepath.Join(s.dir, entry.Name()))
	}
	for name, data := range s.files {
		_ = os.WriteFile(filepath.Join(s.dir, name), data, systemdUnitFileMode)
	}
}

func validateAddonResourceSlice(slice string) error {
	slice = strings.TrimSpace(slice)
	if slice == "" {
		return nil
	}
	if strings.Contains(slice, ".slice") && strings.HasSuffix(slice, ".slice") && systemdUnitToken(slice) {
		return nil
	}
	return fmt.Errorf("%w: %q", ErrAddonSystemdSliceUnsafe, slice)
}

func systemdUnitToken(name string) bool {
	if name == "" || strings.ContainsAny(name, "/\\ \t\r\n=\"'") {
		return false
	}
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == ':', r == '_', r == '.', r == '@', r == '-':
		default:
			return false
		}
	}
	return true
}

func pathIsWithin(path, root string) bool {
	path = filepath.Clean(path)
	root = filepath.Clean(root)
	if path == root {
		return true
	}
	return strings.HasPrefix(path, root+string(os.PathSeparator))
}

// rejectAgentWritableUnitExecPaths fails closed when a unit's ExecStart or
// ExecStartPre command path is under the agent-writable add-on tree. Helper
// commands such as /usr/bin/install are outside that tree and remain allowed.
func rejectAgentWritableUnitExecPaths(unit []byte, runtimeRoot string) error {
	for _, path := range systemdUnitCommandPaths(unit) {
		cleaned := filepath.Clean(path)
		if !filepath.IsAbs(cleaned) {
			continue
		}
		for _, root := range writableAddonRoots(runtimeRoot) {
			if pathIsWithin(cleaned, root) {
				return fmt.Errorf("%w: %s", ErrAddonUnitExecPathUnsafe, path)
			}
		}
	}
	return nil
}

func systemdUnitCommandPaths(unit []byte) []string {
	text := joinSystemdContinuations(string(unit))
	var paths []string
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || !systemdExecDirective(strings.TrimSpace(key)) {
			continue
		}
		path, ok := systemdCommandPath(value)
		if !ok {
			continue
		}
		paths = append(paths, path)
	}
	return paths
}

func systemdExecDirective(key string) bool {
	switch key {
	case "ExecStart", "ExecStartPre", "ExecStartPost", "ExecStop", "ExecStopPost", "ExecReload", "ExecCondition":
		return true
	default:
		return false
	}
}

func joinSystemdContinuations(text string) string {
	lines := strings.Split(text, "\n")
	out := make([]string, 0, len(lines))
	var b strings.Builder
	for _, line := range lines {
		if strings.HasSuffix(line, "\\") {
			b.WriteString(strings.TrimSuffix(line, "\\"))
			b.WriteByte(' ')
			continue
		}
		b.WriteString(line)
		out = append(out, b.String())
		b.Reset()
	}
	if b.Len() > 0 {
		out = append(out, b.String())
	}
	return strings.Join(out, "\n")
}

func systemdCommandPath(value string) (string, bool) {
	value = strings.TrimSpace(value)
	for len(value) > 0 {
		switch value[0] {
		case '-', '+', '@', '!':
			value = value[1:]
			continue
		}
		break
	}
	value = strings.TrimSpace(value)
	if value == "" {
		return "", false
	}
	if value[0] == '"' || value[0] == '\'' {
		quote := value[0]
		rest := value[1:]
		end := strings.IndexByte(rest, quote)
		if end < 0 {
			return "", false
		}
		return rest[:end], true
	}
	field, _, _ := strings.Cut(value, " ")
	field = strings.TrimSpace(field)
	if field == "" {
		return "", false
	}
	return field, true
}

// discoverStagedAddonUnits lists the systemd unit files (.service/.timer) shipped in an
// add-on's staged current/ dir. The unit files ride inside the signed bundle, so the
// agent enumerates them (reading its own staging area) to tell the root-owned updater
// exactly which units to install — avoiding any need to thread unit names through the
// proto/manifest. The returned names are validated and sorted for determinism; the
// updater independently re-resolves and escape-guards each one before installing.
func discoverStagedAddonUnits(runtimeRoot, addonID string) ([]string, error) {
	if !safeAddonSegment(addonID) {
		return nil, fmt.Errorf("%w: addon_id %q", ErrAddonUnsafePath, addonID)
	}

	currentDir := filepath.Join(resolveAddonArtifactRoot(runtimeRoot), addonID, addonCurrentLink)
	entries, err := os.ReadDir(currentDir)
	if err != nil {
		return nil, fmt.Errorf("read staged addon dir: %w", err)
	}

	return filterSystemdUnitEntries(entries), nil
}

// filterSystemdUnitEntries returns the validated .service/.timer file names from a dir
// listing, sorted for determinism.
func filterSystemdUnitEntries(entries []os.DirEntry) []string {
	var units []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if (strings.HasSuffix(name, ".service") || strings.HasSuffix(name, ".timer")) && validateAddonUnitName(name) == nil {
			units = append(units, name)
		}
	}

	sort.Strings(units)

	return units
}

// listStagedSystemdUnits is the best-effort variant of discoverStagedAddonUnits for a
// resolved directory (a missing/unreadable dir yields no units), used by rehydration.
func listStagedSystemdUnits(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}

	return filterSystemdUnitEntries(entries)
}

// discoverInstalledSystemdAddons scans the add-on staging root and returns, for each
// add-on whose current/ dir ships systemd units, its id -> unit names. Used to rehydrate
// the agent's installed-unit tracking after a restart so a later disable/unassign can
// still uninstall the units. agent-sidecar add-ons ship no units and are skipped.
func discoverInstalledSystemdAddons(addonsRoot string) map[string][]string {
	entries, err := os.ReadDir(addonsRoot)
	if err != nil {
		return nil
	}

	var out map[string][]string
	for _, e := range entries {
		if !e.IsDir() || !safeAddonSegment(e.Name()) {
			continue
		}
		units := listStagedSystemdUnits(filepath.Join(addonsRoot, e.Name(), addonCurrentLink))
		if len(units) > 0 {
			if out == nil {
				out = make(map[string][]string)
			}
			out[e.Name()] = units
		}
	}

	return out
}

// pickPrimarySystemdUnit selects the unit to `enable --now` for a supervision model: the
// .timer for systemd-timer, the .service for systemd-service. Exactly one matching unit
// must exist; the other units (e.g. a timer's backing .service) are installed but pulled
// in transitively rather than enabled directly.
func pickPrimarySystemdUnit(units []string, supervision string) (string, error) {
	var suffix string
	switch supervision {
	case addonSupervisionSystemdTimer:
		suffix = ".timer"
	case addonSupervisionSystemdService:
		suffix = ".service"
	default:
		return "", fmt.Errorf("%w: %q", ErrAddonSystemdSupervisionUnknown, supervision)
	}

	var matches []string
	for _, u := range units {
		if strings.HasSuffix(u, suffix) {
			matches = append(matches, u)
		}
	}

	if len(matches) != 1 {
		return "", fmt.Errorf("%w: %q expects exactly one %s unit, found %d", ErrAddonSystemdPrimaryAmbiguous, supervision, suffix, len(matches))
	}

	return matches[0], nil
}

// installStagedAddonSystemdUnitsViaUpdater invokes the root-owned, package-owned
// agent-updater to install the discovered units and enable the primary. The non-root
// agent never installs units itself.
func installStagedAddonSystemdUnitsViaUpdater(ctx context.Context, req AddonSystemdInstallRequest) error {
	if len(req.Units) == 0 {
		return ErrAddonSystemdNoUnits
	}

	requiredFlags := []string{
		"addon-id",
		"addon-version",
		"addon-bin",
		"addon-sha256",
		"addon-signature",
		"addon-artifact",
		"addon-systemd-install",
		"addon-systemd-enable",
	}
	if req.RunTimerNow {
		requiredFlags = append(requiredFlags, "addon-systemd-run-timer-now")
	}
	if !req.Resources.IsZero() {
		requiredFlags = append(requiredFlags, "addon-systemd-resources")
	}
	if len(req.Capabilities) > 0 {
		requiredFlags = append(requiredFlags, "addon-capabilities")
	}
	if req.StateSnapshotPath != "" {
		requiredFlags = append(requiredFlags, "addon-state-snapshot")
	}

	updaterPath, err := ValidatedPrivilegedAgentUpdaterPath(requiredFlags...)
	if err != nil {
		return fmt.Errorf("locate agent updater for systemd install: %w", err)
	}

	args := []string{
		"--addon-id", req.AddonID,
		"--addon-version", req.Version,
		"--addon-bin", req.BinaryName,
		"--addon-sha256", req.ArtifactSHA256,
		"--addon-signature", req.Signature,
		"--addon-artifact", req.ArtifactPath,
		"--addon-systemd-install", strings.Join(req.Units, ","),
		"--addon-systemd-enable", req.Enable,
	}
	if req.RunTimerNow {
		args = append(args, "--addon-systemd-run-timer-now")
	}
	if len(req.Capabilities) > 0 {
		normalized, err := normalizeAddonCapabilities(req.Capabilities)
		if err != nil {
			return err
		}
		args = append(args, "--addon-capabilities", strings.Join(normalized, ","))
	}
	if req.PrivilegedRoot != "" {
		args = append(args, "--privileged-root", req.PrivilegedRoot)
	}
	if req.StateSnapshotPath != "" {
		args = append(args, "--addon-state-snapshot", req.StateSnapshotPath)
	}

	// Pass the manifest resource limits as JSON so the root-owned updater can write
	// a systemd drop-in (CPUQuota/MemoryMax/...) for the enabled unit. Omitted when
	// no limits are declared.
	if !req.Resources.IsZero() {
		encoded, err := json.Marshal(req.Resources)
		if err != nil {
			return fmt.Errorf("encode add-on systemd resource limits: %w", err)
		}
		args = append(args, "--addon-systemd-resources", string(encoded))
	}

	if err := runAgentUpdaterCommand(ctx, updaterPath, args...); err != nil {
		return fmt.Errorf("agent-updater systemd install failed: %w", err)
	}

	return nil
}

// uninstallAddonSystemdUnitsViaUpdater invokes the root-owned agent-updater to disable +
// remove an add-on's previously-installed units (assignment disabled or unassigned).
func uninstallAddonSystemdUnitsViaUpdater(ctx context.Context, units []string) error {
	if len(units) == 0 {
		return nil
	}

	updaterPath, err := ValidatedPrivilegedAgentUpdaterPath("addon-systemd-uninstall")
	if err != nil {
		return fmt.Errorf("locate agent updater for systemd uninstall: %w", err)
	}

	if err := runAgentUpdaterCommand(ctx, updaterPath, "--addon-systemd-uninstall", strings.Join(units, ",")); err != nil {
		return fmt.Errorf("agent-updater systemd uninstall failed: %w", err)
	}

	return nil
}

// stringsNotIn returns the elements of a that are not present in b.
func stringsNotIn(a, b []string) []string {
	if len(a) == 0 {
		return nil
	}
	set := make(map[string]bool, len(b))
	for _, s := range b {
		set[s] = true
	}
	var out []string
	for _, s := range a {
		if !set[s] {
			out = append(out, s)
		}
	}

	return out
}

// systemdAddonsToRemove returns the installed systemd add-ons (id -> unit names) that are
// no longer desired (disabled or unassigned), so the caller can uninstall their units.
func systemdAddonsToRemove(installed map[string][]string, desired map[string]bool) map[string][]string {
	var toRemove map[string][]string
	for id, units := range installed {
		if desired[id] {
			continue
		}
		if toRemove == nil {
			toRemove = make(map[string][]string)
		}
		toRemove[id] = units
	}

	return toRemove
}
