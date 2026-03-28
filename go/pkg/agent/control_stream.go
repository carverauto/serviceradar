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
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/mtr"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

const controlStreamReconnectDelay = 5 * time.Second

const (
	commandTypeMapperRun       = "mapper.run_job"
	commandTypeSweepRun        = "sweep.run_group"
	commandTypeMtrRun          = "mtr.run"
	commandTypeCameraRelayOpen = "camera.open_relay"
	commandTypeCameraRelayStop = "camera.close_relay"
	commandTypeAgentUpdate     = "agent.update_release"
)

const defaultOnDemandMtrDeadline = 45 * time.Second
const defaultMaxConcurrentOnDemandMtr = 2

var errControlStreamClosed = errors.New("control stream closed")

type mapperRunPayload struct {
	JobID   string   `json:"job_id"`
	JobName string   `json:"job_name"`
	Seeds   []string `json:"seeds,omitempty"`
}

type sweepRunPayload struct {
	SweepGroupID string `json:"sweep_group_id"`
}

type mtrRunPayload struct {
	Target   string `json:"target"`
	Protocol string `json:"protocol,omitempty"`
	MaxHops  int    `json:"max_hops,omitempty"`
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

	if err := sender.Send(req); err != nil {
		return err
	}

	if err := p.sendPendingReleaseActivationReport(sender); err != nil {
		p.logger.Warn().Err(err).Msg("Failed to send pending release activation report")
	}

	return nil
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
		case commandTypeMtrRun:
			p.handleMtrRun(ctx, cmd, sender)
		case commandTypeCameraRelayOpen:
			p.handleCameraRelayOpen(ctx, cmd, sender)
		case commandTypeCameraRelayStop:
			p.handleCameraRelayStop(ctx, cmd, sender)
		case commandTypeAgentUpdate:
			p.handleAgentUpdateRelease(ctx, cmd, sender)
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

	var discoveryID string

	var err error
	if len(payload.Seeds) > 0 {
		discoveryID, err = mapperSvc.RunScheduledJobWithSeeds(ctx, payload.JobName, payload.Seeds)
	} else {
		discoveryID, err = mapperSvc.RunScheduledJob(ctx, payload.JobName)
	}
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	resultPayload := map[string]interface{}{
		"discovery_id": discoveryID,
		"job_id":       payload.JobID,
		"job_name":     payload.JobName,
	}
	if len(payload.Seeds) > 0 {
		resultPayload["seeds"] = payload.Seeds
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

func (p *PushLoop) handleMtrRun(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	if !p.tryAcquireOnDemandMtrSlot() {
		_ = sender.Send(commandResult(cmd, false, "agent busy: too many concurrent mtr traces", nil))
		return
	}
	defer p.releaseOnDemandMtrSlot()

	payload := mtrRunPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid mtr payload", nil))
			return
		}
	}

	if payload.Target == "" {
		_ = sender.Send(commandResult(cmd, false, "missing target", nil))
		return
	}

	runTimeout := commandTimeoutCap(cmd)
	if runTimeout <= 0 {
		_ = sender.Send(commandResult(cmd, false, "command deadline exceeded", nil))
		return
	}

	runCtx, cancel := context.WithTimeout(ctx, runTimeout)
	defer cancel()

	opts := onDemandMtrOptions(payload)
	trace, err := runOnDemandMtr(runCtx, opts, p.logger)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	traceJSON, err := json.Marshal(trace)
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, "failed to marshal trace", nil))
		return
	}

	resultPayload := map[string]any{
		"target": payload.Target,
		"trace":  json.RawMessage(traceJSON),
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("target", payload.Target).
		Bool("target_reached", trace.TargetReached).
		Int("total_hops", trace.TotalHops).
		Msg("On-demand MTR trace completed")

	_ = sender.Send(commandResult(cmd, true, "mtr trace completed", resultPayload))
}

func (p *PushLoop) handleCameraRelayOpen(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	if p.cameraRelayManager == nil {
		_ = sender.Send(commandResult(cmd, false, "camera relay manager unavailable", nil))
		return
	}

	payload := cameraRelayStartPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid camera relay payload", nil))
			return
		}
	}

	p.server.mu.RLock()
	agentID := p.server.config.AgentID
	p.server.mu.RUnlock()

	state, err := p.cameraRelayManager.Start(ctx, cameraRelaySessionSpec{
		RelaySessionID:     payload.RelaySessionID,
		AgentID:            agentID,
		GatewayID:          p.gateway.GetGatewayID(),
		CameraSourceID:     payload.CameraSourceID,
		StreamProfileID:    payload.StreamProfileID,
		LeaseToken:         payload.LeaseToken,
		PluginAssignmentID: payload.PluginAssignmentID,
		SourceURL:          payload.SourceURL,
		RTSPTransport:      payload.RTSPTransport,
		CodecHint:          payload.CodecHint,
		ContainerHint:      payload.ContainerHint,
		InsecureSkipVerify: payload.InsecureSkipVerify,
	})
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	_ = sender.Send(commandResult(cmd, true, "camera relay started", map[string]interface{}{
		"relay_session_id":      state.RelaySessionID,
		"media_ingest_id":       state.MediaIngestID,
		"lease_expires_at_unix": state.LeaseExpiresAtUnix,
	}))
}

