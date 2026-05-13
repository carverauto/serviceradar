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
)

func (p *PushLoop) handleFileTransferFrame(frame *proto.ConsoleFrame, sender *controlStreamSender) {
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

	p.remoteConsoleManager.HandleFileTransferFrame(context.Background(), frame, sender)
}

func (m *proxmoxConsoleManager) HandleFileTransferFrame(
	ctx context.Context,
	frame *proto.ConsoleFrame,
	sender proxmoxConsoleSender,
) {
	if frame == nil || frame.GetSessionId() == "" {
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

	_ = sendFileTransferProgress(sender, frame.GetSessionId(), request.TransferID, remoteaccess.FileTransferStatusStarted)

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

	result, err := adapter.Execute(ctx, cfg, request, nil, output)
	if err != nil {
		return result, err
	}
	if streamOutput != nil {
		return result, streamOutput.SendEOF()
	}

	return result, nil
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
	code := "failed"
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

	return sender.Send(consoleControlFrame(sessionID, frameType, data, "", 0, 0))
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
