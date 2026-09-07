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
	"fmt"
	"time"
)

const (
	ProtocolSSH = "ssh"

	SSHCredentialModeUserPresent    = "user_present"
	SSHCredentialModeSSHCertificate = "ssh_certificate"
)

var (
	ErrUnsupportedSSHProtocol       = errors.New("unsupported remote access ssh protocol")
	ErrInvalidSSHOpenPayload        = errors.New("invalid ssh open payload")
	ErrUnsupportedSSHCredentialMode = errors.New("unsupported ssh credential mode")
	ErrSSHCertificateRequired       = errors.New("ssh certificate is required")
	ErrSSHOpenSessionMismatch       = errors.New("ssh open payload session_id does not match frame")
	ErrSSHOpenProtocolMismatch      = errors.New("ssh open payload protocol does not match frame")
	ErrSSHOpenAgentMismatch         = errors.New("ssh open payload agent_id does not match frame metadata")
	ErrSSHOpenGatewayMismatch       = errors.New("ssh open payload gateway_id does not match frame metadata")
)

// SSHOpenPayload is the JSON payload carried by an SSH open frame.
type SSHOpenPayload struct {
	Protocol           string              `json:"protocol,omitempty"`
	SessionID          string              `json:"session_id,omitempty"`
	AgentID            string              `json:"agent_id,omitempty"`
	GatewayID          string              `json:"gateway_id,omitempty"`
	Target             SSHTarget           `json:"target"`
	SSH                SSHAuth             `json:"ssh,omitempty"`
	CredentialMode     string              `json:"credential_mode,omitempty"`
	TerminalType       string              `json:"terminal_type,omitempty"`
	TimeoutMS          int                 `json:"timeout_ms,omitempty"`
	SSHHostKeyPolicy   string              `json:"ssh_host_key_policy,omitempty"`
	SSHHostKeyApproval *SSHHostKeyApproval `json:"ssh_host_key_approval,omitempty"`
}

// SSHOpenOptions configures frame-to-PTY SSH opening.
type SSHOpenOptions struct {
	Dial           SSHDialer
	KnownHostsPath string
}

// OpenSSHFromFrame opens an SSH PTY from a generic remote-access open frame.
func OpenSSHFromFrame(ctx context.Context, frame Frame, opts SSHOpenOptions) (PTY, error) {
	cfg, err := SSHConfigFromOpenFrame(frame)
	if err != nil {
		return nil, err
	}
	cfg.KnownHostsPath = opts.KnownHostsPath

	return OpenSSHPTY(ctx, cfg, opts.Dial)
}

// SSHConfigFromOpenFrame decodes and validates an SSH open frame.
func SSHConfigFromOpenFrame(frame Frame) (SSHConfig, error) {
	if frame.Protocol != "" && frame.Protocol != ProtocolSSH {
		return SSHConfig{}, fmt.Errorf("%w %q", ErrUnsupportedSSHProtocol, frame.Protocol)
	}

	var payload SSHOpenPayload
	if err := json.Unmarshal(frame.Data, &payload); err != nil {
		return SSHConfig{}, fmt.Errorf("%w: %w", ErrInvalidSSHOpenPayload, err)
	}
	if err := validateSSHOpenPayloadScope(frame, payload); err != nil {
		return SSHConfig{}, err
	}

	mode := payload.CredentialMode
	if mode == "" {
		mode = SSHCredentialModeUserPresent
	}

	auth, err := sshAuthForOpenPayload(payload, mode)
	if err != nil {
		return SSHConfig{}, err
	}

	return SSHConfig{
		Target:             payload.Target,
		Auth:               auth,
		TerminalType:       payload.TerminalType,
		Cols:               frame.Cols,
		Rows:               frame.Rows,
		Timeout:            time.Duration(payload.TimeoutMS) * time.Millisecond,
		SSHHostKeyPolicy:   payload.SSHHostKeyPolicy,
		SSHHostKeyApproval: payload.SSHHostKeyApproval,
	}, nil
}

func validateSSHOpenPayloadScope(frame Frame, payload SSHOpenPayload) error {
	if payload.Protocol != "" && payload.Protocol != ProtocolSSH {
		return fmt.Errorf("%w %q", ErrUnsupportedSSHProtocol, payload.Protocol)
	}
	if frame.Protocol != "" && payload.Protocol != "" && payload.Protocol != frame.Protocol {
		return fmt.Errorf("%w %q != %q", ErrSSHOpenProtocolMismatch, payload.Protocol, frame.Protocol)
	}
	if payload.SessionID != "" && payload.SessionID != frame.SessionID {
		return fmt.Errorf("%w %q != %q", ErrSSHOpenSessionMismatch, payload.SessionID, frame.SessionID)
	}
	if payload.AgentID != "" && frame.Metadata != nil {
		if expected := frame.Metadata["agent_id"]; expected != "" && payload.AgentID != expected {
			return fmt.Errorf("%w %q != %q", ErrSSHOpenAgentMismatch, payload.AgentID, expected)
		}
	}
	if payload.GatewayID != "" && frame.Metadata != nil {
		if expected := frame.Metadata["gateway_id"]; expected != "" && payload.GatewayID != expected {
			return fmt.Errorf("%w %q != %q", ErrSSHOpenGatewayMismatch, payload.GatewayID, expected)
		}
	}
	return nil
}

func sshAuthForOpenPayload(
	payload SSHOpenPayload,
	mode string,
) (SSHAuth, error) {
	switch mode {
	case SSHCredentialModeUserPresent:
		return payload.SSH, nil
	case SSHCredentialModeSSHCertificate:
		if payload.SSH.Certificate == "" {
			return SSHAuth{}, ErrSSHCertificateRequired
		}
		if payload.SSH.PrivateKey == "" {
			return SSHAuth{}, ErrSSHCertificateRequiresKey
		}
		return payload.SSH, nil
	default:
		return SSHAuth{}, fmt.Errorf("%w %q", ErrUnsupportedSSHCredentialMode, mode)
	}
}
