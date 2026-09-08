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
	"encoding/base64"
	"strings"
	"testing"
)

func TestFrameAuthenticatorSignsFramesWithMonotonicSequence(t *testing.T) {
	key := strings.Repeat("a", 32)
	payload := `{"frame_auth":{"alg":"hmac-sha256-v1","key":"` +
		base64.RawURLEncoding.EncodeToString([]byte(key)) +
		`","required":true}}`

	auth, err := NewFrameAuthenticatorFromOpenPayload([]byte(payload))
	if err != nil {
		t.Fatalf("NewFrameAuthenticatorFromOpenPayload() error = %v", err)
	}
	if auth == nil {
		t.Fatal("NewFrameAuthenticatorFromOpenPayload() returned nil authenticator")
	}

	first := auth.Sign(Frame{
		SessionID: "session-1",
		FrameType: FrameTypeData,
		Data:      []byte("hello"),
	}, "agent-1")

	if first.Seq != 1 {
		t.Fatalf("first sequence = %d, want 1", first.Seq)
	}
	if first.PayloadSHA256 != "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" {
		t.Fatalf("unexpected payload hash %q", first.PayloadSHA256)
	}
	if first.Signature == "" {
		t.Fatal("signature is required")
	}

	second := auth.Sign(Frame{
		SessionID: "session-1",
		FrameType: FrameTypeClose,
		Reason:    "done",
	}, "agent-1")

	if second.Seq != 2 {
		t.Fatalf("second sequence = %d, want 2", second.Seq)
	}
	if second.Signature == first.Signature {
		t.Fatal("different frame binding should produce a different signature")
	}
}
