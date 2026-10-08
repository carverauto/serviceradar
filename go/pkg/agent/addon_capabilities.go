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

// File-capability application for pushed-artifact native add-ons (delivery-models
// task 2.2). A non-root agent stages a signed add-on binary (addon_activation.go) and
// then asks the root-owned serviceradar-agent-updater to apply the Linux file
// capabilities the add-on's manifest declares (requires.os_capabilities), e.g.
// netprobe's cap_net_raw / cap_bpf / cap_perfmon for eBPF + AF_XDP capture. The agent
// itself never gains those capabilities; the privileged setcap runs only inside the
// root-owned updater, against the verified binary the updater materialized under the
// root-owned add-on runtime.

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const trustedSetcapPath = "/usr/sbin/setcap"

// Tests temporarily retarget this to a synthetic helper. Production never
// resolves the privileged executable through the caller-controlled PATH.
var setcapCommandPath = trustedSetcapPath //nolint:gochecknoglobals // test seam for an external command

// allowedAddonCapabilities bounds what an add-on may request through
// requires.os_capabilities. Keeping an explicit allowlist means an approved manifest
// (or a compromised control plane) cannot have the root-owned updater grant arbitrary
// capabilities such as cap_sys_admin. Extend deliberately as real add-ons need them.
//
//nolint:gochecknoglobals // an effectively-const allowlist shared read-only by the updater path.
var allowedAddonCapabilities = map[string]bool{
	"cap_net_raw":          true, // raw/packet sockets (netprobe capture)
	"cap_net_admin":        true, // interface/qdisc configuration
	"cap_net_bind_service": true, // bind privileged ports
	"cap_bpf":              true, // load eBPF programs (netprobe)
	"cap_perfmon":          true, // perf/AF_XDP rings (netprobe)
	"cap_dac_read_search":  true, // read-any-file (privileged scanners)
}

// addonCapabilityActionSuffix is appended to the comma-joined capability set to form
// the setcap capability string; "+ep" makes each capability effective + permitted on
// the file, matching the agent package's existing netprobe setcap convention.
const addonCapabilityActionSuffix = "=+ep"

var (
	// ErrAddonCapabilityUnsafe is returned when an add-on requests a capability that is
	// not in the allowlist.
	ErrAddonCapabilityUnsafe = errors.New("addon requested a capability outside the allowed set")
	// ErrAddonCapabilityNone is returned when capability application is requested with
	// no capabilities (the caller should simply skip setcap instead).
	ErrAddonCapabilityNone = errors.New("addon capability application requested with no capabilities")
	// ErrAddonCapabilityBinaryEscape is returned when a staged add-on binary path
	// resolves outside its add-on directory (symlink-escape guard).
	ErrAddonCapabilityBinaryEscape = errors.New("addon binary resolves outside its staging directory")
	// ErrSetcapUnavailable is returned when the setcap tool is not available at its
	// trusted absolute path (e.g. libcap is not installed on the host).
	ErrSetcapUnavailable = errors.New("setcap tool not available")
	// ErrAddonBinaryNotRegular is returned when a resolved staged add-on binary is not
	// a regular file (so it must not be setcap'd).
	ErrAddonBinaryNotRegular = errors.New("staged addon binary is not a regular file")
)

// AddonCapabilityRequest describes a privileged setcap of one staged add-on binary.
type AddonCapabilityRequest struct {
	RuntimeRoot    string   // agent release runtime root ("" -> package default)
	PrivilegedRoot string   // privileged add-on runtime root ("" -> /usr/lib/serviceradar/addons)
	AddonID        string   // add-on id (a single safe path segment)
	BinaryName     string   // staged binary filename (a single safe path segment)
	Capabilities   []string // requested Linux capabilities (validated against the allowlist)
}

// normalizeAddonCapabilities lower-cases, trims, de-duplicates, and validates the
// requested capabilities against the allowlist, returning a stable sorted slice. An
// empty input yields ErrAddonCapabilityNone; any capability outside the allowlist
// yields ErrAddonCapabilityUnsafe (so the updater fails closed rather than granting it).
func normalizeAddonCapabilities(caps []string) ([]string, error) {
	seen := make(map[string]bool, len(caps))
	out := make([]string, 0, len(caps))

	for _, c := range caps {
		name := strings.ToLower(strings.TrimSpace(c))
		if name == "" {
			continue
		}
		if !allowedAddonCapabilities[name] {
			return nil, fmt.Errorf("%w: %q", ErrAddonCapabilityUnsafe, name)
		}
		if seen[name] {
			continue
		}
		seen[name] = true
		out = append(out, name)
	}

	if len(out) == 0 {
		return nil, ErrAddonCapabilityNone
	}

	sort.Strings(out)

	return out, nil
}

