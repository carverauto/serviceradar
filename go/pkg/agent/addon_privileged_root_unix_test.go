//go:build !windows

package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestRestoreStateThroughAnchorRefusesDirectorySymlink(t *testing.T) {
	anchor := t.TempDir()
	outside := filepath.Join(anchor, "outside")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(persistedAddonStateRollback{
		Files: map[string][]byte{"pwned": []byte("root-write")},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, ".serviceradar-state-rollback"), body, 0o644); err != nil {
		t.Fatal(err)
	}
	stateLink := filepath.Join(anchor, "addons", "np", "state")
	if err := os.MkdirAll(filepath.Dir(stateLink), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, stateLink); err != nil {
		t.Fatal(err)
	}

	if err := restoreStateThroughAnchor(anchor, stateLink); err == nil {
		t.Fatal("directory symlink was followed")
	}
	if _, err := os.Stat(filepath.Join(outside, "pwned")); !os.IsNotExist(err) {
		t.Fatalf("restore wrote through the directory symlink: %v", err)
	}
}

func TestRestoreStateThroughAnchorWritesRegularDirectory(t *testing.T) {
	anchor := t.TempDir()
	stateDir := filepath.Join(anchor, "addons", "np", "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	want := []byte("{\n  \"mode\": \"v1\"\n}\n")
	body, err := json.Marshal(persistedAddonStateRollback{
		Files: map[string][]byte{"bumblebee-scan.json": want},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, ".serviceradar-state-rollback"), body, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := restoreStateThroughAnchor(anchor, stateDir); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(stateDir, "bumblebee-scan.json"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("restored state = %q, want %q", got, want)
	}
}

func TestPrivilegedRootForSetuidInstallIgnoresCallerRoots(t *testing.T) {
	got, err := PrivilegedRootForSetuidInstall("/tmp/evil/privileged-addons", "/tmp/evil")
	if err != nil {
		t.Fatalf("default privileged root rejected: %v", err)
	}
	if got != defaultPrivilegedAddonRoot {
		t.Fatalf("setuid root = %q, want %q", got, defaultPrivilegedAddonRoot)
	}

	owned := t.TempDir()
	if os.Getuid() == 0 {
		// A root test process owns its temp dir. The rejected case is a directory
		// not owned by root, which is what a non-root caller can create.
		if err := os.Chown(owned, 65534, 65534); err != nil {
			t.Fatalf("chown caller-owned fixture: %v", err)
		}
	}
	if err := validatePrivilegedAddonRootOwnership(owned); err == nil {
		t.Fatal("caller-owned directory was accepted as the privileged addon root")
	}
}
