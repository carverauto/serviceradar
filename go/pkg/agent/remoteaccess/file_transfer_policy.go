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

package remoteaccess

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"path"
	"strings"
)

const (
	FileTransferSymlinkDeny             FileTransferSymlinkMode = "deny"
	FileTransferSymlinkFollowInsideRoot FileTransferSymlinkMode = "follow_inside_root"
	FileTransferSymlinkAllow            FileTransferSymlinkMode = "allow"

	fileTransferRedactedPath = "REDACTED"
)

var (
	ErrFileTransferPolicyDenied       = errors.New("file transfer denied by policy")
	ErrFileTransferPolicyUnavailable  = errors.New("file transfer policy is unavailable")
	ErrInvalidFileTransferPathRule    = errors.New("invalid file transfer path rule")
	ErrInvalidFileTransferSymlinkMode = errors.New("invalid file transfer symlink mode")
	ErrFileTransferApprovalRequired   = errors.New("file transfer approval is required")
	ErrFileTransferQuotaExceeded      = errors.New("file transfer quota exceeded")
)

// FileTransferSymlinkMode controls how agent-side policy handles target symlinks.
type FileTransferSymlinkMode string

// FileTransferPolicy is the policy snapshot the selected agent must enforce
// before and during target file operations.
type FileTransferPolicy struct {
	AllowedOperations  []FileTransferOperation `json:"allowed_operations,omitempty"`
	AllowedPathRules   []string                `json:"allowed_path_rules,omitempty"`
	DeniedPathRules    []string                `json:"denied_path_rules,omitempty"`
	RedactedPathRules  []string                `json:"redacted_path_rules,omitempty"`
	SymlinkMode        FileTransferSymlinkMode `json:"symlink_mode,omitempty"`
	MaxBytes           int64                   `json:"max_bytes,omitempty"`
	MaxFiles           int64                   `json:"max_files,omitempty"`
	RequiresApproval   bool                    `json:"requires_approval,omitempty"`
	ContentAuditRetain bool                    `json:"content_audit_retain,omitempty"`
}

// FileTransferPolicyInput carries the trusted transfer request plus target
// filesystem facts observed by the selected agent.
type FileTransferPolicyInput struct {
	Request      FileTransferRequestPayload
	ResolvedPath string
	Bytes        int64
	Files        int64
	HasSymlink   bool
	RealPathOK   bool
	Approved     bool
}

// FileTransferPolicyDecision is safe to persist in audit and replay streams.
type FileTransferPolicyDecision struct {
	Allowed            bool               `json:"allowed"`
	Status             FileTransferStatus `json:"status"`
	Reason             string             `json:"reason,omitempty"`
	NormalizedPath     string             `json:"normalized_path,omitempty"`
	RedactedPath       string             `json:"redacted_path,omitempty"`
	PathHash           string             `json:"path_hash,omitempty"`
	ContentAuditRetain bool               `json:"content_audit_retain,omitempty"`
}

// EvaluateFileTransferPolicy applies the agent-enforced policy gates for a
// transfer. It does not open files and does not inspect file contents.
func EvaluateFileTransferPolicy(input FileTransferPolicyInput, policy FileTransferPolicy) (FileTransferPolicyDecision, error) {
	if err := input.Request.Validate(); err != nil {
		return deniedDecision(input.Request.Path, FileTransferStatusDenied, err), err
	}

	normalizedPath, err := normalizeRemotePath(input.Request.Path)
	if err != nil {
		return deniedDecision(input.Request.Path, FileTransferStatusDenied, err), err
	}

	if err := validatePolicy(policy); err != nil {
		return deniedDecision(normalizedPath, FileTransferStatusDenied, err), err
	}
	if !operationAllowed(input.Request.Operation, policy.AllowedOperations) {
		err := fmt.Errorf("%w: operation %q", ErrFileTransferPolicyDenied, input.Request.Operation)
		return deniedDecision(normalizedPath, FileTransferStatusDenied, err), err
	}
	if !pathAllowed(normalizedPath, policy.AllowedPathRules) || pathDenied(normalizedPath, policy.DeniedPathRules) {
		err := fmt.Errorf("%w: path", ErrFileTransferPolicyDenied)
		return deniedDecision(normalizedPath, FileTransferStatusDenied, err), err
	}
	if err := enforceSymlinkPolicy(input, policy, normalizedPath); err != nil {
		return deniedDecision(normalizedPath, FileTransferStatusDenied, err), err
	}
	if policy.RequiresApproval && !input.Approved {
		return deniedDecision(normalizedPath, FileTransferStatusApprovalPending, ErrFileTransferApprovalRequired),
			ErrFileTransferApprovalRequired
	}
	if err := enforceTransferQuotas(input, policy); err != nil {
		return deniedDecision(normalizedPath, FileTransferStatusQuotaExhausted, err), err
	}

	redactedPath, pathHash := auditPath(normalizedPath, policy.RedactedPathRules)

	return FileTransferPolicyDecision{
		Allowed:            true,
		Status:             FileTransferStatusRequested,
		NormalizedPath:     normalizedPath,
		RedactedPath:       redactedPath,
		PathHash:           pathHash,
		ContentAuditRetain: policy.ContentAuditRetain,
	}, nil
}

