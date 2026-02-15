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
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

const controlStreamReconnectDelay = 5 * time.Second

const (
	commandTypeMapperRun      = "mapper.run_job"
	commandTypeSweepRun       = "sweep.run_group"
	commandTypeTFTPReceive    = "tftp.start_receive"
	commandTypeTFTPServe      = "tftp.start_serve"
	commandTypeTFTPStop       = "tftp.stop_session"
	commandTypeTFTPStatus     = "tftp.status"
	commandTypeTFTPStageImage = "tftp.stage_image"
)

var errControlStreamClosed = errors.New("control stream closed")

type mapperRunPayload struct {
	JobID   string `json:"job_id"`
	JobName string `json:"job_name"`
}

type sweepRunPayload struct {
	SweepGroupID string `json:"sweep_group_id"`
}

// tftpReceivePayload is the payload for tftp.start_receive commands.
type tftpReceivePayload struct {
	SessionID        string `json:"session_id"`
	ExpectedFilename string `json:"expected_filename"`
	MaxFileSize      int64  `json:"max_file_size"`
	TimeoutSeconds   int64  `json:"timeout_seconds"`
	BindAddress      string `json:"bind_address,omitempty"`
	Port             int    `json:"port,omitempty"`
}

// tftpServePayload is the payload for tftp.start_serve commands.
type tftpServePayload struct {
	SessionID      string `json:"session_id"`
	ImageID        string `json:"image_id"`
	Filename       string `json:"filename"`
	ContentHash    string `json:"content_hash"`
	FileSize       int64  `json:"file_size"`
	TimeoutSeconds int64  `json:"timeout_seconds"`
	BindAddress    string `json:"bind_address,omitempty"`
	Port           int    `json:"port,omitempty"`
}

// tftpStopPayload is the payload for tftp.stop_session commands.
type tftpStopPayload struct {
	SessionID string `json:"session_id"`
}

// tftpStagePayload is the payload for tftp.stage_image commands.
type tftpStagePayload struct {
	SessionID   string `json:"session_id"`
	ImageID     string `json:"image_id"`
	ContentHash string `json:"content_hash"`
	FileSize    int64  `json:"file_size"`
}

type controlStreamSender struct {
	mu     sync.Mutex
	stream grpc.BidiStreamingClient[proto.ControlStreamRequest, proto.ControlStreamResponse]
	closed bool
}

func newControlStreamSender(stream grpc.BidiStreamingClient[proto.ControlStreamRequest, proto.ControlStreamResponse]) *controlStreamSender {
	return &controlStreamSender{stream: stream}
}

func (s *controlStreamSender) Send(req *proto.ControlStreamRequest) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errControlStreamClosed
	}
	return s.stream.Send(req)
}

func (s *controlStreamSender) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	_ = s.stream.CloseSend()
	s.mu.Unlock()
}

func (p *PushLoop) controlStreamLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-p.stopCh:
			return
		default:
		}

		if !p.isEnrolled() || !p.gateway.IsConnected() {
			time.Sleep(time.Second)
			continue
		}

		stream, err := p.gateway.ControlStream(ctx)
		if err != nil {
			p.logger.Warn().Err(err).Msg("Control stream connection failed")
			select {
			case <-ctx.Done():
				return
			case <-time.After(controlStreamReconnectDelay):
				continue
			}
		}

		sender := newControlStreamSender(stream)
		if err := p.sendControlHello(sender); err != nil {
			p.logger.Warn().Err(err).Msg("Failed to send control stream hello")
			sender.Close()
			select {
			case <-ctx.Done():
				return
			case <-time.After(controlStreamReconnectDelay):
				continue
			}
		}

		if err := p.handleControlStream(ctx, stream, sender); err != nil {
			if !errors.Is(err, io.EOF) {
				p.logger.Warn().Err(err).Msg("Control stream ended with error")
			}
		}

		sender.Close()

		select {
		case <-ctx.Done():
			return
		case <-time.After(controlStreamReconnectDelay):
			continue
		}
	}
}

