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
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	pkgsftp "github.com/pkg/sftp"
)

const defaultSFTPChunkBytes = 32 * 1024

var (
	ErrSFTPInputRequired                = errors.New("sftp input is required")
	ErrSFTPInputEmpty                   = errors.New("sftp upload file must not be empty")
	ErrSFTPOutputRequired               = errors.New("sftp output is required")
	ErrSFTPOperationMetadataRequired    = errors.New("sftp operation metadata is required")
	ErrSFTPDirectionOperationMismatch   = errors.New("sftp direction does not match operation")
	ErrUnsupportedFileTransferOperation = errors.New("unsupported file transfer operation")
)

// FileTransferEntry is safe directory or stat metadata returned by SFTP reads.
type FileTransferEntry struct {
	Name    string    `json:"name"`
	Path    string    `json:"path,omitempty"`
	Size    int64     `json:"size"`
	Mode    string    `json:"mode"`
	IsDir   bool      `json:"is_dir"`
	ModTime time.Time `json:"mod_time"`
}

// FileTransferResult returns transfer metadata without file contents.
type FileTransferResult struct {
	Outcome FileTransferOutcomePayload
	Entries []FileTransferEntry
}

// SFTPClient is the subset of github.com/pkg/sftp.Client used by the adapter.
type SFTPClient interface {
	io.Closer
	Chmod(path string, mode os.FileMode) error
	Chown(path string, uid int, gid int) error
	Create(path string) (SFTPFile, error)
	Lstat(path string) (os.FileInfo, error)
	Mkdir(path string) error
	Open(path string) (SFTPFile, error)
	ReadDir(path string) ([]os.FileInfo, error)
	RealPath(path string) (string, error)
	Remove(path string) error
	Rename(oldname string, newname string) error
	Stat(path string) (os.FileInfo, error)
}

// SFTPFile is the file handle subset used for upload and download.
type SFTPFile interface {
	io.Reader
	io.Writer
	io.Closer
}

// SFTPDialer opens an SFTP client using session-scoped SSH configuration.
type SFTPDialer func(context.Context, SSHConfig) (SFTPClient, error)

// SFTPAdapter executes policy-gated SFTP operations.
type SFTPAdapter struct {
	Dial           SFTPDialer
	Policy         FileTransferPolicy
	Approved       bool
	MaxChunkBytes  int
	ChmodMode      os.FileMode
	ChmodModeSet   bool
	ChownUID       int
	ChownGID       int
	ChownSet       bool
	KnownHostsPath string
}

// Execute runs one SFTP operation. File contents are streamed only through the
// supplied input/output handles and are not retained by the adapter.
func (a SFTPAdapter) Execute(
	ctx context.Context,
	cfg SSHConfig,
	request FileTransferRequestPayload,
	input io.Reader,
	output io.Writer,
) (FileTransferResult, error) {
	if err := validateSFTPRequestDirection(request); err != nil {
		return fileTransferErrorResult(request, FileTransferStatusDenied, err), err
	}

	dial := a.Dial
	if dial == nil {
		dial = a.defaultDial
	}

	client, err := dial(ctx, cfg)
	if err != nil {
		return fileTransferErrorResult(request, FileTransferStatusFailed, err), err
	}
	defer func() { _ = client.Close() }()

	decision, err := a.evaluatePolicy(client, request)
	if err != nil {
		return resultFromDecision(request, decision), err
	}

	result, err := a.executeAllowed(ctx, client, request, input, output)
	if err != nil {
		return fileTransferErrorResult(request, statusForTransferError(err), err), err
	}

	result.Outcome.RedactedPath = decision.RedactedPath
	result.Outcome.PathHash = decision.PathHash

	return result, nil
}

func (a SFTPAdapter) defaultDial(ctx context.Context, cfg SSHConfig) (SFTPClient, error) {
	cfg.KnownHostsPath = a.KnownHostsPath

	sshClient, err := DialSSHClient(ctx, cfg)
	if err != nil {
		return nil, err
	}

	client, err := pkgsftp.NewClient(sshClient)
	if err != nil {
		_ = sshClient.Close()

		return nil, err
	}

	return &sftpClientCloser{Client: client, sshClient: sshClient}, nil
}

