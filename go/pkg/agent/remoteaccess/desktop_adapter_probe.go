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
	"fmt"
	"os/exec"
	"strings"
)

const DefaultRDPAdapterBinary = "serviceradar-rdp-adapter"

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
