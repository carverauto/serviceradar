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
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errRemoteFileTransferInvalidPayload  = errors.New("invalid remote file-transfer payload")
	errRemoteFileTransferSessionMismatch = errors.New(
		"remote file-transfer session_id does not match frame",
	)
	errRemoteFileTransferSessionNotActive = errors.New("remote file-transfer SSH session is not active")
	errRemoteFileTransferAlreadyActive    = errors.New("remote file-transfer is already active")
	errRemoteFileTransferUploadNotActive  = errors.New("remote file-transfer upload is not active")
)

func (p *PushLoop) handleFileTransferFrame(
	ctx context.Context,
	frame *proto.ConsoleFrame,
	sender *controlStreamSender,
) {
	if frame.GetSessionId() == "" {
		return
	}

	if p.remoteConsoleManager == nil {
		p.remoteConsoleManager = newRemoteConsoleManagerWithRoute(
			p.agentID(),
			gatewayIDFromClient(p.gateway),
			p.logger,
		)
		p.remoteConsoleManager.sshOptions.KnownHostsPath = remoteAccessKnownHostsFile(p.server)
	}

	p.remoteConsoleManager.HandleFileTransferFrame(ctx, frame, sender)
}

func (m *proxmoxConsoleManager) HandleFileTransferFrame(
	ctx context.Context,
	frame *proto.ConsoleFrame,
	sender proxmoxConsoleSender,
) {
	if frame == nil || frame.GetSessionId() == "" {
		return
	}

	sender = m.signingSender(sender)

	if frame.GetFrameType() == remoteaccess.FrameTypeFileTransferData {
		m.handleFileTransferDataFrame(frame, sender)
		return
	}

	request, err := decodeFileTransferRequest(frame)
	if err != nil {
		sendFileTransferError(sender, frame.GetSessionId(), "", remoteaccess.FileTransferStatusFailed, err)
		return
	}

	if request.SessionID != frame.GetSessionId() {
		sendFileTransferError(
			sender,
			frame.GetSessionId(),
			request.TransferID,
			remoteaccess.FileTransferStatusFailed,
			errRemoteFileTransferSessionMismatch,
		)
		return
	}

	cfg, ok := m.getSSHConfig(frame.GetSessionId())
	if !ok {
		sendFileTransferError(
			sender,
			frame.GetSessionId(),
			request.TransferID,
			remoteaccess.FileTransferStatusFailed,
			errRemoteFileTransferSessionNotActive,
		)
		return
	}

	if request.Operation == remoteaccess.FileTransferOperationUpload {
		m.startUploadFileTransfer(ctx, cfg, request, sender)
		return
	}

	_ = sendFileTransferProgress(
		sender,
		frame.GetSessionId(),
		request.TransferID,
		remoteaccess.FileTransferStatusStarted,
	)

	result, err := m.executeFileTransfer(ctx, cfg, request, sender)
	if err != nil {
		status := result.Outcome.Status
		if status == "" {
			status = remoteaccess.FileTransferStatusFailed
		}
		sendFileTransferError(sender, frame.GetSessionId(), request.TransferID, status, err)
		return
	}

	sendFileTransferOutcome(sender, frame.GetSessionId(), result)
}

func (m *proxmoxConsoleManager) startUploadFileTransfer(
	ctx context.Context,
	cfg remoteaccess.SSHConfig,
	request remoteaccess.FileTransferRequestPayload,
	sender proxmoxConsoleSender,
) {
	ctx, cancel := context.WithCancel(ctx)
	reader, writer := io.Pipe()
	upload := &fileTransferUpload{writer: writer, cancel: cancel}
	if !m.registerFileTransferUpload(request.SessionID, request.TransferID, upload) {
		cancel()
		_ = reader.Close()
		_ = writer.Close()
		sendFileTransferError(
			sender,
			request.SessionID,
			request.TransferID,
			remoteaccess.FileTransferStatusFailed,
			errRemoteFileTransferAlreadyActive,
		)
		return
	}
	go func() {
		<-ctx.Done()
		_ = writer.CloseWithError(ctx.Err())
	}()

	_ = sendFileTransferProgress(
		sender,
		request.SessionID,
		request.TransferID,
		remoteaccess.FileTransferStatusStarted,
	)

	go func() {
		defer m.unregisterFileTransferUpload(request.SessionID, request.TransferID)
		defer func() { _ = reader.Close() }()

		result, err := m.executeFileTransferWithInput(ctx, cfg, request, reader, sender)
		if err != nil {
			status := result.Outcome.Status
			if status == "" {
				status = remoteaccess.FileTransferStatusFailed
			}
			sendFileTransferError(sender, request.SessionID, request.TransferID, status, err)
			return
		}

		sendFileTransferOutcome(sender, request.SessionID, result)
	}()
}