type sftpClientCloser struct {
	*pkgsftp.Client
	sshClient io.Closer
}

func (c *sftpClientCloser) Create(path string) (SFTPFile, error) {
	return c.Client.Create(path)
}

func (c *sftpClientCloser) Open(path string) (SFTPFile, error) {
	return c.Client.Open(path)
}

func (c *sftpClientCloser) Close() error {
	err := c.Client.Close()
	sshErr := c.sshClient.Close()
	if err != nil {
		return err
	}

	return sshErr
}

func validateSFTPRequestDirection(request FileTransferRequestPayload) error {
	if err := request.Validate(); err != nil {
		return err
	}

	expected, err := DirectionForOperation(request.Operation)
	if err != nil {
		return err
	}
	if request.Direction != "" && request.Direction != expected {
		return fmt.Errorf("%w %q != %q", ErrSFTPDirectionOperationMismatch, request.Direction, expected)
	}

	return nil
}

func (a SFTPAdapter) evaluatePolicy(
	client SFTPClient,
	request FileTransferRequestPayload,
) (FileTransferPolicyDecision, error) {
	input := FileTransferPolicyInput{
		Request:  request,
		Approved: a.Approved,
	}

	if info, err := client.Lstat(request.Path); err == nil {
		input.Files = 1
		if !info.IsDir() {
			input.Bytes = info.Size()
		}
		if info.Mode()&os.ModeSymlink != 0 {
			input.HasSymlink = true
			if resolved, realPathErr := client.RealPath(request.Path); realPathErr == nil {
				input.ResolvedPath = resolved
				input.RealPathOK = true
			}
		}
	}

	return EvaluateFileTransferPolicy(input, a.Policy)
}

func (a SFTPAdapter) executeAllowed(
	ctx context.Context,
	client SFTPClient,
	request FileTransferRequestPayload,
	input io.Reader,
	output io.Writer,
) (FileTransferResult, error) {
	switch request.Operation {
	case FileTransferOperationList:
		return a.list(client, request)
	case FileTransferOperationStat:
		return a.stat(client, request)
	case FileTransferOperationDownload:
		return a.download(ctx, client, request, output)
	case FileTransferOperationUpload:
		return a.upload(ctx, client, request, input)
	case FileTransferOperationMkdir:
		return a.mkdir(client, request)
	case FileTransferOperationRename:
		return a.rename(client, request)
	case FileTransferOperationRemove:
		return a.remove(client, request)
	case FileTransferOperationChmod:
		return a.chmod(client, request)
	case FileTransferOperationChown:
		return a.chown(client, request)
	default:
		return FileTransferResult{}, fmt.Errorf("%w %q", ErrUnsupportedFileTransferOperation, request.Operation)
	}
}

func (a SFTPAdapter) list(client SFTPClient, request FileTransferRequestPayload) (FileTransferResult, error) {
	infos, err := client.ReadDir(request.Path)
	if err != nil {
		return FileTransferResult{}, err
	}
	if err := a.enforceRuntimeQuota(0, int64(len(infos))); err != nil {
		return FileTransferResult{}, err
	}

	entries := make([]FileTransferEntry, 0, len(infos))
	for _, info := range infos {
		entries = append(entries, fileTransferEntry(info, request.Path+"/"+info.Name()))
	}

	return completedResult(request, 0, int64(len(entries)), entries), nil
}

func (a SFTPAdapter) stat(client SFTPClient, request FileTransferRequestPayload) (FileTransferResult, error) {
	info, err := client.Stat(request.Path)
	if err != nil {
		return FileTransferResult{}, err
	}
	if err := a.enforceRuntimeQuota(info.Size(), 1); err != nil {
		return FileTransferResult{}, err
	}

	return completedResult(request, 0, 1, []FileTransferEntry{fileTransferEntry(info, request.Path)}), nil
}

