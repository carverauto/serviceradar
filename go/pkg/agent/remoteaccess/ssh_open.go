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

	SSHCredentialModeUserPresent = "user_present"
	SSHCredentialModeAgentLocal  = "agent_local"
)

var (
	ErrUnsupportedSSHProtocol       = errors.New("unsupported remote access ssh protocol")
	ErrInvalidSSHOpenPayload        = errors.New("invalid ssh open payload")
	ErrUnsupportedSSHCredentialMode = errors.New("unsupported ssh credential mode")
	ErrSSHCredentialResolverMissing = errors.New("ssh credential resolver is required for agent-local credentials")
	ErrSSHCredentialRefRequired     = errors.New("ssh credential ref is required for agent-local credentials")
)

// SSHOpenPayload is the JSON payload carried by an SSH open frame.
type SSHOpenPayload struct {
	Target           SSHTarget `json:"target"`
	SSH              SSHAuth   `json:"ssh,omitempty"`
	CredentialMode   string    `json:"credential_mode,omitempty"`
	CredentialRef    string    `json:"credential_ref,omitempty"`
	TerminalType     string    `json:"terminal_type,omitempty"`
	TimeoutMS        int       `json:"timeout_ms,omitempty"`
	SSHHostKeyPolicy string    `json:"ssh_host_key_policy,omitempty"`
}

// SSHCredentialRequest scopes an agent-local credential lookup.
type SSHCredentialRequest struct {
	SessionID     string
	CredentialRef string
	Target        SSHTarget
	Username      string
}

// SSHCredentialResolver resolves agent-local credentials without exposing them
// to the ServiceRadar control plane.
type SSHCredentialResolver interface {
	ResolveSSHCredential(context.Context, SSHCredentialRequest) (SSHAuth, error)
}

// SSHOpenOptions configures frame-to-PTY SSH opening.
type SSHOpenOptions struct {
	CredentialResolver SSHCredentialResolver
	Dial               SSHDialer
}

// OpenSSHFromFrame opens an SSH PTY from a generic remote-access open frame.
func OpenSSHFromFrame(ctx context.Context, frame Frame, opts SSHOpenOptions) (PTY, error) {
	cfg, err := SSHConfigFromOpenFrame(ctx, frame, opts.CredentialResolver)
	if err != nil {
		return nil, err
	}

	return OpenSSHPTY(ctx, cfg, opts.Dial)
}

// SSHConfigFromOpenFrame decodes and validates an SSH open frame.
func SSHConfigFromOpenFrame(
	ctx context.Context,
	frame Frame,
	resolver SSHCredentialResolver,
) (SSHConfig, error) {
	if frame.Protocol != "" && frame.Protocol != ProtocolSSH {
		return SSHConfig{}, fmt.Errorf("%w %q", ErrUnsupportedSSHProtocol, frame.Protocol)
	}

	var payload SSHOpenPayload
	if err := json.Unmarshal(frame.Data, &payload); err != nil {
		return SSHConfig{}, fmt.Errorf("%w: %w", ErrInvalidSSHOpenPayload, err)
	}

	mode := payload.CredentialMode
	if mode == "" {
		mode = SSHCredentialModeUserPresent
	}

	auth, err := sshAuthForOpenPayload(ctx, frame, payload, mode, resolver)
	if err != nil {
		return SSHConfig{}, err
	}

	return SSHConfig{
		Target:           payload.Target,
		Auth:             auth,
		TerminalType:     payload.TerminalType,
		Cols:             frame.Cols,
		Rows:             frame.Rows,
		Timeout:          time.Duration(payload.TimeoutMS) * time.Millisecond,
		SSHHostKeyPolicy: payload.SSHHostKeyPolicy,
	}, nil
}

func sshAuthForOpenPayload(
	ctx context.Context,
	frame Frame,
	payload SSHOpenPayload,
	mode string,
	resolver SSHCredentialResolver,
) (SSHAuth, error) {
	switch mode {
	case SSHCredentialModeUserPresent:
		return payload.SSH, nil
	case SSHCredentialModeAgentLocal:
		if payload.CredentialRef == "" {
			return SSHAuth{}, ErrSSHCredentialRefRequired
		}
		if resolver == nil {
			return SSHAuth{}, ErrSSHCredentialResolverMissing
		}

		resolved, err := resolver.ResolveSSHCredential(ctx, SSHCredentialRequest{
			SessionID:     frame.SessionID,
			CredentialRef: payload.CredentialRef,
			Target:        payload.Target,
			Username:      payload.SSH.Username,
		})
		if err != nil {
			return SSHAuth{}, err
		}

		return mergeSSHAuth(payload.SSH, resolved), nil
	default:
		return SSHAuth{}, fmt.Errorf("%w %q", ErrUnsupportedSSHCredentialMode, mode)
	}
}

func mergeSSHAuth(primary, fallback SSHAuth) SSHAuth {
	if primary.Username == "" {
		primary.Username = fallback.Username
	}
	if primary.Password == "" {
		primary.Password = fallback.Password
	}
	if primary.PrivateKey == "" {
		primary.PrivateKey = fallback.PrivateKey
	}
	if primary.Passphrase == "" {
		primary.Passphrase = fallback.Passphrase
	}
	return primary
}
