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
	"sync"
	"time"

	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

const controlStreamReconnectDelay = 5 * time.Second

const (
	commandTypeMapperRun = "mapper.run_job"
	commandTypeSweepRun  = "sweep.run_group"
)

var errControlStreamClosed = errors.New("control stream closed")

type mapperRunPayload struct {
	JobID   string `json:"job_id"`
	JobName string `json:"job_name"`
}

type sweepRunPayload struct {
	SweepGroupID string `json:"sweep_group_id"`
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
