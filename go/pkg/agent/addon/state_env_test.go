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
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestAddonStateEnvExportsTheStateDirOnce(t *testing.T) {
	base := []string{"PATH=/usr/bin", envAddonStateDir + "=/stale/state", "HOME=/home/serviceradar"}
	got := addonStateEnv(base, "/var/lib/serviceradar/agent/addons/anomaly/state")

	var seen []string
	for _, kv := range got {
		if len(kv) > len(envAddonStateDir) && kv[:len(envAddonStateDir)+1] == envAddonStateDir+"=" {
			seen = append(seen, kv)
		}
	}
	if len(seen) != 1 || seen[0] != envAddonStateDir+"=/var/lib/serviceradar/agent/addons/anomaly/state" {
		t.Fatalf("state dir env = %v, want exactly one entry with the spawn-time dir", seen)
	}
	if got[0] != "PATH=/usr/bin" || got[len(got)-1] != envAddonStateDir+"=/var/lib/serviceradar/agent/addons/anomaly/state" {
		t.Fatalf("unrelated env must be preserved in order, got %v", got)
	}
}

func TestAddonStateEnvLeavesEnvAloneWithoutAStateDir(t *testing.T) {
	base := []string{"PATH=/usr/bin"}
	got := addonStateEnv(base, "  ")
	if len(got) != 1 || got[0] != "PATH=/usr/bin" {
		t.Fatalf("blank state dir must not add an env entry, got %v", got)
	}
}

func TestEnsureAddonStateDirCreatesAPrivateDirectory(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "anomaly", "state")
	if err := ensureAddonStateDir(dir); err != nil {
		t.Fatalf("ensureAddonStateDir: %v", err)
	}
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		t.Fatalf("state dir not created: %v", err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o700 {
		t.Fatalf("state dir mode = %o, want 0700", info.Mode().Perm())
	}
	// Idempotent: a second call on the existing directory is not an error.
	if err := ensureAddonStateDir(dir); err != nil {
		t.Fatalf("second ensureAddonStateDir: %v", err)
	}
}