func (a SFTPAdapter) download(
	ctx context.Context,
	client SFTPClient,
	request FileTransferRequestPayload,
	output io.Writer,
) (FileTransferResult, error) {
	if output == nil {
		return FileTransferResult{}, ErrSFTPOutputRequired
	}
	if err := a.enforceRuntimeQuota(0, 1); err != nil {
		return FileTransferResult{}, err
	}

	file, err := client.Open(request.Path)
	if err != nil {
		return FileTransferResult{}, err
	}
	defer func() { _ = file.Close() }()

	written, err := copyWithFileTransferQuota(ctx, output, file, a.Policy.MaxBytes, a.chunkBytes())
	if err != nil {
		return FileTransferResult{}, err
	}

	return completedResult(request, written, 1, nil), nil
}

func (a SFTPAdapter) upload(
	ctx context.Context,
	client SFTPClient,
	request FileTransferRequestPayload,
	input io.Reader,
) (FileTransferResult, error) {
	if input == nil {
		return FileTransferResult{}, ErrSFTPInputRequired
	}
	if err := a.enforceRuntimeQuota(0, 1); err != nil {
		return FileTransferResult{}, err
	}

	bufferedInput := bufio.NewReader(input)
	if _, err := bufferedInput.Peek(1); err != nil {
		if errors.Is(err, io.EOF) {
			return FileTransferResult{}, ErrSFTPInputEmpty
		}

		return FileTransferResult{}, fmt.Errorf("read sftp upload file: %w", err)
	}

	file, err := client.Create(request.Path)
	if err != nil {
		return FileTransferResult{}, err
	}

	written, copyErr := copyWithFileTransferQuota(ctx, file, bufferedInput, a.Policy.MaxBytes, a.chunkBytes())
	closeErr := file.Close()
	if copyErr != nil {
		_ = client.Remove(request.Path)

		return FileTransferResult{}, copyErr
	}
	if closeErr != nil {
		_ = client.Remove(request.Path)

		return FileTransferResult{}, closeErr
	}

	return completedResult(request, written, 1, nil), nil
}

func (a SFTPAdapter) mkdir(client SFTPClient, request FileTransferRequestPayload) (FileTransferResult, error) {
	if err := a.enforceRuntimeQuota(0, 1); err != nil {
		return FileTransferResult{}, err
	}
	if err := client.Mkdir(request.Path); err != nil {
		return FileTransferResult{}, err
	}

	return completedResult(request, 0, 1, nil), nil
}

func (a SFTPAdapter) rename(client SFTPClient, request FileTransferRequestPayload) (FileTransferResult, error) {
	if err := a.enforceRuntimeQuota(0, 1); err != nil {
		return FileTransferResult{}, err
	}
	if err := client.Rename(request.Path, request.DestinationPath); err != nil {
		return FileTransferResult{}, err
	}

	return completedResult(request, 0, 1, nil), nil
}

func (a SFTPAdapter) remove(client SFTPClient, request FileTransferRequestPayload) (FileTransferResult, error) {
	if err := a.enforceRuntimeQuota(0, 1); err != nil {
		return FileTransferResult{}, err
	}
	if err := client.Remove(request.Path); err != nil {
		return FileTransferResult{}, err
	}

	return completedResult(request, 0, 1, nil), nil
}

func (a SFTPAdapter) chmod(client SFTPClient, request FileTransferRequestPayload) (FileTransferResult, error) {
	if !a.ChmodModeSet {
		return FileTransferResult{}, ErrSFTPOperationMetadataRequired
	}
	if err := a.enforceRuntimeQuota(0, 1); err != nil {
		return FileTransferResult{}, err
	}
	if err := client.Chmod(request.Path, a.ChmodMode); err != nil {
		return FileTransferResult{}, err
	}

	return completedResult(request, 0, 1, nil), nil
}

