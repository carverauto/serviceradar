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
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errDesktopMediaGatewayRequired = errors.New("desktop media gateway is required")
	errDesktopMediaStreamClosed    = errors.New("desktop media stream is closed")
	errDesktopMediaSessionRejected = errors.New("desktop media session rejected")
)

type desktopMediaGateway interface {
	OpenDesktopMediaSession(
		context.Context,
		*proto.OpenDesktopMediaSessionRequest,
	) (*proto.OpenDesktopMediaSessionResponse, error)
	StreamDesktopMedia(context.Context) (desktopMediaStream, error)
	CloseDesktopMediaSession(
		context.Context,
		*proto.CloseDesktopMediaSessionRequest,
	) (*proto.CloseDesktopMediaSessionResponse, error)
}

type desktopMediaStream interface {
	Send(*proto.DesktopMediaClientMessage) error
	Recv() (*proto.DesktopMediaServerMessage, error)
	CloseSend() error
}

type desktopMediaGatewaySenderConfig struct {
	DesktopSessionID            string
	MediaSessionID              string
	AgentID                     string
	GatewayID                   string
	TargetID                    string
	RouteID                     string
	LeaseToken                  string
	EncodingHint                string
	RequestedInitialCreditBytes uint32
	RequestedMaxChunkBytes      uint32
}

type desktopMediaGatewaySender struct {
	stream        desktopMediaStream
	gateway       desktopMediaGateway
	ackHandler    remoteaccess.DesktopMediaAckHandler
	ackMu         sync.RWMutex
	recvDone      chan struct{}
	recvErr       chan error
	desktopID     string
	mediaID       string
	mediaIngest   string
	agentID       string
	gatewayID     string
	maxChunkBytes uint32
	sendMu        sync.Mutex
	closeOnce     sync.Once
	closeErr      error
	closed        bool
}