func (p *PushLoop) sendControlHello(sender *controlStreamSender) error {
	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	partition := p.server.config.Partition
	p.server.mu.RUnlock()

	req := &proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_Hello{
			Hello: &proto.ControlStreamHello{
				AgentId:       agentID,
				Partition:     partition,
				Capabilities:  getAgentCapabilities(),
				ConfigVersion: p.getConfigVersion(),
			},
		},
	}

	return sender.Send(req)
}

func (p *PushLoop) handleControlStream(
	ctx context.Context,
	stream grpc.BidiStreamingClient[proto.ControlStreamRequest, proto.ControlStreamResponse],
	sender *controlStreamSender,
) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-p.stopCh:
			return context.Canceled
		default:
		}

		resp, err := stream.Recv()
		if err != nil {
			return err
		}

		if cmd := resp.GetCommand(); cmd != nil {
			p.handleCommand(ctx, cmd, sender)
			continue
		}

		if cfg := resp.GetConfig(); cfg != nil {
			p.applyConfigResponse(cfg, "control")
			_ = sender.Send(&proto.ControlStreamRequest{
				Payload: &proto.ControlStreamRequest_ConfigAck{
					ConfigAck: &proto.ConfigAck{
						ConfigVersion: cfg.ConfigVersion,
						Timestamp:     time.Now().Unix(),
					},
				},
			})
		}
	}
}

func (p *PushLoop) handleCommand(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	if cmd == nil {
		return
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("command_type", cmd.CommandType).
		Int("payload_bytes", len(cmd.PayloadJson)).
		Int64("ttl_seconds", cmd.TtlSeconds).
		Int64("created_at", cmd.CreatedAt).
		Msg("Received control command")

	_ = sender.Send(&proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_CommandAck{
			CommandAck: &proto.CommandAck{
				CommandId:   cmd.CommandId,
				CommandType: cmd.CommandType,
				Timestamp:   time.Now().Unix(),
				Message:     "command received",
			},
		},
	})

	if commandExpired(cmd) {
		p.logger.Warn().
			Str("command_id", cmd.CommandId).
			Str("command_type", cmd.CommandType).
			Msg("Dropping expired command")
		_ = sender.Send(commandResult(cmd, false, "command expired", nil))
		return
	}

	go func() {
		switch cmd.CommandType {
		case commandTypeMapperRun:
			p.handleMapperRun(ctx, cmd, sender)
		case commandTypeSweepRun:
			p.handleSweepRun(ctx, cmd, sender)
		case commandTypeTFTPReceive:
			p.handleTFTPReceive(ctx, cmd, sender)
		case commandTypeTFTPServe:
			p.handleTFTPServe(ctx, cmd, sender)
		case commandTypeTFTPStop:
			p.handleTFTPStop(ctx, cmd, sender)
		case commandTypeTFTPStatus:
			p.handleTFTPStatus(cmd, sender)
		case commandTypeTFTPStageImage:
			p.handleTFTPStageImage(ctx, cmd, sender)
		default:
			_ = sender.Send(commandResult(cmd, false, "unsupported command", nil))
		}
	}()
}

func (p *PushLoop) handleMapperRun(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	payload := mapperRunPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid mapper payload", nil))
			return
		}
	}

	if payload.JobName == "" {
		_ = sender.Send(commandResult(cmd, false, "missing job_name", nil))
		return
	}

	p.server.mu.RLock()
	mapperSvc := p.server.mapperService
	p.server.mu.RUnlock()

	if mapperSvc == nil {
		_ = sender.Send(commandResult(cmd, false, "mapper service unavailable", nil))
		return
	}

	discoveryID, err := mapperSvc.RunScheduledJob(ctx, payload.JobName)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	resultPayload := map[string]interface{}{
		"discovery_id": discoveryID,
		"job_id":       payload.JobID,
		"job_name":     payload.JobName,
	}

	_ = sender.Send(commandResult(cmd, true, "mapper run started", resultPayload))
}

