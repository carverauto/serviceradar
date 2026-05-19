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
	"errors"
	"testing"
)

const (
	testTransferID      = "transfer-1"
	testTransferSession = "session-1"
	testAllowedRoot     = "/srv/data"
	testSecretRoot      = "/srv/data/secret"
	testReportPath      = "/srv/data/reports/report.txt"
)

func TestEvaluateFileTransferPolicyAllowsAndRedacts(t *testing.T) {
	t.Parallel()

	decision, err := EvaluateFileTransferPolicy(
		FileTransferPolicyInput{
			Request: fileTransferRequest(FileTransferOperationDownload, "/srv/data/secret/report.txt"),
			Bytes:   100,
			Files:   1,
		},
		FileTransferPolicy{
			AllowedOperations: []FileTransferOperation{FileTransferOperationDownload},
			AllowedPathRules:  []string{testAllowedRoot},
			RedactedPathRules: []string{testSecretRoot},
			MaxBytes:          200,
			MaxFiles:          1,
		},
	)
	if err != nil {
		t.Fatalf("EvaluateFileTransferPolicy returned error: %v", err)
	}
	if !decision.Allowed {
		t.Fatalf("decision = %#v", decision)
	}
	if decision.RedactedPath != fileTransferRedactedPath {
		t.Fatalf("RedactedPath = %q, want redacted", decision.RedactedPath)
	}
	if decision.PathHash == "" {
		t.Fatal("expected path hash")
	}
}

func TestEvaluateFileTransferPolicyDeniesOperationPathAndQuota(t *testing.T) {
	t.Parallel()

	policy := FileTransferPolicy{
		AllowedOperations: []FileTransferOperation{FileTransferOperationDownload},
		AllowedPathRules:  []string{testAllowedRoot},
		DeniedPathRules:   []string{testSecretRoot},
		MaxBytes:          10,
	}

	tests := []struct {
		name  string
		input FileTransferPolicyInput
		want  error
	}{
		{
			name:  "operation",
			input: FileTransferPolicyInput{Request: fileTransferRequest(FileTransferOperationUpload, testReportPath)},
			want:  ErrFileTransferPolicyDenied,
		},
		{
			name:  "denied path",
			input: FileTransferPolicyInput{Request: fileTransferRequest(FileTransferOperationDownload, "/srv/data/secret/key")},
			want:  ErrFileTransferPolicyDenied,
		},
		{
			name:  "outside root",
			input: FileTransferPolicyInput{Request: fileTransferRequest(FileTransferOperationDownload, "/etc/passwd")},
			want:  ErrFileTransferPolicyDenied,
		},
		{
			name: "quota",
			input: FileTransferPolicyInput{
				Request: fileTransferRequest(FileTransferOperationDownload, testReportPath),
				Bytes:   11,
			},
			want: ErrFileTransferQuotaExceeded,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			decision, err := EvaluateFileTransferPolicy(tt.input, policy)
			if !errors.Is(err, tt.want) {
				t.Fatalf("error = %v, want %v", err, tt.want)
			}
			if decision.Allowed {
				t.Fatalf("decision = %#v, want denied", decision)
			}
			if decision.RedactedPath != fileTransferRedactedPath {
				t.Fatalf("denied RedactedPath = %q, want redacted", decision.RedactedPath)
			}
		})
	}
}

func TestEvaluateFileTransferPolicyApproval(t *testing.T) {
	t.Parallel()

	policy := FileTransferPolicy{
		AllowedOperations: []FileTransferOperation{FileTransferOperationUpload},
		AllowedPathRules:  []string{testAllowedRoot},
		RequiresApproval:  true,
	}

	decision, err := EvaluateFileTransferPolicy(
		FileTransferPolicyInput{Request: fileTransferRequest(FileTransferOperationUpload, testReportPath)},
		policy,
	)
	if !errors.Is(err, ErrFileTransferApprovalRequired) {
		t.Fatalf("error = %v, want %v", err, ErrFileTransferApprovalRequired)
	}
	if decision.Status != FileTransferStatusApprovalPending {
		t.Fatalf("status = %q, want %q", decision.Status, FileTransferStatusApprovalPending)
	}

	decision, err = EvaluateFileTransferPolicy(
		FileTransferPolicyInput{
			Request:  fileTransferRequest(FileTransferOperationUpload, testReportPath),
			Approved: true,
		},
		policy,
	)
	if err != nil {
		t.Fatalf("approved EvaluateFileTransferPolicy returned error: %v", err)
	}
	if !decision.Allowed {
		t.Fatalf("decision = %#v, want allowed", decision)
	}
}

func TestEvaluateFileTransferPolicySymlinkModes(t *testing.T) {
	t.Parallel()

	basePolicy := FileTransferPolicy{
		AllowedOperations: []FileTransferOperation{FileTransferOperationDownload},
		AllowedPathRules:  []string{testAllowedRoot},
	}

	tests := []struct {
		name        string
		mode        FileTransferSymlinkMode
		resolved    string
		wantAllowed bool
	}{
		{name: "default deny", wantAllowed: false},
		{name: "explicit deny", mode: FileTransferSymlinkDeny, wantAllowed: false},
		{name: "follow inside root", mode: FileTransferSymlinkFollowInsideRoot, resolved: "/srv/data/real/report.txt", wantAllowed: true},
		{name: "follow unresolved symlink", mode: FileTransferSymlinkFollowInsideRoot, wantAllowed: false},
		{name: "follow outside root", mode: FileTransferSymlinkFollowInsideRoot, resolved: "/etc/passwd", wantAllowed: false},
		{name: "allow", mode: FileTransferSymlinkAllow, wantAllowed: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			policy := basePolicy
			policy.SymlinkMode = tt.mode

			decision, err := EvaluateFileTransferPolicy(
				FileTransferPolicyInput{
					Request:      fileTransferRequest(FileTransferOperationDownload, testReportPath),
					HasSymlink:   true,
					ResolvedPath: tt.resolved,
					RealPathOK:   tt.resolved != "",
				},
				policy,
			)
			if tt.wantAllowed && err != nil {
				t.Fatalf("EvaluateFileTransferPolicy returned error: %v", err)
			}
			if !tt.wantAllowed && !errors.Is(err, ErrFileTransferPolicyDenied) {
				t.Fatalf("error = %v, want %v", err, ErrFileTransferPolicyDenied)
			}
			if decision.Allowed != tt.wantAllowed {
				t.Fatalf("Allowed = %t, want %t", decision.Allowed, tt.wantAllowed)
			}
		})
	}
}

func TestEvaluateFileTransferPolicyFailsClosedWithoutPolicy(t *testing.T) {
	t.Parallel()

	_, err := EvaluateFileTransferPolicy(
		FileTransferPolicyInput{Request: fileTransferRequest(FileTransferOperationDownload, testReportPath)},
		FileTransferPolicy{},
	)
	if !errors.Is(err, ErrFileTransferPolicyUnavailable) {
		t.Fatalf("error = %v, want %v", err, ErrFileTransferPolicyUnavailable)
	}
}

func fileTransferRequest(operation FileTransferOperation, candidatePath string) FileTransferRequestPayload {
	return FileTransferRequestPayload{
		TransferID: testTransferID,
		SessionID:  testTransferSession,
		Operation:  operation,
		Path:       candidatePath,
	}
}
