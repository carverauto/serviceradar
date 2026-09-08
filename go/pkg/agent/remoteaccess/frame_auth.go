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
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"sync"
)

const (
	FrameAuthAlgorithm = "hmac-sha256-v1"

	frameAuthDomain = "serviceradar.remote_access.frame.v1"
)

var (
	ErrInvalidFrameAuth     = errors.New("invalid remote access frame auth")
	ErrUnsupportedFrameAuth = errors.New("unsupported remote access frame auth")
)

type frameAuthEnvelope struct {
	FrameAuth frameAuthOpenPayload `json:"frame_auth"`
}

type frameAuthOpenPayload struct {
	Algorithm string `json:"alg"`
	Key       string `json:"key"`
	Required  bool   `json:"required"`
}

// FrameAuthenticator signs agent-to-broker frames for a single remote-access
// session. It is safe for concurrent use by PTY, recording, and transfer loops.
type FrameAuthenticator struct {
	mu  sync.Mutex
	key []byte
	seq uint64
}

// NewFrameAuthenticatorFromOpenPayload extracts a per-session frame signing key
// from broker-generated open-frame JSON.
func NewFrameAuthenticatorFromOpenPayload(data []byte) (*FrameAuthenticator, error) {
	if len(data) == 0 {
		return nil, nil
	}

	var envelope frameAuthEnvelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		return nil, nil
	}

	payload := envelope.FrameAuth
	if payload.Key == "" && payload.Algorithm == "" && !payload.Required {
		return nil, nil
	}
	if payload.Algorithm != FrameAuthAlgorithm {
		return nil, ErrUnsupportedFrameAuth
	}

	key, err := base64.RawURLEncoding.DecodeString(payload.Key)
	if err != nil || len(key) < 32 {
		return nil, ErrInvalidFrameAuth
	}

	return &FrameAuthenticator{key: key}, nil
}

// Sign binds a frame to the authenticated session route and assigns the next
// monotonic sequence number.
func (a *FrameAuthenticator) Sign(frame Frame, agentID string) Frame {
	if a == nil {
		return frame
	}

	if agentID == "" && frame.Metadata != nil {
		agentID = frame.Metadata["agent_id"]
	}

	payloadHash := payloadSHA256(frame.Data)

	a.mu.Lock()
	a.seq++
	seq := a.seq
	signature := signFrame(a.key, frame, agentID, seq, payloadHash)
	a.mu.Unlock()

	frame.Seq = seq
	frame.PayloadSHA256 = payloadHash
	frame.Signature = signature

	return frame
}

func payloadSHA256(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func signFrame(key []byte, frame Frame, agentID string, seq uint64, payloadHash string) string {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(canonicalFrameBinding(frame, agentID, seq, payloadHash)))

	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func canonicalFrameBinding(frame Frame, agentID string, seq uint64, payloadHash string) string {
	var builder strings.Builder
	builder.Grow(256)
	builder.WriteString(frameAuthDomain)
	builder.WriteByte('\n')
	builder.WriteString(frame.SessionID)
	builder.WriteByte('\n')
	builder.WriteString(agentID)
	builder.WriteByte('\n')
	builder.WriteString(strconv.FormatUint(seq, 10))
	builder.WriteByte('\n')
	builder.WriteString(frame.FrameType)
	builder.WriteByte('\n')
	builder.WriteString(strconv.FormatUint(uint64(frame.Cols), 10))
	builder.WriteByte('\n')
	builder.WriteString(strconv.FormatUint(uint64(frame.Rows), 10))
	builder.WriteByte('\n')
	builder.WriteString(frame.Reason)
	builder.WriteByte('\n')
	builder.WriteString(payloadHash)

	return builder.String()
}
