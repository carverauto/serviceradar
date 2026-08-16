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
)

// systemdUnitDir is where the root-owned updater installs add-on unit files.
const systemdUnitDir = "/etc/systemd/system"

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
)

// AddonSystemdInstallRequest describes a privileged install + enable of an add-on's
// systemd units, all of which ship inside the staged add-on bundle.
type AddonSystemdInstallRequest struct {
	RuntimeRoot string               // agent release runtime root ("" -> package default)
	AddonID     string               // add-on id (a single safe path segment)
	Units       []string             // unit file names in the staged current/ dir (".service"/".timer")
	Enable      string               // the unit to `enable --now` (must be one of Units)
	Resources   agentaddon.Resources // manifest CPU/memory/task limits applied to Enable via a drop-in
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

// InstallAddonSystemdUnits is the privileged operation invoked inside the root-owned
// agent-updater: it resolves each declared unit under the controlled add-on staging
// root, copies them into the system unit dir, reloads systemd, and enables (--now) the
// primary unit. On any failure it removes the units it copied and reloads, so the host
// is never left with half-installed or orphaned add-on units (the agent additionally
// rolls the `current` symlink back).
func InstallAddonSystemdUnits(ctx context.Context, req AddonSystemdInstallRequest) error {
	if len(req.Units) == 0 {
		return ErrAddonSystemdNoUnits
	}

	enable := strings.TrimSpace(req.Enable)
	if enable != "" && !containsString(req.Units, enable) {
		return fmt.Errorf("%w: %q", ErrAddonSystemdEnableNotListed, enable)
	}

	// Resolve + validate every staged unit before touching the system unit dir, so a
	// bad unit name aborts the install before anything is copied.
	type stagedUnit struct{ name, src string }
	resolved := make([]stagedUnit, 0, len(req.Units))
	for _, name := range req.Units {
		src, err := resolveStagedAddonUnit(req.RuntimeRoot, req.AddonID, name)
		if err != nil {
			return err
		}
		resolved = append(resolved, stagedUnit{name: name, src: src})
	}

	// Track only the unit files this install NEWLY creates. On failure we remove only
	// those, never a pre-existing unit file (e.g. a re-deploy over an already-running
	// add-on), so a failed re-install cannot tear down the running add-on's units.
	created := make([]string, 0, len(resolved))
	// The drop-in dir this install newly created (removed on rollback so a failed
	// re-install never leaves a half-applied limit on a running unit).
	createdDropIn := ""
	cleanup := func() {
		if createdDropIn != "" {
			_ = os.RemoveAll(createdDropIn)
		}
		for _, name := range created {
			_ = os.Remove(filepath.Join(systemdUnitDir, name))
		}
		_ = runSystemctl(ctx, "daemon-reload")
	}

	// Staged binaries under /var/lib inherit SELinux var_lib_t; systemd cannot
	// exec that label (203/EXEC). Relabel before enable --now so the first start
	// is not doomed on Enforcing hosts. Missing chcon is ignored.
	relabelStagedAddonExecutables(req.RuntimeRoot, req.AddonID)

	for _, u := range resolved {
		dest := filepath.Join(systemdUnitDir, u.name)
		preExisted := false
		if _, statErr := os.Stat(dest); statErr == nil {
			preExisted = true
		}

		data, err := os.ReadFile(u.src) //nolint:gosec // src is resolved under the controlled add-on staging root.
		if err != nil {
			cleanup()
			return fmt.Errorf("read staged unit %s: %w", u.name, err)
		}
		if err := os.WriteFile(dest, data, systemdUnitFileMode); err != nil {
			cleanup()
			return fmt.Errorf("install unit %s: %w", u.name, err)
		}
		if !preExisted {
			created = append(created, u.name)
		}
	}

	// Apply the manifest resource limits to the enabled unit via a systemd drop-in
	// (CPUQuota/MemoryMax/MemoryHigh/TasksMax/Slice) so manifest `resources` is the
	// single source of truth for systemd-supervised add-ons too — the unit author
	// does not hand-maintain limits. Unbounded (zero) resources write nothing.
	if enable != "" && !req.Resources.IsZero() {
		dir, err := writeSystemdResourceDropIn(enable, req.Resources)
		if err != nil {
			cleanup()
			return err
		}
		createdDropIn = dir
	}

	if err := runSystemctl(ctx, "daemon-reload"); err != nil {
		cleanup()
		return err
	}

	if enable != "" {
		if err := runSystemctl(ctx, "enable", "--now", enable); err != nil {
			// Disable best-effort, then remove the units we installed and reload.
			_ = runSystemctl(ctx, "disable", "--now", enable)
			cleanup()
			return err
		}
		if err := runSystemctl(ctx, "restart", enable); err != nil {
			_ = runSystemctl(ctx, "disable", "--now", enable)
			cleanup()
			return err
		}
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
func installStagedAddonSystemdUnitsViaUpdater(ctx context.Context, addonID string, units []string, enable string, resources agentaddon.Resources) error {
	if len(units) == 0 {
		return ErrAddonSystemdNoUnits
	}

	requiredFlags := []string{"addon-id", "addon-systemd-install", "addon-systemd-enable"}
	if !resources.IsZero() {
		requiredFlags = append(requiredFlags, "addon-systemd-resources")
	}

	updaterPath, err := ValidatedPrivilegedAgentUpdaterPath(requiredFlags...)
	if err != nil {
		return fmt.Errorf("locate agent updater for systemd install: %w", err)
	}

	args := []string{
		"--addon-id", addonID,
		"--addon-systemd-install", strings.Join(units, ","),
		"--addon-systemd-enable", enable,
	}

	// Pass the manifest resource limits as JSON so the root-owned updater can write
	// a systemd drop-in (CPUQuota/MemoryMax/...) for the enabled unit. Omitted when
	// no limits are declared.
	if !resources.IsZero() {
		encoded, err := json.Marshal(resources)
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
