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
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
)

var (
	ErrDesktopAdapterUnavailable = errors.New("desktop adapter unavailable")
	ErrDesktopAdapterClosed      = errors.New("desktop adapter closed")
)

// DesktopMediaSender is the adapter-facing media sink for SRDP screen updates.
// Implementations typically wrap the dedicated desktop media gRPC stream.
// Metadata and Payload may alias adapter-owned buffers; senders must
// synchronously serialize or copy bytes needed after SendDesktopMediaFrame
// returns and must not retain the frame slices.
type DesktopMediaSender interface {
	SendDesktopMediaFrame(context.Context, DesktopMediaFrame) error
}

type DesktopMediaAckHandler func(context.Context, DesktopMediaAck) error

// DesktopMediaAckHandlerRegistrar lets adapter-facing media sinks route
// browser/gateway backpressure acknowledgements back to protocol adapters.
type DesktopMediaAckHandlerRegistrar interface {
	SetDesktopMediaAckHandler(DesktopMediaAckHandler)
}

// DesktopAdapterInput receives browser control/input frames after the session
// guard has validated route, lifetime, redirection, and quota policy.
type DesktopAdapterInput interface {
	SendDesktopFrame(context.Context, DesktopFrame) error
}

// DesktopAdapterSession is an active protocol adapter instance. It owns the
// target connection and must release any per-session credential material during
// Close.
type DesktopAdapterSession interface {
	DesktopAdapterInput
	Close(context.Context, string) error
}

// DesktopRDPAdapter is the narrow seam for the future IronRDP bridge. Open
// receives an already-normalized, route-bound target and memory-only credential
// grant. Implementations must not persist credential material.
type DesktopRDPAdapter interface {
	Open(context.Context, DesktopAdapterOpenRequest) (DesktopAdapterSession, error)
}

type DesktopAdapterOpenRequest struct {
	SessionID        string
	ActorID          string
	LocalAgentID     string
	CurrentGatewayID string
	StartUnix        int64
	Target           DesktopTarget
	CredentialGrant  *DesktopCredentialGrant
	MediaSender      DesktopMediaSender
}

// DesktopAdapterRuntime validates a trusted desktop open frame and delegates to
// a concrete protocol adapter. It intentionally keeps validation outside the
// adapter implementation so every adapter enters through the same policy path.
type DesktopAdapterRuntime struct {
	LocalAgentID     string
	CurrentGatewayID string
	NowUnix          func() int64
	NowUnixNano      func() int64
	Adapter          DesktopRDPAdapter
}

func (r DesktopAdapterRuntime) OpenRDP(
	ctx context.Context,
	frame Frame,
	mediaSender DesktopMediaSender,
) (DesktopAdapterSession, error) {
	localAgentID := strings.TrimSpace(r.LocalAgentID)
	if localAgentID == "" {
		return nil, fmt.Errorf("%w: missing local agent binding", ErrInvalidDesktopTarget)
	}

	payload, err := DecodeDesktopOpenFrameForAgent(frame, localAgentID)
	if err != nil {
		return nil, err
	}
	if payload.Target.Protocol != ProtocolRDP {
		return nil, fmt.Errorf("%w: expected rdp target", ErrInvalidDesktopTarget)
	}

	nowUnix := r.nowUnix()
	guard, err := NewDesktopSessionGuard(frame.SessionID, payload.Target, nowUnix)
	if err != nil {
		cleanupDesktopOpenPayload(&payload)

		return nil, err
	}
	if err := ValidateDesktopRouteBinding(payload.Target, localAgentID, r.CurrentGatewayID); err != nil {
		cleanupDesktopOpenPayload(&payload)

		return nil, err
	}
	grant, err := ValidateDesktopOpenCredentialGrant(payload, frame.SessionID, nowUnix)
	if err != nil {
		cleanupDesktopOpenPayload(&payload)

		return nil, err
	}
	payload.CredentialGrant = grant
	if mediaSender == nil {
		cleanupDesktopOpenPayload(&payload)

		return nil, fmt.Errorf("%w: missing media sender", ErrInvalidDesktopTarget)
	}
	if r.Adapter == nil {
		cleanupDesktopOpenPayload(&payload)

		return nil, ErrDesktopAdapterUnavailable
	}

	guardedState := &guardedDesktopAdapterState{
		guard:            guard,
		localAgentID:     localAgentID,
		currentGatewayID: strings.TrimSpace(r.CurrentGatewayID),
		nowUnix:          r.nowUnix,
		nowUnixNano:      r.nowUnixNano,
	}

	session, err := r.Adapter.Open(ctx, DesktopAdapterOpenRequest{
		SessionID:        frame.SessionID,
		ActorID:          payload.ActorID,
		LocalAgentID:     localAgentID,
		CurrentGatewayID: strings.TrimSpace(r.CurrentGatewayID),
		StartUnix:        nowUnix,
		Target:           payload.Target,
		CredentialGrant:  payload.CredentialGrant,
		MediaSender:      &guardedDesktopMediaSender{inner: mediaSender, state: guardedState},
	})
	if err != nil {
		cleanupDesktopOpenPayload(&payload)

		return nil, err
	}
	if session == nil {
		cleanupDesktopOpenPayload(&payload)

		return nil, ErrDesktopAdapterUnavailable
	}

	cleanupDesktopOpenPayload(&payload)

	return &guardedDesktopAdapterSession{
		inner: session,
		state: guardedState,
	}, nil
}

