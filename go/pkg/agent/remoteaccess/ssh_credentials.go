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
	"os"
	"strings"
)

var (
	ErrSSHCredentialFileUnavailable = errors.New("agent-local ssh credential file is unavailable")
	ErrSSHCredentialFileInsecure    = errors.New("agent-local ssh credential file permissions are too broad")
	ErrSSHCredentialNotFound        = errors.New("agent-local ssh credential not found")
)

// FileSSHCredentialResolver resolves credentials from an agent-local JSON file.
type FileSSHCredentialResolver struct {
	Path string
}

type fileSSHCredentialPayload struct {
	Version     int                 `json:"version,omitempty"`
	Credentials []fileSSHCredential `json:"credentials"`
}

type fileSSHCredential struct {
	CredentialRef string `json:"credential_ref"`
	Host          string `json:"host,omitempty"`
	Port          int    `json:"port,omitempty"`
	Username      string `json:"username,omitempty"`
	Password      string `json:"password,omitempty"`
	PrivateKey    string `json:"private_key,omitempty"`
	Passphrase    string `json:"passphrase,omitempty"`
}

// ResolveSSHCredential returns the agent-local credential matching the scoped
// session request. The file must be readable only by the agent user.
func (r FileSSHCredentialResolver) ResolveSSHCredential(
	_ context.Context,
	request SSHCredentialRequest,
) (SSHAuth, error) {
	path := strings.TrimSpace(r.Path)
	if path == "" {
		return SSHAuth{}, ErrSSHCredentialFileUnavailable
	}
	if strings.TrimSpace(request.CredentialRef) == "" {
		return SSHAuth{}, ErrSSHCredentialRefRequired
	}

	payload, err := loadSSHCredentialFile(path)
	if err != nil {
		return SSHAuth{}, err
	}

	for _, credential := range payload.Credentials {
		if credential.matches(request) {
			return credential.auth(), nil
		}
	}

	return SSHAuth{}, ErrSSHCredentialNotFound
}

func loadSSHCredentialFile(path string) (fileSSHCredentialPayload, error) {
	info, err := os.Stat(path)
	if err != nil {
		return fileSSHCredentialPayload{}, err
	}
	if info.Mode().Perm()&0o077 != 0 {
		return fileSSHCredentialPayload{}, fmt.Errorf("%w: %s must be readable only by the agent user", ErrSSHCredentialFileInsecure, path)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return fileSSHCredentialPayload{}, err
	}

	var payload fileSSHCredentialPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return fileSSHCredentialPayload{}, err
	}

	return payload, nil
}

func (c fileSSHCredential) matches(request SSHCredentialRequest) bool {
	if strings.TrimSpace(c.CredentialRef) != strings.TrimSpace(request.CredentialRef) {
		return false
	}
	if strings.TrimSpace(c.Host) != "" && strings.TrimSpace(c.Host) != strings.TrimSpace(request.Target.Host) {
		return false
	}
	if c.Port > 0 && c.Port != request.Target.Port {
		return false
	}
	if strings.TrimSpace(request.Username) != "" &&
		strings.TrimSpace(c.Username) != "" &&
		strings.TrimSpace(c.Username) != strings.TrimSpace(request.Username) {
		return false
	}
	return true
}

func (c fileSSHCredential) auth() SSHAuth {
	return SSHAuth{
		Username:   strings.TrimSpace(c.Username),
		Password:   c.Password,
		PrivateKey: c.PrivateKey,
		Passphrase: c.Passphrase,
	}
}