func newDesktopMediaGatewaySender(
	ctx context.Context,
	gateway desktopMediaGateway,
	cfg desktopMediaGatewaySenderConfig,
	ackHandler remoteaccess.DesktopMediaAckHandler,
) (*desktopMediaGatewaySender, error) {
	if gateway == nil {
		return nil, errDesktopMediaGatewayRequired
	}

	normalized, err := normalizeDesktopMediaGatewaySenderConfig(cfg)
	if err != nil {
		return nil, err
	}

	openResp, err := gateway.OpenDesktopMediaSession(ctx, &proto.OpenDesktopMediaSessionRequest{
		DesktopSessionId:            normalized.DesktopSessionID,
		MediaSessionId:              normalized.MediaSessionID,
		AgentId:                     normalized.AgentID,
		GatewayId:                   normalized.GatewayID,
		TargetId:                    normalized.TargetID,
		RouteId:                     normalized.RouteID,
		LeaseToken:                  normalized.LeaseToken,
		RequestedInitialCreditBytes: normalized.RequestedInitialCreditBytes,
		RequestedMaxChunkBytes:      normalized.RequestedMaxChunkBytes,
		EncodingHint:                normalized.EncodingHint,
	})
	if err != nil {
		return nil, err
	}
	if openResp == nil {
		return nil, fmt.Errorf("%w: empty gateway response", errDesktopMediaSessionRejected)
	}
	if !openResp.GetAccepted() {
		return nil, fmt.Errorf("%w: %s", errDesktopMediaSessionRejected, strings.TrimSpace(openResp.GetMessage()))
	}
	responseMediaSessionID := strings.TrimSpace(openResp.GetMediaSessionId())
	mediaIngestID := strings.TrimSpace(openResp.GetMediaIngestId())
	if openResp.GetMaxChunkBytes() > remoteaccess.DesktopMaxFrameData {
		err := fmt.Errorf("%w: gateway max chunk exceeds desktop policy", remoteaccess.ErrInvalidDesktopMediaFrame)
		if closeErr := closeAcceptedDesktopMediaGatewaySession(
			ctx,
			gateway,
			normalized,
			responseMediaSessionID,
			mediaIngestID,
			"desktop media gateway max chunk rejected",
		); closeErr != nil {
			return nil, errors.Join(err, closeErr)
		}

		return nil, err
	}
	if responseMediaSessionID != "" && responseMediaSessionID != normalized.MediaSessionID {
		err := fmt.Errorf("%w: media session mismatch", remoteaccess.ErrInvalidDesktopMediaFrame)
		if closeErr := closeAcceptedDesktopMediaGatewaySession(
			ctx,
			gateway,
			normalized,
			responseMediaSessionID,
			mediaIngestID,
			"desktop media session binding rejected",
		); closeErr != nil {
			return nil, errors.Join(err, closeErr)
		}

		return nil, err
	}

	if mediaIngestID == "" {
		err := fmt.Errorf("%w: missing media ingest binding", remoteaccess.ErrInvalidDesktopMediaFrame)
		if closeErr := closeAcceptedDesktopMediaGatewaySession(
			ctx,
			gateway,
			normalized,
			responseMediaSessionID,
			mediaIngestID,
			"desktop media ingest binding rejected",
		); closeErr != nil {
			return nil, errors.Join(err, closeErr)
		}

		return nil, err
	}

	stream, err := gateway.StreamDesktopMedia(ctx)
	if err != nil {
		if closeErr := closeAcceptedDesktopMediaGatewaySession(
			ctx,
			gateway,
			normalized,
			responseMediaSessionID,
			mediaIngestID,
			"desktop media stream open failed",
		); closeErr != nil {
			return nil, errors.Join(err, closeErr)
		}

		return nil, err
	}
	if stream == nil {
		err := fmt.Errorf("%w: empty desktop media stream", errDesktopMediaSessionRejected)
		if closeErr := closeAcceptedDesktopMediaGatewaySession(
			ctx,
			gateway,
			normalized,
			responseMediaSessionID,
			mediaIngestID,
			"desktop media stream open failed",
		); closeErr != nil {
			return nil, errors.Join(err, closeErr)
		}

		return nil, err
	}

	sender := &desktopMediaGatewaySender{
		stream:      stream,
		gateway:     gateway,
		ackHandler:  ackHandler,
		recvDone:    make(chan struct{}),
		recvErr:     make(chan error, 1),
		desktopID:   normalized.DesktopSessionID,
		mediaID:     normalized.MediaSessionID,
		mediaIngest: mediaIngestID,
		agentID:     normalized.AgentID,
		gatewayID:   normalized.GatewayID,
		maxChunkBytes: desktopMediaMaxChunkBytes(
			openResp.GetMaxChunkBytes(),
			normalized.RequestedMaxChunkBytes,
		),
	}

	go sender.recvLoop()

	return sender, nil
}

func (s *desktopMediaGatewaySender) SendDesktopMediaFrame(ctx context.Context, frame remoteaccess.DesktopMediaFrame) error {
	if s == nil {
		return errDesktopMediaGatewayRequired
	}
	if err := s.validateFrame(frame); err != nil {
		return err
	}

	msg := &proto.DesktopMediaClientMessage{
		Message: &proto.DesktopMediaClientMessage_Frame{
			Frame: &proto.DesktopMediaFrameChunk{
				DesktopSessionId:  frame.SessionBindingID,
				MediaSessionId:    frame.MediaSessionID,
				MediaIngestId:     s.mediaIngest,
				AgentId:           s.agentID,
				Sequence:          frame.Sequence,
				TimestampUnixNano: frame.TimestampUnixNano,
				Width:             frame.Width,
				Height:            frame.Height,
				PayloadFamily:     frame.PayloadFamily,
				Encoding:          frame.Encoding,
				Metadata:          frame.Metadata,
				Payload:           frame.Payload,
				Flags:             uint32(frame.Flags),
			},
		},
	}

	return s.send(ctx, msg)
}