func (p *PushLoop) handleSweepRun(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	payload := sweepRunPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			p.logger.Warn().
				Err(err).
				Str("command_id", cmd.CommandId).
				Str("command_type", cmd.CommandType).
				Msg("Invalid sweep command payload")
			_ = sender.Send(commandResult(cmd, false, "invalid sweep payload", nil))
			return
		}
	}

	if payload.SweepGroupID == "" {
		p.logger.Warn().
			Str("command_id", cmd.CommandId).
			Str("command_type", cmd.CommandType).
			Msg("Sweep command missing sweep_group_id")
		_ = sender.Send(commandResult(cmd, false, "missing sweep_group_id", nil))
		return
	}

	if err := p.runSweepGroup(ctx, payload.SweepGroupID); err != nil {
		p.logger.Warn().
			Err(err).
			Str("command_id", cmd.CommandId).
			Str("command_type", cmd.CommandType).
			Str("sweep_group_id", payload.SweepGroupID).
			Msg("Failed to run sweep group")
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("command_type", cmd.CommandType).
		Str("sweep_group_id", payload.SweepGroupID).
		Msg("Sweep run started")

	resultPayload := map[string]interface{}{
		"sweep_group_id": payload.SweepGroupID,
	}

	_ = sender.Send(commandResult(cmd, true, "sweep run started", resultPayload))
}

func (p *PushLoop) runSweepGroup(ctx context.Context, groupID string) error {
	p.server.mu.RLock()
	services := append([]Service(nil), p.server.services...)
	p.server.mu.RUnlock()

	for _, svc := range services {
		if runner, ok := svc.(interface {
			RunSweepGroup(context.Context, string) error
		}); ok {
			p.logger.Info().
				Str("sweep_group_id", groupID).
				Str("service", svc.Name()).
				Msg("Dispatching on-demand sweep run to service")
			return runner.RunSweepGroup(ctx, groupID)
		}
	}

	serviceNames := make([]string, 0, len(services))
	for _, svc := range services {
		serviceNames = append(serviceNames, svc.Name())
	}
	p.logger.Warn().
		Str("sweep_group_id", groupID).
		Strs("services", serviceNames).
		Msg("No sweep runner available for on-demand sweep")

	return errSweepRunnerUnavailable
}

func commandExpired(cmd *proto.CommandRequest) bool {
	if cmd == nil || cmd.TtlSeconds <= 0 || cmd.CreatedAt <= 0 {
		return false
	}

	expiry := time.Unix(cmd.CreatedAt, 0).Add(time.Duration(cmd.TtlSeconds) * time.Second)
	return time.Now().After(expiry)
}

func commandResult(cmd *proto.CommandRequest, success bool, message string, payload map[string]interface{}) *proto.ControlStreamRequest {
	var payloadJSON []byte
	if payload != nil {
		payloadJSON, _ = json.Marshal(payload)
	}

	return &proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_CommandResult{
			CommandResult: &proto.CommandResult{
				CommandId:   cmd.CommandId,
				CommandType: cmd.CommandType,
				Success:     success,
				Message:     message,
				PayloadJson: payloadJSON,
				Timestamp:   time.Now().Unix(),
			},
		},
	}
}

func commandProgress(cmd *proto.CommandRequest, percent int32, message string) *proto.ControlStreamRequest {
	return &proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_CommandProgress{
			CommandProgress: &proto.CommandProgress{
				CommandId:       cmd.CommandId,
				CommandType:     cmd.CommandType,
				ProgressPercent: percent,
				Message:         message,
				Timestamp:       time.Now().Unix(),
			},
		},
	}
}

func (p *PushLoop) getTFTPService() *TFTPService {
	p.server.mu.RLock()
	svc := p.server.tftpService
	p.server.mu.RUnlock()

	return svc
}

