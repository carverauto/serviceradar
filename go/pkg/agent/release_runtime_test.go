package agent

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestActivateAndCompleteReleaseActivation(t *testing.T) {
	runtimeRoot := t.TempDir()
	seedDir := filepath.Join(runtimeRoot, releaseVersionsDirName, releaseSeedVersionDir)
	nextDir := filepath.Join(runtimeRoot, releaseVersionsDirName, "1.2.3")

	for _, dir := range []string{seedDir, nextDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("MkdirAll(%q) error = %v", dir, err)
		}
	}
	if err := os.Symlink(filepath.Join(releaseVersionsDirName, releaseSeedVersionDir), filepath.Join(runtimeRoot, releaseCurrentLinkName)); err != nil {
		t.Fatalf("Symlink() error = %v", err)
	}

	if err := ActivateStagedRelease(ReleaseActivationConfig{
		RuntimeRoot:      runtimeRoot,
		Version:          "1.2.3",
		CommandID:        "cmd-1",
		CommandType:      commandTypeAgentUpdate,
		RollbackDeadline: time.Minute,
	}); err != nil {
		t.Fatalf("ActivateStagedRelease() error = %v", err)
	}

	currentTarget, err := os.Readlink(filepath.Join(runtimeRoot, releaseCurrentLinkName))
	if err != nil {
		t.Fatalf("Readlink() error = %v", err)
	}
	if got, want := currentTarget, filepath.Join(releaseVersionsDirName, "1.2.3"); got != want {
		t.Fatalf("current target = %q, want %q", got, want)
	}

	completed, err := CompleteReleaseActivation(runtimeRoot, "1.2.3")
	if err != nil {
		t.Fatalf("CompleteReleaseActivation() error = %v", err)
	}
	if !completed {
		t.Fatal("expected CompleteReleaseActivation() to report completion")
	}

	report, err := LoadReleaseActivationReport(runtimeRoot)
	if err != nil {
		t.Fatalf("LoadReleaseActivationReport() error = %v", err)
	}
	if !report.Success {
		t.Fatalf("expected success report, got %#v", report)
	}
	if report.Payload["status"] != "healthy" {
		t.Fatalf("expected healthy status, got %#v", report.Payload)
	}
}

func TestRollbackReleaseActivationRestoresPreviousTarget(t *testing.T) {
	runtimeRoot := t.TempDir()
	seedDir := filepath.Join(runtimeRoot, releaseVersionsDirName, releaseSeedVersionDir)
	nextDir := filepath.Join(runtimeRoot, releaseVersionsDirName, "1.2.3")

	for _, dir := range []string{seedDir, nextDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("MkdirAll(%q) error = %v", dir, err)
		}
	}
	if err := os.Symlink(filepath.Join(releaseVersionsDirName, releaseSeedVersionDir), filepath.Join(runtimeRoot, releaseCurrentLinkName)); err != nil {
		t.Fatalf("Symlink() error = %v", err)
	}

	if err := ActivateStagedRelease(ReleaseActivationConfig{
		RuntimeRoot:      runtimeRoot,
		Version:          "1.2.3",
		CommandID:        "cmd-2",
		CommandType:      commandTypeAgentUpdate,
		RollbackDeadline: time.Minute,
	}); err != nil {
		t.Fatalf("ActivateStagedRelease() error = %v", err)
	}

	rolledBack, err := RollbackReleaseActivation(runtimeRoot, "deadline exceeded")
	if err != nil {
		t.Fatalf("RollbackReleaseActivation() error = %v", err)
	}
	if !rolledBack {
		t.Fatal("expected rollback to occur")
	}

	currentTarget, err := os.Readlink(filepath.Join(runtimeRoot, releaseCurrentLinkName))
	if err != nil {
		t.Fatalf("Readlink() error = %v", err)
	}
	if got, want := currentTarget, filepath.Join(releaseVersionsDirName, releaseSeedVersionDir); got != want {
		t.Fatalf("current target = %q, want %q", got, want)
	}

	report, err := LoadReleaseActivationReport(runtimeRoot)
	if err != nil {
		t.Fatalf("LoadReleaseActivationReport() error = %v", err)
	}
	if report.Success {
		t.Fatalf("expected rollback report to be unsuccessful, got %#v", report)
	}
	if report.Payload["status"] != "rolled_back" {
		t.Fatalf("expected rolled_back status, got %#v", report.Payload)
	}
}

func TestActivateStagedReleaseRejectsUnsafeCurrentTarget(t *testing.T) {
	runtimeRoot := t.TempDir()
	nextDir := filepath.Join(runtimeRoot, releaseVersionsDirName, "1.2.3")

	if err := os.MkdirAll(nextDir, 0o755); err != nil {
		t.Fatalf("MkdirAll(%q) error = %v", nextDir, err)
	}
	if err := os.Symlink("/tmp/serviceradar-outside", filepath.Join(runtimeRoot, releaseCurrentLinkName)); err != nil {
		t.Fatalf("Symlink() error = %v", err)
	}

	err := ActivateStagedRelease(ReleaseActivationConfig{
		RuntimeRoot:      runtimeRoot,
		Version:          "1.2.3",
		CommandID:        "cmd-unsafe",
		CommandType:      commandTypeAgentUpdate,
		RollbackDeadline: time.Minute,
	})
	if !errors.Is(err, errReleaseSymlinkTargetInvalid) {
		t.Fatalf("expected errReleaseSymlinkTargetInvalid, got %v", err)
	}
}

func TestRollbackReleaseActivationRejectsUnsafePreviousTarget(t *testing.T) {
	runtimeRoot := t.TempDir()
	reportPath := filepath.Join(runtimeRoot, releaseActivationState)
	nextDir := filepath.Join(runtimeRoot, releaseVersionsDirName, "1.2.3")

	if err := os.MkdirAll(nextDir, 0o755); err != nil {
		t.Fatalf("MkdirAll(%q) error = %v", nextDir, err)
	}

	state := releaseActivationStateFile{
		CommandID:      "cmd-unsafe",
		CommandType:    commandTypeAgentUpdate,
		TargetVersion:  "1.2.3",
		PreviousTarget: "../outside",
	}
	if err := writeJSONAtomically(reportPath, state); err != nil {
		t.Fatalf("writeJSONAtomically() error = %v", err)
	}

	rolledBack, err := RollbackReleaseActivation(runtimeRoot, "unsafe target")
	if rolledBack {
		t.Fatal("expected rollback to be rejected")
	}
	if !errors.Is(err, errReleaseSymlinkTargetInvalid) {
		t.Fatalf("expected errReleaseSymlinkTargetInvalid, got %v", err)
	}
}
