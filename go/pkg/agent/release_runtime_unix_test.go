//go:build !windows

package agent

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestValidatedAgentUpdaterPathRejectsNonRootOwnedFile(t *testing.T) {
	tempDir := t.TempDir()
	updaterPath := filepath.Join(tempDir, "updater")
	if err := os.WriteFile(updaterPath, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	info, err := os.Stat(updaterPath)
	if err != nil {
		t.Fatalf("Stat() error = %v", err)
	}

	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatal("expected syscall.Stat_t for updater file")
	}
	if stat.Uid == 0 {
		if err := os.Chown(updaterPath, 1, int(stat.Gid)); err != nil {
			t.Fatalf("Chown() error = %v", err)
		}
	}

	_, err = validatePackageOwnedExecutable(updaterPath)
	if !errors.Is(err, errReleaseUpdaterOwnershipInvalid) {
		t.Fatalf("expected errReleaseUpdaterOwnershipInvalid, got %v", err)
	}
}