func (s *desktopMediaGatewaySender) Close(ctx context.Context, reason string) error {
	if s == nil {
		return nil
	}

	s.closeOnce.Do(func() {
		s.sendMu.Lock()
		defer s.sendMu.Unlock()

		s.closed = true
		reason = normalizeDesktopMediaTerminalReason(reason)
		closeMsg := &proto.DesktopMediaClientMessage{
			Message: &proto.DesktopMediaClientMessage_Close{
				Close: &proto.DesktopMediaStreamClose{
					DesktopSessionId: s.desktopID,
					MediaSessionId:   s.mediaID,
					MediaIngestId:    s.mediaIngest,
					AgentId:          s.agentID,
					GatewayId:        s.gatewayID,
					Reason:           reason,
				},
			},
		}
		sendErr := s.stream.Send(closeMsg)
		closeSendErr := s.stream.CloseSend()
		_, closeSessionErr := s.gateway.CloseDesktopMediaSession(ctx, &proto.CloseDesktopMediaSessionRequest{
			DesktopSessionId: s.desktopID,
			MediaSessionId:   s.mediaID,
			MediaIngestId:    s.mediaIngest,
			AgentId:          s.agentID,
			GatewayId:        s.gatewayID,
			Reason:           reason,
		})
		s.closeErr = errors.Join(sendErr, closeSendErr, closeSessionErr)
	})

	return s.closeErr
}

func (s *desktopMediaGatewaySender) RecvErr() <-chan error {
	if s == nil {
		return nil
	}

	return s.recvErr
}

func (s *desktopMediaGatewaySender) SetDesktopMediaAckHandler(handler remoteaccess.DesktopMediaAckHandler) {
	if s == nil {
		return
	}

	s.ackMu.Lock()
	s.ackHandler = handler
	s.ackMu.Unlock()
}

func (s *desktopMediaGatewaySender) validateFrame(frame remoteaccess.DesktopMediaFrame) error {
	if frame.SessionBindingID != s.desktopID {
		return fmt.Errorf("%w: desktop session mismatch", remoteaccess.ErrInvalidDesktopMediaFrame)
	}
	if frame.MediaSessionID != s.mediaID {
		return fmt.Errorf("%w: media session mismatch", remoteaccess.ErrInvalidDesktopMediaFrame)
	}
	if err := remoteaccess.ValidateDesktopMediaFrame(frame, desktopMediaGatewaySenderValidationPolicy()); err != nil {
		return err
	}

	cost := uint64(len(frame.Metadata)) + uint64(len(frame.Payload))
	if cost > uint64(s.maxChunkBytes) {
		return fmt.Errorf("%w: frame exceeds gateway chunk limit", remoteaccess.ErrInvalidDesktopMediaFrame)
	}

	return nil
}

func (s *desktopMediaGatewaySender) send(ctx context.Context, msg *proto.DesktopMediaClientMessage) error {
	if ctx != nil {
		if err := ctx.Err(); err != nil {
			return err
		}
	}

	s.sendMu.Lock()
	defer s.sendMu.Unlock()

	if s.closed {
		return errDesktopMediaStreamClosed
	}

	return s.stream.Send(msg)
}

func (s *desktopMediaGatewaySender) recvLoop() {
	defer close(s.recvDone)

	for {
		msg, err := s.stream.Recv()
		if err != nil {
			if !errors.Is(err, io.EOF) {
				s.recvErr <- err
			}

			return
		}

		if ack := msg.GetAck(); ack != nil {
			if err := s.validateInboundAck(ack); err != nil {
				s.recvErr <- err

				return
			}

			converted := remoteaccess.DesktopMediaAck{
				SessionBindingID: ack.GetDesktopSessionId(),
				MediaSessionID:   ack.GetMediaSessionId(),
				LastAcceptedSeq:  ack.GetLastAcceptedSequence(),
				CreditBytes:      uint64(ack.GetCreditBytes()),
				QualityLevel:     desktopMediaQualityFromProto(ack.GetQualityLevel()),
				Pause:            ack.GetPause(),
				Resume:           ack.GetResume(),
				CloseReason:      ack.GetCloseReason(),
			}
			if err := s.handleAck(context.Background(), converted); err != nil {
				s.recvErr <- err

				return
			}
		}

		if closeMsg := msg.GetClose(); closeMsg != nil {
			if err := s.validateInboundClose(closeMsg); err != nil {
				s.recvErr <- err

				return
			}

			reason := normalizeDesktopMediaTerminalReason(closeMsg.GetReason())
			if reason == "" {
				reason = "desktop media stream closed"
			}
			s.recvErr <- fmt.Errorf("%w: %s", errDesktopMediaStreamClosed, reason)

			return
		}
	}
}

