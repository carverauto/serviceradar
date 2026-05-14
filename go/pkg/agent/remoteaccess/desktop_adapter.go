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
)

var ErrDesktopAdapterUnavailable = errors.New("desktop adapter unavailable")

// DesktopMediaSender is the adapter-facing media sink for SRDP screen updates.
// Implementations typically wrap the dedicated desktop media gRPC stream.
type DesktopMediaSender interface {
	SendDesktopMediaFrame(context.Context, DesktopMediaFrame) error
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
	if _, err := NewDesktopSessionGuard(frame.SessionID, payload.Target, nowUnix); err != nil {
		cleanupDesktopOpenPayload(&payload)

		return nil, err
	}
	if err := ValidateDesktopRouteBinding(payload.Target, localAgentID, r.CurrentGatewayID); err != nil {
		cleanupDesktopOpenPayload(&payload)

		return nil, err
	}
	if payload.CredentialGrant != nil {
		grant, err := NormalizeDesktopCredentialGrantAt(*payload.CredentialGrant, payload.Target, nowUnix)
		if err != nil {
			cleanupDesktopOpenPayload(&payload)

			return nil, err
		}
		payload.CredentialGrant = &grant
	}
	if mediaSender == nil {
		cleanupDesktopOpenPayload(&payload)

		return nil, fmt.Errorf("%w: missing media sender", ErrInvalidDesktopTarget)
	}
	if r.Adapter == nil {
		cleanupDesktopOpenPayload(&payload)

		return nil, ErrDesktopAdapterUnavailable
	}

	session, err := r.Adapter.Open(ctx, DesktopAdapterOpenRequest{
		SessionID:        frame.SessionID,
		LocalAgentID:     localAgentID,
		CurrentGatewayID: strings.TrimSpace(r.CurrentGatewayID),
		StartUnix:        nowUnix,
		Target:           payload.Target,
		CredentialGrant:  payload.CredentialGrant,
		MediaSender:      mediaSender,
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

	return session, nil
}

func (r DesktopAdapterRuntime) nowUnix() int64 {
	if r.NowUnix != nil {
		return r.NowUnix()
	}

	return nowUnix()
}

func cleanupDesktopOpenPayload(payload *DesktopOpenPayload) {
	if payload == nil || payload.CredentialGrant == nil {
		return
	}

	payload.CredentialGrant.DropSensitive()
}
