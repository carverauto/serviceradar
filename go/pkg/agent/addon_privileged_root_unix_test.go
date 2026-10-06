//go:build !windows

package agent

import (
	"testing"
)

func TestPrivilegedRootForSetuidInstallIgnoresCallerRoots(t *testing.T) {
	got, err := PrivilegedRootForSetuidInstall("/tmp/evil/privileged-addons", "/tmp/evil")
	if err != nil {
		t.Fatalf("default privileged root rejected: %v", err)
	}
	if got != defaultPrivilegedAddonRoot {
		t.Fatalf("setuid root = %q, want %q", got, defaultPrivilegedAddonRoot)
	}

	owned := t.TempDir()
	if err := validatePrivilegedAddonRootOwnership(owned); err == nil {
		t.Fatal("caller-owned directory was accepted as the privileged addon root")
	}
}
