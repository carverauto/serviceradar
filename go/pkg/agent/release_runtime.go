/*
 * Copyright 2025 Carver Automation Corporation.
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

package agent

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"github.com/google/uuid"
)

const (
	defaultAgentUpdaterPath = "/usr/local/bin/serviceradar-agent-updater"
	defaultAgentSeedPath    = "/usr/local/lib/serviceradar/agent/serviceradar-agent-seed"

	releaseCurrentLinkName  = "current"
	releaseActivationState  = "activation.json"
	releaseActivationReport = "activation-report.json"
	releaseSeedVersionDir   = "seed-installed"
)

var errReleaseCurrentLinkMissing = errors.New("release current symlink is missing")
var errReleaseActivationPreviousTargetMissing = errors.New("release activation state missing previous target")
var errReleaseSymlinkTargetInvalid = errors.New("release symlink target is invalid")
var errReleaseUpdaterOwnershipUnknown = errors.New("release updater ownership could not be determined")
var errReleaseUpdaterOwnershipInvalid = errors.New("release updater must be owned by root")
var errReleaseUpdaterModeInvalid = errors.New("release updater must not be group or world writable")
var errReleaseUpdaterNotRegular = errors.New("release updater must be a regular file")
var errReleaseActivationVersionInvalid = errors.New("release activation version is invalid")
var errReleaseActivationCommandIDInvalid = errors.New("release activation command id is invalid")
var errReleaseActivationCommandTypeInvalid = errors.New("release activation command type is invalid")
var errReleaseActivationArgumentControlChars = errors.New("release activation arguments must not contain control characters")

type ReleaseActivationConfig struct {
	RuntimeRoot      string
	Version          string
	CommandID        string
	CommandType      string
	RollbackDeadline time.Duration
}

type releaseActivationStateFile struct {
	CommandID       string `json:"command_id"`
	CommandType     string `json:"command_type"`
	TargetVersion   string `json:"target_version"`
	PreviousTarget  string `json:"previous_target"`
	ActivatedAtUnix int64  `json:"activated_at_unix"`
	RollbackAtUnix  int64  `json:"rollback_at_unix"`
}

type releaseActivationReportFile struct {
	CommandID   string                 `json:"command_id"`
	CommandType string                 `json:"command_type"`
	Success     bool                   `json:"success"`
	Message     string                 `json:"message"`
	Payload     map[string]interface{} `json:"payload,omitempty"`
}

type releaseActivationExecArgs struct {
	Version     string
	CommandID   string
	CommandType string
}

func ActivateStagedRelease(cfg ReleaseActivationConfig) error {
	runtimeRoot := resolveReleaseRuntimeRoot(cfg.RuntimeRoot)
	execArgs, err := validateReleaseActivationExecArgs(cfg.Version, cfg.CommandID, cfg.CommandType)
	if err != nil {
		return err
	}

	versionDir, err := releaseVersionDir(runtimeRoot, execArgs.Version)
	if err != nil {
		return err
	}
	if _, err := os.Stat(versionDir); err != nil {
		return fmt.Errorf("stat staged release version dir: %w", err)
	}

	currentPath := filepath.Join(runtimeRoot, releaseCurrentLinkName)
	previousTarget, err := os.Readlink(currentPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return errReleaseCurrentLinkMissing
		}
		return fmt.Errorf("read current release symlink: %w", err)
	}
	previousTarget, err = normalizeExistingReleaseSymlinkTarget(runtimeRoot, previousTarget)
	if err != nil {
		return err
	}

	deadline := cfg.RollbackDeadline
	if deadline <= 0 {
		deadline = 3 * time.Minute
	}

	state := releaseActivationStateFile{
		CommandID:       execArgs.CommandID,
		CommandType:     execArgs.CommandType,
		TargetVersion:   execArgs.Version,
		PreviousTarget:  previousTarget,
		ActivatedAtUnix: time.Now().UTC().Unix(),
		RollbackAtUnix:  time.Now().UTC().Add(deadline).Unix(),
	}

	if err := writeJSONAtomically(filepath.Join(runtimeRoot, releaseActivationState), state); err != nil {
		return fmt.Errorf("write release activation state: %w", err)
	}
	if err := os.Remove(filepath.Join(runtimeRoot, releaseActivationReport)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove stale activation report: %w", err)
	}
	if err := switchReleaseCurrentSymlink(runtimeRoot, filepath.Join(releaseVersionsDirName, execArgs.Version)); err != nil {
		return err
	}

	return nil
}

func CompleteReleaseActivation(runtimeRoot, currentVersion string) (bool, error) {
	state, err := loadReleaseActivationState(runtimeRoot)
	if err != nil || state == nil {
		return false, err
	}
	if strings.TrimSpace(state.TargetVersion) != strings.TrimSpace(currentVersion) {
		return false, nil
	}

	report := releaseActivationReportFile{
		CommandID:   state.CommandID,
		CommandType: state.CommandType,
		Success:     true,
		Message:     "release activated",
		Payload: map[string]interface{}{
			"status":          "healthy",
			"current_version": currentVersion,
		},
	}

	root := resolveReleaseRuntimeRoot(runtimeRoot)
	if err := writeJSONAtomically(filepath.Join(root, releaseActivationReport), report); err != nil {
		return false, fmt.Errorf("write activation report: %w", err)
	}
	if err := os.Remove(filepath.Join(root, releaseActivationState)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, fmt.Errorf("remove activation state: %w", err)
	}

	return true, nil
}

func RollbackReleaseActivation(runtimeRoot, reason string) (bool, error) {
	state, err := loadReleaseActivationState(runtimeRoot)
	if err != nil || state == nil {
		return false, err
	}
	if strings.TrimSpace(state.PreviousTarget) == "" {
		return false, errReleaseActivationPreviousTargetMissing
	}
	previousTarget, err := normalizeExistingReleaseSymlinkTarget(runtimeRoot, state.PreviousTarget)
	if err != nil {
		return false, err
	}

	root := resolveReleaseRuntimeRoot(runtimeRoot)
	previousPath := filepath.Join(root, previousTarget)
	if _, err := os.Stat(previousPath); err != nil {
		return false, fmt.Errorf("stat previous release target: %w", err)
	}
	if err := switchReleaseCurrentSymlink(root, previousTarget); err != nil {
		return false, err
	}

	report := releaseActivationReportFile{
		CommandID:   state.CommandID,
		CommandType: state.CommandType,
		Success:     false,
		Message:     "release rolled back",
		Payload: map[string]interface{}{
			"status": "rolled_back",
			"reason": strings.TrimSpace(reason),
		},
	}
	if err := writeJSONAtomically(filepath.Join(root, releaseActivationReport), report); err != nil {
		return false, fmt.Errorf("write rollback report: %w", err)
	}
	if err := os.Remove(filepath.Join(root, releaseActivationState)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, fmt.Errorf("remove activation state: %w", err)
	}

	return true, nil
}

func LoadReleaseActivationState(runtimeRoot string) (*releaseActivationStateFile, error) {
	return loadReleaseActivationState(runtimeRoot)
}

func LoadReleaseActivationReport(runtimeRoot string) (*releaseActivationReportFile, error) {
	root := resolveReleaseRuntimeRoot(runtimeRoot)
	data, err := os.ReadFile(filepath.Join(root, releaseActivationReport))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("read activation report: %w", err)
	}

	var report releaseActivationReportFile
	if err := json.Unmarshal(data, &report); err != nil {
		return nil, fmt.Errorf("decode activation report: %w", err)
	}
	return &report, nil
}

func ClearReleaseActivationReport(runtimeRoot string) error {
	root := resolveReleaseRuntimeRoot(runtimeRoot)
	if err := os.Remove(filepath.Join(root, releaseActivationReport)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove activation report: %w", err)
	}
	return nil
}

func AgentUpdaterPath() string {
	return defaultAgentUpdaterPath
}

func AgentSeedBinaryPath() string {
	return defaultAgentSeedPath
}

func ValidatedAgentUpdaterPath() (string, error) {
	return validatePackageOwnedExecutable(AgentUpdaterPath())
}

func validatePackageOwnedExecutable(path string) (string, error) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", fmt.Errorf("resolve release updater path: %w", err)
	}

	info, err := os.Stat(resolved)
	if err != nil {
		return "", fmt.Errorf("stat release updater path: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", errReleaseUpdaterNotRegular
	}
	if err := validateRootOwnedFile(info); err != nil {
		return "", err
	}
	if info.Mode().Perm()&0o022 != 0 {
		return "", errReleaseUpdaterModeInvalid
	}

	return resolved, nil
}

func validateReleaseActivationExecArgs(version, commandID, commandType string) (releaseActivationExecArgs, error) {
	cleanVersion, err := normalizeManagedReleaseVersion(version)
	if err != nil {
		return releaseActivationExecArgs{}, err
	}

	cleanCommandID, err := normalizeReleaseActivationCommandID(commandID)
	if err != nil {
		return releaseActivationExecArgs{}, err
	}

	cleanCommandType, err := normalizeReleaseActivationCommandType(commandType)
	if err != nil {
		return releaseActivationExecArgs{}, err
	}

	return releaseActivationExecArgs{
		Version:     cleanVersion,
		CommandID:   cleanCommandID,
		CommandType: cleanCommandType,
	}, nil
}

func normalizeManagedReleaseVersion(value string) (string, error) {
	if containsControlChars(value) {
		return "", fmt.Errorf("%w: version", errReleaseActivationArgumentControlChars)
	}

	clean := strings.TrimSpace(value)
	if !isManagedReleaseVersionToken(clean) {
		return "", errReleaseActivationVersionInvalid
	}

	return clean, nil
}

func normalizeReleaseActivationCommandID(value string) (string, error) {
	if containsControlChars(value) {
		return "", fmt.Errorf("%w: command_id", errReleaseActivationArgumentControlChars)
	}

	clean := strings.TrimSpace(value)
	parsed, err := uuid.Parse(clean)
	if err != nil || !strings.EqualFold(parsed.String(), clean) {
		return "", errReleaseActivationCommandIDInvalid
	}

	return parsed.String(), nil
}

func normalizeReleaseActivationCommandType(value string) (string, error) {
	if containsControlChars(value) {
		return "", fmt.Errorf("%w: command_type", errReleaseActivationArgumentControlChars)
	}

	clean := strings.TrimSpace(value)
	if clean != commandTypeAgentUpdate {
		return "", errReleaseActivationCommandTypeInvalid
	}

	return commandTypeAgentUpdate, nil
}

func isManagedReleaseVersionToken(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}

	for idx, r := range value {
		switch {
		case isASCIIAlphaNum(r):
		case idx > 0 && (r == '.' || r == '_' || r == '-'):
		default:
			return false
		}
	}

	return true
}

func isASCIIAlphaNum(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')
}

func containsControlChars(value string) bool {
	return strings.IndexFunc(value, unicode.IsControl) >= 0
}

func loadReleaseActivationState(runtimeRoot string) (*releaseActivationStateFile, error) {
	root := resolveReleaseRuntimeRoot(runtimeRoot)
	data, err := os.ReadFile(filepath.Join(root, releaseActivationState))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("read activation state: %w", err)
	}

	var state releaseActivationStateFile
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, fmt.Errorf("decode activation state: %w", err)
	}
	return &state, nil
}

func switchReleaseCurrentSymlink(runtimeRoot, target string) error {
	root := resolveReleaseRuntimeRoot(runtimeRoot)
	normalizedTarget, err := normalizeReleaseSymlinkTarget(target)
	if err != nil {
		return err
	}
	currentPath := filepath.Join(root, releaseCurrentLinkName)
	tempPath := currentPath + ".new"

	_ = os.Remove(tempPath)
	if err := os.Symlink(normalizedTarget, tempPath); err != nil {
		return fmt.Errorf("create current release symlink: %w", err)
	}
	if err := os.Rename(tempPath, currentPath); err != nil {
		_ = os.Remove(tempPath)
		return fmt.Errorf("publish current release symlink: %w", err)
	}
	return nil
}

func normalizeReleaseSymlinkTarget(target string) (string, error) {
	clean, err := safeJoin(".", target)
	if err != nil {
		return "", errReleaseSymlinkTargetInvalid
	}
	clean = filepath.Clean(clean)
	prefix := releaseVersionsDirName + string(filepath.Separator)
	if !strings.HasPrefix(clean, prefix) {
		return "", errReleaseSymlinkTargetInvalid
	}
	return clean, nil
}

func normalizeExistingReleaseSymlinkTarget(runtimeRoot, target string) (string, error) {
	if filepath.IsAbs(target) {
		root, err := filepath.Abs(resolveReleaseRuntimeRoot(runtimeRoot))
		if err != nil {
			return "", errReleaseSymlinkTargetInvalid
		}
		targetAbs, err := filepath.Abs(target)
		if err != nil {
			return "", errReleaseSymlinkTargetInvalid
		}
		rel, err := filepath.Rel(root, targetAbs)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
			return "", errReleaseSymlinkTargetInvalid
		}
		target = rel
	}

	return normalizeReleaseSymlinkTarget(target)
}

func writeJSONAtomically(path string, value interface{}) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}

	tempPath := path + ".tmp"
	if err := os.WriteFile(tempPath, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tempPath, path); err != nil {
		_ = os.Remove(tempPath)
		return err
	}
	return nil
}