func validatePolicy(policy FileTransferPolicy) error {
	if len(policy.AllowedOperations) == 0 || len(policy.AllowedPathRules) == 0 {
		return ErrFileTransferPolicyUnavailable
	}
	if !policy.SymlinkMode.Valid() {
		return fmt.Errorf("%w %q", ErrInvalidFileTransferSymlinkMode, policy.SymlinkMode)
	}
	for _, rule := range append(append([]string{}, policy.AllowedPathRules...), append(policy.DeniedPathRules, policy.RedactedPathRules...)...) {
		if _, err := normalizeRemotePath(rule); err != nil {
			return fmt.Errorf("%w %q", ErrInvalidFileTransferPathRule, rule)
		}
	}

	return nil
}

// Valid returns true for supported symlink modes. Empty defaults to deny.
func (m FileTransferSymlinkMode) Valid() bool {
	switch m {
	case "", FileTransferSymlinkDeny, FileTransferSymlinkFollowInsideRoot, FileTransferSymlinkAllow:
		return true
	default:
		return false
	}
}

func operationAllowed(operation FileTransferOperation, allowed []FileTransferOperation) bool {
	for _, candidate := range allowed {
		if operation == candidate {
			return true
		}
	}

	return false
}

func pathAllowed(candidate string, rules []string) bool {
	for _, rule := range rules {
		if pathMatchesRule(candidate, rule) {
			return true
		}
	}

	return false
}

func pathDenied(candidate string, rules []string) bool {
	for _, rule := range rules {
		if pathMatchesRule(candidate, rule) {
			return true
		}
	}

	return false
}

func enforceSymlinkPolicy(input FileTransferPolicyInput, policy FileTransferPolicy, normalizedPath string) error {
	if !input.HasSymlink {
		return nil
	}

	switch policy.SymlinkMode {
	case "", FileTransferSymlinkDeny:
		return fmt.Errorf("%w: symlink", ErrFileTransferPolicyDenied)
	case FileTransferSymlinkAllow:
		return nil
	case FileTransferSymlinkFollowInsideRoot:
		if !input.RealPathOK || strings.TrimSpace(input.ResolvedPath) == "" {
			return fmt.Errorf("%w: resolved symlink path unavailable", ErrFileTransferPolicyDenied)
		}
		resolved, err := normalizeRemotePath(input.ResolvedPath)
		if err != nil {
			return fmt.Errorf("%w: resolved symlink path", ErrFileTransferPolicyDenied)
		}
		if !pathAllowed(resolved, policy.AllowedPathRules) || pathDenied(resolved, policy.DeniedPathRules) {
			return fmt.Errorf("%w: resolved symlink path", ErrFileTransferPolicyDenied)
		}
		if resolved == normalizedPath {
			return nil
		}
		return nil
	default:
		return fmt.Errorf("%w %q", ErrInvalidFileTransferSymlinkMode, policy.SymlinkMode)
	}
}

func enforceTransferQuotas(input FileTransferPolicyInput, policy FileTransferPolicy) error {
	if input.Bytes < 0 || input.Files < 0 {
		return ErrFileTransferQuotaExceeded
	}
	if policy.MaxBytes > 0 && input.Bytes > policy.MaxBytes {
		return ErrFileTransferQuotaExceeded
	}
	if policy.MaxFiles > 0 && input.Files > policy.MaxFiles {
		return ErrFileTransferQuotaExceeded
	}

	return nil
}

func auditPath(candidate string, redactedRules []string) (string, string) {
	if pathDenied(candidate, redactedRules) {
		return fileTransferRedactedPath, hashRemotePath(candidate)
	}

	return candidate, hashRemotePath(candidate)
}

func deniedDecision(candidate string, status FileTransferStatus, err error) FileTransferPolicyDecision {
	normalized, normalizeErr := normalizeRemotePath(candidate)
	if normalizeErr != nil {
		normalized = ""
	}

	return FileTransferPolicyDecision{
		Allowed:        false,
		Status:         status,
		Reason:         err.Error(),
		NormalizedPath: normalized,
		RedactedPath:   fileTransferRedactedPath,
		PathHash:       hashRemotePath(candidate),
	}
}

func pathMatchesRule(candidate, rule string) bool {
	normalizedRule, err := normalizeRemotePath(rule)
	if err != nil {
		return false
	}
	if normalizedRule == "/" {
		return strings.HasPrefix(candidate, "/")
	}

	return candidate == normalizedRule || strings.HasPrefix(candidate, normalizedRule+"/")
}

func normalizeRemotePath(candidate string) (string, error) {
	candidate = strings.TrimSpace(candidate)
	if candidate == "" || !strings.HasPrefix(candidate, "/") {
		return "", ErrInvalidFileTransferPath
	}
	if containsInvalidPathRune(candidate) || containsDotPathSegment(candidate) {
		return "", ErrInvalidFileTransferPath
	}

	normalized := path.Clean(candidate)
	if normalized == "." || normalized == "" {
		return "", ErrInvalidFileTransferPath
	}

	return normalized, nil
}

func containsInvalidPathRune(candidate string) bool {
	for _, r := range candidate {
		if r < 0x20 || r == 0x7f {
			return true
		}
	}

	return false
}

func containsDotPathSegment(candidate string) bool {
	for _, segment := range strings.Split(candidate, "/") {
		if segment == "." || segment == ".." {
			return true
		}
	}

	return false
}

func hashRemotePath(candidate string) string {
	sum := sha256.Sum256([]byte(candidate))
	return hex.EncodeToString(sum[:])
}
