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
	"encoding/json"
	"errors"
	"testing"
)

func TestFileTransferRequestPayloadValidatesBoundedIntent(t *testing.T) {
	t.Parallel()

	payload := FileTransferRequestPayload{
		Protocol:   ProtocolSFTP,
		TransferID: "transfer-1",
		SessionID:  "session-1",
		Operation:  FileTransferOperationDownload,
		Path:       "/var/log/syslog",
	}

	if err := payload.Validate(); err != nil {
		t.Fatalf("Validate returned error: %v", err)
	}

	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}

	forbidden := []string{
		"agent_id",
		"gateway_id",
		"target_host",
		"credential_rule_id",
		"credential_custody_mode",
		"recording_policy",
		"quota",
		"approval_id",
		"ssh",
	}
	for _, key := range forbidden {
		if _, ok := decoded[key]; ok {
			t.Fatalf("payload includes forbidden client-controlled field %q", key)
		}
	}
}

func TestFileTransferRequestPayloadRejectsInvalidValues(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		payload FileTransferRequestPayload
		want    error
	}{
		{
			name:    "transfer id",
			payload: FileTransferRequestPayload{SessionID: "session-1", Operation: FileTransferOperationList, Path: "/tmp"},
			want:    ErrInvalidFileTransferID,
		},
		{
			name:    "session id",
			payload: FileTransferRequestPayload{TransferID: "transfer-1", Operation: FileTransferOperationList, Path: "/tmp"},
			want:    ErrInvalidFileTransferSessionID,
		},
		{
			name: "protocol",
			payload: FileTransferRequestPayload{
				Protocol:   ProtocolSSH,
				TransferID: "transfer-1",
				SessionID:  "session-1",
				Operation:  FileTransferOperationList,
				Path:       "/tmp",
			},
			want: ErrUnsupportedProtocolAdapter,
		},
		{
			name:    "operation",
			payload: FileTransferRequestPayload{TransferID: "transfer-1", SessionID: "session-1", Operation: "sync", Path: "/tmp"},
			want:    ErrInvalidFileTransferOperation,
		},
		{
			name:    "path",
			payload: FileTransferRequestPayload{TransferID: "transfer-1", SessionID: "session-1", Operation: FileTransferOperationList},
			want:    ErrInvalidFileTransferPath,
		},
		{
			name:    "empty upload path",
			payload: FileTransferRequestPayload{TransferID: "transfer-1", SessionID: "session-1", Operation: FileTransferOperationUpload, Path: ""},
			want:    ErrInvalidFileTransferPath,
		},
		{
			name:    "blank upload path",
			payload: FileTransferRequestPayload{TransferID: "transfer-1", SessionID: "session-1", Operation: FileTransferOperationUpload, Path: "   "},
			want:    ErrInvalidFileTransferPath,
		},
		{
			name:    "empty download path",
			payload: FileTransferRequestPayload{TransferID: "transfer-1", SessionID: "session-1", Operation: FileTransferOperationDownload, Path: ""},
			want:    ErrInvalidFileTransferPath,
		},
		{
			name:    "missing download path",
			payload: FileTransferRequestPayload{TransferID: "transfer-1", SessionID: "session-1", Operation: FileTransferOperationDownload},
			want:    ErrInvalidFileTransferPath,
		},
		{
			name: "dot segment path",
			payload: FileTransferRequestPayload{
				TransferID: "transfer-1",
				SessionID:  "session-1",
				Operation:  FileTransferOperationList,
				Path:       "/tmp/../secret",
			},
			want: ErrInvalidFileTransferPath,
		},
		{
			name: "control byte path",
			payload: FileTransferRequestPayload{
				TransferID: "transfer-1",
				SessionID:  "session-1",
				Operation:  FileTransferOperationList,
				Path:       "/tmp/\x00secret",
			},
			want: ErrInvalidFileTransferPath,
		},
		{
			name: "rename destination",
			payload: FileTransferRequestPayload{
				TransferID: "transfer-1",
				SessionID:  "session-1",
				Operation:  FileTransferOperationRename,
				Path:       "/tmp/a",
			},
			want: ErrFileTransferDestinationMissing,
		},
		{
			name: "rename unsafe destination",
			payload: FileTransferRequestPayload{
				TransferID:      "transfer-1",
				SessionID:       "session-1",
				Operation:       FileTransferOperationRename,
				Path:            "/tmp/a",
				DestinationPath: "/tmp/./b",
			},
			want: ErrInvalidFileTransferPath,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			if err := tt.payload.Validate(); !errors.Is(err, tt.want) {
				t.Fatalf("Validate error = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestDirectionForOperation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		operation FileTransferOperation
		want      FileTransferDirection
	}{
		{operation: FileTransferOperationList, want: FileTransferDirectionRead},
		{operation: FileTransferOperationStat, want: FileTransferDirectionRead},
		{operation: FileTransferOperationDownload, want: FileTransferDirectionRead},
		{operation: FileTransferOperationUpload, want: FileTransferDirectionWrite},
		{operation: FileTransferOperationMkdir, want: FileTransferDirectionManage},
		{operation: FileTransferOperationRename, want: FileTransferDirectionManage},
		{operation: FileTransferOperationRemove, want: FileTransferDirectionManage},
		{operation: FileTransferOperationChmod, want: FileTransferDirectionManage},
		{operation: FileTransferOperationChown, want: FileTransferDirectionManage},
	}

	for _, tt := range tests {
		got, err := DirectionForOperation(tt.operation)
		if err != nil {
			t.Fatalf("DirectionForOperation(%q) returned error: %v", tt.operation, err)
		}
		if got != tt.want {
			t.Fatalf("DirectionForOperation(%q) = %q, want %q", tt.operation, got, tt.want)
		}
	}
}

func TestFileTransferChunkPayloadValidation(t *testing.T) {
	t.Parallel()

	if err := (FileTransferDataPayload{TransferID: "transfer-1", Sequence: 1}).Validate(); err != nil {
		t.Fatalf("data payload Validate returned error: %v", err)
	}
	if err := (FileTransferAckPayload{TransferID: "transfer-1", Sequence: 1}).Validate(); err != nil {
		t.Fatalf("ack payload Validate returned error: %v", err)
	}
	if err := (FileTransferDataPayload{TransferID: "transfer-1", Sequence: 0}).Validate(); !errors.Is(err, ErrInvalidFileTransferSequence) {
		t.Fatalf("data payload error = %v, want %v", err, ErrInvalidFileTransferSequence)
	}
	if err := (FileTransferAckPayload{TransferID: "transfer-1", Sequence: 1, Offset: -1}).Validate(); !errors.Is(err, ErrInvalidFileTransferOffset) {
		t.Fatalf("ack payload error = %v, want %v", err, ErrInvalidFileTransferOffset)
	}
}
