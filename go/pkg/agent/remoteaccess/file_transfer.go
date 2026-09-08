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
	"fmt"
	"strings"
)

const (
	ProtocolSFTP = "sftp"

	FrameTypeFileTransferRequest  = "file_transfer_request"
	FrameTypeFileTransferProgress = "file_transfer_progress"
	FrameTypeFileTransferData     = "file_transfer_data"
	FrameTypeFileTransferAck      = "file_transfer_ack"
	FrameTypeFileTransferError    = "file_transfer_error"
	FrameTypeFileTransferOutcome  = "file_transfer_outcome"

	FileTransferOperationList     FileTransferOperation = "list"
	FileTransferOperationStat     FileTransferOperation = "stat"
	FileTransferOperationDownload FileTransferOperation = "download"
	FileTransferOperationUpload   FileTransferOperation = "upload"
	FileTransferOperationMkdir    FileTransferOperation = "mkdir"
	FileTransferOperationRename   FileTransferOperation = "rename"
	FileTransferOperationRemove   FileTransferOperation = "remove"
	FileTransferOperationChmod    FileTransferOperation = "chmod"
	FileTransferOperationChown    FileTransferOperation = "chown"

	FileTransferDirectionRead   FileTransferDirection = "read"
	FileTransferDirectionWrite  FileTransferDirection = "write"
	FileTransferDirectionManage FileTransferDirection = "manage"

	FileTransferStatusRequested       FileTransferStatus = "requested"
	FileTransferStatusStarted         FileTransferStatus = "started"
	FileTransferStatusInProgress      FileTransferStatus = "in_progress"
	FileTransferStatusCompleted       FileTransferStatus = "completed"
	FileTransferStatusDenied          FileTransferStatus = "denied"
	FileTransferStatusFailed          FileTransferStatus = "failed"
	FileTransferStatusCanceled        FileTransferStatus = "canceled"
	FileTransferStatusQuotaExhausted  FileTransferStatus = "quota_exhausted"
	FileTransferStatusApprovalPending FileTransferStatus = "approval_pending"
)

var (
	ErrInvalidFileTransferID          = errors.New("invalid file transfer id")
	ErrInvalidFileTransferSessionID   = errors.New("invalid file transfer session id")
	ErrInvalidFileTransferOperation   = errors.New("invalid file transfer operation")
	ErrInvalidFileTransferDirection   = errors.New("invalid file transfer direction")
	ErrInvalidFileTransferPath        = errors.New("invalid file transfer path")
	ErrFileTransferDestinationMissing = errors.New("file transfer destination path is required")
	ErrInvalidFileTransferSequence    = errors.New("invalid file transfer sequence")
	ErrInvalidFileTransferOffset      = errors.New("invalid file transfer offset")
)

// FileTransferOperation identifies a policy-gated remote filesystem action.
type FileTransferOperation string

// FileTransferDirection groups operations into read, write, and management
// buckets for RBAC, approval, quota, and recording policy.
type FileTransferDirection string

// FileTransferStatus is the stable status vocabulary used by frames, audit, and replay.
type FileTransferStatus string

// FileTransferRequestPayload is the JSON payload carried by
// FrameTypeFileTransferRequest. Route, agent, gateway, target host,
// credential, custody, recording, and approval override fields are not accepted
// from browser intent; the trusted control plane adds the policy snapshot and
// approval binding that the selected agent must enforce before it opens target
// file handles.
type FileTransferRequestPayload struct {
	Protocol        string                `json:"protocol,omitempty"`
	TransferID      string                `json:"transfer_id"`
	SessionID       string                `json:"session_id"`
	Operation       FileTransferOperation `json:"operation"`
	Direction       FileTransferDirection `json:"direction,omitempty"`
	Path            string                `json:"path"`
	DestinationPath string                `json:"destination_path,omitempty"`
	DisplayName     string                `json:"display_name,omitempty"`
	Policy          FileTransferPolicy    `json:"policy,omitempty"`
	Approved        bool                  `json:"approved,omitempty"`
	ApprovalID      string                `json:"approval_id,omitempty"`
}

// FileTransferProgressPayload reports transfer lifecycle progress. Payloads
// must contain counters and redacted/hashable path metadata only, never file contents.
type FileTransferProgressPayload struct {
	TransferID       string             `json:"transfer_id"`
	Status           FileTransferStatus `json:"status"`
	BytesTransferred int64              `json:"bytes_transferred,omitempty"`
	FilesTransferred int64              `json:"files_transferred,omitempty"`
	TotalBytes       int64              `json:"total_bytes,omitempty"`
	RedactedPath     string             `json:"redacted_path,omitempty"`
	PathHash         string             `json:"path_hash,omitempty"`
}

// FileTransferDataPayload carries a bounded chunk of file bytes. When this
// struct is JSON-encoded, Data is base64-encoded by encoding/json.
type FileTransferDataPayload struct {
	TransferID string `json:"transfer_id"`
	Sequence   uint64 `json:"sequence"`
	Offset     int64  `json:"offset"`
	Data       []byte `json:"data,omitempty"`
	EOF        bool   `json:"eof,omitempty"`
}

