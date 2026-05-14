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
	"encoding/json"
	"fmt"
	"strings"
)

// EncodeDesktopFramePayload validates and serializes a typed desktop frame for
// transport inside the existing ConsoleFrame data field.
func EncodeDesktopFramePayload(frame DesktopFrame, policy DesktopScreenPolicy) ([]byte, error) {
	return EncodeDesktopFramePayloadWithPolicy(frame, policy, DesktopRedirectionPolicy{})
}

// EncodeDesktopFramePayloadWithPolicy validates and serializes a typed desktop
// frame with an explicit redirection policy.
func EncodeDesktopFramePayloadWithPolicy(
	frame DesktopFrame,
	policy DesktopScreenPolicy,
	redirection DesktopRedirectionPolicy,
) ([]byte, error) {
	if err := ValidateDesktopFrameWithPolicy(frame, policy, redirection); err != nil {
		return nil, err
	}

	data, err := json.Marshal(frame)
	if err != nil {
		return nil, fmt.Errorf("%w: encode frame payload: %w", ErrInvalidDesktopFrame, err)
	}

	return data, nil
}

// DecodeDesktopFramePayload decodes and validates a typed desktop frame carried
// inside the existing ConsoleFrame data field.
func DecodeDesktopFramePayload(data []byte, policy DesktopScreenPolicy) (DesktopFrame, error) {
	return DecodeDesktopFramePayloadWithPolicy(data, policy, DesktopRedirectionPolicy{})
}

// DecodeDesktopFramePayloadWithPolicy decodes and validates a typed desktop
// frame with an explicit redirection policy.
func DecodeDesktopFramePayloadWithPolicy(
	data []byte,
	policy DesktopScreenPolicy,
	redirection DesktopRedirectionPolicy,
) (DesktopFrame, error) {
	var frame DesktopFrame
	if err := json.Unmarshal(data, &frame); err != nil {
		return frame, fmt.Errorf("%w: decode frame payload: %w", ErrInvalidDesktopFrame, err)
	}
	if err := ValidateDesktopFrameWithPolicy(frame, policy, redirection); err != nil {
		return frame, err
	}

	return frame, nil
}

// DecodeDesktopFramePayloadForSession decodes a typed desktop frame and rejects
// frames that are not bound to the expected remote-access session.
func DecodeDesktopFramePayloadForSession(
	data []byte,
	policy DesktopScreenPolicy,
	sessionID string,
) (DesktopFrame, error) {
	return DecodeDesktopFramePayloadForSessionWithPolicy(data, policy, DesktopRedirectionPolicy{}, sessionID)
}

// DecodeDesktopFramePayloadForSessionWithPolicy decodes a typed desktop frame,
// applies redirection policy, and rejects frames not bound to the expected
// remote-access session.
func DecodeDesktopFramePayloadForSessionWithPolicy(
	data []byte,
	policy DesktopScreenPolicy,
	redirection DesktopRedirectionPolicy,
	sessionID string,
) (DesktopFrame, error) {
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return DesktopFrame{}, fmt.Errorf("%w: missing session binding", ErrInvalidDesktopFrame)
	}

	frame, err := DecodeDesktopFramePayloadWithPolicy(data, policy, redirection)
	if err != nil {
		return frame, err
	}
	if frame.SessionID != sessionID {
		return frame, fmt.Errorf("%w: session binding mismatch", ErrInvalidDesktopFrame)
	}

	return frame, nil
}

func ValidateDesktopFrame(frame DesktopFrame, policy DesktopScreenPolicy) error {
	return validateDesktopFrame(frame, policy, nil)
}

// ValidateDesktopFrameWithPolicy validates a desktop frame against both screen
// and redirection policy. Use this for any path that accepts clipboard or other
// local resource redirection frames.
func ValidateDesktopFrameWithPolicy(
	frame DesktopFrame,
	policy DesktopScreenPolicy,
	redirection DesktopRedirectionPolicy,
) error {
	return validateDesktopFrame(frame, policy, &redirection)
}