// setcapCapabilityString joins normalized capabilities into the setcap capability
// argument, e.g. "cap_bpf,cap_net_raw,cap_perfmon=+ep".
func setcapCapabilityString(caps []string) string {
	return strings.Join(caps, ",") + addonCapabilityActionSuffix
}

// resolveStagedAddonBinaryForCapabilities resolves the absolute path of an add-on
// binary (via its `current` symlink) under the root-owned privileged runtime only.
// A missing privileged binary fails closed: file capabilities are never applied to
// the agent-writable staging tree.
func resolveStagedAddonBinaryForCapabilities(req AddonCapabilityRequest) (string, error) {
	if !safeAddonSegment(req.AddonID) {
		return "", fmt.Errorf("%w: addon_id %q", ErrAddonUnsafePath, req.AddonID)
	}
	if !safeAddonSegment(req.BinaryName) {
		return "", fmt.Errorf("%w: binary %q", ErrAddonUnsafePath, req.BinaryName)
	}

	privRoot := resolvePrivilegedAddonRoot(req.PrivilegedRoot, req.RuntimeRoot)
	if capabilityRootOverlapsWritable(privRoot, req.RuntimeRoot) {
		return "", fmt.Errorf("%w: %s", ErrAddonCapabilityBinaryEscape, privRoot)
	}

	privAddonDir := filepath.Join(privRoot, req.AddonID)
	privCurrentBin := filepath.Join(privAddonDir, addonCurrentLink, req.BinaryName)
	if _, err := os.Stat(privCurrentBin); err != nil {
		return "", fmt.Errorf("resolve privileged addon binary: %w", err)
	}

	real, err := filepath.EvalSymlinks(privCurrentBin)
	if err != nil {
		return "", fmt.Errorf("resolve privileged addon binary: %w", err)
	}

	privAddonDirReal, err := filepath.EvalSymlinks(privAddonDir)
	if err != nil {
		return "", fmt.Errorf("resolve privileged addon dir: %w", err)
	}
	if !pathIsWithin(real, privAddonDirReal) {
		return "", fmt.Errorf("%w: %s", ErrAddonCapabilityBinaryEscape, real)
	}
	for _, root := range writableAddonRoots(req.RuntimeRoot) {
		if pathIsWithin(real, root) {
			return "", fmt.Errorf("%w: %s", ErrAddonCapabilityBinaryEscape, real)
		}
	}

	info, err := os.Stat(real)
	if err != nil {
		return "", fmt.Errorf("stat privileged addon binary: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("%w: %s", ErrAddonBinaryNotRegular, real)
	}

	return real, nil
}

func writableAddonRoots(runtimeRoot string) []string {
	roots := []string{resolveAddonArtifactRoot(""), resolveAddonArtifactRoot(runtimeRoot)}
	out := make([]string, 0, len(roots))
	seen := make(map[string]bool, len(roots))
	for _, root := range roots {
		clean := filepath.Clean(root)
		if seen[clean] {
			continue
		}
		seen[clean] = true
		out = append(out, clean)
	}
	return out
}

func capabilityRootOverlapsWritable(privRoot, runtimeRoot string) bool {
	priv := filepath.Clean(privRoot)
	for _, root := range writableAddonRoots(runtimeRoot) {
		if pathIsWithin(priv, root) || pathIsWithin(root, priv) {
			return true
		}
	}
	return false
}

// ApplyAddonCapabilities is the privileged operation invoked inside the root-owned
// serviceradar-agent-updater: it validates the requested capabilities, re-resolves the
// staged binary under the controlled add-on root, and applies the capabilities with
// setcap. It is Linux-only in practice (setcap); on a host without libcap it returns
// ErrSetcapUnavailable.
func ApplyAddonCapabilities(ctx context.Context, req AddonCapabilityRequest) error {
	caps, err := normalizeAddonCapabilities(req.Capabilities)
	if err != nil {
		return err
	}

	binary, err := resolveStagedAddonBinaryForCapabilities(req)
	if err != nil {
		return err
	}

	cmd := exec.CommandContext(ctx, setcapCommandPath, setcapCapabilityString(caps), binary)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if errors.Is(err, exec.ErrNotFound) || errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("%w: %w", ErrSetcapUnavailable, err)
		}
		return fmt.Errorf("apply addon capabilities via setcap: %w", err)
	}

	return nil
}