func (p *PushLoop) handleCameraRelayStop(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	if p.cameraRelayManager == nil {
		_ = sender.Send(commandResult(cmd, false, "camera relay manager unavailable", nil))
		return
	}

	payload := cameraRelayStopPayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid camera relay stop payload", nil))
			return
		}
	}

	stopCtx, cancel := context.WithTimeout(ctx, defaultCameraRelayCloseTimeout)
	defer cancel()

	if err := p.cameraRelayManager.Stop(stopCtx, payload); err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), nil))
		return
	}

	_ = sender.Send(commandResult(cmd, true, "camera relay stopped", map[string]interface{}{
		"relay_session_id": payload.RelaySessionID,
	}))
}

func (p *PushLoop) handleAgentUpdateRelease(ctx context.Context, cmd *proto.CommandRequest, sender *controlStreamSender) {
	payload := releaseUpdatePayload{}
	if len(cmd.PayloadJson) > 0 {
		if err := json.Unmarshal(cmd.PayloadJson, &payload); err != nil {
			_ = sender.Send(commandResult(cmd, false, "invalid release update payload", map[string]interface{}{
				"status": "failed",
				"reason": "invalid_payload",
			}))
			return
		}
	}

	_ = sender.Send(commandProgress(cmd, 10, "downloading"))

	result, err := stageAgentRelease(ctx, payload, releaseStageConfig{})
	if err != nil {
		_ = sender.Send(commandResult(cmd, false, err.Error(), map[string]interface{}{
			"status": "failed",
			"reason": err.Error(),
		}))
		return
	}

	_ = sender.Send(commandProgress(cmd, 60, "verifying"))
	_ = sender.Send(commandProgress(cmd, 80, "staged"))

	updaterCmd := exec.CommandContext(
		ctx,
		AgentUpdaterPath(),
		"--runtime-root", result.RuntimeRoot,
		"--version", result.Version,
		"--command-id", cmd.CommandId,
		"--command-type", cmd.CommandType,
		"--rollback-deadline", "3m0s",
	)
	updaterCmd.Stdout = os.Stdout
	updaterCmd.Stderr = os.Stderr
	if err := updaterCmd.Run(); err != nil {
		_ = sender.Send(commandResult(cmd, false, "failed to prepare updater activation", map[string]interface{}{
			"status": "failed",
			"reason": err.Error(),
		}))
		return
	}

	p.logger.Info().
		Str("command_id", cmd.CommandId).
		Str("version", result.Version).
		Msg("Prepared agent updater activation")

	_ = sender.Send(commandProgress(cmd, 90, "switching"))
	_ = sender.Send(commandProgress(cmd, 95, "restarting"))

	go func() {
		time.Sleep(250 * time.Millisecond)
		_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
	}()
}

func (p *PushLoop) sendPendingReleaseActivationReport(sender *controlStreamSender) error {
	report, err := LoadReleaseActivationReport("")
	if err != nil || report == nil {
		return err
	}

	req := &proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_CommandResult{
			CommandResult: &proto.CommandResult{
				CommandId:   report.CommandID,
				CommandType: report.CommandType,
				Success:     report.Success,
				Message:     report.Message,
				Timestamp:   time.Now().Unix(),
			},
		},
	}
	if len(report.Payload) > 0 {
		req.GetCommandResult().PayloadJson, _ = json.Marshal(report.Payload)
	}

	if err := sender.Send(req); err != nil {
		return err
	}
	return ClearReleaseActivationReport("")
}

func (p *PushLoop) tryAcquireOnDemandMtrSlot() bool {
	if p == nil || p.mtrOnDemandSem == nil {
		return true
	}

	select {
	case p.mtrOnDemandSem <- struct{}{}:
		return true
	default:
		return false
	}
}

func (p *PushLoop) releaseOnDemandMtrSlot() {
	if p == nil || p.mtrOnDemandSem == nil {
		return
	}

	select {
	case <-p.mtrOnDemandSem:
	default:
	}
}

func onDemandMtrOptions(payload mtrRunPayload) mtr.Options {
	target := strings.TrimSpace(payload.Target)
	opts := mtr.DefaultOptions(target)

	if protocol := strings.TrimSpace(payload.Protocol); protocol != "" {
		opts.Protocol = mtr.ParseProtocol(strings.ToLower(protocol))
	}

	if payload.MaxHops > 0 {
		opts.MaxHops = clampInt(payload.MaxHops, mtrMaxHopsUpperBound)
	}

	return opts
}

func commandTimeoutCap(cmd *proto.CommandRequest) time.Duration {
	if defaultOnDemandMtrDeadline <= 0 {
		return 0
	}

	if cmd == nil || cmd.TtlSeconds <= 0 || cmd.CreatedAt <= 0 {
		return defaultOnDemandMtrDeadline
	}

	expiry := time.Unix(cmd.CreatedAt, 0).Add(time.Duration(cmd.TtlSeconds) * time.Second)
	remaining := time.Until(expiry)
	if remaining <= 0 {
		return 0
	}

	if remaining < defaultOnDemandMtrDeadline {
		return remaining
	}

	return defaultOnDemandMtrDeadline
}

func commandExpired(cmd *proto.CommandRequest) bool {
	if cmd == nil || cmd.TtlSeconds <= 0 || cmd.CreatedAt <= 0 {
		return false
	}

	expiry := time.Unix(cmd.CreatedAt, 0).Add(time.Duration(cmd.TtlSeconds) * time.Second)
	return time.Now().After(expiry)
}

func commandProgress(cmd *proto.CommandRequest, progressPercent int32, message string) *proto.ControlStreamRequest {
	return &proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_CommandProgress{
			CommandProgress: &proto.CommandProgress{
				CommandId:       cmd.CommandId,
				CommandType:     cmd.CommandType,
				ProgressPercent: progressPercent,
				Message:         message,
				Timestamp:       time.Now().Unix(),
			},
		},
	}
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