func (m *proxmoxConsoleManager) handleFileTransferDataFrame(
	frame *proto.ConsoleFrame,
	sender proxmoxConsoleSender,
) {
	var payload remoteaccess.FileTransferDataPayload
	if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
		sendFileTransferError(
			sender,
			frame.GetSessionId(),
			"",
			remoteaccess.FileTransferStatusFailed,
			fmt.Errorf("%w: %w", errRemoteFileTransferInvalidPayload, err),
		)
		return
	}
	if err := payload.Validate(); err != nil {
		sendFileTransferError(sender, frame.GetSessionId(), payload.TransferID, remoteaccess.FileTransferStatusFailed, err)
		return
	}

	upload, ok := m.getFileTransferUpload(frame.GetSessionId(), payload.TransferID)
	if !ok {
		sendFileTransferError(
			sender,
			frame.GetSessionId(),
			payload.TransferID,
			remoteaccess.FileTransferStatusFailed,
			errRemoteFileTransferUploadNotActive,
		)
		return
	}

	if err := upload.Write(payload); err != nil {
		m.unregisterFileTransferUpload(frame.GetSessionId(), payload.TransferID)
		sendFileTransferError(sender, frame.GetSessionId(), payload.TransferID, remoteaccess.FileTransferStatusFailed, err)
	}
}

func decodeFileTransferRequest(frame *proto.ConsoleFrame) (remoteaccess.FileTransferRequestPayload, error) {
	var request remoteaccess.FileTransferRequestPayload
	if err := json.Unmarshal(frame.GetData(), &request); err != nil {
		return request, fmt.Errorf("%w: %w", errRemoteFileTransferInvalidPayload, err)
	}
	if err := request.Validate(); err != nil {
		return request, err
	}
	return request, nil
}

func (m *proxmoxConsoleManager) executeFileTransfer(
	ctx context.Context,
	cfg remoteaccess.SSHConfig,
	request remoteaccess.FileTransferRequestPayload,
	sender proxmoxConsoleSender,
) (remoteaccess.FileTransferResult, error) {
	return m.executeFileTransferWithInput(ctx, cfg, request, nil, sender)
}

func (m *proxmoxConsoleManager) executeFileTransferWithInput(
	ctx context.Context,
	cfg remoteaccess.SSHConfig,
	request remoteaccess.FileTransferRequestPayload,
	input io.Reader,
	sender proxmoxConsoleSender,
) (remoteaccess.FileTransferResult, error) {
	adapter := remoteaccess.SFTPAdapter{
		Dial:           m.sftpDialer,
		Policy:         request.Policy,
		Approved:       request.Approved,
		KnownHostsPath: cfg.KnownHostsPath,
	}

	var output io.Writer
	var streamOutput *fileTransferFrameWriter
	if request.Operation == remoteaccess.FileTransferOperationDownload {
		streamOutput = &fileTransferFrameWriter{
			sender:     sender,
			sessionID:  request.SessionID,
			transferID: request.TransferID,
		}
		output = streamOutput
	}

	result, err := adapter.Execute(ctx, cfg, request, input, output)
	if err != nil {
		return result, err
	}
	if streamOutput != nil {
		return result, streamOutput.SendEOF()
	}

	return result, nil
}

type fileTransferUpload struct {
	writer       *io.PipeWriter
	cancel       context.CancelFunc
	nextSequence uint64
	nextOffset   int64
}

func (u *fileTransferUpload) Write(payload remoteaccess.FileTransferDataPayload) error {
	if payload.Sequence != u.nextSequence+1 {
		_ = u.writer.CloseWithError(remoteaccess.ErrInvalidFileTransferSequence)
		return remoteaccess.ErrInvalidFileTransferSequence
	}
	if payload.Offset != u.nextOffset {
		_ = u.writer.CloseWithError(remoteaccess.ErrInvalidFileTransferOffset)
		return remoteaccess.ErrInvalidFileTransferOffset
	}

	u.nextSequence = payload.Sequence

	if len(payload.Data) > 0 {
		written, err := u.writer.Write(payload.Data)
		u.nextOffset += int64(written)
		if err != nil {
			return err
		}
		if written != len(payload.Data) {
			err := io.ErrShortWrite
			_ = u.writer.CloseWithError(err)
			return err
		}
	}

	if payload.EOF {
		return u.writer.Close()
	}

	return nil
}

