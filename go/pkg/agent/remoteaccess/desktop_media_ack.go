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

func DecodeDesktopMediaAckMessage(data []byte, sessionBindingID, mediaSessionID string) (DesktopMediaAck, error) {
	var message desktopMediaAckMessage
	if err := json.Unmarshal(data, &message); err != nil {
		return DesktopMediaAck{}, fmt.Errorf("%w: decode ack message: %w", ErrInvalidDesktopMediaAck, err)
	}
	if message.Type != DesktopMediaControlTypeAck {
		return DesktopMediaAck{}, fmt.Errorf("%w: unsupported control message type", ErrInvalidDesktopMediaAck)
	}

	ack := message.DesktopMediaAck
	if err := ValidateDesktopMediaAck(ack, sessionBindingID, mediaSessionID); err != nil {
		return DesktopMediaAck{}, err
	}

	return ack, nil
}

func ValidateDesktopMediaAck(ack DesktopMediaAck, sessionBindingID, mediaSessionID string) error {
	if ack.SessionBindingID == "" {
		return fmt.Errorf("%w: missing session binding id", ErrInvalidDesktopMediaAck)
	}
	if ack.MediaSessionID == "" {
		return fmt.Errorf("%w: missing media session id", ErrInvalidDesktopMediaAck)
	}
	if sessionBindingID != "" && ack.SessionBindingID != sessionBindingID {
		return fmt.Errorf("%w: session binding mismatch", ErrInvalidDesktopMediaAck)
	}
	if mediaSessionID != "" && ack.MediaSessionID != mediaSessionID {
		return fmt.Errorf("%w: media session mismatch", ErrInvalidDesktopMediaAck)
	}
	if ack.Pause && ack.Resume {
		return fmt.Errorf("%w: pause and resume cannot both be set", ErrInvalidDesktopMediaAck)
	}
	if !validDesktopMediaQualityLevel(ack.QualityLevel) {
		return fmt.Errorf("%w: unsupported quality level", ErrInvalidDesktopMediaAck)
	}
	if len(strings.TrimSpace(ack.CloseReason)) > DesktopMediaMaxCloseReason {
		return fmt.Errorf("%w: close reason exceeds maximum", ErrInvalidDesktopMediaAck)
	}

	return nil
}

func desktopMediaAckHasControlSignal(ack DesktopMediaAck) bool {
	return ack.Pause || ack.Resume || ack.QualityLevel != "" || normalizeDesktopMediaAckCloseReason(ack.CloseReason) != ""
}

func validDesktopMediaQualityLevel(level string) bool {
	switch level {
	case "", DesktopMediaQualityAuto, DesktopMediaQualityLow:
		return true
	default:
		return false
	}
}

func normalizeDesktopMediaAckCloseReason(reason string) string {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return ""
	}

	var normalized strings.Builder
	normalized.Grow(len(reason))

	for _, r := range reason {
		if r < ' ' || r == 0x7f {
			r = ' '
		}

		normalized.WriteRune(r)
	}

	return strings.TrimSpace(normalized.String())
}
