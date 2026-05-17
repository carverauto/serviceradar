/*
 * Copyright 2025 Carver Automation Corporation.
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

package remoteaccess

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

const (
	DefaultRDPAdapterBinary       = "serviceradar-rdp-adapter"
	RDPAdapterCapabilitiesArg     = "--capabilities"
	RDPAdapterCapabilitiesSchema  = "serviceradar.rdp.helper.capabilities.v1"
	RDPAdapterProbeTimeout        = 2 * time.Second
	RDPAdapterMinProtocolVersion  = 1
	rdpAdapterMaxCapabilitiesJSON = 16 * 1024
)

type RDPAdapterCapabilities struct {
	Schema                string `json:"schema"`
	Protocol              string `json:"protocol"`
	HelperProtocolVersion int    `json:"helper_protocol_version"`
	IronRDPBackendLinked  bool   `json:"ironrdp_backend_linked"`
	ConnectorReady        bool   `json:"connector_ready"`
	ConnectorReadyReason  string `json:"connector_ready_reason,omitempty"`
}

// NormalizeRDPAdapterPath returns the configured helper path, or the default
// helper binary name when the agent config leaves the path unset.
func NormalizeRDPAdapterPath(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return DefaultRDPAdapterBinary
	}

	return path
}

// ResolveRDPAdapterPath resolves the local per-session RDP helper that backs
// the concrete IronRDP adapter. Agents must not advertise remote_access.rdp
// unless this helper can be executed.
func ResolveRDPAdapterPath(path string) (string, error) {
	adapterPath := NormalizeRDPAdapterPath(path)
	resolved, err := exec.LookPath(adapterPath)
	if err != nil {
		return "", fmt.Errorf("%w: %s", ErrDesktopAdapterUnavailable, adapterPath)
	}

	return resolved, nil
}

func RDPAdapterBinaryAvailable(path string) bool {
	_, err := ResolveRDPAdapterPath(path)

	return err == nil
}

func ProbeRDPAdapterCapabilities(
	ctx context.Context,
	path string,
) (string, RDPAdapterCapabilities, error) {
	resolved, err := ResolveRDPAdapterPath(path)
	if err != nil {
		return "", RDPAdapterCapabilities{}, err
	}

	ctx, cancel := context.WithTimeout(ctx, RDPAdapterProbeTimeout)
	defer cancel()

	output, err := exec.CommandContext(ctx, resolved, RDPAdapterCapabilitiesArg).Output()
	if err != nil {
		return "", RDPAdapterCapabilities{}, fmt.Errorf("%w: capability probe failed", ErrDesktopAdapterUnavailable)
	}
	if len(output) > rdpAdapterMaxCapabilitiesJSON {
		return "", RDPAdapterCapabilities{}, fmt.Errorf("%w: capability output too large", ErrDesktopAdapterUnavailable)
	}

	var capabilities RDPAdapterCapabilities
	if err := json.Unmarshal(output, &capabilities); err != nil {
		return "", RDPAdapterCapabilities{}, fmt.Errorf("%w: decode capabilities", ErrDesktopAdapterUnavailable)
	}
	if err := validateRDPAdapterCapabilities(capabilities); err != nil {
		return "", RDPAdapterCapabilities{}, err
	}

	return resolved, capabilities, nil
}

func RDPAdapterReady(path string) bool {
	_, capabilities, err := ProbeRDPAdapterCapabilities(context.Background(), path)

	return err == nil && capabilities.ConnectorReady
}

func validateRDPAdapterCapabilities(capabilities RDPAdapterCapabilities) error {
	if capabilities.Schema != RDPAdapterCapabilitiesSchema {
		return fmt.Errorf("%w: unsupported capability schema", ErrDesktopAdapterUnavailable)
	}
	if capabilities.Protocol != ProtocolRDP {
		return fmt.Errorf("%w: unsupported capability protocol", ErrDesktopAdapterUnavailable)
	}
	if capabilities.HelperProtocolVersion < RDPAdapterMinProtocolVersion {
		return fmt.Errorf("%w: unsupported helper protocol version", ErrDesktopAdapterUnavailable)
	}
	if !capabilities.IronRDPBackendLinked {
		return fmt.Errorf("%w: ironrdp backend not linked", ErrDesktopAdapterUnavailable)
	}
	if !capabilities.ConnectorReady {
		if capabilities.ConnectorReadyReason != "" {
			return fmt.Errorf(
				"%w: connector not ready: %s",
				ErrDesktopAdapterUnavailable,
				capabilities.ConnectorReadyReason,
			)
		}

		return fmt.Errorf("%w: connector not ready", ErrDesktopAdapterUnavailable)
	}

	return nil
}
