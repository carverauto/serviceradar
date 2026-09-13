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

package addon

import (
	"fmt"
	"os"
	"strings"
)

// envAddonStateDir names the per-add-on persistent state directory the agent
// hands every sidecar add-on it spawns. The directory lives beside the add-on's
// versions tree (<runtime root>/addons/<id>/state), so it survives artifact
// upgrades, agent restarts and the add-on's own restarts. Add-ons that keep
// re-warm state (the anomaly detector's baseline checkpoint) default their
// files into it instead of requiring an operator to configure a host path.
const envAddonStateDir = "SERVICERADAR_ADDON_STATE_DIR"

// addonStateEnv returns baseEnv with envAddonStateDir set to dir, replacing any
// inherited value so the add-on never sees a stale directory from the agent's
// own environment. A blank dir leaves the environment untouched.
func addonStateEnv(baseEnv []string, dir string) []string {
	dir = strings.TrimSpace(dir)
	if dir == "" {
		return baseEnv
	}

	env := make([]string, 0, len(baseEnv)+1)
	for _, kv := range baseEnv {
		if key, _, ok := strings.Cut(kv, "="); ok && key == envAddonStateDir {
			continue
		}
		env = append(env, kv)
	}
	return append(env, envAddonStateDir+"="+dir)
}

// ensureAddonStateDir creates dir (and parents) as a private 0700 directory owned
// by the agent's own user, which is also the user the sidecar runs as. The mode is
// re-applied on an existing directory so a permissive umask cannot widen it.
func ensureAddonStateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create addon state dir %s: %w", dir, err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return fmt.Errorf("restrict addon state dir %s: %w", dir, err)
	}
	return nil
}