func (s *desktopMediaGatewaySender) validateInboundAck(ack *proto.DesktopMediaAck) error {
	switch {
	case ack.GetDesktopSessionId() != s.desktopID:
		return fmt.Errorf("%w: desktop session mismatch", remoteaccess.ErrInvalidDesktopMediaAck)
	case ack.GetMediaSessionId() != s.mediaID:
		return fmt.Errorf("%w: media session mismatch", remoteaccess.ErrInvalidDesktopMediaAck)
	case ack.GetMediaIngestId() != s.mediaIngest:
		return fmt.Errorf("%w: media ingest mismatch", remoteaccess.ErrInvalidDesktopMediaAck)
	case ack.GetGatewayId() != s.gatewayID:
		return fmt.Errorf("%w: gateway mismatch", remoteaccess.ErrInvalidDesktopMediaAck)
	default:
		return nil
	}
}

func (s *desktopMediaGatewaySender) validateInboundClose(closeMsg *proto.DesktopMediaStreamClose) error {
	switch {
	case closeMsg.GetDesktopSessionId() != s.desktopID:
		return fmt.Errorf("%w: desktop session mismatch", remoteaccess.ErrInvalidDesktopMediaFrame)
	case closeMsg.GetMediaSessionId() != s.mediaID:
		return fmt.Errorf("%w: media session mismatch", remoteaccess.ErrInvalidDesktopMediaFrame)
	case closeMsg.GetMediaIngestId() != s.mediaIngest:
		return fmt.Errorf("%w: media ingest mismatch", remoteaccess.ErrInvalidDesktopMediaFrame)
	case closeMsg.GetAgentId() != s.agentID:
		return fmt.Errorf("%w: agent mismatch", remoteaccess.ErrInvalidDesktopMediaFrame)
	case closeMsg.GetGatewayId() != s.gatewayID:
		return fmt.Errorf("%w: gateway mismatch", remoteaccess.ErrInvalidDesktopMediaFrame)
	default:
		return nil
	}
}

func normalizeDesktopMediaTerminalReason(reason string) string {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return ""
	}

	var out strings.Builder
	for _, r := range reason {
		if r < ' ' || r == 0x7f {
			r = ' '
		}

		next := string(r)
		if out.Len()+len(next) > remoteaccess.DesktopMediaMaxCloseReason {
			break
		}
		out.WriteString(next)
	}

	return strings.TrimSpace(out.String())
}

func (s *desktopMediaGatewaySender) handleAck(ctx context.Context, ack remoteaccess.DesktopMediaAck) error {
	if err := remoteaccess.ValidateDesktopMediaAck(ack, s.desktopID, s.mediaID); err != nil {
		return err
	}
	ack.CloseReason = normalizeDesktopMediaTerminalReason(ack.CloseReason)

	s.ackMu.RLock()
	handler := s.ackHandler
	s.ackMu.RUnlock()

	if handler == nil {
		return nil
	}

	return handler(ctx, ack)
}

