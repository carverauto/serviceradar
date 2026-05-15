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
	if strings.TrimSpace(openResp.GetMediaSessionId()) != "" &&
		openResp.GetMediaSessionId() != normalized.MediaSessionID {
		return nil, fmt.Errorf("%w: media session mismatch", remoteaccess.ErrInvalidDesktopMediaFrame)
	}

	mediaIngestID := strings.TrimSpace(openResp.GetMediaIngestId())
	if mediaIngestID == "" {
		return nil, fmt.Errorf("%w: missing media ingest binding", remoteaccess.ErrInvalidDesktopMediaFrame)
	}

	stream, err := gateway.StreamDesktopMedia(ctx)
	if err != nil {
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
		reason = strings.TrimSpace(reason)
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
			s.recvErr <- fmt.Errorf("%w: %s", errDesktopMediaStreamClosed, strings.TrimSpace(closeMsg.GetReason()))

			return
		}
	}
}

func (s *desktopMediaGatewaySender) handleAck(ctx context.Context, ack remoteaccess.DesktopMediaAck) error {
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

	return cfg, nil
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