// FileTransferAckPayload acknowledges receipt or application of a data chunk.
type FileTransferAckPayload struct {
	TransferID string `json:"transfer_id"`
	Sequence   uint64 `json:"sequence"`
	Offset     int64  `json:"offset"`
}

// FileTransferErrorPayload reports a denied, failed, canceled, or quota-exhausted transfer.
type FileTransferErrorPayload struct {
	TransferID   string             `json:"transfer_id"`
	ApprovalID   string             `json:"approval_id,omitempty"`
	Status       FileTransferStatus `json:"status"`
	Code         string             `json:"code"`
	Message      string             `json:"message,omitempty"`
	RedactedPath string             `json:"redacted_path,omitempty"`
	PathHash     string             `json:"path_hash,omitempty"`
}

// FileTransferOutcomePayload reports the durable outcome metadata for audit and replay.
type FileTransferOutcomePayload struct {
	TransferID       string             `json:"transfer_id"`
	ApprovalID       string             `json:"approval_id,omitempty"`
	Status           FileTransferStatus `json:"status"`
	BytesTransferred int64              `json:"bytes_transferred,omitempty"`
	FilesTransferred int64              `json:"files_transferred,omitempty"`
	SHA256           string             `json:"sha256,omitempty"`
	RedactedPath     string             `json:"redacted_path,omitempty"`
	PathHash         string             `json:"path_hash,omitempty"`
	FailureReason    string             `json:"failure_reason,omitempty"`
}

// Validate verifies the bounded client intent schema before route/session context is applied.
func (p FileTransferRequestPayload) Validate() error {
	if strings.TrimSpace(p.TransferID) == "" {
		return ErrInvalidFileTransferID
	}
	if strings.TrimSpace(p.SessionID) == "" {
		return ErrInvalidFileTransferSessionID
	}
	if p.Protocol != "" && p.Protocol != ProtocolSFTP {
		return fmt.Errorf("%w %q", ErrUnsupportedProtocolAdapter, p.Protocol)
	}
	if !p.Operation.Valid() {
		return fmt.Errorf("%w %q", ErrInvalidFileTransferOperation, p.Operation)
	}
	if p.Direction != "" && !p.Direction.Valid() {
		return fmt.Errorf("%w %q", ErrInvalidFileTransferDirection, p.Direction)
	}
	if strings.TrimSpace(p.Path) == "" {
		return ErrInvalidFileTransferPath
	}
	if _, err := normalizeRemotePath(p.Path); err != nil {
		return err
	}
	if p.Operation == FileTransferOperationRename && strings.TrimSpace(p.DestinationPath) == "" {
		return ErrFileTransferDestinationMissing
	}
	if strings.TrimSpace(p.DestinationPath) != "" {
		if _, err := normalizeRemotePath(p.DestinationPath); err != nil {
			return err
		}
	}

	return nil
}

// DirectionForOperation returns the default RBAC/policy direction for an operation.
func DirectionForOperation(operation FileTransferOperation) (FileTransferDirection, error) {
	switch operation {
	case FileTransferOperationList, FileTransferOperationStat, FileTransferOperationDownload:
		return FileTransferDirectionRead, nil
	case FileTransferOperationUpload:
		return FileTransferDirectionWrite, nil
	case FileTransferOperationMkdir, FileTransferOperationRename, FileTransferOperationRemove,
		FileTransferOperationChmod, FileTransferOperationChown:
		return FileTransferDirectionManage, nil
	default:
		return "", fmt.Errorf("%w %q", ErrInvalidFileTransferOperation, operation)
	}
}

// Valid returns true when the operation is part of the first SFTP slice.
func (o FileTransferOperation) Valid() bool {
	switch o {
	case FileTransferOperationList, FileTransferOperationStat, FileTransferOperationDownload,
		FileTransferOperationUpload, FileTransferOperationMkdir, FileTransferOperationRename,
		FileTransferOperationRemove, FileTransferOperationChmod, FileTransferOperationChown:
		return true
	default:
		return false
	}
}

// Valid returns true when the direction maps to a file-transfer RBAC group.
func (d FileTransferDirection) Valid() bool {
	switch d {
	case FileTransferDirectionRead, FileTransferDirectionWrite, FileTransferDirectionManage:
		return true
	default:
		return false
	}
}

// Validate verifies the chunk acknowledgement schema.
func (p FileTransferAckPayload) Validate() error {
	if strings.TrimSpace(p.TransferID) == "" {
		return ErrInvalidFileTransferID
	}
	if p.Sequence == 0 {
		return ErrInvalidFileTransferSequence
	}
	if p.Offset < 0 {
		return ErrInvalidFileTransferOffset
	}

	return nil
}

// Validate verifies the chunk data schema.
func (p FileTransferDataPayload) Validate() error {
	if strings.TrimSpace(p.TransferID) == "" {
		return ErrInvalidFileTransferID
	}
	if p.Sequence == 0 {
		return ErrInvalidFileTransferSequence
	}
	if p.Offset < 0 {
		return ErrInvalidFileTransferOffset
	}

	return nil
}
