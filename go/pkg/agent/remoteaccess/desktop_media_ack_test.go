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
	"errors"
	"strings"
	"testing"
)

func TestValidateDesktopMediaAckRejectsAmbiguousFlowControl(t *testing.T) {
	t.Parallel()

	err := ValidateDesktopMediaAck(
		DesktopMediaAck{
			SessionBindingID: desktopMediaTestSessionID,
			MediaSessionID:   desktopMediaTestMediaSessionID,
			Pause:            true,
			Resume:           true,
		},
		desktopMediaTestSessionID,
		desktopMediaTestMediaSessionID,
	)
	if !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("ValidateDesktopMediaAck error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
}

func TestValidateDesktopMediaAckRejectsUnsupportedQualityLevel(t *testing.T) {
	t.Parallel()

	err := ValidateDesktopMediaAck(
		DesktopMediaAck{
			SessionBindingID: desktopMediaTestSessionID,
			MediaSessionID:   desktopMediaTestMediaSessionID,
			QualityLevel:     "ultra",
		},
		desktopMediaTestSessionID,
		desktopMediaTestMediaSessionID,
	)
	if !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("ValidateDesktopMediaAck error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
}

func TestValidateDesktopMediaAckRejectsOversizedCloseReason(t *testing.T) {
	t.Parallel()

	err := ValidateDesktopMediaAck(
		DesktopMediaAck{
			SessionBindingID: desktopMediaTestSessionID,
			MediaSessionID:   desktopMediaTestMediaSessionID,
			CloseReason:      strings.Repeat("x", DesktopMediaMaxCloseReason+1),
		},
		desktopMediaTestSessionID,
		desktopMediaTestMediaSessionID,
	)
	if !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("ValidateDesktopMediaAck error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
}

func TestDesktopMediaAckJSONContractUsesBrowserFieldNames(t *testing.T) {
	t.Parallel()

	data, err := json.Marshal(map[string]any{
		"type":               DesktopMediaControlTypeAck,
		"session_binding_id": desktopMediaTestSessionID,
		"media_session_id":   desktopMediaTestMediaSessionID,
		"last_accepted_seq":  42,
		"credit_bytes":       1024,
		"quality_level":      "low",
	})
	if err != nil {
		t.Fatalf("Marshal returned error: %v", err)
	}

	ack, err := DecodeDesktopMediaAckMessage(data, desktopMediaTestSessionID, desktopMediaTestMediaSessionID)
	if err != nil {
		t.Fatalf("DecodeDesktopMediaAckMessage returned error: %v", err)
	}

	if ack.SessionBindingID != desktopMediaTestSessionID ||
		ack.MediaSessionID != desktopMediaTestMediaSessionID ||
		ack.LastAcceptedSeq != 42 ||
		ack.CreditBytes != 1024 ||
		ack.QualityLevel != "low" {
		t.Fatalf("decoded ack = %#v", ack)
	}
}

func TestDecodeDesktopMediaAckMessageRejectsUnsupportedType(t *testing.T) {
	t.Parallel()

	_, err := DecodeDesktopMediaAckMessage(
		[]byte(`{"type":"desktop_quality","session_binding_id":"session-1","media_session_id":"media-1"}`),
		desktopMediaTestSessionID,
		desktopMediaTestMediaSessionID,
	)
	if !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("DecodeDesktopMediaAckMessage error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
}