func (a SFTPAdapter) chown(client SFTPClient, request FileTransferRequestPayload) (FileTransferResult, error) {
	if !a.ChownSet {
		return FileTransferResult{}, ErrSFTPOperationMetadataRequired
	}
	if err := a.enforceRuntimeQuota(0, 1); err != nil {
		return FileTransferResult{}, err
	}
	if err := client.Chown(request.Path, a.ChownUID, a.ChownGID); err != nil {
		return FileTransferResult{}, err
	}

	return completedResult(request, 0, 1, nil), nil
}

func (a SFTPAdapter) enforceRuntimeQuota(bytes int64, files int64) error {
	if bytes < 0 || files < 0 {
		return ErrFileTransferQuotaExceeded
	}
	if a.Policy.MaxBytes > 0 && bytes > a.Policy.MaxBytes {
		return ErrFileTransferQuotaExceeded
	}
	if a.Policy.MaxFiles > 0 && files > a.Policy.MaxFiles {
		return ErrFileTransferQuotaExceeded
	}

	return nil
}

func (a SFTPAdapter) chunkBytes() int {
	if a.MaxChunkBytes > 0 {
		return a.MaxChunkBytes
	}

	return defaultSFTPChunkBytes
}

func copyWithFileTransferQuota(
	ctx context.Context,
	dst io.Writer,
	src io.Reader,
	maxBytes int64,
	chunkBytes int,
) (int64, error) {
	buf := make([]byte, chunkBytes)
	var total int64

	for {
		if err := ctx.Err(); err != nil {
			return total, err
		}

		nr, readErr := src.Read(buf)
		if nr > 0 {
			nextTotal := total + int64(nr)
			if maxBytes > 0 && nextTotal > maxBytes {
				return total, ErrFileTransferQuotaExceeded
			}

			nw, writeErr := dst.Write(buf[:nr])
			total += int64(nw)
			if writeErr != nil {
				return total, writeErr
			}
			if nw != nr {
				return total, io.ErrShortWrite
			}
		}

		if errors.Is(readErr, io.EOF) {
			return total, nil
		}
		if readErr != nil {
			return total, readErr
		}
	}
}

func fileTransferEntry(info os.FileInfo, entryPath string) FileTransferEntry {
	return FileTransferEntry{
		Name:    info.Name(),
		Path:    entryPath,
		Size:    info.Size(),
		Mode:    info.Mode().String(),
		IsDir:   info.IsDir(),
		ModTime: info.ModTime(),
	}
}

func completedResult(
	request FileTransferRequestPayload,
	bytes int64,
	files int64,
	entries []FileTransferEntry,
) FileTransferResult {
	return FileTransferResult{
		Outcome: FileTransferOutcomePayload{
			TransferID:       request.TransferID,
			ApprovalID:       request.ApprovalID,
			Status:           FileTransferStatusCompleted,
			BytesTransferred: bytes,
			FilesTransferred: files,
		},
		Entries: entries,
	}
}

func resultFromDecision(
	request FileTransferRequestPayload,
	decision FileTransferPolicyDecision,
) FileTransferResult {
	return FileTransferResult{
		Outcome: FileTransferOutcomePayload{
			TransferID:    request.TransferID,
			ApprovalID:    request.ApprovalID,
			Status:        decision.Status,
			RedactedPath:  decision.RedactedPath,
			PathHash:      decision.PathHash,
			FailureReason: decision.Reason,
		},
	}
}

func fileTransferErrorResult(
	request FileTransferRequestPayload,
	status FileTransferStatus,
	err error,
) FileTransferResult {
	reason := ""
	if err != nil {
		reason = err.Error()
	}

	return FileTransferResult{
		Outcome: FileTransferOutcomePayload{
			TransferID:    request.TransferID,
			ApprovalID:    request.ApprovalID,
			Status:        status,
			FailureReason: reason,
		},
	}
}

func statusForTransferError(err error) FileTransferStatus {
	if errors.Is(err, ErrFileTransferQuotaExceeded) {
		return FileTransferStatusQuotaExhausted
	}

	return FileTransferStatusFailed
}