func validateDesktopFrame(
	frame DesktopFrame,
	policy DesktopScreenPolicy,
	redirection *DesktopRedirectionPolicy,
) error {
	if frame.SessionID == "" {
		return fmt.Errorf("%w: missing session id", ErrInvalidDesktopFrame)
	}
	if !validDesktopProtocol(frame.Protocol) {
		return fmt.Errorf("%w: unsupported protocol", ErrInvalidDesktopFrame)
	}

	policy = normalizeDesktopScreenPolicy(policy)
	switch frame.FrameType {
	case DesktopFrameTypeUpdate:
		if frame.Width == 0 || frame.Height == 0 || frame.Width > policy.MaxWidth || frame.Height > policy.MaxHeight {
			return fmt.Errorf("%w: update dimensions exceed policy", ErrInvalidDesktopFrame)
		}
		if len(frame.Data) > DesktopMaxFrameData {
			return fmt.Errorf("%w: update data exceeds maximum", ErrInvalidDesktopFrame)
		}
	case DesktopFrameTypeResize:
		if frame.Width == 0 || frame.Height == 0 || frame.Width > policy.MaxWidth || frame.Height > policy.MaxHeight {
			return fmt.Errorf("%w: resize dimensions exceed policy", ErrInvalidDesktopFrame)
		}
	case DesktopFrameTypeInput:
		if frame.Input == nil || !validDesktopInputKind(frame.Input.Kind) {
			return fmt.Errorf("%w: invalid input event", ErrInvalidDesktopFrame)
		}
		if err := validateDesktopInputEvent(*frame.Input, policy); err != nil {
			return err
		}
	case DesktopFrameTypeClipboard:
		if !desktopClipboardFrameAllowed(redirection, frame.Direction) {
			return fmt.Errorf("%w: clipboard redirection disabled", ErrInvalidDesktopFrame)
		}
		if len(frame.Data) > MaxTerminalFrameData {
			return fmt.Errorf("%w: clipboard data exceeds maximum", ErrInvalidDesktopFrame)
		}
	case DesktopFrameTypeQuality:
		if frame.Quality == nil {
			return fmt.Errorf("%w: missing quality request", ErrInvalidDesktopFrame)
		}
		if frame.Quality.MaxFrameRate > policy.FrameRate ||
			frame.Quality.MaxBitrate > policy.BitrateBPS ||
			frame.Quality.Width > policy.MaxWidth ||
			frame.Quality.Height > policy.MaxHeight {
			return fmt.Errorf("%w: quality request exceeds policy", ErrInvalidDesktopFrame)
		}
	case DesktopFrameTypeDisconnect:
	default:
		return fmt.Errorf("%w: unsupported frame type", ErrInvalidDesktopFrame)
	}

	return nil
}

func validateDesktopInputEvent(input DesktopInputEvent, policy DesktopScreenPolicy) error {
	if len(input.Key) > DesktopMaxInputTokenSize || len(input.Button) > DesktopMaxInputTokenSize {
		return fmt.Errorf("%w: input token exceeds maximum", ErrInvalidDesktopFrame)
	}
	if input.Kind == DesktopInputKindPointer &&
		(input.X > policy.MaxWidth || input.Y > policy.MaxHeight) {
		return fmt.Errorf("%w: pointer coordinates exceed policy", ErrInvalidDesktopFrame)
	}

	return nil
}

func desktopClipboardFrameAllowed(redirection *DesktopRedirectionPolicy, direction string) bool {
	if redirection == nil {
		return false
	}

	policy := normalizeDesktopRedirectionPolicy(*redirection)

	switch strings.TrimSpace(direction) {
	case DesktopClipboardDirectionToRemote:
		return policy.ClipboardMode == DesktopClipboardModeTextToRemote ||
			policy.ClipboardMode == DesktopClipboardModeTextBoth
	case DesktopClipboardDirectionToBrowser:
		return policy.ClipboardMode == DesktopClipboardModeTextToBrowser ||
			policy.ClipboardMode == DesktopClipboardModeTextBoth
	default:
		return false
	}
}

func validDesktopInputKind(kind string) bool {
	switch kind {
	case DesktopInputKindKey, DesktopInputKindPointer, DesktopInputKindFocus:
		return true
	default:
		return false
	}
}
