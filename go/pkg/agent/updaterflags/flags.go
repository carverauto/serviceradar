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

// Package updaterflags is the command-line contract between the non-root agent
// and the root-owned serviceradar-agent-updater. The updater registers its flags
// from here and the agent builds its command lines from the same names.
//
// Installed updaters are upgraded by the OS package, not by an agent self-update,
// so a flag name here is a compatibility interface: renaming one breaks every
// agent paired with an updater that still carries the old name.
package updaterflags

import (
	"flag"
	"time"
)

// Flag names, without the leading dashes.
const (
	RuntimeRoot      = "runtime-root"
	Version          = "version"
	CommandID        = "command-id"
	CommandType      = "command-type"
	RollbackDeadline = "rollback-deadline"

	AddonID           = "addon-id"
	AddonBinary       = "addon-binary"
	AddonCapabilities = "addon-capabilities"

	AddonSystemdInstall     = "addon-systemd-install"
	AddonSystemdEnable      = "addon-systemd-enable"
	AddonSystemdUninstall   = "addon-systemd-uninstall"
	AddonSystemdResources   = "addon-systemd-resources"
	AddonSystemdRunTimerNow = "addon-systemd-run-timer-now"
	AddonStateSnapshot      = "addon-state-snapshot"

	AddonVersion   = "addon-version"
	AddonSHA256    = "addon-sha256"
	AddonSignature = "addon-signature"
	AddonArtifact  = "addon-artifact"
	PrivilegedRoot = "privileged-root"
)

// DefaultCommandType is the activation command type reported when none is passed.
const DefaultCommandType = "agent.update_release"

// DefaultRollbackDeadline is the activation rollback deadline used when none is passed.
const DefaultRollbackDeadline = 3 * time.Minute

// Options holds the parsed updater command line.
type Options struct {
	RuntimeRoot      string
	Version          string
	CommandID        string
	CommandType      string
	RollbackDeadline time.Duration

	AddonID           string
	AddonBinary       string
	AddonCapabilities string

	AddonSystemdInstall     string
	AddonSystemdEnable      string
	AddonSystemdUninstall   string
	AddonSystemdResources   string
	AddonSystemdRunTimerNow bool
	AddonStateSnapshot      string

	AddonVersion   string
	AddonSHA256    string
	AddonSignature string
	AddonArtifact  string
	PrivilegedRoot string
}

// Register defines every updater flag on fs and returns the options they fill.
func Register(fs *flag.FlagSet) *Options {
	o := &Options{}

	fs.StringVar(&o.RuntimeRoot, RuntimeRoot, "", "ServiceRadar runtime root")
	fs.StringVar(&o.Version, Version, "", "Target staged release version")
	fs.StringVar(&o.CommandID, CommandID, "", "Command ID for activation result reporting")
	fs.StringVar(&o.CommandType, CommandType, DefaultCommandType, "Command type for activation result reporting")
	fs.DurationVar(&o.RollbackDeadline, RollbackDeadline, DefaultRollbackDeadline, "Rollback deadline after activation")

	// Add-on file capabilities are applied only while installing a signature-verified
	// systemd unit, and only to the root-owned binary that install materializes.
	fs.StringVar(&o.AddonID, AddonID, "", "Add-on id (systemd install mode)")
	fs.StringVar(&o.AddonBinary, AddonBinary, "", "Add-on binary filename inside the verified artifact")
	fs.StringVar(&o.AddonCapabilities, AddonCapabilities, "", "Comma-separated Linux file capabilities to apply to the verified privileged binary (e.g. cap_net_raw,cap_bpf)")

	// Add-on systemd supervision mode (delivery-models task 3.1 & harden-native-addon-privilege-boundary):
	// install/enable or uninstall the add-on's bundled systemd units.
	fs.StringVar(&o.AddonSystemdInstall, AddonSystemdInstall, "", "Comma-separated staged unit files to install (.service/.timer)")
	fs.StringVar(&o.AddonSystemdEnable, AddonSystemdEnable, "", "Unit to enable --now after install (must be one of --addon-systemd-install)")
	fs.StringVar(&o.AddonSystemdUninstall, AddonSystemdUninstall, "", "Comma-separated installed unit files to disable + remove")
	fs.StringVar(&o.AddonSystemdResources, AddonSystemdResources, "", "JSON resource limits applied to the enabled unit via a drop-in (cpu_max_percent, memory_max_bytes, ...)")
	fs.BoolVar(&o.AddonSystemdRunTimerNow, AddonSystemdRunTimerNow, false, "Reset the prior timer service failure and queue a fresh run of the staged candidate")
	fs.StringVar(&o.AddonStateSnapshot, AddonStateSnapshot, "", "Previous add-on state snapshot restored before re-enabling the prior unit")

	// Privileged add-on materialization flags (harden-native-addon-privilege-boundary tasks 1.2, 1.3).
	fs.StringVar(&o.AddonVersion, AddonVersion, "", "Target staged add-on version for privileged materialization")
	fs.StringVar(&o.AddonSHA256, AddonSHA256, "", "Expected staged add-on artifact SHA256 digest")
	fs.StringVar(&o.AddonSignature, AddonSignature, "", "Ed25519 signature of staged add-on artifact")
	fs.StringVar(&o.AddonArtifact, AddonArtifact, "", "Path to the staged add-on artifact archive")
	fs.StringVar(&o.PrivilegedRoot, PrivilegedRoot, "", "Privileged add-on runtime root (default /usr/lib/serviceradar/addons)")

	return o
}