func (p *PushLoop) handleTFTPReceive(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	tftpSvc := p.getTFTPService()
	if tftpSvc == nil {
		_ = sender.Send(commandResult(cmd, false, "tftp service unavailable", nil))
		return
	}

	var payload tftpReceivePayload
	if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
		_ = sender.Send(commandResult(cmd, false, "invalid tftp receive payload", nil))
		return
	}

	if payload.SessionID == "" || payload.ExpectedFilename == "" {
		_ = sender.Send(commandResult(cmd, false, "missing session_id or expected_filename", nil))
		return
	}

	// Wire up callbacks to send progress/results back through the control stream.
	// After a successful receive, automatically upload the file to core storage.
	tftpSvc.SetCallbacks(
		func(sessionID string, bytesTransferred int64, message string) {
			progressMsg := fmt.Sprintf("[%s] %s (%d bytes)", sessionID, message, bytesTransferred)
			_ = sender.Send(commandProgress(cmd, 0, progressMsg))
		},
		func(sessionID string, success bool, message string, fileSize int64, contentHash string) {
			if !success {
				result := map[string]interface{}{
					"session_id":   sessionID,
					"file_size":    fileSize,
					"content_hash": contentHash,
				}
				_ = sender.Send(commandResult(cmd, false, message, result))
				return
			}

			// Upload the received file to core storage via gateway
			_ = sender.Send(commandProgress(cmd, 50, fmt.Sprintf("[%s] uploading to storage", sessionID)))

			filePath := tftpSvc.GetReceivedFilePath(sessionID, payload.ExpectedFilename)

			uploadResp, uploadErr := p.gateway.UploadFile(ctx, sessionID, payload.ExpectedFilename, filePath)

			result := map[string]interface{}{
				"session_id":   sessionID,
				"file_size":    fileSize,
				"content_hash": contentHash,
			}

			if uploadErr != nil {
				p.logger.Error().Err(uploadErr).
					Str("session_id", sessionID).
					Msg("Failed to upload received file")
				result["upload_error"] = uploadErr.Error()
				_ = sender.Send(commandResult(cmd, false, fmt.Sprintf("upload failed: %v", uploadErr), result))
				return
			}

			if uploadResp != nil && !uploadResp.Success {
				result["upload_error"] = uploadResp.Message
				_ = sender.Send(commandResult(cmd, false, fmt.Sprintf("upload rejected: %s", uploadResp.Message), result))
				return
			}

			result["uploaded"] = true
			_ = sender.Send(commandResult(cmd, true, "transfer and upload complete", result))

			// Clean up staging files after successful upload
			tftpSvc.CleanupStagingFiles(sessionID)
		},
	)

	if err := tftpSvc.StartReceive(ctx, payload); err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("session_id", payload.SessionID).
		Str("filename", payload.ExpectedFilename).
		Msg("TFTP receive session started")

	_ = sender.Send(commandProgress(cmd, 0, "tftp receive session started, listening"))
}

func (p *PushLoop) handleTFTPServe(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	tftpSvc := p.getTFTPService()
	if tftpSvc == nil {
		_ = sender.Send(commandResult(cmd, false, "tftp service unavailable", nil))
		return
	}

	var payload tftpServePayload
	if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
		_ = sender.Send(commandResult(cmd, false, "invalid tftp serve payload", nil))
		return
	}

	if payload.SessionID == "" || payload.Filename == "" {
		_ = sender.Send(commandResult(cmd, false, "missing session_id or filename", nil))
		return
	}

	// Wire up callbacks
	tftpSvc.SetCallbacks(
		func(sessionID string, bytesTransferred int64, message string) {
			progressMsg := fmt.Sprintf("[%s] %s (%d bytes)", sessionID, message, bytesTransferred)
			_ = sender.Send(commandProgress(cmd, 0, progressMsg))
		},
		func(sessionID string, success bool, message string, fileSize int64, contentHash string) {
			result := map[string]interface{}{
				"session_id":   sessionID,
				"file_size":    fileSize,
				"content_hash": contentHash,
			}
			_ = sender.Send(commandResult(cmd, success, message, result))
		},
	)

	if err := tftpSvc.StartServe(ctx, payload); err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("session_id", payload.SessionID).
		Str("filename", payload.Filename).
		Msg("TFTP serve session started")

	_ = sender.Send(commandProgress(cmd, 0, "tftp serve session started, listening"))
}

