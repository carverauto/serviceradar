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
	"fmt"
	"strings"
)

const desktopQuotaWindowNanos int64 = 1_000_000_000

// DesktopFrameQuotaWindow tracks per-second screen update quotas for adapter
// code before the dedicated desktop media stream carries production traffic.
type DesktopFrameQuotaWindow struct {
	policy              DesktopScreenPolicy
	windowStartUnixNano int64
	frameCount          uint32
	bitCount            uint64
}

// DesktopSessionGuard centralizes the per-frame checks an adapter must perform
// while a desktop session is active. It keeps route binding, lifetime,
// redirection policy, and update-frame quotas on one path so adapter code does
// not accidentally validate only part of the session contract.
type DesktopSessionGuard struct {
	sessionID        string
	target           DesktopTarget
	startUnix        int64
	lastActivityUnix int64
	quota            DesktopFrameQuotaWindow
}

func NewDesktopFrameQuotaWindow(policy DesktopScreenPolicy) DesktopFrameQuotaWindow {
	return DesktopFrameQuotaWindow{policy: normalizeDesktopScreenPolicy(policy)}
}

func NewDesktopSessionGuard(sessionID string, target DesktopTarget, startUnix int64) (DesktopSessionGuard, error) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return DesktopSessionGuard{}, fmt.Errorf("%w: missing session binding", ErrInvalidDesktopFrame)
	}
	if startUnix <= 0 {
		return DesktopSessionGuard{}, fmt.Errorf("%w: invalid session timestamp", ErrInvalidDesktopFrame)
	}

	target, err := NormalizeDesktopTarget(target)
	if err != nil {
		return DesktopSessionGuard{}, err
	}

	return DesktopSessionGuard{
		sessionID:        sessionID,
		target:           target,
		startUnix:        startUnix,
		lastActivityUnix: startUnix,
		quota:            NewDesktopFrameQuotaWindow(target.Screen),
	}, nil
}

func (g *DesktopSessionGuard) SessionID() string {
	if g == nil {
		return ""
	}

	return g.sessionID
}

func (g *DesktopSessionGuard) Target() DesktopTarget {
	if g == nil {
		return DesktopTarget{}
	}

	return g.target
}

func (g *DesktopSessionGuard) LastActivityUnix() int64 {
	if g == nil {
		return 0
	}

	return g.lastActivityUnix
}

// ValidateFrame applies the current session guard before an adapter consumes or
// emits a desktop frame. Accepted frames update last-activity time after all
// validation and quota checks succeed.
func (g *DesktopSessionGuard) ValidateFrame(
	frame DesktopFrame,
	localAgentID string,
	currentGatewayID string,
	nowUnix int64,
	nowUnixNano int64,
) error {
	if g == nil {
		return fmt.Errorf("%w: missing session guard", ErrInvalidDesktopFrame)
	}
	if frame.SessionID != g.sessionID {
		return fmt.Errorf("%w: session binding mismatch", ErrInvalidDesktopFrame)
	}
	if err := validateDesktopRouteBindingNormalized(g.target, localAgentID, currentGatewayID); err != nil {
		return err
	}
	if err := ValidateDesktopSessionLifetime(g.target.Screen, g.startUnix, g.lastActivityUnix, nowUnix); err != nil {
		return err
	}
	if err := ValidateDesktopFrameWithPolicy(frame, g.target.Screen, g.target.Redirection); err != nil {
		return err
	}
	if err := g.quota.Consume(frame, nowUnixNano); err != nil {
		return err
	}

	g.lastActivityUnix = nowUnix

	return nil
}

