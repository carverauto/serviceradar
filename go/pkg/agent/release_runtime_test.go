package agent

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
		CommandID:        "41f97057-7385-4ed0-b64c-a03f61c93876",
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
		CommandID:        "cc5a27d3-2d7b-42e1-b2da-014f4b8684f4",
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
		CommandID:        "cbe886a2-a3be-4f02-b8f9-46f8627cff3f",
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
		CommandID:      "80c9fcd2-265f-4c6b-9329-eac340c67914",
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

func TestAgentUpdaterPathIgnoresEnvironmentOverride(t *testing.T) {
	t.Setenv("SERVICERADAR_AGENT_UPDATER", "/tmp/evil-updater")

	if got, want := AgentUpdaterPath(), defaultAgentUpdaterPath; got != want {
		t.Fatalf("AgentUpdaterPath() = %q, want %q", got, want)
	}
}

func TestAgentSeedBinaryPathIgnoresEnvironmentOverride(t *testing.T) {
	t.Setenv("SERVICERADAR_AGENT_SEED_BINARY", "/tmp/evil-seed")

	if got, want := AgentSeedBinaryPath(), defaultAgentSeedPath; got != want {
		t.Fatalf("AgentSeedBinaryPath() = %q, want %q", got, want)
	}
}

func TestResolveReleaseRuntimeRootIgnoresEnvironmentOverride(t *testing.T) {
	t.Setenv("SERVICERADAR_AGENT_RUNTIME_ROOT", "/tmp/evil-root")

	if got, want := resolveReleaseRuntimeRoot(""), defaultReleaseRuntimeRoot; got != want {
		t.Fatalf("resolveReleaseRuntimeRoot(\"\") = %q, want %q", got, want)
	}
}

func TestValidateReleaseActivationExecArgsAcceptsCanonicalValues(t *testing.T) {
	args, err := validateReleaseActivationExecArgs(
		"v1.2.16",
		"CB128844-D63B-4720-A22D-647E784E5FF8",
		commandTypeAgentUpdate,
	)
	if err != nil {
		t.Fatalf("validateReleaseActivationExecArgs() error = %v", err)
	}
	if got, want := args.Version, "v1.2.16"; got != want {
		t.Fatalf("version = %q, want %q", got, want)
	}
	if got, want := args.CommandID, "cb128844-d63b-4720-a22d-647e784e5ff8"; got != want {
		t.Fatalf("command id = %q, want %q", got, want)
	}
	if got, want := args.CommandType, commandTypeAgentUpdate; got != want {
		t.Fatalf("command type = %q, want %q", got, want)
	}
}

func TestValidateReleaseActivationExecArgsRejectsInvalidValues(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		version     string
		commandID   string
		commandType string
		targetErr   error
	}{
		{
			name:        "invalid version token",
			version:     "v1.2.16+meta",
			commandID:   "cb128844-d63b-4720-a22d-647e784e5ff8",
			commandType: commandTypeAgentUpdate,
			targetErr:   errReleaseActivationVersionInvalid,
		},
		{
			name:        "invalid command id",
			version:     "v1.2.16",
			commandID:   "not-a-uuid",
			commandType: commandTypeAgentUpdate,
			targetErr:   errReleaseActivationCommandIDInvalid,
		},
		{
			name:        "invalid command type",
			version:     "v1.2.16",
			commandID:   "cb128844-d63b-4720-a22d-647e784e5ff8",
			commandType: "mapper.run_job",
			targetErr:   errReleaseActivationCommandTypeInvalid,
		},
		{
			name:        "control characters",
			version:     "v1.2.16",
			commandID:   "cb128844-d63b-4720-a22d-647e784e5ff8\n",
			commandType: commandTypeAgentUpdate,
			targetErr:   errReleaseActivationArgumentControlChars,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := validateReleaseActivationExecArgs(tt.version, tt.commandID, tt.commandType)
			if !errors.Is(err, tt.targetErr) {
				t.Fatalf("expected %v, got %v", tt.targetErr, err)
			}
		})
	}
}

func TestValidateReleaseActivationExecArgsRejectsOversizeVersion(t *testing.T) {
	version := fmt.Sprintf("v%s", strings.Repeat("1", 128))

	_, err := validateReleaseActivationExecArgs(
		version,
		"cb128844-d63b-4720-a22d-647e784e5ff8",
		commandTypeAgentUpdate,
	)
	if !errors.Is(err, errReleaseActivationVersionInvalid) {
		t.Fatalf("expected errReleaseActivationVersionInvalid, got %v", err)
	}
}

func TestActivateStagedReleaseRejectsInvalidCommandMetadata(t *testing.T) {
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

	err := ActivateStagedRelease(ReleaseActivationConfig{
		RuntimeRoot:      runtimeRoot,
		Version:          "1.2.3",
		CommandID:        "not-a-uuid",
		CommandType:      commandTypeAgentUpdate,
		RollbackDeadline: time.Minute,
	})
	if !errors.Is(err, errReleaseActivationCommandIDInvalid) {
		t.Fatalf("expected errReleaseActivationCommandIDInvalid, got %v", err)
	}
}
