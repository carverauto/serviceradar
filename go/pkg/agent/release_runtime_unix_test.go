//go:build !windows

package agent

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
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

func TestValidateAgentUpdaterSupportsFlags(t *testing.T) {
	updaterPath := writeUpdaterHelpScript(t, `
Usage of updater:
  -addon-id string
  -addon-binary string
  -addon-capabilities string
`)

	if err := validateAgentUpdaterSupportsFlags(
		updaterPath,
		"addon-id",
		"--addon-binary",
		"addon-capabilities",
	); err != nil {
		t.Fatalf("validateAgentUpdaterSupportsFlags() error = %v", err)
	}
}

func TestValidateAgentUpdaterSupportsFlagsRejectsMissingFlag(t *testing.T) {
	updaterPath := writeUpdaterHelpScript(t, `
Usage of updater:
  -version string
  -command-id string
`)

	err := validateAgentUpdaterSupportsFlags(updaterPath, "addon-id")
	if !errors.Is(err, errReleaseUpdaterFlagUnsupported) {
		t.Fatalf("expected errReleaseUpdaterFlagUnsupported, got %v", err)
	}
}

func TestRunAgentUpdaterCommandIncludesOutput(t *testing.T) {
	updaterPath := writeExecutableScript(t, `
echo "unable to set CAP_SETFCAP effective capability: Operation not permitted" >&2
exit 1
`)

	err := runAgentUpdaterCommand(context.Background(), updaterPath, "--addon-id", "netprobe")
	if err == nil {
		t.Fatal("runAgentUpdaterCommand() error = nil, want failure")
	}
	if !strings.Contains(err.Error(), "unable to set CAP_SETFCAP effective capability") {
		t.Fatalf("runAgentUpdaterCommand() error = %q, want helper stderr", err)
	}
}

func writeUpdaterHelpScript(t *testing.T, usage string) string {
	t.Helper()

	return writeExecutableScript(t, "cat <<'EOF'\n"+strings.TrimSpace(usage)+"\nEOF\n")
}

func writeExecutableScript(t *testing.T, body string) string {
	t.Helper()

	updaterPath := filepath.Join(t.TempDir(), "updater")
	if err := os.WriteFile(updaterPath, []byte("#!/bin/sh\n"+strings.TrimSpace(body)+"\n"), 0o755); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	return updaterPath
}