// ValidateMediaFrame applies the session guard to a dedicated SRDP media frame
// before the gateway or adapter accepts screen/cursor/media payloads.
func (g *DesktopSessionGuard) ValidateMediaFrame(
	frame DesktopMediaFrame,
	localAgentID string,
	currentGatewayID string,
	nowUnix int64,
) error {
	if g == nil {
		return fmt.Errorf("%w: missing session guard", ErrInvalidDesktopMediaFrame)
	}
	if frame.SessionBindingID != g.sessionID {
		return fmt.Errorf("%w: session binding mismatch", ErrInvalidDesktopMediaFrame)
	}
	if err := validateDesktopRouteBindingNormalized(g.target, localAgentID, currentGatewayID); err != nil {
		return err
	}
	if err := ValidateDesktopSessionLifetime(g.target.Screen, g.startUnix, g.lastActivityUnix, nowUnix); err != nil {
		return err
	}
	if err := ValidateDesktopMediaFrame(frame, g.target.Screen); err != nil {
		return err
	}

	g.lastActivityUnix = nowUnix

	return nil
}

// ValidateMediaAck applies the session guard to a browser/gateway SRDP media
// acknowledgement before the ack mutates sender credit-window state.
func (g *DesktopSessionGuard) ValidateMediaAck(
	ack DesktopMediaAck,
	mediaSessionID string,
	localAgentID string,
	currentGatewayID string,
	nowUnix int64,
) error {
	if _, err := g.validateMediaAck(ack, mediaSessionID, localAgentID, currentGatewayID, nowUnix); err != nil {
		return err
	}

	g.lastActivityUnix = nowUnix

	return nil
}

// ApplyMediaAck validates a browser/gateway acknowledgement against the active
// session guard and applies it to the sender credit window as one operation.
// This keeps route, lifetime, session/media binding, and replay checks on the
// same path before sender flow-control state mutates.
func (g *DesktopSessionGuard) ApplyMediaAck(
	window *DesktopMediaCreditWindow,
	ack DesktopMediaAck,
	mediaSessionID string,
	localAgentID string,
	currentGatewayID string,
	nowUnix int64,
) error {
	expectedMediaSessionID, err := g.validateMediaAck(ack, mediaSessionID, localAgentID, currentGatewayID, nowUnix)
	if err != nil {
		return err
	}
	if window == nil {
		return fmt.Errorf("%w: missing media credit window", ErrInvalidDesktopMediaAck)
	}
	if err := window.ApplyAck(ack, g.sessionID, expectedMediaSessionID); err != nil {
		return err
	}

	g.lastActivityUnix = nowUnix

	return nil
}

func (g *DesktopSessionGuard) validateMediaAck(
	ack DesktopMediaAck,
	mediaSessionID string,
	localAgentID string,
	currentGatewayID string,
	nowUnix int64,
) (string, error) {
	if g == nil {
		return "", fmt.Errorf("%w: missing session guard", ErrInvalidDesktopMediaAck)
	}
	mediaSessionID = strings.TrimSpace(mediaSessionID)
	if mediaSessionID == "" {
		return "", fmt.Errorf("%w: missing media session binding", ErrInvalidDesktopMediaAck)
	}
	if err := ValidateDesktopMediaAck(ack, g.sessionID, mediaSessionID); err != nil {
		return "", err
	}
	if err := validateDesktopRouteBindingNormalized(g.target, localAgentID, currentGatewayID); err != nil {
		return "", err
	}
	if err := ValidateDesktopSessionLifetime(g.target.Screen, g.startUnix, g.lastActivityUnix, nowUnix); err != nil {
		return "", err
	}

	return mediaSessionID, nil
}

// ValidateContentRecording checks whether retaining the sensitive content from
// an already accepted frame is allowed by this session's recording policy.
// Metadata-only audit paths do not need this check; screen pixels and clipboard
// bytes must pass it before being persisted or exported.
func (g *DesktopSessionGuard) ValidateContentRecording(frame DesktopFrame) error {
	if g == nil {
		return fmt.Errorf("%w: missing session guard", ErrInvalidDesktopFrame)
	}
	if frame.SessionID != g.sessionID {
		return fmt.Errorf("%w: session binding mismatch", ErrInvalidDesktopFrame)
	}

	return ValidateDesktopContentRecording(frame, g.target.Recording)
}

