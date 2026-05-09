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
		Target: SSHTarget{Host: "router.example", Port: 2222},
		SSH: SSHAuth{
			Username:   "admin",
			PrivateKey: "private-key",
			Passphrase: "passphrase",
		},
		TimeoutMS:        45000,
		SSHHostKeyPolicy: "skip_verify",
	})

	cfg, err := SSHConfigFromOpenFrame(context.Background(), Frame{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		FrameType: FrameTypeOpen,
		Data:      payload,
		Cols:      132,
		Rows:      43,
	}, nil)
	if err != nil {
		t.Fatalf("SSHConfigFromOpenFrame returned error: %v", err)
	}

	if cfg.Target.Host != "router.example" || cfg.Target.Port != 2222 {
		t.Fatalf("target = %#v", cfg.Target)
	}
	if cfg.Auth.Username != "admin" || cfg.Auth.PrivateKey != "private-key" || cfg.Auth.Passphrase != "passphrase" {
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

func TestSSHConfigFromOpenFrameResolvesAgentLocalCredential(t *testing.T) {
	t.Parallel()

	resolver := &fakeSSHCredentialResolver{
		auth: SSHAuth{
			Username:   "from-resolver",
			PrivateKey: "agent-local-key",
		},
	}
	payload := mustSSHOpenPayload(t, SSHOpenPayload{
		Target:         SSHTarget{Host: "switch.example"},
		SSH:            SSHAuth{Username: "operator-selected-user"},
		CredentialMode: SSHCredentialModeAgentLocal,
		CredentialRef:  "ssh/router-admin",
	})

	cfg, err := SSHConfigFromOpenFrame(context.Background(), Frame{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		Data:      payload,
	}, resolver)
	if err != nil {
		t.Fatalf("SSHConfigFromOpenFrame returned error: %v", err)
	}

	if cfg.Auth.Username != "operator-selected-user" {
		t.Fatalf("username = %q", cfg.Auth.Username)
	}
	if cfg.Auth.PrivateKey != "agent-local-key" {
		t.Fatalf("private key = %q", cfg.Auth.PrivateKey)
	}
	if resolver.request.SessionID != "session-1" ||
		resolver.request.CredentialRef != "ssh/router-admin" ||
		resolver.request.Target.Host != "switch.example" ||
		resolver.request.Username != "operator-selected-user" {
		t.Fatalf("resolver request = %#v", resolver.request)
	}
}

func TestSSHConfigFromOpenFrameRejectsAgentLocalWithoutResolver(t *testing.T) {
	t.Parallel()

	payload := mustSSHOpenPayload(t, SSHOpenPayload{
		Target:         SSHTarget{Host: "switch.example"},
		CredentialMode: SSHCredentialModeAgentLocal,
		CredentialRef:  "ssh/router-admin",
	})

	_, err := SSHConfigFromOpenFrame(context.Background(), Frame{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		Data:      payload,
	}, nil)
	if !errors.Is(err, ErrSSHCredentialResolverMissing) {
		t.Fatalf("error = %v, want %v", err, ErrSSHCredentialResolverMissing)
	}
}

func TestSSHConfigFromOpenFrameRejectsInvalidModeAndProtocol(t *testing.T) {
	t.Parallel()

	payload := mustSSHOpenPayload(t, SSHOpenPayload{
		Target:         SSHTarget{Host: "switch.example"},
		CredentialMode: "central",
	})

	_, err := SSHConfigFromOpenFrame(context.Background(), Frame{
		SessionID: "session-1",
		Protocol:  ProtocolSSH,
		Data:      payload,
	}, nil)
	if !errors.Is(err, ErrUnsupportedSSHCredentialMode) {
		t.Fatalf("mode error = %v, want %v", err, ErrUnsupportedSSHCredentialMode)
	}

	_, err = SSHConfigFromOpenFrame(context.Background(), Frame{
		SessionID: "session-1",
		Protocol:  "rdp",
		Data:      payload,
	}, nil)
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

type fakeSSHCredentialResolver struct {
	auth    SSHAuth
	request SSHCredentialRequest
}

func (f *fakeSSHCredentialResolver) ResolveSSHCredential(
	_ context.Context,
	request SSHCredentialRequest,
) (SSHAuth, error) {
	f.request = request
	return f.auth, nil
}
