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

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/agent/updaterflags"
)

const (
	testSubprocessEnv  = "SERVICERADAR_TEST_AGENT_UPDATER_SUBPROCESS"
	testUpdaterArgsEnv = "SERVICERADAR_TEST_AGENT_UPDATER_ARGS"
	wantPermanentExit  = updaterflags.ExitPermanentRefusal
)

func TestMain(m *testing.M) {
	if os.Getenv(testSubprocessEnv) == "1" {
		rawArgs := os.Getenv(testUpdaterArgsEnv)
		args := []string{"serviceradar-agent-updater"}
		if rawArgs != "" {
			var decoded []string
			if err := json.Unmarshal([]byte(rawArgs), &decoded); err != nil {
				os.Exit(2)
			}
			args = append(args, decoded...)
		}
		os.Args = args
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func runUpdaterSubprocess(t *testing.T, args ...string) (int, string) {
	t.Helper()

	exe, err := os.Executable()
	if err != nil {
		t.Fatalf("resolve test executable: %v", err)
	}
	encodedArgs, err := json.Marshal(args)
	if err != nil {
		t.Fatalf("marshal args: %v", err)
	}
	cmd := exec.CommandContext(t.Context(), exe)
	cmd.Env = append(os.Environ(),
		testSubprocessEnv+"=1",
		testUpdaterArgsEnv+"="+string(encodedArgs),
	)
	out, runErr := cmd.CombinedOutput()
	if runErr == nil {
		return 0, string(out)
	}
	var exitErr *exec.ExitError
	if !errors.As(runErr, &exitErr) {
		t.Fatalf("unexpected exec error: %v", runErr)
	}
	return exitErr.ExitCode(), string(out)
}

func TestAgentUpdaterExitsPermanentRefusalCodeForDeterministicAddonContractErrors(t *testing.T) {
	dir := t.TempDir()
	artPath := filepath.Join(dir, "addon.tar.gz")
	payload := []byte("synthetic-archive-bytes")
	if err := os.WriteFile(artPath, payload, 0o644); err != nil {
		t.Fatalf("write artifact: %v", err)
	}
	sum := sha256.Sum256(payload)
	shaHex := hex.EncodeToString(sum[:])

	code, _ := runUpdaterSubprocess(
		t,
		"--"+updaterflags.PrivilegedRoot, filepath.Join(dir, "priv"),
		"--"+updaterflags.AddonID, "synthetic-scanner",
		"--"+updaterflags.AddonVersion, "0.1.0",
		"--"+updaterflags.AddonBinary, "serviceradar-synthetic-scanner",
		"--"+updaterflags.AddonSHA256, shaHex,
		"--"+updaterflags.AddonSignature, "Zm9yZ2VkLXNpZ25hdHVyZQ==",
		"--"+updaterflags.AddonArtifact, artPath,
		"--"+updaterflags.AddonSystemdInstall, "serviceradar-synthetic-scanner.service",
		"--"+updaterflags.AddonSystemdEnable, "serviceradar-synthetic-scanner.service",
	)
	if code != wantPermanentExit {
		t.Fatalf("exit code for forged signature refusal = %d, want %d", code, wantPermanentExit)
	}

	// Missing staged artifact on disk is environmental/transient (race or cleanup), not 78.
	transientCode, _ := runUpdaterSubprocess(
		t,
		"--"+updaterflags.PrivilegedRoot, filepath.Join(dir, "priv"),
		"--"+updaterflags.AddonID, "synthetic-scanner",
		"--"+updaterflags.AddonVersion, "0.1.0",
		"--"+updaterflags.AddonBinary, "serviceradar-synthetic-scanner",
		"--"+updaterflags.AddonSHA256, shaHex,
		"--"+updaterflags.AddonSignature, "Zm9yZ2VkLXNpZ25hdHVyZQ==",
		"--"+updaterflags.AddonArtifact, filepath.Join(dir, "absent.tar.gz"),
		"--"+updaterflags.AddonSystemdInstall, "serviceradar-synthetic-scanner.service",
		"--"+updaterflags.AddonSystemdEnable, "serviceradar-synthetic-scanner.service",
	)
	if transientCode != 1 {
		t.Fatalf("exit code for missing artifact = %d, want 1", transientCode)
	}
}

func TestAgentUpdaterExitsPermanentRefusalCodeForUnusableCommandLines(t *testing.T) {
	cases := map[string][]string{
		"unknown flag":           {"--addon-flag-from-a-future-agent", "x"},
		"invalid flag value":     {"--" + updaterflags.Version, "1.0.0", "--" + updaterflags.RollbackDeadline, "bogus"},
		"no operation requested": {},
	}
	for name, args := range cases {
		t.Run(name, func(t *testing.T) {
			if code, out := runUpdaterSubprocess(t, args...); code != wantPermanentExit {
				t.Fatalf("exit code = %d, want %d; output: %s", code, wantPermanentExit, out)
			}
		})
	}
}
