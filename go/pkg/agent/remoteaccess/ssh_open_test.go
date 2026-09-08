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
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestSSHConfigFromOpenFrameUsesUserPresentCredential(t *testing.T) {
	t.Parallel()

	payload := mustSSHOpenPayload(t, SSHOpenPayload{
		Protocol:  ProtocolSSH,
		SessionID: "session-1",
		AgentID:   "agent-1",
		Target:    SSHTarget{Host: "router.example", Port: 2222},
		SSH: SSHAuth{
			Username:    "admin",
			PrivateKey:  "private-key",
			Passphrase:  "passphrase",
			Certificate: "user-cert",
		},
		TimeoutMS:        45000,
		SSHHostKeyPolicy: "skip_verify",
	})

	cfg, err := SSHConfigFromOpenFrame(Frame{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Data:      payload,
		Cols:      132,
		Rows:      43,
		Metadata:  map[string]string{"agent_id": "agent-1"},
	})
	if err != nil {
		t.Fatalf("SSHConfigFromOpenFrame returned error: %v", err)
	}

	if cfg.Target.Host != "router.example" || cfg.Target.Port != 2222 {
		t.Fatalf("target = %#v", cfg.Target)
	}
	if cfg.Auth.Username != fakeSSHUsername ||
		cfg.Auth.PrivateKey != "private-key" ||
		cfg.Auth.Passphrase != "passphrase" ||
		cfg.Auth.Certificate != "user-cert" {
		t.Fatalf("auth = %#v", cfg.Auth)
	}
	if cfg.Cols != 132 || cfg.Rows != 43 {
		t.Fatalf("size = %dx%d", cfg.Cols, cfg.Rows)
	}
	if cfg.Timeout != 45*time.Second {
		t.Fatalf("timeout = %s", cfg.Timeout)
	}
	if cfg.SSHHostKeyPolicy != "skip_verify" {
		t.Fatalf("host key policy = %q", cfg.SSHHostKeyPolicy)
	}
}