func normalizeDesktopMediaGatewaySenderConfig(
	cfg desktopMediaGatewaySenderConfig,
) (desktopMediaGatewaySenderConfig, error) {
	cfg.DesktopSessionID = strings.TrimSpace(cfg.DesktopSessionID)
	cfg.MediaSessionID = strings.TrimSpace(cfg.MediaSessionID)
	cfg.AgentID = strings.TrimSpace(cfg.AgentID)
	cfg.GatewayID = strings.TrimSpace(cfg.GatewayID)
	cfg.TargetID = strings.TrimSpace(cfg.TargetID)
	cfg.RouteID = strings.TrimSpace(cfg.RouteID)
	cfg.LeaseToken = strings.TrimSpace(cfg.LeaseToken)
	cfg.EncodingHint = strings.TrimSpace(cfg.EncodingHint)

	switch {
	case cfg.DesktopSessionID == "":
		return cfg, fmt.Errorf("%w: missing desktop session id", remoteaccess.ErrInvalidDesktopMediaFrame)
	case cfg.MediaSessionID == "":
		return cfg, fmt.Errorf("%w: missing media session id", remoteaccess.ErrInvalidDesktopMediaFrame)
	case cfg.AgentID == "":
		return cfg, fmt.Errorf("%w: missing agent id", remoteaccess.ErrInvalidDesktopMediaFrame)
	case cfg.GatewayID == "":
		return cfg, fmt.Errorf("%w: missing gateway id", remoteaccess.ErrInvalidDesktopMediaFrame)
	case cfg.TargetID == "":
		return cfg, fmt.Errorf("%w: missing target id", remoteaccess.ErrInvalidDesktopMediaFrame)
	case cfg.RouteID == "":
		return cfg, fmt.Errorf("%w: missing route id", remoteaccess.ErrInvalidDesktopMediaFrame)
	case cfg.LeaseToken == "":
		return cfg, fmt.Errorf("%w: missing lease token", remoteaccess.ErrInvalidDesktopMediaFrame)
	}

	if cfg.RequestedInitialCreditBytes == 0 {
		cfg.RequestedInitialCreditBytes = remoteaccess.DesktopMediaDefaultInitialCreditBytes
	}
	if cfg.RequestedMaxChunkBytes == 0 {
		cfg.RequestedMaxChunkBytes = remoteaccess.DesktopMediaDefaultMaxChunkBytes
	}
	if cfg.RequestedMaxChunkBytes > remoteaccess.DesktopMaxFrameData {
		return cfg, fmt.Errorf("%w: requested max chunk exceeds desktop policy", remoteaccess.ErrInvalidDesktopMediaFrame)
	}

	return cfg, nil
}

func closeAcceptedDesktopMediaGatewaySession(
	ctx context.Context,
	gateway desktopMediaGateway,
	cfg desktopMediaGatewaySenderConfig,
	mediaSessionID string,
	mediaIngestID string,
	reason string,
) error {
	mediaSessionID = strings.TrimSpace(mediaSessionID)
	if mediaSessionID == "" {
		mediaSessionID = cfg.MediaSessionID
	}
	mediaIngestID = strings.TrimSpace(mediaIngestID)

	_, err := gateway.CloseDesktopMediaSession(ctx, &proto.CloseDesktopMediaSessionRequest{
		DesktopSessionId: cfg.DesktopSessionID,
		MediaSessionId:   mediaSessionID,
		MediaIngestId:    mediaIngestID,
		AgentId:          cfg.AgentID,
		GatewayId:        cfg.GatewayID,
		Reason:           normalizeDesktopMediaTerminalReason(reason),
	})

	return err
}

func desktopMediaMaxChunkBytes(responseMax uint32, requestedMax uint32) uint32 {
	switch {
	case responseMax != 0:
		return responseMax
	case requestedMax != 0:
		return requestedMax
	default:
		return remoteaccess.DesktopMediaDefaultMaxChunkBytes
	}
}

func desktopMediaQualityFromProto(quality uint32) string {
	switch quality {
	case 1:
		return remoteaccess.DesktopMediaQualityLow
	default:
		return remoteaccess.DesktopMediaQualityAuto
	}
}

func desktopMediaGatewaySenderValidationPolicy() remoteaccess.DesktopScreenPolicy {
	return remoteaccess.DesktopScreenPolicy{
		MaxWidth:  remoteaccess.DesktopMaxWidth,
		MaxHeight: remoteaccess.DesktopMaxHeight,
	}
}
