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
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// rustAddonBin is the compiled Rust reference add-on
// (rust/addon-sdk serviceradar-rust-sample-addon) used by the cross-language
// interop test. It is empty when no binary could be produced (no prebuilt path
// and no cargo toolchain), in which case the test skips rather than fails.
//
//nolint:gochecknoglobals // resolved once and shared read-only by the Rust interop test.
var (
	rustAddonBin     string
	rustAddonBinOnce sync.Once
)

// resolveRustAddonBin prefers a prebuilt binary supplied via
// SERVICERADAR_RUST_ADDON_BIN (e.g. a Bazel data dependency or a CI artifact)
// and otherwise compiles the Rust reference add-on with cargo. Building Rust is
// slow, so the env override is the expected path in CI.
func resolveRustAddonBin(t *testing.T) string {
	t.Helper()
	rustAddonBinOnce.Do(func() {
		if bin := resolveBinPath(os.Getenv("SERVICERADAR_RUST_ADDON_BIN")); bin != "" {
			rustAddonBin = bin
			return
		}

		// Optional cargo fallback, gated on SERVICERADAR_BUILD_RUST_ADDON so the
		// default `go test` run does not silently kick off a multi-minute Rust
		// build. The repo root is found by walking up from the test's CWD.
		if os.Getenv("SERVICERADAR_BUILD_RUST_ADDON") == "" {
			return
		}
		if _, err := exec.LookPath("cargo"); err != nil {
			return
		}
		root := repoRoot()
		if root == "" {
			return
		}
		cmd := exec.CommandContext(context.Background(), "cargo", "build",
			"-p", "addon-sdk", "--bin", "serviceradar-rust-sample-addon")
		cmd.Dir = root
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return
		}
		candidate := filepath.Join(root, "target", "debug", "serviceradar-rust-sample-addon")
		if _, err := os.Stat(candidate); err == nil {
			rustAddonBin = candidate
		}
	})
	return rustAddonBin
}

// repoRoot walks up from the working directory to find the Cargo workspace root
// (the directory containing both go.mod and Cargo.toml).
func repoRoot() string {
	dir, err := os.Getwd()
	if err != nil {
		return ""
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "Cargo.toml")); err == nil {
			if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
				return dir
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

func requireRustAddon(t *testing.T) string {
	t.Helper()
	bin := resolveRustAddonBin(t)
	if bin == "" {
		t.Skip("Rust reference add-on binary unavailable " +
			"(set SERVICERADAR_RUST_ADDON_BIN to a prebuilt binary, " +
			"or SERVICERADAR_BUILD_RUST_ADDON=1 with a cargo toolchain)")
	}
	return bin
}

// TestManagerLaunchesRustAddonOverGoPlugin is the cross-language proof of the
// native add-on framework's polyglot claim: it launches the Rust reference
// add-on with the agent's REAL go-plugin client (via the Manager, not a mock),
// completes the go-plugin handshake + AutoMTLS against a Rust server, and drives
// Info / Configure / Health. If AutoMTLS or the handshake were even slightly off,
// the client would never reach StateRunning.
func TestManagerLaunchesRustAddonOverGoPlugin(t *testing.T) {
	bin := requireRustAddon(t)

	mgr := NewManager(testConfig(t))
	t.Cleanup(func() { stopManager(t, mgr) })

	if err := mgr.Apply(context.Background(), []Spec{{
		ID:           "rust-sample",
		Version:      "0.1.0",
		BinaryPath:   bin,
		ConfigJSON:   []byte(`{"scan_interval_seconds":60}`),
		Capabilities: []string{"rust-sample"},
	}}); err != nil {
		t.Fatalf("apply: %v", err)
	}

	// Reaching StateRunning means: the Rust binary printed a valid handshake
	// line, the go-plugin client completed AutoMTLS against the Rust server,
	// pinged the gRPC health service, dispensed the addon, and the Manager
	// successfully called Configure + Info over the supervised mTLS connection.
	s := waitForState(t, mgr, "rust-sample", 20*time.Second)
	if s.Version != "0.1.0" {
		t.Fatalf("expected version 0.1.0 reported via Info, got %q", s.Version)
	}
	if s.ConfigHash == "" {
		t.Fatalf("expected a config hash after Configure, got empty")
	}

	// Confirm the Rust add-on stays running across several health-poll cycles,
	// proving the Health RPC works repeatedly over the mTLS connection.
	time.Sleep(500 * time.Millisecond)
	s, ok := statusByID(mgr, "rust-sample")
	if !ok {
		t.Fatalf("rust-sample addon missing from status")
	}
	if s.State != StateRunning {
		t.Fatalf("expected running after health cycles, got %s (last_error=%q)", s.State, s.LastError)
	}
	if s.LastHealthAt.IsZero() {
		t.Fatalf("expected a health timestamp to be recorded via Health RPC")
	}
}

// TestManagerStopsRustAddon verifies the agent can tear down the supervised Rust
// add-on cleanly (go-plugin Kill + Unix socket cleanup).
func TestManagerStopsRustAddon(t *testing.T) {
	bin := requireRustAddon(t)

	mgr := NewManager(testConfig(t))
	t.Cleanup(func() { stopManager(t, mgr) })

	if err := mgr.Apply(context.Background(), []Spec{{
		ID:         "rust-sample",
		BinaryPath: bin,
		ConfigJSON: []byte("{}"),
	}}); err != nil {
		t.Fatalf("apply: %v", err)
	}
	waitForState(t, mgr, "rust-sample", 20*time.Second)

	if err := mgr.Apply(context.Background(), nil); err != nil {
		t.Fatalf("apply empty: %v", err)
	}
	if s, ok := statusByID(mgr, "rust-sample"); ok {
		t.Fatalf("expected rust-sample addon to be removed, still present: %+v", s)
	}
}