func TestSSHConfigFromOpenFrameRejectsPayloadScopeMismatch(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		payload SSHOpenPayload
		frame   Frame
		want    error
	}{
		{
			name:    "session",
			payload: SSHOpenPayload{SessionID: "session-2", Target: SSHTarget{Host: "router.example"}},
			frame:   Frame{SessionID: "session-1", Protocol: ProtocolSSH},
			want:    ErrSSHOpenSessionMismatch,
		},
		{
			name:    "payload protocol",
			payload: SSHOpenPayload{Protocol: "rdp", Target: SSHTarget{Host: "router.example"}},
			frame:   Frame{SessionID: "session-1", Protocol: ProtocolSSH},
			want:    ErrUnsupportedSSHProtocol,
		},
		{
			name:    "frame protocol",
			payload: SSHOpenPayload{Protocol: ProtocolSSH, Target: SSHTarget{Host: "router.example"}},
			frame:   Frame{SessionID: "session-1", Protocol: "proxmox-console"},
			want:    ErrUnsupportedSSHProtocol,
		},
		{
			name:    "agent metadata",
			payload: SSHOpenPayload{AgentID: "agent-2", Target: SSHTarget{Host: "router.example"}},
			frame: Frame{
				SessionID: "session-1",
				Protocol:  ProtocolSSH,
				Metadata:  map[string]string{"agent_id": "agent-1"},
			},
			want: ErrSSHOpenAgentMismatch,
		},
		{
			name:    "gateway metadata",
			payload: SSHOpenPayload{GatewayID: "gateway-2", Target: SSHTarget{Host: "router.example"}},
			frame: Frame{
				SessionID: "session-1",
				Protocol:  ProtocolSSH,
				Metadata:  map[string]string{"gateway_id": remoteAccessTestGatewayID},
			},
			want: ErrSSHOpenGatewayMismatch,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			tt.frame.Data = mustSSHOpenPayload(t, tt.payload)
			_, err := SSHConfigFromOpenFrame(tt.frame)
			if !errors.Is(err, tt.want) {
				t.Fatalf("error = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestSSHConfigFromOpenFrameUsesSSHCertificateCredential(t *testing.T) {
	t.Parallel()

	payload := mustSSHOpenPayload(t, SSHOpenPayload{
		Target: SSHTarget{Host: "router.example"},
		SSH: SSHAuth{
			Username:    "admin",
			PrivateKey:  "session-key",
			Certificate: "session-cert",
		},
		CredentialMode: SSHCredentialModeSSHCertificate,
	})

	cfg, err := SSHConfigFromOpenFrame(Frame{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		Data:      payload,
	})
	if err != nil {
		t.Fatalf("SSHConfigFromOpenFrame returned error: %v", err)
	}

	if cfg.Auth.Username != "admin" ||
		cfg.Auth.PrivateKey != "session-key" ||
		cfg.Auth.Certificate != "session-cert" {
		t.Fatalf("auth = %#v", cfg.Auth)
	}
}

func TestSSHConfigFromOpenFrameRejectsInvalidSSHCertificateCredential(t *testing.T) {
	t.Parallel()

	payload := mustSSHOpenPayload(t, SSHOpenPayload{
		Target:         SSHTarget{Host: "router.example"},
		SSH:            SSHAuth{Username: "admin", PrivateKey: "session-key"},
		CredentialMode: SSHCredentialModeSSHCertificate,
	})

	_, err := SSHConfigFromOpenFrame(Frame{SessionID: "session-1", Protocol: ProtocolSSH, Data: payload})
	if !errors.Is(err, ErrSSHCertificateRequired) {
		t.Fatalf("missing cert error = %v, want %v", err, ErrSSHCertificateRequired)
	}

	payload = mustSSHOpenPayload(t, SSHOpenPayload{
		Target:         SSHTarget{Host: "router.example"},
		SSH:            SSHAuth{Username: "admin", Certificate: "session-cert"},
		CredentialMode: SSHCredentialModeSSHCertificate,
	})

	_, err = SSHConfigFromOpenFrame(Frame{SessionID: "session-1", Protocol: ProtocolSSH, Data: payload})
	if !errors.Is(err, ErrSSHCertificateRequiresKey) {
		t.Fatalf("missing key error = %v, want %v", err, ErrSSHCertificateRequiresKey)
	}
}

func TestSSHConfigFromOpenFrameRejectsAgentLocalCredentialMode(t *testing.T) {
	t.Parallel()

	payload := mustSSHOpenPayload(t, SSHOpenPayload{
		Target:         SSHTarget{Host: "switch.example"},
		CredentialMode: "agent_local",
	})

	_, err := SSHConfigFromOpenFrame(Frame{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		Data:      payload,
	})
	if !errors.Is(err, ErrUnsupportedSSHCredentialMode) {
		t.Fatalf("error = %v, want %v", err, ErrUnsupportedSSHCredentialMode)
	}
}

func TestSSHConfigFromOpenFrameRejectsInvalidModeAndProtocol(t *testing.T) {
	t.Parallel()

	payload := mustSSHOpenPayload(t, SSHOpenPayload{
		Target:         SSHTarget{Host: "switch.example"},
		CredentialMode: "central",
	})

	_, err := SSHConfigFromOpenFrame(Frame{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		Data:      payload,
	})
	if !errors.Is(err, ErrUnsupportedSSHCredentialMode) {
		t.Fatalf("mode error = %v, want %v", err, ErrUnsupportedSSHCredentialMode)
	}

	_, err = SSHConfigFromOpenFrame(Frame{
		SessionID: "session-1",
		Protocol:  "rdp",
		Data:      payload,
	})
	if !errors.Is(err, ErrUnsupportedSSHProtocol) {
		t.Fatalf("protocol error = %v, want %v", err, ErrUnsupportedSSHProtocol)
	}
}

func TestOpenSSHFromFramePassesDecodedConfigToPTY(t *testing.T) {
	t.Parallel()

	session := &fakeSSHSession{
		stdout: strings.NewReader(""),
		stderr: strings.NewReader(""),
		waitCh: make(chan struct{}),
	}
	payload := mustSSHOpenPayload(t, SSHOpenPayload{
		Target: SSHTarget{Host: "router.example"},
		SSH:    SSHAuth{Username: "admin", Password: "secret"},
	})

	pty, err := OpenSSHFromFrame(context.Background(), Frame{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		Data:      payload,
		Cols:      90,
		Rows:      25,
	}, SSHOpenOptions{
		Dial: func(_ context.Context, cfg SSHConfig) (SSHSession, error) {
			if cfg.Target.Host != "router.example" || cfg.Auth.Username != "admin" {
				t.Fatalf("decoded cfg = %#v", cfg)
			}
			return session, nil
		},
	})
	if err != nil {
		t.Fatalf("OpenSSHFromFrame returned error: %v", err)
	}
	defer func() { _ = pty.Close() }()

	rows, cols, shellStarted := session.ptyState()
	if rows != 25 || cols != 90 || !shellStarted {
		t.Fatalf("pty rows=%d cols=%d shell=%t", rows, cols, shellStarted)
	}
}

func mustSSHOpenPayload(t *testing.T, payload SSHOpenPayload) []byte {
	t.Helper()

	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal ssh open payload: %v", err)
	}

	return data
}