func (r DesktopAdapterRuntime) nowUnix() int64 {
	if r.NowUnix != nil {
		return r.NowUnix()
	}

	return nowUnix()
}

func (r DesktopAdapterRuntime) nowUnixNano() int64 {
	if r.NowUnixNano != nil {
		return r.NowUnixNano()
	}

	return r.nowUnix() * desktopQuotaWindowNanos
}

type guardedDesktopAdapterState struct {
	mu               sync.Mutex
	guard            DesktopSessionGuard
	localAgentID     string
	currentGatewayID string
	nowUnix          func() int64
	nowUnixNano      func() int64
	closed           bool
}

type guardedDesktopAdapterSession struct {
	inner DesktopAdapterSession
	state *guardedDesktopAdapterState
}

func (s *guardedDesktopAdapterSession) SendDesktopFrame(ctx context.Context, frame DesktopFrame) error {
	if err := s.state.validateFrame(frame); err != nil {
		return err
	}

	return s.inner.SendDesktopFrame(ctx, frame)
}

func (s *guardedDesktopAdapterSession) Close(ctx context.Context, reason string) error {
	if !s.state.markClosed() {
		return nil
	}

	return s.inner.Close(ctx, reason)
}

type guardedDesktopMediaSender struct {
	inner DesktopMediaSender
	state *guardedDesktopAdapterState
}

func (s *guardedDesktopMediaSender) SendDesktopMediaFrame(ctx context.Context, frame DesktopMediaFrame) error {
	if err := s.state.validateMediaFrame(frame); err != nil {
		return err
	}

	return s.inner.SendDesktopMediaFrame(ctx, frame)
}

func (s *guardedDesktopMediaSender) SetDesktopMediaAckHandler(handler DesktopMediaAckHandler) {
	registrar, ok := s.inner.(DesktopMediaAckHandlerRegistrar)
	if !ok {
		return
	}

	registrar.SetDesktopMediaAckHandler(func(ctx context.Context, ack DesktopMediaAck) error {
		if err := s.state.validateMediaAck(ack); err != nil {
			return err
		}
		if handler == nil {
			return nil
		}

		return handler(ctx, ack)
	})
}

func (s *guardedDesktopAdapterState) validateFrame(frame DesktopFrame) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return ErrDesktopAdapterClosed
	}
	if err := s.guard.ValidateFrame(
		frame,
		s.localAgentID,
		s.currentGatewayID,
		s.nowUnix(),
		s.nowUnixNano(),
	); err != nil {
		return err
	}

	return nil
}

func (s *guardedDesktopAdapterState) validateMediaFrame(frame DesktopMediaFrame) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return ErrDesktopAdapterClosed
	}
	if err := s.guard.ValidateMediaFrame(
		frame,
		s.localAgentID,
		s.currentGatewayID,
		s.nowUnix(),
	); err != nil {
		return err
	}

	return nil
}

func (s *guardedDesktopAdapterState) validateMediaAck(ack DesktopMediaAck) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return ErrDesktopAdapterClosed
	}
	if err := s.guard.ValidateMediaAck(
		ack,
		ack.MediaSessionID,
		s.localAgentID,
		s.currentGatewayID,
		s.nowUnix(),
	); err != nil {
		return err
	}

	return nil
}

func (s *guardedDesktopAdapterState) markClosed() bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return false
	}
	s.closed = true

	return true
}

func cleanupDesktopOpenPayload(payload *DesktopOpenPayload) {
	if payload == nil || payload.CredentialGrant == nil {
		return
	}

	payload.CredentialGrant.DropSensitive()
}