// Consume applies frame-rate and bitrate quotas to desktop update frames.
// Non-screen frames are ignored here and still use their normal validators.
func (w *DesktopFrameQuotaWindow) Consume(frame DesktopFrame, nowUnixNano int64) error {
	if frame.FrameType != DesktopFrameTypeUpdate {
		return nil
	}
	if nowUnixNano <= 0 {
		return fmt.Errorf("%w: missing quota timestamp", ErrInvalidDesktopFrame)
	}

	if w.policy.FrameRate == 0 || w.policy.BitrateBPS == 0 {
		w.policy = normalizeDesktopScreenPolicy(w.policy)
	}
	if w.windowStartUnixNano == 0 ||
		nowUnixNano < w.windowStartUnixNano ||
		nowUnixNano-w.windowStartUnixNano >= desktopQuotaWindowNanos {
		w.windowStartUnixNano = nowUnixNano
		w.frameCount = 0
		w.bitCount = 0
	}

	if w.frameCount >= w.policy.FrameRate {
		return fmt.Errorf("%w: frame rate", ErrDesktopQuotaExceeded)
	}

	frameBits := uint64(len(frame.Data)) * 8
	maxBits := uint64(w.policy.BitrateBPS)
	if frameBits > maxBits || w.bitCount > maxBits-frameBits {
		return fmt.Errorf("%w: bitrate", ErrDesktopQuotaExceeded)
	}

	w.frameCount++
	w.bitCount += frameBits

	return nil
}

// ValidateDesktopSessionLifetime enforces the idle and absolute TTL policy for
// an adapter session. Timestamps are Unix seconds; callers should update
// lastActivityUnix whenever user input, screen traffic, or explicit heartbeat
// activity is accepted for the session.
func ValidateDesktopSessionLifetime(
	policy DesktopScreenPolicy,
	startUnix int64,
	lastActivityUnix int64,
	nowUnix int64,
) error {
	if startUnix <= 0 || nowUnix <= 0 {
		return fmt.Errorf("%w: invalid session timestamp", ErrInvalidDesktopFrame)
	}
	if lastActivityUnix <= 0 {
		lastActivityUnix = startUnix
	}

	policy = normalizeDesktopScreenPolicy(policy)
	if nowUnix < startUnix || nowUnix < lastActivityUnix {
		return fmt.Errorf("%w: clock moved backwards", ErrInvalidDesktopFrame)
	}
	if nowUnix-startUnix >= int64(policy.TTLSeconds) {
		return fmt.Errorf("%w: ttl", ErrDesktopSessionExpired)
	}
	if nowUnix-lastActivityUnix >= int64(policy.IdleSeconds) {
		return fmt.Errorf("%w: idle", ErrDesktopSessionExpired)
	}

	return nil
}

// ValidateDesktopRouteBinding verifies that a still-running desktop session is
// on the selected agent and, when supplied, selected gateway route.
func ValidateDesktopRouteBinding(target DesktopTarget, localAgentID string, currentGatewayID string) error {
	target, err := NormalizeDesktopTarget(target)
	if err != nil {
		return err
	}

	return validateDesktopRouteBindingNormalized(target, localAgentID, currentGatewayID)
}

func validateDesktopRouteBindingNormalized(target DesktopTarget, localAgentID string, currentGatewayID string) error {
	localAgentID = strings.TrimSpace(localAgentID)
	currentGatewayID = strings.TrimSpace(currentGatewayID)
	if localAgentID == "" {
		return fmt.Errorf("%w: missing local agent binding", ErrInvalidDesktopTarget)
	}
	if target.Route.SelectedAgentID != localAgentID {
		return fmt.Errorf("%w: selected agent changed", ErrDesktopRouteLost)
	}
	if currentGatewayID != "" &&
		target.Route.SelectedGateway != "" &&
		target.Route.SelectedGateway != currentGatewayID {
		return fmt.Errorf("%w: selected gateway changed", ErrDesktopRouteLost)
	}

	return nil
}