func (m *proxmoxConsoleManager) registerFileTransferUpload(
	sessionID string,
	transferID string,
	upload *fileTransferUpload,
) bool {
	if m == nil || sessionID == "" || transferID == "" || upload == nil {
		return false
	}

	m.uploadMu.Lock()
	defer m.uploadMu.Unlock()
	if m.uploads == nil {
		m.uploads = make(map[string]*fileTransferUpload)
	}
	key := fileTransferUploadKey(sessionID, transferID)
	if _, exists := m.uploads[key]; exists {
		return false
	}
	m.uploads[key] = upload
	return true
}

func (m *proxmoxConsoleManager) getFileTransferUpload(sessionID string, transferID string) (*fileTransferUpload, bool) {
	if m == nil || sessionID == "" || transferID == "" {
		return nil, false
	}

	m.uploadMu.Lock()
	defer m.uploadMu.Unlock()
	upload, ok := m.uploads[fileTransferUploadKey(sessionID, transferID)]
	return upload, ok
}

func (m *proxmoxConsoleManager) unregisterFileTransferUpload(sessionID string, transferID string) {
	if m == nil || sessionID == "" || transferID == "" {
		return
	}

	m.uploadMu.Lock()
	upload, ok := m.uploads[fileTransferUploadKey(sessionID, transferID)]
	if ok {
		delete(m.uploads, fileTransferUploadKey(sessionID, transferID))
	}
	m.uploadMu.Unlock()

	if ok {
		if upload.cancel != nil {
			upload.cancel()
		}
		_ = upload.writer.Close()
	}
}

func fileTransferUploadKey(sessionID string, transferID string) string {
	return sessionID + "\x00" + transferID
}

type fileTransferFrameWriter struct {
	sender     proxmoxConsoleSender
	sessionID  string
	transferID string
	sequence   uint64
	offset     int64
}

func (w *fileTransferFrameWriter) Write(data []byte) (int, error) {
	if len(data) == 0 {
		return 0, nil
	}

	w.sequence++
	payload := remoteaccess.FileTransferDataPayload{
		TransferID: w.transferID,
		Sequence:   w.sequence,
		Offset:     w.offset,
		Data:       append([]byte(nil), data...),
	}
	if err := sendJSONFileTransferFrame(w.sender, w.sessionID, remoteaccess.FrameTypeFileTransferData, payload); err != nil {
		return 0, err
	}

	w.offset += int64(len(data))
	return len(data), nil
}

func (w *fileTransferFrameWriter) SendEOF() error {
	w.sequence++
	return sendJSONFileTransferFrame(w.sender, w.sessionID, remoteaccess.FrameTypeFileTransferData,
		remoteaccess.FileTransferDataPayload{
			TransferID: w.transferID,
			Sequence:   w.sequence,
			Offset:     w.offset,
			EOF:        true,
		})
}

func sendFileTransferProgress(
	sender proxmoxConsoleSender,
	sessionID string,
	transferID string,
	status remoteaccess.FileTransferStatus,
) error {
	return sendJSONFileTransferFrame(sender, sessionID, remoteaccess.FrameTypeFileTransferProgress,
		remoteaccess.FileTransferProgressPayload{
			TransferID: transferID,
			Status:     status,
		})
}

func sendFileTransferOutcome(
	sender proxmoxConsoleSender,
	sessionID string,
	result remoteaccess.FileTransferResult,
) {
	payload := fileTransferOutcomeResponse{
		FileTransferOutcomePayload: result.Outcome,
		Entries:                    result.Entries,
	}
	_ = sendJSONFileTransferFrame(sender, sessionID, remoteaccess.FrameTypeFileTransferOutcome, payload)
}

func sendFileTransferError(
	sender proxmoxConsoleSender,
	sessionID string,
	transferID string,
	status remoteaccess.FileTransferStatus,
	err error,
) {
	code := string(remoteaccess.FileTransferStatusFailed)
	if status != "" {
		code = strings.ReplaceAll(string(status), " ", "_")
	}

	_ = sendJSONFileTransferFrame(sender, sessionID, remoteaccess.FrameTypeFileTransferError,
		remoteaccess.FileTransferErrorPayload{
			TransferID: transferID,
			Status:     status,
			Code:       code,
			Message:    errorString(err),
		})
}

func sendJSONFileTransferFrame(
	sender proxmoxConsoleSender,
	sessionID string,
	frameType string,
	payload any,
) error {
	if sender == nil {
		return nil
	}

	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	return sender.Send(consoleControlFrame(sessionID, frameType, data, "", 0, 0, 0, "", ""))
}

type fileTransferOutcomeResponse struct {
	remoteaccess.FileTransferOutcomePayload
	Entries []remoteaccess.FileTransferEntry `json:"entries,omitempty"`
}

func errorString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