func (p *PushLoop) handleTFTPStop(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	tftpSvc := p.getTFTPService()
	if tftpSvc == nil {
		_ = sender.Send(commandResult(cmd, false, "tftp service unavailable", nil))
		return
	}

	var payload tftpStopPayload
	if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
		_ = sender.Send(commandResult(cmd, false, "invalid tftp stop payload", nil))
		return
	}

	if payload.SessionID == "" {
		_ = sender.Send(commandResult(cmd, false, "missing session_id", nil))
		return
	}

	if err := tftpSvc.stopSession(ctx, payload.SessionID); err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("session_id", payload.SessionID).
		Msg("TFTP session stopped")

	_ = sender.Send(commandResult(cmd, true, "session stopped", map[string]interface{}{
		"session_id": payload.SessionID,
	}))
}

func (p *PushLoop) handleTFTPStatus(cmd *proto.CommandRequest, sender *controlStreamSender) {
	tftpSvc := p.getTFTPService()
	if tftpSvc == nil {
		_ = sender.Send(commandResult(cmd, false, "tftp service unavailable", nil))
		return
	}

	tftpSvc.mu.RLock()
	session := tftpSvc.session
	tftpSvc.mu.RUnlock()

	if session == nil {
		_ = sender.Send(commandResult(cmd, true, "no active session", map[string]interface{}{
			"active": false,
		}))
		return
	}

	session.mu.RLock()
	result := map[string]interface{}{
		"active":            true,
		"session_id":        session.SessionID,
		"mode":              string(session.Mode),
		"expected_filename": session.ExpectedFilename,
		"bind_address":      session.BindAddress,
		"port":              session.Port,
		"bytes_transferred": session.bytesTransfer,
		"started_at":        session.started.Unix(),
		"elapsed_seconds":   int64(time.Since(session.started).Seconds()),
	}
	session.mu.RUnlock()

	_ = sender.Send(commandResult(cmd, true, "session active", result))
}

func (p *PushLoop) handleTFTPStageImage(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	tftpSvc := p.getTFTPService()
	if tftpSvc == nil {
		_ = sender.Send(commandResult(cmd, false, "tftp service unavailable", nil))
		return
	}

	var payload tftpStagePayload
	if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
		_ = sender.Send(commandResult(cmd, false, "invalid tftp stage payload", nil))
		return
	}

	if payload.SessionID == "" || payload.ImageID == "" {
		_ = sender.Send(commandResult(cmd, false, "missing session_id or image_id", nil))
		return
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("session_id", payload.SessionID).
		Str("image_id", payload.ImageID).
		Msg("TFTP stage image requested")

	// Create the staging directory for this session
	sessionDir := filepath.Join(tftpSvc.StagingDir(), payload.SessionID)
	if err := os.MkdirAll(sessionDir, 0o750); err != nil {
		_ = sender.Send(commandResult(cmd, false, fmt.Sprintf("create staging dir: %v", err), nil))
		return
	}

	_ = sender.Send(commandProgress(cmd, 10, fmt.Sprintf("[%s] downloading image from storage", payload.SessionID)))

	// Download the image via DownloadFile gRPC streaming RPC from gateway
	// The filename is derived from the image; for staging we use the image_id as a placeholder
	// and the actual filename will be determined by the serve command.
	imagePath := filepath.Join(sessionDir, payload.ImageID)

	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	p.server.mu.RUnlock()

	downloadReq := &proto.FileDownloadRequest{
		SessionId:    payload.SessionID,
		AgentId:      agentID,
		ImageId:      payload.ImageID,
		ExpectedHash: payload.ContentHash,
	}

	if err := p.gateway.DownloadFile(ctx, downloadReq, imagePath); err != nil {
		// Clean up on failure
		_ = os.RemoveAll(sessionDir)

		p.logger.Error().Err(err).
			Str("session_id", payload.SessionID).
			Str("image_id", payload.ImageID).
			Msg("Failed to download image for staging")

		_ = sender.Send(commandResult(cmd, false, fmt.Sprintf("download failed: %v", err), nil))
		return
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("session_id", payload.SessionID).
		Str("image_id", payload.ImageID).
		Str("image_path", imagePath).
		Msg("Image staged successfully")

	_ = sender.Send(commandResult(cmd, true, "image staged successfully", map[string]interface{}{
		"session_id":  payload.SessionID,
		"image_id":    payload.ImageID,
		"staging_dir": sessionDir,
		"image_path":  imagePath,
	}))
}
